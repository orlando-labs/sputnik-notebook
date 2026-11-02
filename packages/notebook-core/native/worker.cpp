#include "notebook/core/worker/main.h"
#include "notebook/core/worker/telemetry.h"
#include "notebook/audio_components.h"
#include "notebook/core/worker/process.h"
#include "notebook/core/worker/presentation.h"
#include "notebook/core/worker/grants.h"
#include "notebook/core/worker/environment.h"
#include "notebook/renderers.h"
#include "tools/isputnik/project_session.h"
#include "tools/isputnik/dependencies.h"
#include "tools/isputnik/dispatch.h"
#include "runtime/context.h"
#include "runtime/audio_system.h"
#include "package/registry_json.h"
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <fstream>
#include <sstream>
#include <set>
#include <mutex>
#include <poll.h>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

using namespace sputnik::notebook;
using namespace sputnik::notebook::worker;
using namespace std::chrono_literals;

namespace {
// The control receiver touches only this small run ledger, never Session,
// RuntimeWorld or heap locks. Remember early Stop across channel reordering.
class Control {
public:
  explicit Control(std::uint64_t generation) : generation_(generation) {
    configure_socket(kControlFd);
    thread_ = std::thread([this] { listen(); });
  }
  ~Control() {
    done_.store(true);
    thread_.join();
    ::close(kControlFd);
  }
  sputnik::runtime::RuntimeRunCancellation begin(std::uint64_t id) {
    std::lock_guard<std::mutex> lock(mutex_);
    active_id_ = id;
    active_ = std::make_shared<sputnik::runtime::RuntimeRunState>();
    if (id <= cancelled_through_) active_->request_cancel();
    return active_;
  }
  bool finish() {
    std::lock_guard<std::mutex> lock(mutex_);
    const bool cancelled = active_ && active_->cancelled();
    active_.reset(); active_id_ = 0;
    return cancelled;
  }
private:
  void listen() noexcept {
    while (!done_.load()) {
      pollfd fds[2]{{kControlFd, POLLIN, 0}, {kDataFd, 0, 0}};
      const int rc = ::poll(fds, 2, 50);
      // Parent disconnect is not a graceful Stop. No host remains to own the
      // world; terminate even if the execution thread is stuck in native code.
      if (rc > 0 && (fds[1].revents & (POLLHUP | POLLERR | POLLNVAL))) {
        try { terminate_process_session(::getpid()); } catch (...) {}
        std::_Exit(0);
      }
      if (rc <= 0 || !(fds[0].revents & POLLIN)) continue;
      char bytes[64];
      const auto n = ::recv(kControlFd, bytes, sizeof(bytes), 0);
      if (n <= 0) continue;
      try {
        const auto message = decode(std::string(bytes, static_cast<std::size_t>(n)));
        if (message.kind != Kind::Stop || message.generation != generation_ ||
            message.request == 0 || !message.fields.empty()) continue;
        sputnik::runtime::RuntimeRunCancellation active;
        {
          std::lock_guard<std::mutex> lock(mutex_);
          cancelled_through_ = std::max(cancelled_through_, message.request);
          if (active_ && active_id_ <= cancelled_through_) active = active_;
        }
        if (active) active->request_cancel();
      } catch (...) { /* Malformed control cannot affect an active run. */ }
    }
  }
  const std::uint64_t generation_;
  std::atomic<bool> done_{false};
  std::mutex mutex_;
  std::uint64_t active_id_ = 0, cancelled_through_ = 0;
  sputnik::runtime::RuntimeRunCancellation active_;
  std::thread thread_;
};
bool boolean(const std::string &value) {
  if (value == "1") return true;
  if (value == "0") return false;
  throw ProtocolError("expected worker boolean 0 or 1");
}
void arity(const Message &message, std::size_t count) {
  if (message.fields.size() != count) throw ProtocolError("invalid worker command arguments");
}
// Producers only replace immutable entries in a bounded store. One reporter
// sends coalesced snapshots; neither the VM nor its callbacks write to IPC.
// Stop has its independent channel even if the UI stops draining image data.
class LiveReporter {
public:
  LiveReporter(Session &session, Channel &channel, std::mutex &send_mutex, std::uint64_t generation,
               std::uint64_t request, const std::map<CellId, std::uint64_t> &revisions,
               sputnik::runtime::RuntimeRunCancellation token)
      : store(std::make_shared<sputnik::runtime::NotebookLiveStore>()), channel_(channel),
        send_mutex_(send_mutex), generation_(generation), request_(request),
        revisions_(revisions), token_(std::move(token)), session_(session), previous_(session.output_observer) {
    previous_finished_ = session_.execution_finished;
    session_.execution_finished = [this](CellId id) {
      if (previous_finished_) previous_finished_(id);
      finish_cell(id);
    };
    session_.output_observer = [this](CellId id, auto out, auto err) {
      if (previous_) previous_(id, out, err);
      std::lock_guard<std::mutex> lock(telemetry_mutex_);
      if (id && revisions_.count(id)) writers_[id] = Writers{out, err};
      const auto now = sputnik::runtime::NotebookLiveStore::monotonic_millis();
      for (auto &[_, value] : timings_) if (value.running) { value.elapsed = now - value.start; value.running = false; }
      if (id && revisions_.count(id)) timings_[id] = Timing{now, 0, true};
      executing_cell_.store(id);
    };
    thread_ = std::thread([this] {
      try {
        std::unique_lock<std::mutex> lock(mutex_);
        while (!done_) {
          wake_.wait_for(lock, 100ms, [&] { return done_; });
          lock.unlock(); flush(); lock.lock();
        }
      } catch (...) { failure_ = std::current_exception(); token_->request_cancel(); }
    });
  }
  ~LiveReporter() { session_.output_observer = std::move(previous_); session_.execution_finished = std::move(previous_finished_); join(); store->close(); }
  void end_evaluation() { finish_cell(executing_cell_.load()); executing_cell_.store(0); }
  void finish(Session &session) {
    store->finish_audio_streams();
    join();
    if (failure_) std::rethrow_exception(failure_);
    // Even a run that finishes before the reporter thread starts must emit
    // its terminal telemetry. Producers have drained and join owns flush now.
    finishing_ = true; flush();
    session.run_telemetry = latest_.telemetry;
    for (const auto &cell : latest_.cells)
      for (auto &target : session.cells) if (target.id == cell.id) {
        target.progress = cell.progress;
        target.charts = cell.charts;
        target.images = cell.images;
        if (target.ok || !cell.audio.empty()) target.audio = cell.audio;
        target.audio_controls = cell.audio_controls;
        if (cell.elapsed_ms) target.elapsed_ms = cell.elapsed_ms;
        if (cell.stopwatches_updated) target.stopwatches = cell.stopwatches;
        // Live output is explicitly nontransactional. On cancellation retain
        // the last accepted frame, labelled stale by the cell outcome in UI.
        if (!target.ok && !cell.displays.empty()) target.displays = cell.displays;
        break;
      }
  }
  std::shared_ptr<sputnik::runtime::NotebookLiveStore> store;
private:
  struct Writers { std::shared_ptr<sputnik::runtime::RuntimeTextWriter> out, err; std::uint64_t out_revision = 0, err_revision = 0; };
  std::map<CellId, Writers> writers_;
  ProcessTelemetry process_usage_;
  std::uint64_t last_usage_ms_ = 0;
  struct Timing { std::uint64_t start, elapsed; bool running; };
  void finish_cell(CellId id) {
    std::lock_guard<std::mutex> lock(telemetry_mutex_);
    const auto found = timings_.find(id);
    if (found != timings_.end() && found->second.running) {
      found->second.elapsed = sputnik::runtime::NotebookLiveStore::monotonic_millis() - found->second.start;
      found->second.running = false;
    }
    if (executing_cell_.load() == id) executing_cell_.store(0);
  }
  void join() noexcept {
    { std::lock_guard<std::mutex> lock(mutex_); done_ = true; }
    wake_.notify_one();
    if (thread_.joinable()) thread_.join();
  }
  void flush() {
    sputnik::runtime::NotebookLiveStore::Delta delta;
    auto sequence = sent_;
    const auto executing = executing_cell_.load();
    const bool changed = executing != latest_.executing_cell;
    const bool store_changed = store->changes_since(&sequence, &delta);
    Presentation next; next.telemetry_updated = false;
    next.executing_cell = executing;
    auto cell_for = [&](CellId id) -> CellPresentation & {
      auto found = std::find_if(next.cells.begin(), next.cells.end(), [&](const auto &c) { return c.id == id; });
      if (found == next.cells.end()) {
        CellPresentation cell; cell.id = id; cell.source_revision = revisions_.at(id);
        cell.displays_updated = cell.progress_updated = cell.charts_updated = cell.images_updated = cell.audio_updated = cell.audio_controls_updated = cell.output_updated = false;
        next.cells.push_back(std::move(cell)); found = std::prev(next.cells.end());
      }
      return *found;
    };
    for (auto cell : delta.resets) if (revisions_.count(cell)) {
      auto &value = cell_for(cell); value.displays_updated = value.progress_updated = value.charts_updated = value.images_updated = true;
      value.stopwatches_updated = true; value.output_updated = true;
      value.charts_reset = true; value.audio_updated = value.audio_reset = value.audio_controls_updated = true;
    }
    for (const auto &event : delta.events) {
      const auto revision = revisions_.find(event.cell_id);
      if (revision == revisions_.end()) continue; // environment is not a cell
      auto &cell = cell_for(event.cell_id);
      if (event.kind == sputnik::runtime::NotebookLiveEventKind::Progress) {
        cell.progress_updated = true; cell.progress.push_back(event);
      } else if (event.kind == sputnik::runtime::NotebookLiveEventKind::Figure) {
        cell.displays_updated = true; cell.displays.push_back(event.display);
      } else if (event.kind == sputnik::runtime::NotebookLiveEventKind::Images) {
        cell.images_updated = true; cell.images.push_back(event);
      } else if (event.kind == sputnik::runtime::NotebookLiveEventKind::Stopwatch) {
        cell.stopwatches_updated = true; cell.stopwatches.push_back(event);
      } else if (event.kind == sputnik::runtime::NotebookLiveEventKind::AudioControl) {
        cell.audio_controls_updated = true; cell.audio_controls.push_back(event);
      } else if (event.kind == sputnik::runtime::NotebookLiveEventKind::Audio) {
        cell.audio_updated = true; cell.audio.push_back(event);
      } else { cell.charts_updated = true; cell.charts.push_back(event); }
    }
    const auto now = sputnik::runtime::NotebookLiveStore::monotonic_millis();
    bool ticking = false;
    auto tasks = token_->telemetry();
    if (finishing_ || tasks.revision != latest_.telemetry.revision || now - last_usage_ms_ >= 500) {
      next.telemetry = std::move(tasks); next.telemetry_updated = true;
      process_usage_.sample(next.telemetry, now); last_usage_ms_ = now;
    }
    {
      std::lock_guard<std::mutex> lock(telemetry_mutex_);
      for (auto &[id, writers] : writers_) {
        const auto out_revision = writers.out ? writers.out->revision() : 0, err_revision = writers.err ? writers.err->revision() : 0;
        if (out_revision == writers.out_revision && err_revision == writers.err_revision && !finishing_) continue;
        auto &cell = cell_for(id); cell.output_updated = true; cell.output_revision = out_revision + err_revision;
        if (writers.out) cell.output = writers.out->events();
        if (writers.err) { auto events = writers.err->events(); cell.output.insert(cell.output.end(), events.begin(), events.end()); }
        std::stable_sort(cell.output.begin(), cell.output.end(), [](const auto &a, const auto &b) { return a.order < b.order; });
        writers.out_revision = out_revision; writers.err_revision = err_revision;
      }
    }
    {
      std::lock_guard<std::mutex> lock(telemetry_mutex_);
      for (const auto &[id, timing] : timings_) {
        auto &cell = cell_for(id);
        cell.elapsed_ms = timing.running ? now - timing.start : timing.elapsed;
        cell.timing_running = timing.running;
        ticking |= timing.running;
      }
    }
    for (const auto &old : latest_.cells) if (std::any_of(old.stopwatches.begin(), old.stopwatches.end(), [](const auto &timer) { return !timer.done; })) {
      auto &cell = cell_for(old.id);
      if (!cell.stopwatches_updated) { cell.stopwatches = old.stopwatches; cell.stopwatches_updated = true; }
    }
    for (auto &cell : next.cells) for (auto &timer : cell.stopwatches) if (!timer.done) {
      timer.elapsed_ms += now >= timer.timestamp_ms ? now - timer.timestamp_ms : 0;
      timer.timestamp_ms = now; ticking = true;
    }
    if (!store_changed && !changed && !ticking && !finishing_ && !next.telemetry_updated && std::none_of(next.cells.begin(), next.cells.end(), [](const auto &c) { return c.output_updated; })) return;
    if (changed || !next.cells.empty() || !latest_.cells.empty()) {
      std::lock_guard<std::mutex> send(send_mutex_);
      send_presentation(channel_, generation_, request_, next, 2s, true);
    }
    merge_live_presentation(latest_, std::move(next)); sent_ = sequence;
  }
  Channel &channel_;
  std::mutex &send_mutex_;
  std::uint64_t generation_, request_, sent_ = 0;
  std::map<CellId, std::uint64_t> revisions_;
  sputnik::runtime::RuntimeRunCancellation token_;
  Session &session_;
  SessionOutputObserver previous_;
  std::function<void(CellId)> previous_finished_;
  std::mutex telemetry_mutex_;
  std::map<CellId, Timing> timings_;
  bool finishing_ = false;
  std::atomic<CellId> executing_cell_{0};
  Presentation latest_;
  std::thread thread_;
  std::mutex mutex_;
  std::condition_variable wake_;
  bool done_ = false;
  std::exception_ptr failure_;
};
std::size_t cell_index(const Session &session, const std::string &text) {
  const auto id = parse_id(text);
  for (std::size_t i = 0; i < session.cells.size(); ++i)
    if (session.cells[i].id == id) return i;
  throw ProtocolError("unknown worker cell");
}
int serve(std::uint64_t generation, std::vector<sputnik::capability::CapabilityRequest> grants) {
  Channel data(kDataFd);
  Control control(generation);
  std::optional<LoadedProject> project;
  Session session;
  std::map<CellId, std::uint64_t> source_revisions;
  std::set<std::string> pending_inputs;
  RuntimePumpDispatch watch_dispatch;
  bool watch_paused = false;
  register_builtin_renderers();
  data.send({Kind::Ready, generation, 0, {}}, 2s);
  std::uint64_t previous = 0;
  while (true) {
    const auto message = data.receive(1s);
    if (!message) continue;
    if (message->generation != generation || message->request <= previous)
      throw ProtocolError("stale worker command");
    previous = message->request;
    try {
      if (message->kind == Kind::Shutdown) {
        arity(*message, 0);
        data.send({Kind::Result, generation, previous, {}}, 2s);
        return 0;
      }
      if (message->kind == Kind::Load || message->kind == Kind::LoadModule) {
        const bool module = message->kind == Kind::LoadModule;
        if (module ? message->fields.size() != 4 : (message->fields.size() < 2 || message->fields.size() > 4))
          throw ProtocolError("Load expects path, sheet and optional explicit native trust");
        const auto unrestricted = [&](const char *name) {
          return std::any_of(grants.begin(), grants.end(), [&](const auto &grant) {
            return grant.name == name && grant.target == "*";
          });
        };
        const bool trusted = (message->fields.size() >= 3 && boolean(message->fields[2])) ||
                             (unrestricted("ffi.call") && unrestricted("ffi.load"));
        // Read-only bootstrap. Reload in a fresh worker instead of destroying
        // a possibly live world under an inert document-open operation.
        if (project) throw ProtocolError("worker already has a sheet");
        auto candidate = load_project(message->fields[0]);
        if (module) {
          const auto source = load_project_module(candidate, message->fields[1]);
          load_project_module_into_session(&session, candidate, source);
          session.cells[0].id = parse_id(message->fields[3]);
        } else load_project_into_session(&session, candidate, message->fields[1]);
        if (!module && message->fields.size() == 4) {
          const std::filesystem::path packages(message->fields[3]);
          if (!packages.is_absolute() || packages.filename() != "packages")
            throw ProtocolError("package directory must be an absolute packages directory");
          if (::setenv("SPUTNIK_NOTEBOOK_PACKAGE_HOME", packages.c_str(), 1))
            throw ProtocolError("cannot configure notebook package home");
        }
        session.runtime_capability_grants = grants;
        for (const auto &cell : session.cells) source_revisions[cell.id] = 0;
        project = std::move(candidate);
        if (trusted) for (const auto *name : {"ffi.call", "ffi.load", "fs.read"}) {
          sputnik::capability::CapabilityRequest grant;
          if (!sputnik::capability::parse_cli_grant(name, &grant)) throw ProtocolError("invalid native host grant");
          session.runtime_capability_grants.push_back(std::move(grant));
        }
        session.prepare_runtime = [&, trusted](const auto &module) {
          load_prepared_native_dependencies(*project, module, trusted);
        };
      } else {
        if (!project) throw ProtocolError("load a sheet before executing");
        if (message->kind == Kind::Poll) {
          arity(*message, 0);
          if (session.activity_waiter().wait(0ms).runtime_ready) watch_dispatch.notify_runtime();
          // Hints are coalesced wakeups, not unconsumed watch events. An
          // explicit Run/Inputs may already have handled their source.
          if (!has_pending_runtime_events(session)) watch_dispatch = {};
          data.send({Kind::Result, generation, previous,
                     {!watch_paused && watch_dispatch.due(RuntimePumpDispatch::Clock::now()) ? "1" : "0"}}, 2s);
          continue;
        } else if (message->kind == Kind::Sync) {
          const auto ordinary = session.module_editor ? 3U : 2U;
          if (message->fields.size() != ordinary && message->fields.size() != ordinary + 1)
            throw ProtocolError("invalid synchronized document fields");
          // Inert host draft/structure synchronization. Never save these bytes
          // or replace the runtime; evaluation reconciles the kernel graph.
          auto document = parse_project_document(message->fields[0]);
          // Core may advance an immutable asset revision without replacing the
          // initialized world. Desktop clients continue to send the original form.
          auto directory = project->directory;
          if (message->fields.size() == ordinary + 1) {
            directory = std::filesystem::canonical(message->fields.back());
            const auto checked = load_project(directory);
            (void)checked;
          }
          const auto image_inputs = load_project_image_inputs(document, directory, session.project_sheet_id);
          const auto audio_inputs = load_project_audio_inputs(document, directory, session.project_sheet_id);
          const bool stale = boolean(message->fields[1]);
          const auto sheet = std::find_if(document.sheets.begin(), document.sheets.end(),
              [&](const auto &s) { return s.id == session.project_sheet_id; });
          ProjectSheet module_sheet;
          if (session.module_editor) {
            // The editor buffer travels in Sync, never through a temporary
            // source file or a save to the user's module.
            ProjectCell source;
            source.id = session.cells.at(0).id;
            source.kind = "code"; source.mode = CellMode::Manual;
            source.source = message->fields[2];
            module_sheet.cells.push_back(std::move(source));
          } else if (sheet == document.sheets.end()) throw ProtocolError("missing synchronized sheet");
          std::vector<Cell> cells;
          std::map<CellId, std::uint64_t> revisions;
          for (const auto &source : (session.module_editor ? module_sheet.cells : sheet->cells)) {
            const auto old = std::find_if(session.cells.begin(), session.cells.end(),
                [&](const auto &c) { return c.id == source.id && c.kind == source.kind; });
            Cell cell = old == session.cells.end() ? Cell{} : *old;
            for (const auto &[id, input] : *image_inputs) {
              const bool changed = !session.project_images || !session.project_images->count(id) ||
                  session.project_images->at(id).revision != input.revision;
              if (changed) {
                const auto channel = id;
                cell.images.erase(std::remove_if(cell.images.begin(), cell.images.end(), [&](const auto &images) { return images.id == channel; }), cell.images.end());
                if (cell.kind == "code") cell.dirty = true;
              }
              if (session.project_images && session.project_images->count(id) &&
                  session.project_images->at(id).readable != input.readable)
                cell.dirty = true;
            }
            const bool watch = source.kind == "code" && source.mode == CellMode::Watch;
            if (cell.source != source.source || cell.watch != watch) cell.dirty = true;
            cell.id = source.id; cell.kind = source.kind;
            cell.source = source.source; cell.formatting = source.formatting; cell.watch = watch;
            if (cell.kind != "code") cell.dirty = false;
            cells.push_back(std::move(cell)); revisions.emplace(source.id, previous);
            reserve_cell_id(source.id);
          }
          auto inputs = std::make_shared<sputnik::runtime::NotebookInputSnapshot>(*project_input_defaults(document));
          session.runtime_capability_grants.erase(std::remove_if(session.runtime_capability_grants.begin(), session.runtime_capability_grants.end(),
            [](const auto &grant) { return grant.reason == "managed File Input"; }), session.runtime_capability_grants.end());
          const auto managed = std::filesystem::current_path() / "managed-inputs";
          std::set<std::string> retained_files;
          // The remote contract carries an immutable relative identity. Only
          // the worker resolves a managed File Input to a host filesystem path.
          std::function<void(const std::vector<ProjectComponent> &)> files = [&](const auto &components) {
            for (const auto &c : components) {
              if (c.panels) for (const auto &panel : *c.panels) files(panel.components);
              if (c.kind != "file_input" || message->fields.size() != ordinary + 1) continue;
              auto &value = inputs->at(c.input);
              const auto relative = std::get_if<std::string>(&value);
              if (!relative || relative->rfind("inputs/web_", 0)) continue;
              const std::filesystem::path member(*relative);
              if (member.is_absolute() || member.filename() != relative->substr(7) || relative->find("..") != std::string::npos)
                throw ProtocolError("invalid managed File Input identity");
              const auto folder = std::filesystem::symlink_status(directory / "inputs");
              const auto file = std::filesystem::symlink_status(directory / member);
              if (!std::filesystem::is_directory(folder) || !std::filesystem::is_regular_file(file))
                throw ProtocolError("managed File Input unavailable");
              std::filesystem::create_directories(managed);
              if (!std::filesystem::is_directory(std::filesystem::symlink_status(managed))) throw ProtocolError("invalid managed input directory");
              const auto destination = managed / member.filename();
              if (std::filesystem::exists(std::filesystem::symlink_status(destination))) {
                if (!std::filesystem::is_regular_file(std::filesystem::symlink_status(destination)) || !std::filesystem::equivalent(destination, directory / member))
                  throw ProtocolError("managed input identity changed");
              } else std::filesystem::create_hard_link(directory / member, destination);
              retained_files.insert(member.filename().string());
              value = destination.string();
            }
          };
          for (const auto &b : document.boards) files(b.components);
          if (message->fields.size() == ordinary + 1) {
            // Grant the private immutable-input namespace from the first world
            // creation, including an initially empty input. Future acceptance
            // does not widen an already initialized world's capabilities.
            sputnik::capability::CapabilityRequest grant;
            grant.name = "fs.read"; grant.target = managed.string(); grant.reason = "managed File Input";
            session.runtime_capability_grants.push_back(std::move(grant));
          }
          if (std::filesystem::exists(managed)) {
            if (!std::filesystem::is_directory(std::filesystem::symlink_status(managed))) throw ProtocolError("invalid managed input directory");
            for (const auto &entry : std::filesystem::directory_iterator(managed))
              if (!retained_files.count(entry.path().filename().string())) {
                if (!std::filesystem::is_regular_file(entry.symlink_status()) || entry.path().filename().string().rfind("web_", 0))
                  throw ProtocolError("unexpected managed input entry");
                std::filesystem::remove(entry.path());
              }
          }
          if (session.project_inputs) for (const auto &[id, value] : *inputs) {
            const auto old = session.project_inputs->find(id);
            if (old == session.project_inputs->end() || old->second != value) pending_inputs.insert(id);
          }
          if (session.project_inputs) for (const auto &[id, value] : *session.project_inputs)
            if (!inputs->count(id)) pending_inputs.insert(id);
          project->document = std::move(document);
          project->directory = directory;
          session.package_search_directory = directory.string();
          if (session.module_editor) {
            // Filesystem module mappings come from the checked disk manifest;
            // Sync's editable sheet/input snapshot is not a persisted manifest.
            session.bundled_modules = load_project_bundled_sources(load_project(project->directory));
            session.bundled_modules.erase(std::remove_if(session.bundled_modules.begin(), session.bundled_modules.end(),
                [&](const auto &m) { return m.id == session.project_module_id; }), session.bundled_modules.end());
            for (auto &m : session.bundled_modules) m.auto_import = false;
          }
          session.project_inputs = inputs;
          session.project_images = image_inputs;
          session.project_audio_inputs = audio_inputs;
          session.project_audio = project_audio_components(project->document, session.project_sheet_id);
          session.cells.swap(cells); source_revisions.swap(revisions);
          session.environment_stale = stale;
          session.selected = std::min(session.selected, session.cells.empty() ? 0U : session.cells.size() - 1);
        } else if (message->kind == Kind::Source) {
          arity(*message, 3);
          const auto index = cell_index(session, message->fields[0]);
          const bool watch = boolean(message->fields[2]);
          session.cells[index].source = message->fields[1];
          session.cells[index].watch = watch;
          session.cells[index].dirty = true;
          source_revisions[session.cells[index].id] = previous;
        } else if (message->kind == Kind::Run || message->kind == Kind::Apply || message->kind == Kind::Inputs || message->kind == Kind::Watch) {
          arity(*message, (message->kind == Kind::Inputs || message->kind == Kind::Watch) ? 0 : message->kind == Kind::Run ? 2 : 1);
          const auto index = message->kind == Kind::Run ? cell_index(session, message->fields[0]) : 0;
          const bool force = (message->kind == Kind::Run || message->kind == Kind::Apply) && boolean(message->fields.back());
          RunOutputCapture output(session);
          auto token = control.begin(previous);
          std::mutex send_mutex;
          data.send({Kind::Started, generation, previous, {}}, 2s);
          LiveReporter live(session, data, send_mutex, generation, previous, source_revisions, token);
          bool cancelled = false;
          std::exception_ptr failure;
          // Explicit Run/Apply already use the synchronized snapshot. Consume
          // those keys too, so a later Inputs command cannot replay old edits.
          auto changed_inputs = std::move(pending_inputs);
          pending_inputs.clear();
          if (message->kind != Kind::Watch) watch_paused = false;
          try {
            sputnik::runtime::RuntimeRunCancellationScope scope(token);
            sputnik::runtime::NotebookLiveScope live_scope(live.store);
            if (message->kind == Kind::Run) {
              invalidate_project_input_changes(&session, changed_inputs);
              evaluate_from(&session, index, force, false, false);
            }
            else if (message->kind == Kind::Watch) {
              const auto result = pump_runtime_events_detailed(&session, false, {});
              watch_dispatch.complete(result, RuntimePumpDispatch::Clock::now());
            } else if (message->kind == Kind::Inputs) {
              apply_project_input_changes(&session, changed_inputs);
            }
            else
              apply_project_environment(&session, load_project(project->directory), force, false);
          } catch (...) {
            failure = std::current_exception();
            try { token->request_cancel(); } catch (...) { /* Still drain, or Force Stop. */ }
          }
          // Keep Stop addressing this run throughout draining. No new source
          // command, Apply or world destruction may race its live descendants.
          live.end_evaluation();
          token->close_root();
          if (!token->wait_for_idle(0ms)) {
            {
              std::lock_guard<std::mutex> send(send_mutex);
              data.send({Kind::Draining, generation, previous,
                         {std::to_string(token->active_tasks())}}, 2s);
            }
            while (!token->wait_for_idle(100ms)) {}
          }
          cancelled = control.finish();
          if (cancelled) { watch_paused = true; watch_dispatch = {}; }
          output.finish();
          live.finish(session);
          if (failure) std::rethrow_exception(failure);
          auto presentation = presentation_from_session(session, source_revisions, cancelled);
          presentation.unobserved_task_failures = token->unobserved_failures();
          if (!presentation.unobserved_task_failures.empty())
            presentation.status = std::to_string(presentation.unobserved_task_failures.size()) +
                " unobserved child task failure(s)" + (cancelled ? " (run cancelled)" : "");
          send_presentation(data, generation, previous, presentation, 2s);
          continue;
        } else throw ProtocolError("unsupported worker command");
      }
      send_presentation(data, generation, previous,
                        presentation_from_session(session, source_revisions, false), 2s);
    } catch (const std::exception &error) {
      data.send({Kind::Error, generation, previous, {error.what()}}, 2s);
    }
  }
}
} // namespace
// Pure validation/serialization for the server; no Session or VM is created.
static std::string resolve_cell_inputs(int argc, char **argv) {
  const auto read = [](const char *path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw ProtocolError("cannot read cell input request");
    std::string value((std::istreambuf_iterator<char>(input)), {});
    if (value.size() > 16U * 1024U * 1024U) throw ProtocolError("cell input request too large");
    return value;
  };
  auto document = parse_project_document(read(argv[2]));
  const auto previous = parse_project_input_edits(read(argv[3]));
  const bool project_edits = argc == 6 && std::string(argv[4]) == "project";
  const auto owner = argc == 6 && !project_edits ? parse_id(argv[4]) : 0;
  const auto edits = argc == 6 ? parse_project_input_edits(read(argv[5])) : std::map<std::string, std::string>{};
  std::map<std::string, std::string> normalized;
  bool found_owner = owner == 0;
  if (project_edits) for (const auto &edit : edits)
    if (std::none_of(document.inputs.begin(), document.inputs.end(), [&](const auto &input) { return input.id == edit.first; }))
      throw ProtocolError("unknown project input: " + edit.first);
  for (auto &input : document.inputs) {
    const auto key = "project:" + input.id;
    auto value = input.initial;
    if (const auto old = previous.find(key); old != previous.end()) {
      try { auto accepted = parse_project_input_value(old->second); validate_project_input_value(input, accepted); value = std::move(accepted); }
      catch (const std::exception &) { /* Incompatible definitions restore defaults. */ }
    }
    if (project_edits) if (const auto edit = edits.find(input.id); edit != edits.end()) {
      auto accepted = parse_project_input_value(edit->second); validate_project_input_value(input, accepted); value = std::move(accepted);
    }
    if (input.type == "number" && std::holds_alternative<std::int64_t>(value)) value = static_cast<double>(std::get<std::int64_t>(value));
    normalized.emplace(key, serialize_project_input_value(value)); input.initial = std::move(value);
  }
  for (auto &sheet : document.sheets) for (auto &cell : sheet.cells) {
    const auto saved = cell.extra.find("cell_ui");
    if (cell.kind != "code" || saved == cell.extra.end()) continue;
    auto ui = parse_project_cell_ui(saved->second);
    if (cell.id == owner) {
      found_owner = true;
      for (const auto &edit : edits)
        if (std::none_of(ui.inputs.begin(), ui.inputs.end(), [&](const auto &input) { return input.id == edit.first; }))
          throw ProtocolError("unknown cell input: " + edit.first);
    }
    for (auto &input : ui.inputs) {
      const auto key = std::to_string(cell.id) + ":" + input.id;
      auto value = input.initial;
      if (const auto old = previous.find(key); old != previous.end()) {
        try {
          auto accepted = parse_project_input_value(old->second);
          validate_project_input_value(input, accepted); value = std::move(accepted);
        } catch (const std::exception &) { /* Changed definitions restore their default. */ }
      }
      if (cell.id == owner) if (const auto edit = edits.find(input.id); edit != edits.end()) {
        auto accepted = parse_project_input_value(edit->second);
        validate_project_input_value(input, accepted); value = std::move(accepted);
      }
      if (input.type == "number" && std::holds_alternative<std::int64_t>(value)) value = static_cast<double>(std::get<std::int64_t>(value));
      normalized.emplace(key, serialize_project_input_value(value));
      input.initial = std::move(value);
    }
    saved->second = serialize_project_cell_ui(ui);
  }
  if (!found_owner) throw ProtocolError("cell input owner unavailable");
  validate_project_control_values(document, *project_input_defaults(document));
  std::string out = "{\"document\":" + serialize_project_input_value(serialize_project_document(document)) + ",\"values\":{";
  bool first = true;
  for (const auto &[key, value] : normalized) {
    if (!first) out += ',';
    first = false;
    out += serialize_project_input_value(key) + ':' + serialize_project_input_value(value);
  }
  return out + "}}";
}

static std::string action_document(char **argv) {
  std::ifstream input(argv[2], std::ios::binary);
  if (!input) throw ProtocolError("cannot read invocation document");
  const std::string text((std::istreambuf_iterator<char>(input)), {});
  if (text.size() > 8U * 1024U * 1024U) throw ProtocolError("invocation document too large");
  auto document = parse_project_document(text);
  const auto board = std::find_if(document.boards.begin(), document.boards.end(), [&](const auto &b) { return b.id == argv[3]; });
  if (board == document.boards.end()) throw ProtocolError("invocation board unavailable");
  const ProjectComponent *component = nullptr;
  std::function<void(const std::vector<ProjectComponent> &)> find = [&](const auto &items) {
    for (const auto &c : items) {
      if (c.id == argv[4]) component = &c;
      if (c.panels) for (const auto &panel : *c.panels) find(panel.components);
    }
  };
  find(board->components);
  if (!component || (component->kind != "action" && component->kind != "periodic_work")) throw ProtocolError("invocation component unavailable");
  auto values = project_input_defaults(document);
  std::string source, module;
  if (component->kind == "action") {
    auto invocation = project_action_invocation(*component, *values);
    source = invocation.source; values = invocation.inputs;
    module = std::get<std::string>(parse_project_input_value(component->extra.at("module_id")));
  } else {
    const auto settings = project_periodic_work_settings(*component);
    module = settings.module_id;
    source = "import " + module + "\n" + module + "." + settings.function + "()\n";
  }
  if (std::none_of(document.modules.begin(), document.modules.end(), [&](const auto &m) { return m.id == module; }))
    throw ProtocolError("invocation module unavailable: " + module);
  for (const auto &entry : *values) {
    const auto &id = entry.first; const auto &value = entry.second;
    if (!id.empty() && id[0] != '\0' &&
      std::none_of(document.inputs.begin(), document.inputs.end(), [&](const auto &i) { return i.id == id; })) {
      const auto type = std::holds_alternative<std::string>(value) ? "string" : std::holds_alternative<bool>(value) ? "boolean" : std::holds_alternative<std::int64_t>(value) ? "integer" : "number";
      document.inputs.push_back({id, id, type, value, {}, {}, {}});
    }
  }
  auto sheet = std::find_if(document.sheets.begin(), document.sheets.end(), [&](const auto &s) { return s.id == board->sheet; });
  if (sheet == document.sheets.end()) throw ProtocolError("invocation controller unavailable");
  CellId id = 1;
  for (const auto &s : document.sheets) for (const auto &c : s.cells) id = std::max(id, c.id + 1);
  if (id == std::numeric_limits<CellId>::max()) throw ProtocolError("no invocation cell identity available");
  ProjectCell cell; cell.id = id; cell.kind = "code"; cell.mode = CellMode::Manual; cell.source = source;
  sheet->cells = {cell};
  return "{\"document\":" + serialize_project_input_value(serialize_project_document(document)) +
      ",\"kind\":" + serialize_project_input_value(component->kind) + ",\"sheet_id\":" + serialize_project_input_value(sheet->id) + ",\"cell_id\":" + serialize_project_input_value(std::to_string(id)) + "}";
}

// Managed input acceptance is a document transaction, never an evaluator. The
// caller owns the disposable directory; paths and identities are generated here.
static sputnik::runtime::DecodedAudioPCM validate_input_audio(const std::string &bytes, const std::string &extension) {
  using namespace sputnik::runtime;
  // PCM WAV requires no platform decoder. Other encodings use the same bounded
  // system codec as native annotation/input validation when that host has one.
  if ((extension == "wav" || extension == "wave") && bytes.size() >= 12 && bytes.substr(0, 4) == "RIFF" && bytes.substr(8, 4) == "WAVE") {
    if (audio_read_u32(bytes, 4) != bytes.size() - 8) throw ProtocolError("invalid WAV length");
    std::string format, pcm; unsigned rate = 0, channels = 0, chunks = 0; bool seen_format = false, seen_data = false;
    const auto u16 = [&](std::size_t at) { if (at + 2 > bytes.size()) throw ProtocolError("incomplete WAV metadata"); return unsigned(static_cast<unsigned char>(bytes[at])) | unsigned(static_cast<unsigned char>(bytes[at + 1])) << 8; };
    for (std::size_t at = 12; at < bytes.size();) {
      if (++chunks > 4096 || bytes.size() - at < 8) throw ProtocolError("invalid WAV chunks");
      const auto length = audio_read_u32(bytes, at + 4); const auto start = at + 8;
      if (length > bytes.size() - start || (length & 1U) > bytes.size() - start - length) throw ProtocolError("incomplete WAV chunk");
      const auto kind = bytes.substr(at, 4);
      if (kind == "fmt ") {
        if (seen_format || length < 16) throw ProtocolError("invalid WAV format chunk"); seen_format = true;
        const auto code = u16(start), bits = u16(start + 14); channels = u16(start + 2); rate = audio_read_u32(bytes, start + 4);
        format = code == 1 && bits == 16 ? "s16le" : code == 3 && bits == 32 ? "f32le" : "";
        if (!format.empty() && (u16(start + 12) != channels * (bits / 8) || audio_read_u32(bytes, start + 8) != rate * channels * (bits / 8))) throw ProtocolError("invalid WAV alignment");
      } else if (kind == "data") {
        if (seen_data || !length) throw ProtocolError("invalid WAV data chunk"); seen_data = true; pcm = bytes.substr(start, length);
      }
      at = start + length + (length & 1U);
    }
    if (!seen_format || !seen_data) throw ProtocolError("missing WAV audio data");
    if (!format.empty()) {
      (void)audio_pcm(pcm, format, rate, channels, true);
      if (format == "s16le" && pcm.size() > (kAudioMaxBytes - 64) / 2) throw ProtocolError("decoded audio exceeds input limit");
      return {audio_convert_pcm(pcm, format, "f32le", rate, channels), rate, channels};
    }
  }
  return audio_system_decode(bytes, extension);
}

static ProjectComponent *media_component(ProjectDocument &document, const std::string &board, const std::string &id) {
  std::function<ProjectComponent *(std::vector<ProjectComponent> &)> find = [&](auto &items) -> ProjectComponent * {
    for (auto &c : items) { if (c.id == id) return &c; if (c.panels) for (auto &panel : *c.panels) if (auto found = find(panel.components)) return found; } return nullptr;
  };
  for (auto &b : document.boards) if (b.id == board) if (auto c = find(b.components)) return c;
  throw ProtocolError("unknown media component");
}
static Presentation media_publication(const std::string &path) {
  if (path.empty()) return {};
  std::ifstream file(path, std::ios::binary | std::ios::ate);
  if (!file || file.tellg() > std::streamoff(kMaxPresentationBytes)) throw ProtocolError("publication unavailable");
  file.seekg(0); return decode_presentation(std::string((std::istreambuf_iterator<char>(file)), {}));
}
static sputnik::runtime::AudioDisplay annotation_audio(const ProjectDocument &document, const std::filesystem::path &directory,
    const std::string &sheet, const ProjectComponent &component, const Presentation &publication) {
  using namespace sputnik::runtime;
  const auto channel = project_audio_channel(component);
  if (project_audio_source(component) != "cell") {
    const auto inputs = load_project_audio_inputs(document, directory, sheet);
    const auto found = inputs->find(channel);
    if (found != inputs->end() && !found->second.audio.bytes.empty()) return found->second.audio;
  } else for (const auto &cell : publication.cells) if (cell.id == component.cell && cell.ok && !cell.dirty) {
    for (const auto &display : cell.displays) if (display.mime == kAudioMime && display.id == channel) return audio_decode(display.bytes);
    // Stream snapshots remain read-only: only completed encoded AudioTrack publications are editable.
  }
  throw ProtocolError("completed audio source unavailable");
}
static std::string annotation_source(char **argv) {
  using namespace sputnik::runtime;
  auto project = load_project(argv[2]); auto &document = project.document;
  const auto component = media_component(document, argv[3], argv[4]);
  if (component->kind == "table") {
    const auto publication = media_publication(argv[5]);
    const auto channel = component->extra.count("table_id") ? std::get<std::string>(parse_project_input_value(component->extra.at("table_id"))) : std::string{};
    std::string table;
    for (const auto &cell : publication.cells) if (cell.id == component->cell && cell.ok && !cell.dirty) {
      for (const auto &display : cell.displays) if (display.mime == "application/vnd.sputnik.table+json" && (channel.empty() || display.id == channel)) { table = display.bytes; break; }
      if (table.empty() && channel.empty()) table = cell.result_format.table_json;
    }
    if (table.empty() || table.size() > 1048576) throw ProtocolError("completed table source unavailable");
    return "{\"source\":" + serialize_project_input_value(notebook_asset_id(table)) + ",\"table\":" + serialize_project_input_value(table) + "}";
  }
  if (component->kind != "audio_annotator") throw ProtocolError("component has no editable source");
  const auto board = std::find_if(document.boards.begin(), document.boards.end(), [&](const auto &b) { return b.id == argv[3]; });
  const auto audio = annotation_audio(document, project.directory, board->sheet, *component, media_publication(argv[5]));
  const auto decoded = validate_input_audio(audio.bytes, audio.format);
  const bool from_cell = project_audio_source(*component) == "cell";
  const auto base64 = [](const std::string &bytes) {
    constexpr char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out; out.reserve((bytes.size() + 2) / 3 * 4);
    for (std::size_t i = 0; i < bytes.size(); i += 3) {
      const unsigned a = static_cast<unsigned char>(bytes[i]), b = i + 1 < bytes.size() ? static_cast<unsigned char>(bytes[i + 1]) : 0, c = i + 2 < bytes.size() ? static_cast<unsigned char>(bytes[i + 2]) : 0;
      out += alphabet[a >> 2]; out += alphabet[((a & 3) << 4) | (b >> 4)]; out += i + 1 < bytes.size() ? alphabet[((b & 15) << 2) | (c >> 6)] : '='; out += i + 2 < bytes.size() ? alphabet[c & 63] : '=';
    } return out;
  };
  return "{\"asset\":" + serialize_project_input_value(notebook_asset_id(audio.bytes)) +
    ",\"source\":" + serialize_project_input_value(from_cell ? std::string("cell") : std::string("input")) +
    ",\"channel\":" + serialize_project_input_value(project_audio_channel(*component)) +
    ",\"cell\":" + serialize_project_input_value(std::to_string(from_cell ? component->cell : 0)) +
    ",\"sample_rate\":" + std::to_string(decoded.rate) + ",\"channels\":" + std::to_string(decoded.channels) +
    ",\"frames\":" + std::to_string(decoded.bytes.size() / (4 * decoded.channels)) +
    ",\"data\":" + serialize_project_input_value(base64(decoded.bytes)) + "}";
}

// Reuse the bounded protocol JSON parser; never parse Pretty or evaluate values.
static std::string selection_json(const sputnik::pkg::registry_json::Value &v) {
  using V = sputnik::pkg::registry_json::Value;
  if (v.kind == V::Null) return "null";
  if (v.kind == V::String) return serialize_project_input_value(v.text);
  if (v.kind == V::Number || v.kind == V::Boolean) return serialize_project_input_value(parse_project_input_value(v.text));
  if (v.kind != V::Object) throw ProtocolError("selection requires scalar fields");
  std::string out = "{";
  for (const auto &[key, value] : v.object) { if (out.size() > 1) out += ','; out += serialize_project_input_value(key) + ':' + selection_json(value); }
  return out + '}';
}
static void validate_selection(const ProjectComponent &component, const std::string &bytes, const Presentation &publication) {
  using namespace sputnik::pkg::registry_json;
  const auto labels = Parser(bytes).parse();
  const auto channel = component.extra.count("table_id") ? std::get<std::string>(parse_project_input_value(component.extra.at("table_id"))) : std::string{};
  const auto key_name = component.extra.count("selection_key") ? std::get<std::string>(parse_project_input_value(component.extra.at("selection_key"))) : std::string{};
  std::string table;
  for (const auto &cell : publication.cells) if (cell.id == component.cell && cell.ok && !cell.dirty) {
    for (const auto &d : cell.displays) if (d.mime == "application/vnd.sputnik.table+json" && (channel.empty() || d.id == channel)) { table = d.bytes; break; }
    if (table.empty() && channel.empty()) table = cell.result_format.table_json;
  }
  if (table.empty() || table.size() > 1048576 || sputnik::runtime::notebook_asset_id(table) != labels.at("source").string()) throw ProtocolError("selection source changed");
  const auto parsed = Parser(table).parse(); const auto &columns = parsed.at("columns").array;
  std::set<std::string> titles; int key = -1, matches = 0;
  for (std::size_t i = 0; i < columns.size(); i++) {
    const auto title = columns[i].at("title").string();
    if (!titles.insert(title).second) throw ProtocolError("selection requires unique column names");
    if (columns[i].at("id").string() == key_name || title == key_name) { key = int(i); matches++; }
  }
  if (matches != 1 || labels.at("key").kind == Value::Null) throw ProtocolError("choose a unique key column");
  std::set<std::string> keys; bool found = false;
  for (const auto &row : parsed.at("rows").array) {
    const auto &values = row.at("values").array;
    if (values.size() != columns.size() || values.at(key).kind == Value::Null || !keys.insert(selection_json(values.at(key))).second) throw ProtocolError("selection keys must be unique and non-null");
    Value record; record.kind = Value::Object;
    for (std::size_t i = 0; i < columns.size(); i++) record.object.emplace(columns[i].at("title").string(), values[i]);
    if (selection_json(values.at(key)) == selection_json(labels.at("key")) && selection_json(record) == selection_json(labels.at("row"))) found = true;
  }
  if (!found) throw ProtocolError("selection row/key differs from its source");
}

static std::string accept_media_input(char **argv, const std::string &publication_path) {
  auto project = load_project(argv[2]);
  auto &document = project.document;
  const std::string board_id(argv[3]), component_id(argv[4]), extension(argv[5]), name(argv[6]), operation(argv[7]);
  if (name.size() > 1024 || name.find('\0') != std::string::npos ||
      extension.empty() || extension.size() > 16 || extension.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789") != std::string::npos ||
      (operation != "replace" && operation != "append" && operation != "clear" && operation != "annotations")) throw ProtocolError("invalid media input metadata");
  std::ifstream input(argv[8], std::ios::binary);
  if (!input) throw ProtocolError("cannot read media input");
  std::string bytes((std::istreambuf_iterator<char>(input)), {});
  if (bytes.size() > 16U * 1024U * 1024U || (bytes.empty() != (operation == "clear"))) throw ProtocolError("invalid media input size");
  auto board = std::find_if(document.boards.begin(), document.boards.end(), [&](const auto &b) { return b.id == board_id; });
  if (board == document.boards.end()) throw ProtocolError("unknown media input board");
  std::function<ProjectComponent *(std::vector<ProjectComponent> &)> find = [&](auto &components) -> ProjectComponent * {
    for (auto &c : components) { if (c.id == component_id) return &c; if (c.panels) for (auto &panel : *c.panels) if (auto found = find(panel.components)) return found; }
    return nullptr;
  };
  auto component = find(board->components);
  if (!component) throw ProtocolError("unknown media input component");
  const auto json = [](const std::string &s) { return serialize_project_input_value(s); };
  const auto store = [&](const std::string &folder, const std::string &ext) {
    const auto relative = folder + "/web_" + sputnik::runtime::notebook_asset_id(bytes) + "." + ext;
    std::filesystem::create_directories(project.directory / folder);
    std::ofstream file(project.directory / relative, std::ios::binary); file.write(bytes.data(), bytes.size());
    if (!file) throw ProtocolError("cannot stage managed input");
    return relative;
  };
  if (operation == "annotations") {
    const bool audio = component->kind == "audio_annotator";
    const bool selection = component->kind == "table" && !project_component_data_channel(*component, "selection").empty();
    if (!audio && !selection && ((component->kind != "image" && component->kind != "image_carousel") || !project_image_option(*component, "image_annotator")))
      throw ProtocolError("component does not own image annotations");
    const std::string kind = selection ? "selection" : audio ? "audio_annotations" : "annotations";
    validate_project_component_data(kind, bytes);
    if (bytes != "null") {
      validate_project_annotation_data(*component, kind, bytes);
      const auto labels = project_component_data_source(kind, bytes);
      const auto publication = media_publication(publication_path);
      bool current = false;
      if (selection) {
        validate_selection(*component, bytes, publication); current = true;
      } else if (audio) {
        const bool cell = project_audio_source(*component) == "cell";
        if (labels.channel != project_audio_channel(*component) || labels.source != (cell ? "cell" : "input") || labels.cell != (cell ? component->cell : 0)) throw ProtocolError("audio annotation binding changed");
        const auto track = annotation_audio(document, project.directory, board->sheet, *component, publication);
        const auto decoded = validate_input_audio(track.bytes, track.format);
        current = sputnik::runtime::notebook_asset_id(track.bytes) == labels.identity && decoded.rate == labels.rate && decoded.channels == labels.channels && decoded.bytes.size() / (4 * decoded.channels) == labels.frames;
      } else {
        if (labels.channel != project_image_channel(*component)) throw ProtocolError("annotation channel changed");
        const auto matches = [&](const auto &image) { return image.width == labels.width && image.height == labels.height && sputnik::runtime::notebook_asset_id(image.bytes) == labels.identity; };
        const auto inputs = load_project_image_inputs(document, project.directory, board->sheet);
        const auto found = inputs->find(labels.channel);
        if (found != inputs->end()) current = std::any_of(found->second.images.begin(), found->second.images.end(), matches);
        for (auto cell = publication.cells.rbegin(); cell != publication.cells.rend(); ++cell) {
          const auto series = std::find_if(cell->images.begin(), cell->images.end(), [&](const auto &s) { return s.id == labels.channel; });
          if (series != cell->images.end()) { current = cell->ok && !cell->dirty && std::any_of(series->images.begin(), series->images.end(), matches); break; }
        }
      }
      if (!current) throw ProtocolError("annotation source changed; reopen the current snapshot");
    }
    component->extra[kind] = bytes;
  } else if (project_owns_audio_input(*component)) {
    if (operation == "append") throw ProtocolError("audio input replaces one track");
    std::string path;
    if (!bytes.empty()) {
      sputnik::runtime::AudioDisplay audio; audio.bytes = bytes; audio.format = sputnik::runtime::audio_format(extension);
      (void)sputnik::runtime::audio_encode(audio);
      validate_input_audio(bytes, audio.format);
      path = store("audio", audio.format);
    }
    component->extra["audio_asset"] = json(path); component->extra["audio_name"] = json(name);
  } else if (component->kind == "image" || component->kind == "image_carousel") {
    if (!project_image_option(*component, "image_allow_load")) throw ProtocolError("image loading is disabled");
    if (operation == "append" && component->kind != "image_carousel") throw ProtocolError("single image cannot append");
    auto assets = operation == "append" ? project_image_assets(*component) : std::vector<ProjectImageAsset>{};
    if (!bytes.empty()) {
      sputnik::runtime::NotebookDisplay image;
      image.mime = extension == "png" ? "image/png" : extension == "jpg" || extension == "jpeg" ? "image/jpeg" : "";
      image.bytes = bytes; const auto dimensions = sputnik::runtime::notebook_image_dimensions(bytes, image.mime);
      image.width = dimensions.first; image.height = dimensions.second; sputnik::runtime::notebook_validate_image(image);
      assets.push_back({store("images", image.mime == "image/png" ? "png" : "jpg"), name});
    }
    if (assets.size() > 64) throw ProtocolError("image collection exceeds 64 images");
    component->extra["image_items"] = serialize_project_image_assets(assets);
    component->extra["image_revision"] = json(sputnik::runtime::notebook_asset_id(serialize_project_image_assets(assets)));
    component->extra["image_selection"] = "0";
    // Existing labels remain available for repair; the shared reader rejects
    // their old asset identity instead of silently retargeting them.
  } else if (component->kind == "file_input") {
    if (operation == "append") throw ProtocolError("file input replaces one file");
    auto definition = std::find_if(document.inputs.begin(), document.inputs.end(), [&](const auto &d) { return d.id == component->input && d.type == "string"; });
    if (definition == document.inputs.end()) throw ProtocolError("file input requires a String definition");
    const auto path = bytes.empty() ? std::string{} : store("inputs", extension);
    definition->initial = path; component->extra["file_name"] = json(name); component->extra["file_asset"] = json(path);
  } else throw ProtocolError("component does not accept media inputs");
  const auto result = serialize_project_document(document);
  (void)load_project_image_inputs(document, project.directory, board->sheet);
  (void)load_project_audio_inputs(document, project.directory, board->sheet);
  return result;
}

int sputnik::notebook::worker::worker_main(int argc, char **argv) {
  try {
    if ((argc == 9 || argc == 10) && std::string(argv[1]) == "--media-input") { std::cout << accept_media_input(argv, argc == 10 ? argv[9] : ""); return 0; }
    if (argc == 6 && std::string(argv[1]) == "--annotation-source") { std::cout << annotation_source(argv); return 0; }
    if (argc == 5 && std::string(argv[1]) == "--action-document") { std::cout << action_document(argv); return 0; }
    if ((argc == 4 || argc == 6) && std::string(argv[1]) == "--cell-inputs") {
      std::cout << resolve_cell_inputs(argc, argv); return 0;
    }
    if (argc == 3 && std::string(argv[1]) == "--check-project") { (void)load_project(argv[2]); return 0; }
    if (argc == 3 && std::string(argv[1]) == "--check-grants") {
      std::cout << grants_text(parse_grants(argv[2])); return 0;
    }
    if (argc < 3 || std::string(argv[1]) != "--notebook-worker")
      throw ProtocolError("Internal notebook worker: start through its host supervisor.");
    int next = 3;
    if (next + 1 < argc && std::string(argv[next]) == "--working-directory") {
      if (::chdir(argv[next + 1]) != 0) throw ProtocolError("cannot enter worker working directory");
      next += 2;
    }
    if (next + 3 < argc && std::string(argv[next]) == "--environment-directory" &&
        std::string(argv[next + 2]) == "--environment-fingerprint") {
      const auto environment = Environment::discover(argv[next + 1]);
      if (environment.fingerprint != argv[next + 3]) throw ProtocolError("worker environment changed during startup; restart required");
      environment.apply();
      next += 4;
    }
    std::string text;
    while (next + 1 < argc && std::string(argv[next]) == "--grant") {
      if (!text.empty()) text += '\n';
      text += argv[next + 1]; next += 2;
    }
    if (next != argc) throw ProtocolError("invalid worker startup arguments");
    return serve(parse_id(argv[2]), parse_grants(text));
  } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
}

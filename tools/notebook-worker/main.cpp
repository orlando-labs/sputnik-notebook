#include "tools/notebook-worker/telemetry.h"
#include "notebook/audio_components.h"
#include "tools/notebook-worker/process.h"
#include "tools/notebook-worker/presentation.h"
#include "tools/notebook-worker/grants.h"
#include "tools/notebook-worker/environment.h"
#include "notebook/renderers.h"
#include "tools/isputnik/project_session.h"
#include "tools/isputnik/dependencies.h"
#include "tools/isputnik/dispatch.h"
#include "runtime/context.h"
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <fstream>
#include <sstream>
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
      if (rc > 0 && (fds[1].revents & (POLLHUP | POLLERR | POLLNVAL))) std::_Exit(0);
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
          data.send({Kind::Result, generation, previous,
                     {!watch_paused && watch_dispatch.due(RuntimePumpDispatch::Clock::now()) ? "1" : "0"}}, 2s);
          continue;
        } else if (message->kind == Kind::Sync) {
          arity(*message, session.module_editor ? 3 : 2);
          // Inert host draft/structure synchronization. Never save these bytes
          // or replace the runtime; evaluation reconciles the kernel graph.
          auto document = parse_project_document(message->fields[0]);
          const auto image_inputs = load_project_image_inputs(document, project->directory, session.project_sheet_id);
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
          const auto inputs = project_input_defaults(document);
          if (session.project_inputs) for (const auto &[id, value] : *inputs) {
            const auto old = session.project_inputs->find(id);
            if (old == session.project_inputs->end() || old->second != value) pending_inputs.insert(id);
          }
          if (session.project_inputs) for (const auto &[id, value] : *session.project_inputs)
            if (!inputs->count(id)) pending_inputs.insert(id);
          project->document = std::move(document);
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
          session.project_audio_inputs = load_project_audio_inputs(project->document, project->directory, session.project_sheet_id);
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

int main(int argc, char **argv) {
  try {
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

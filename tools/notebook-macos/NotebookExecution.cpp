#include "tools/notebook-macos/NotebookExecution.h"
#include "tools/notebook-worker/presentation.h"
#include "tools/notebook-worker/grants.h"
#include <algorithm>
#include <stdexcept>
#include <thread>

using namespace sputnik::notebook;
using namespace sputnik::notebook::worker;
using namespace std::chrono_literals;

int NotebookExecutionControl::phase() const { std::lock_guard<std::mutex> lock(mutex_); return phase_; }
bool NotebookExecutionControl::forced() const { std::lock_guard<std::mutex> lock(mutex_); return force_; }
void NotebookExecutionControl::begin(std::string owner) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (phase_ && !process_) { owner_ = std::move(owner); return; }
  phase_ = 1; stop_ = force_ = false; request_ = {}; generation_ = 0; process_.reset();
  live_.reset();
  owner_ = std::move(owner);
}
void NotebookExecutionControl::publish_live(Presentation value) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (phase_ && !force_) {
    if (!live_) { live_ = Presentation{}; live_->telemetry_updated = false; }
    merge_live_presentation(*live_, std::move(value));
  }
}
std::shared_ptr<const Presentation> NotebookExecutionControl::take_live(std::string *owner) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!live_) return {};
  if (owner) *owner = owner_;
  auto result = std::make_shared<const Presentation>(std::move(*live_));
  live_.reset(); return result;
}
void NotebookExecutionControl::bind(std::shared_ptr<Process> process) {
  std::lock_guard<std::mutex> lock(mutex_);
  process_ = std::move(process); generation_ = process_->generation();
  if (force_) process_->request_force_stop(generation_);
}
void NotebookExecutionControl::running(RequestId request) {
  std::lock_guard<std::mutex> lock(mutex_);
  request_ = request;
  if (!stop_ && !force_) phase_ = 2;
  if (stop_) process_->request_stop(request_);
}
void NotebookExecutionControl::draining() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!stop_ && !force_) phase_ = 3;
}
bool NotebookExecutionControl::stop(bool force) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!phase_) return false;
  if (force) {
    force_ = true; phase_ = 5;
    return !process_ || process_->request_force_stop(generation_);
  }
  if (force_) return false;
  stop_ = true; phase_ = 4;
  return !process_ || !request_.request || process_->request_stop(request_);
}
void NotebookExecutionControl::finish() {
  std::lock_guard<std::mutex> lock(mutex_);
  phase_ = 0; process_.reset(); request_ = {}; generation_ = 0;
}
bool NotebookExecutionControl::commit() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (force_) return false;
  phase_ = 0; process_.reset(); request_ = {}; generation_ = 0;
  return true;
}

namespace {
Presentation receive_snapshot(Process &process, RequestId request,
                              NotebookExecutionControl &control, bool execution,
                              const Session *session = nullptr, std::uint64_t revision = 0) {
  PresentationAssembler assembler(request.generation, request.request);
  std::optional<PresentationAssembler> live;
  const auto deadline = std::chrono::steady_clock::now() + 10s;
  bool started = false, draining = false;
  while (true) {
    if (control.forced()) throw ProtocolError("worker terminated by user");
    const auto message = process.receive(100ms);
    if (!message) {
      if (!execution && std::chrono::steady_clock::now() >= deadline)
        throw ProtocolError("worker synchronization timed out");
      continue;
    }
    if (message->kind == Kind::Error)
      throw ProtocolError(message->fields.empty() ? "worker command failed" : message->fields[0]);
    if (message->kind == Kind::Started) {
      if (!execution || started) throw ProtocolError("unexpected worker Started");
      started = true; continue;
    }
    if (message->kind == Kind::Draining) {
      if (!started || draining) throw ProtocolError("unexpected worker Draining");
      draining = true; control.draining(); continue;
    }
    if (execution && !started) throw ProtocolError("missing worker Started");
    if (message->kind == Kind::LiveBegin || message->kind == Kind::LiveChunk || message->kind == Kind::LiveEnd) {
      if (!execution || !session) throw ProtocolError("unexpected live worker output");
      if (!live) live.emplace(request.generation, request.request, true);
      if (auto snapshot = live->accept(*message)) {
        if (snapshot->executing_cell && std::none_of(session->cells.begin(), session->cells.end(),
            [&](const auto &cell) { return cell.id == snapshot->executing_cell; }))
          throw ProtocolError("unknown executing cell");
        for (const auto &cell : snapshot->cells) {
          const auto found = std::find_if(session->cells.begin(), session->cells.end(),
              [&](const auto &c) { return c.id == cell.id; });
          if (found == session->cells.end() || cell.source_revision != revision)
            throw ProtocolError("stale live cell output");
        }
        control.publish_live(std::move(*snapshot));
        live.reset();
      }
      continue;
    }
    if (live) throw ProtocolError("incomplete live worker output");
    if (auto snapshot = assembler.accept(*message)) return std::move(*snapshot);
  }
}
void terminate_and_reap(Process &process) {
  // SIGKILL acknowledgement is not completion. Remain on the owner queue until
  // waitpid confirms exit; main-thread controls/status stay available.
  process.request_force_stop(process.generation());
  while (!process.poll_exit()) std::this_thread::sleep_for(10ms);
}
void invalidate(Session &session) {
  for (auto &cell : session.cells) if (cell.kind == "code") cell.dirty = true;
}
void merge(Session &session, const Presentation &result, std::uint64_t revision,
           NotebookExecutionControl &control) {
  // All-or-nothing metadata validation before any publication. Session source,
  // selection, formatting, Watch mode and document dirtiness are host-owned.
  if (result.cells.size() != session.cells.size()) throw ProtocolError("worker sheet shape mismatch");
  auto cells = session.cells;
  for (std::size_t i = 0; i < cells.size(); ++i) {
    auto &cell = cells[i]; const auto &value = result.cells[i];
    if (cell.id != value.id || value.source_revision != revision)
      throw ProtocolError("stale worker cell revision");
    cell.dirty = value.dirty; cell.ok = value.ok;
    cell.result = value.result; cell.error = value.error;
    cell.result_format = value.result_format;
    cell.locals = value.locals; cell.output_events = value.output; cell.displays = value.displays;
    cell.progress = value.progress; cell.charts = value.charts;
    cell.images = value.images; cell.audio = value.audio; cell.audio_controls = value.audio_controls;
    cell.elapsed_ms = value.elapsed_ms; cell.stopwatches = value.stopwatches;
    cell.watch_epoch = value.watch_epoch; cell.watch_event_count = value.watch_event_count;
    cell.error_ranges = value.error_ranges; cell.errors = value.errors; cell.selected_error = 0;
  }
  std::string status = result.status;
  if (result.cancelled) status = "Cancelled — " + status;
  for (const auto &failure : result.unobserved_task_failures) {
    status += "\nTask " + std::to_string(failure.task_id) + ": " + failure.error_name + ": " + failure.message;
    if (failure.spawn_source.present)
      status += " (spawned at " + failure.spawn_source.file + ":" + std::to_string(failure.spawn_source.line) + ")";
  }
  auto telemetry = result.telemetry;
  auto environment_error = result.environment_error;
  auto environment_output = result.environment_output;
  // Linearize publication against Force Stop without allocating/copying under
  // the control lock. Once committed, a late Stop cannot kill the idle worker.
  if (!control.commit()) throw ProtocolError("worker terminated by user");
  session.run_telemetry = std::move(telemetry);
  session.cells.swap(cells); session.status.swap(status);
  session.environment_error.swap(environment_error); session.environment_output.swap(environment_output);
  session.environment_stale = result.environment_stale;
}
}

bool NotebookExecution::run(ProjectTabs &tabs, ProjectTab &tab, const std::string &action, std::size_t index,
                            const std::string &runtime_key, bool recover) {
  if (tab.module && action == "apply") throw std::runtime_error("Apply requires a sheet tab");
  if (action == "apply") for (std::size_t i = 0; i < tabs.tabs().size(); ++i)
    if (tabs.tabs()[i]->module && tabs.modified(i)) throw std::runtime_error("Save modified module tabs before Apply.");
  auto &session = tab.session;
  if (recover && !runtime_key.empty() && sheets_[runtime_key].interrupted) restart(tab, runtime_key);
  const auto owner = tab.module ? "module:" + tab.module->id : "sheet:" + session.project_sheet_id;
  const auto key = runtime_key.empty() ? owner : runtime_key;
  auto &sheet = sheets_[key];
  if (sheet.interrupted) throw std::runtime_error("Worker was interrupted. Use Restart Worker before running again; no cells will be replayed automatically.");
  if (session.cells.empty() && action != "apply") return true;
  auto document = tabs.project().document;
  for (auto &input : document.inputs) input.initial = session.project_inputs ? session.project_inputs->at(input.id) : tabs.inputs().at(input.id);
  if (session.project_inputs) for (const auto &[id, value] : *session.project_inputs)
    if (!id.empty() && id[0] != '\0' && std::none_of(document.inputs.begin(), document.inputs.end(), [&](const auto &v) { return v.id == id; })) {
      const auto type = std::holds_alternative<std::string>(value) ? "string" : std::holds_alternative<bool>(value) ? "boolean" : std::holds_alternative<std::int64_t>(value) ? "integer" : "number";
      document.inputs.push_back({id, id, type, value});
    }
  if (session.project_inputs) for (auto &sheet : document.sheets) for (auto &cell : sheet.cells) {
    const auto saved = cell.extra.find("cell_ui");
    if (saved == cell.extra.end()) continue;
    auto ui = parse_project_cell_ui(saved->second);
    for (auto &input : ui.inputs) {
      const auto value = session.project_inputs->find(sputnik::runtime::notebook_cell_input_key(cell.id, input.id));
      if (value != session.project_inputs->end()) input.initial = value->second;
    }
    saved->second = serialize_project_cell_ui(ui);
  }
  auto target = std::find_if(document.sheets.begin(), document.sheets.end(),
      [&](const auto &s) { return s.id == session.project_sheet_id; });
  if (!tab.module && target == document.sheets.end()) throw ProtocolError("host sheet is missing");
  // Preserve unknown project/cell metadata, while substituting unsaved buffers
  // only for this sheet. Dependencies remain links to their original paths.
  std::vector<ProjectCell> cells;
  if (!tab.module) for (const auto &cell : session.cells) {
    const auto saved = std::find_if(target->cells.begin(), target->cells.end(),
        [&](const auto &c) { return c.id == cell.id; });
    auto value = saved == target->cells.end() ? ProjectCell{} : *saved;
    value.id = cell.id; value.kind = cell.kind; value.source = cell.source;
    value.mode = cell.watch ? CellMode::Watch : CellMode::Manual; value.formatting = cell.formatting;
    cells.push_back(std::move(value));
  }
  if (!tab.module) target->cells.swap(cells);
  std::function<void(std::vector<ProjectComponent> &)> select_images = [&](auto &components) {
    for (auto &component : components) {
      if (component.panels) for (auto &panel : *component.panels) select_images(panel.components);
      if ((component.kind == "image" || component.kind == "image_carousel") && session.project_images) {
        const auto input = session.project_images->find(project_image_channel(component));
        if (input != session.project_images->end()) component.extra["image_selection"] = std::to_string(input->second.selected);
      }
    }
  };
  for (auto &board : document.boards) if (board.sheet == session.project_sheet_id) select_images(board.components);
  const auto source = serialize_project_document(document);
  control->begin(runtime_key.empty() ? owner : runtime_key);
  struct Finish { NotebookExecutionControl &control; ~Finish() { control.finish(); } } finish{*control};
  try {
    if (!sheet.process) {
      sheet.owner = owner;
      sheet.process = std::make_shared<Process>(); sheet.process->start(executable_, tabs.project().directory.string(), grants_[owner], environment_directories_[owner]);
      control->bind(sheet.process);
      const auto ready = sheet.process->receive(5s);
      if (!ready || ready->kind != Kind::Ready) throw ProtocolError("worker handshake failed");
      const auto load = tab.module
          ? sheet.process->send(Kind::LoadModule, {tabs.project().directory.string(), tab.module->id,
              native_trusted ? "1" : "0", std::to_string(session.cells[0].id)})
          : sheet.process->send(Kind::Load, {tabs.project().directory.string(), session.project_sheet_id,
              native_trusted ? "1" : "0"});
      (void)receive_snapshot(*sheet.process, load, *control, false);
    } else control->bind(sheet.process);
    std::vector<std::string> sync_fields{source, session.environment_stale ? "1" : "0"};
    if (tab.module) sync_fields.push_back(session.cells.at(0).source);
    const auto sync = sheet.process->send(Kind::Sync, std::move(sync_fields));
    (void)receive_snapshot(*sheet.process, sync, *control, false);
    const auto request = action == "watch" ? sheet.process->send(Kind::Watch) : action == "inputs" ? sheet.process->send(Kind::Inputs) : action == "apply"
        ? sheet.process->send(Kind::Apply, {"0"})
        : sheet.process->send(Kind::Run, {std::to_string(session.cells.at(index).id), action == "run_all" ? "1" : "0"});
    control->running(request);
    auto result = receive_snapshot(*sheet.process, request, *control, true, &session, sync.request);
    // Stop/Force Stop may race the final frame. Never publish a killed world's
    // snapshot even if it was fully received before the main-thread request.
    if (control->forced()) throw ProtocolError("worker terminated by user");
    merge(session, result, sync.request, *control);
    if (action == "apply" && result.environment_error.empty() && !result.environment_stale)
      for (const auto &other : tabs.tabs()) if (!other->module && other.get() != &tab) {
        other->session.environment_stale = true;
        invalidate(other->session);
      }
    return !result.cancelled;
  } catch (const std::exception &error) {
    sheet.interrupted = true;
    invalidate(session);
    session.status = std::string("Worker interrupted; last results retained. Restart required. ") + error.what();
    if (sheet.process && sheet.process->generation()) terminate_and_reap(*sheet.process);
    throw;
  }
}

void NotebookExecution::inputs_changed(ProjectTabs &tabs) {
  for (const auto &tab : tabs.tabs()) if (!tab->module) {
    const auto found = sheets_.find("sheet:" + tab->session.project_sheet_id);
    if (found != sheets_.end() && found->second.process && !found->second.interrupted) {
      if (!run(tabs, *tab, "inputs", 0)) break;
    } else for (auto &cell : tab->session.cells) if (cell.kind == "code") cell.dirty = true;
  }
}
void NotebookExecution::restart(ProjectTab &tab, const std::string &runtime_key) {
  const auto owner = tab.module ? "module:" + tab.module->id : "sheet:" + tab.session.project_sheet_id;
  const auto found = sheets_.find(runtime_key.empty() ? owner : runtime_key);
  if (found != sheets_.end()) {
    if (found->second.process && found->second.process->generation()) terminate_and_reap(*found->second.process);
    sheets_.erase(found);
  }
  invalidate(tab.session); tab.session.environment_stale = false;
  tab.session.status = "Worker reset; next Run starts a fresh runtime. No cells replayed.";
}

void NotebookExecution::configure_grants(ProjectTab &tab, const std::string &text) {
  const auto parsed = parse_grants(text); // Validate before affecting any live world.
  std::vector<std::string> grants;
  for (const auto &grant : parsed) grants.push_back(sputnik::capability::request_to_text(grant));
  const auto owner = tab.module ? "module:" + tab.module->id : "sheet:" + tab.session.project_sheet_id;
  restart(tab);
  // Invocation runtimes use the controller sheet's policy too. Revocation
  // must retire those worlds before a subsequent Periodic Work tick.
  for (auto it = sheets_.begin(); it != sheets_.end();) {
    if (it->second.owner != owner) { ++it; continue; }
    if (it->second.process && it->second.process->generation()) terminate_and_reap(*it->second.process);
    it = sheets_.erase(it);
  }
  grants_[owner] = std::move(grants);
  tab.session.status = "Worker grants updated; next Run starts a fresh runtime. No cells replayed.";
}

void NotebookExecution::configure_environment(ProjectTab &tab, const std::string &directory) {
  if (!directory.empty()) (void)Environment::discover(directory);
  const auto owner = tab.module ? "module:" + tab.module->id : "sheet:" + tab.session.project_sheet_id;
  const auto grants = grants_[owner];
  configure_grants(tab, [&] {
    std::string text;
    for (const auto &grant : grants) { if (!text.empty()) text += '\n'; text += grant; }
    return text;
  }());
  environment_directories_[owner] = directory;
  tab.session.status = "Worker environment updated; next Run starts a fresh runtime. No cells replayed.";
}

std::string NotebookExecution::pending(ProjectTabs &tabs) {
  // Poll only already-created worlds. This command consumes notifications,
  // never runtime events or user code. The GUI starts Watch through Run's
  // normal busy/live/control lifecycle after receiving the owner ID.
  const auto count = tabs.tabs().size();
  for (std::size_t offset = 0; offset < count; ++offset) {
    const auto index = (watch_cursor_ + offset) % count;
    auto &tab = *tabs.tabs()[index];
    if (tab.module || tab.session.environment_stale) continue;
    const auto owner = "sheet:" + tab.session.project_sheet_id;
    const auto found = sheets_.find(owner);
    if (found == sheets_.end() || !found->second.process || found->second.interrupted) continue;
    auto &sheet = found->second;
    try {
      sheet.process->send(Kind::Poll);
      const auto reply = sheet.process->receive(2s);
      if (!reply || reply->kind != Kind::Result || reply->fields.size() != 1 ||
          (reply->fields[0] != "0" && reply->fields[0] != "1"))
        throw ProtocolError("invalid worker activity reply");
      if (reply->fields[0] == "1") {
        watch_cursor_ = (index + 1) % count;
        return owner;
      }
    } catch (...) {
      sheet.interrupted = true; invalidate(tab.session);
      terminate_and_reap(*sheet.process);
      throw;
    }
  }
  return {};
}

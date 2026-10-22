#include "tools/notebook-macos/NotebookBridge.h"
#include "tools/notebook-macos/NotebookExecution.h"
#include "notebook/project.h"
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <thread>
#include <unistd.h>
using namespace std::chrono_literals;
static void require(bool value, const std::string &message) {
  if (!value) { std::cerr << "worker host: " << message << '\n'; std::exit(1); }
}
static std::string snapshot(SputnikNotebook *host) {
  char *error = nullptr; char *raw = sputnik_notebook_snapshot(host, &error);
  require(raw && !error, error ? error : "snapshot failed");
  std::string result(raw); sputnik_notebook_string_free(raw); return result;
}
static std::string command(SputnikNotebook *host, const char *action, const char *cell = nullptr,
                           const char *text = nullptr, const char *tab = "sheet:main") {
  char *error = nullptr;
  const auto ok = sputnik_notebook_command(host, action, tab, cell, text, &error);
  const std::string result = error ? error : ok ? "" : "operation failed";
  sputnik_notebook_string_free(error); return result;
}
static void succeeds(SputnikNotebook *host, const char *action, const char *cell = nullptr,
                     const char *text = nullptr) { const auto error = command(host, action, cell, text); require(error.empty(), error); }
static void wait_running(SputnikNotebookControl *control) {
  const auto deadline = std::chrono::steady_clock::now() + 5s;
  while (sputnik_notebook_control_phase(control) < 2 && std::chrono::steady_clock::now() < deadline)
    std::this_thread::sleep_for(1ms);
  require(sputnik_notebook_control_phase(control) >= 2, "execution starts while UI/control thread is responsive");
}
static std::string first_cell(const std::string &state, const std::string &tab) {
  const auto start = state.find("\"id\":\"" + tab + "\"");
  require(start != std::string::npos, "tab exists");
  const std::string marker = "\"cells\":[{\"id\":\"";
  const auto cell = state.find(marker, start);
  require(cell != std::string::npos, "tab cell exists");
  const auto from = cell + marker.size();
  return state.substr(from, state.find('"', from) - from);
}
static void module_apply_tests(const std::filesystem::path &root, const char *worker) {
  auto document = sputnik::notebook::make_project_document("Apply worker");
  document.sheets[0].cells.resize(1);
  document.sheets[0].cells[0].source = "answer()\n";
  document.sheets.push_back(document.sheets[0]);
  document.sheets[1].id = "second";
  document.sheets[1].cells[0].id = sputnik::notebook::allocate_cell_id();
  auto project = sputnik::notebook::create_project(root / "Apply.sputnikbook", document);
  document.modules.push_back({"helpers", "helpers.s", {}}); document.auto_imports = {"helpers"};
  std::ofstream(project.directory / "helpers.s") << "package helpers\nexport answer\ndef answer(): 41\n";
  sputnik::notebook::save_project(&project, document);
  auto *host = sputnik_notebook_open(project.directory.c_str(), 0, nullptr, nullptr);
  require(host, "open module fixture");
  auto *control = sputnik_notebook_enable_worker(host, worker, nullptr);
  require(control, "module control");
  succeeds(host, "run_all");
  require(command(host, "run_all", nullptr, nullptr, "sheet:second").empty(), "independent second sheet worker");
  const auto before = snapshot(host);
  require(before.find("\"result\":\"41\"") != std::string::npos, "saved module executes");
  const auto module_cell = first_cell(before, "module:helpers");
  require(command(host, "source", module_cell.c_str(), "package helpers\nexport answer\ndef answer(): 99\n", "module:helpers").empty(), "edit module inertly");
  require(command(host, "apply").find("Save modified") != std::string::npos, "Apply refuses unsaved module buffer");
  require(command(host, "run", module_cell.c_str(), nullptr, "module:helpers").empty(),
          "unsaved module Run uses an isolated worker");
  require(command(host, "source", module_cell.c_str(),
      "package helpers\ntry:\n  notebook.progress(\"module\", 1, 2, \"Module\", false)\n  while true:\n    x = 1\nensure:\n  print(\"MODULE STOPPED\")\n", "module:helpers").empty(), "edit slow module buffer");
  std::string module_error;
  std::thread module_owner([&] { module_error = command(host, "run", module_cell.c_str(), nullptr, "module:helpers"); });
  wait_running(control); std::this_thread::sleep_for(150ms);
  char *live = sputnik_notebook_control_live(control);
  require(live && std::string(live).find("module:helpers") != std::string::npos, "live module output carries its owner");
  sputnik_notebook_string_free(live);
  require(sputnik_notebook_control_stop(control, 0), "Stop is available during module Run");
  module_owner.join(); require(module_error.empty(), module_error);
  require(snapshot(host).find("MODULE STOPPED") != std::string::npos, "module Stop executes ensure and retains output");
  module_owner = std::thread([&] { module_error = command(host, "run", module_cell.c_str(), nullptr, "module:helpers"); });
  wait_running(control);
  require(sputnik_notebook_control_stop(control, 1), "Force Stop is available during module Run");
  module_owner.join(); require(!module_error.empty(), "module Force Stop cannot publish success");
  require(command(host, "restart_worker", nullptr, nullptr, "module:helpers").empty(), "module worker restart is inert");
  require(command(host, "source", module_cell.c_str(), "package helpers\nexport answer\ndef answer(): 99\n", "module:helpers").empty(), "restore module buffer");
  require(command(host, "save", nullptr, nullptr, "module:helpers").empty(), "host saves module");
  succeeds(host, "apply");
  auto state = snapshot(host);
  require(state.find("\"result\":\"99\"") != std::string::npos && state.find("\"environment_stale\":true") != std::string::npos,
          "Apply installs saved module and marks other sheet stale");
  require(command(host, "apply", nullptr, nullptr, "sheet:second").empty(), "second worker independently applies environment");
  state = snapshot(host);
  require(state.find("\"result\":\"41\"") == std::string::npos, "both sheets now have new environment results");
  // Root module initialization, not a specially annotated cell, must stop too.
  require(command(host, "source", module_cell.c_str(),
      "package helpers\nexport answer\ndef answer(): 123\nwhile true:\n  x = 1\n", "module:helpers").empty(), "edit slow module");
  require(command(host, "save", nullptr, nullptr, "module:helpers").empty(), "save slow module");
  std::string apply_error;
  std::thread owner([&] { apply_error = command(host, "apply"); });
  wait_running(control); std::this_thread::sleep_for(80ms);
  require(sputnik_notebook_control_stop(control, 0), "Stop addresses module initialization");
  owner.join(); require(apply_error.empty(), apply_error);
  state = snapshot(host);
  require(state.find("Cancelled") != std::string::npos && state.find("\"result\":\"99\"") != std::string::npos,
          "cancelled Apply retains prior results and reports cancellation");
  succeeds(host, "new_input", nullptr, "{\"id\":\"gain\",\"title\":\"Gain\",\"type\":\"number\",\"default\":1}");
  require(command(host, "source", module_cell.c_str(), "package helpers\nexport answer\ndef answer(): 123\n", "module:helpers").empty(), "repair module");
  require(command(host, "save", nullptr, nullptr, "module:helpers").empty(), "save repaired module");
  succeeds(host, "apply");
  succeeds(host, "set_input", "gain", "2");
  sputnik_notebook_destroy(host); sputnik_notebook_control_destroy(control);
}
int main(int argc, char **argv) {
  require(argc == 2, "worker path"); alarm(40);
  char pattern[] = "/tmp/sputnik-worker-host-XXXXXX";
  const char *root = mkdtemp(pattern); require(root, "temporary directory");
  auto document = sputnik::notebook::make_project_document("Worker host");
  document.sheets[0].cells.resize(1); document.sheets[0].cells[0].source = "1\n";
  const auto cell = std::to_string(document.sheets[0].cells[0].id);
  const auto project = sputnik::notebook::create_project(std::filesystem::path(root) / "Host.sputnikbook", document);
  char *error = nullptr;
  auto *host = sputnik_notebook_open(project.directory.c_str(), 0, nullptr, &error);
  require(host && !error, "host open");
  auto *control = sputnik_notebook_enable_worker(host, argv[1], &error);
  require(control && !error, "enable worker preview");
  require(sputnik_notebook_control_phase(control) == 0 && !sputnik_notebook_control_stop(control, 1), "inert open has no process to kill");
  succeeds(host, "source", cell.c_str(), "answer = 42\nanswer\n");
  succeeds(host, "run_all");
  auto state = snapshot(host);
  require(state.find("\"result\":\"42\"") != std::string::npos && state.find("\"modified\":true") != std::string::npos,
          "unsaved source executes but remains host-owned/modified");
  succeeds(host, "add_text", cell.c_str());
  succeeds(host, "run_all"); // Unsaved structure, not present in the disk bootstrap.
  require(snapshot(host).find("\"kind\":\"text\"") != std::string::npos, "Sync accepts unsaved structure without changing it");
  succeeds(host, "source", cell.c_str(), "try:\n  while true:\n    x = 1\nensure:\n  print(\"STOPPED\")\n");
  std::string run_error;
  std::thread owner([&] { run_error = command(host, "run", cell.c_str()); });
  wait_running(control); std::this_thread::sleep_for(80ms);
  bool observed_executing_cell = false;
  for (int i = 0; i < 500 && !observed_executing_cell; ++i) {
    if (auto *json = sputnik_notebook_control_live(control)) {
      observed_executing_cell = std::string(json).find("\"executing_cell\":\"" + cell + "\"") != std::string::npos;
      sputnik_notebook_string_free(json);
    }
    if (!observed_executing_cell) std::this_thread::sleep_for(10ms);
  }
  require(observed_executing_cell, "a silent infinite loop publishes its executing cell through the independent channel");
  require(sputnik_notebook_control_stop(control, 0), "cooperative Stop uses independent control lifetime");
  owner.join(); require(run_error.empty(), run_error);
  state = snapshot(host);
  require(state.find("Cancelled") != std::string::npos && state.find("STOPPED") != std::string::npos, "Stop result and ensure output merged");
  succeeds(host, "source", cell.c_str(), "99\n"); succeeds(host, "run_all");
  require(snapshot(host).find("\"result\":\"99\"") != std::string::npos, "ordinary Stop does not require restart");
  succeeds(host, "source", cell.c_str(),
      "notebook.progress(\"training\", 3, 10, \"MNIST batches\", false)\n"
      "task.sleep(600)\nnotebook.progress(\"training\", 10, 10, \"MNIST batches\", true)\n99\n");
  owner = std::thread([&] { run_error = command(host, "run", cell.c_str()); });
  wait_running(control);
  std::string telemetry;
  const auto live_deadline = std::chrono::steady_clock::now() + 4s;
  while (telemetry.empty() && std::chrono::steady_clock::now() < live_deadline) {
    if (char *json = sputnik_notebook_control_live(control)) {
      telemetry = json; sputnik_notebook_string_free(json);
    }
    if (telemetry.empty()) std::this_thread::sleep_for(10ms);
  }
  require(telemetry.find("MNIST batches") != std::string::npos &&
          telemetry.find("\"current\":3.") != std::string::npos && sputnik_notebook_control_phase(control) > 0,
          "UI receives actual progress while owner is still executing");
  owner.join(); require(run_error.empty(), run_error);
  require(snapshot(host).find("\"done\":true") != std::string::npos, "final progress survives terminal merge");
  succeeds(host, "source", cell.c_str(), "while true:\n  x = 1\n");
  owner = std::thread([&] { run_error = command(host, "run", cell.c_str()); });
  wait_running(control);
  require(sputnik_notebook_control_stop(control, 1), "Force Stop targets active worker");
  owner.join(); require(!run_error.empty(), "forced world cannot publish success");
  state = snapshot(host);
  require(state.find("\"result\":\"99\"") != std::string::npos && state.find("Restart required") != std::string::npos,
          "Force Stop preserves last result with interrupted/stale label");
  require(sputnik_notebook_control_phase(control) == 0 && !sputnik_notebook_control_stop(control, 1), "confirmed exit closes control generation");
  require(command(host, "run", cell.c_str()).find("Restart") != std::string::npos, "never restart/replay implicitly");
  succeeds(host, "restart_worker");
  require(snapshot(host).find("No cells replayed") != std::string::npos, "restart is inert");
  succeeds(host, "source", cell.c_str(), "import task\nchild = task.spawn:\n  task.sleep(100)\n  1 / 0\n17\n");
  succeeds(host, "run_all");
  require(snapshot(host).find("unobserved child task") != std::string::npos, "late child failure reaches native host status");
  succeeds(host, "source", cell.c_str(), "x = 1\nKernel.watch(x)\nx\n");
  succeeds(host, "run_all");
  char *pending_error = nullptr;
  char *pending = sputnik_notebook_worker_pending(host, &pending_error);
  require(pending && !pending_error && std::string(pending) == "sheet:main", "worker watch activity is discoverable while idle");
  sputnik_notebook_string_free(pending);
  succeeds(host, "watch_run");
  pending = sputnik_notebook_worker_pending(host, &pending_error);
  require(!pending && !pending_error, "Watch acknowledges events once without a local VM or busy loop");
  // Overflow forces a conservative automatic resync, so Watch really runs
  // source here rather than merely acknowledging registration metadata.
  succeeds(host, "source", cell.c_str(),
      "x = 1\nKernel.watch(x)\n70000.times:\n  x += 1\n"
      "notebook.progress(\"hot\", 1, 2, \"Watch execution\", false)\ntask.sleep(800)\nx\n");
  succeeds(host, "run_all");
  pending = sputnik_notebook_worker_pending(host, &pending_error);
  require(pending && !pending_error, "hot Watch work is scheduled");
  sputnik_notebook_string_free(pending);
  owner = std::thread([&] { run_error = command(host, "watch_run"); });
  wait_running(control);
  bool watch_live = false;
  const auto watch_deadline = std::chrono::steady_clock::now() + 5s;
  while (!watch_live && sputnik_notebook_control_phase(control) && std::chrono::steady_clock::now() < watch_deadline) {
    if (char *json = sputnik_notebook_control_live(control)) {
      watch_live = std::string(json).find("Watch execution") != std::string::npos;
      sputnik_notebook_string_free(json);
    }
    std::this_thread::sleep_for(10ms);
  }
  require(watch_live && sputnik_notebook_control_stop(control, 0), "automatic Watch publishes live progress and accepts Stop");
  owner.join(); require(run_error.empty(), run_error);
  pending = sputnik_notebook_worker_pending(host, &pending_error);
  require(!pending && !pending_error, "Stop prevents automatic replay of cancelled Watch work");
  succeeds(host, "run_all");
  owner = std::thread([&] { run_error = command(host, "watch_run"); });
  wait_running(control);
  require(sputnik_notebook_control_stop(control, 1), "automatic Watch accepts Force Stop");
  owner.join(); require(!run_error.empty(), "forced Watch worker cannot publish success");
  const auto disk = sputnik::notebook::load_project(project.directory);
  require(disk.document.sheets[0].cells.size() == 1 && disk.document.sheets[0].cells[0].source == "1\n",
          "worker never saves source or unsaved sheet structure");
  sputnik_notebook_destroy(host);
  require(sputnik_notebook_control_phase(control) == 0 && !sputnik_notebook_control_stop(control, 1), "control safely outlives its retired host");
  sputnik_notebook_control_destroy(control);
  module_apply_tests(root, argv[1]);
  NotebookExecutionControl publication;
  publication.begin(); require(publication.commit() && !publication.stop(true), "late Force Stop cannot kill committed runtime");
  publication.begin(); require(publication.stop(true) && !publication.commit(), "Force Stop before commit prevents publication");
  publication.finish();
  std::filesystem::remove_all(root); alarm(0);
  std::cout << "notebook_worker_host_tests: ok\n";
}

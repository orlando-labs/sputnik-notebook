#include "notebook/project.h"
#include "tools/notebook-macos/NotebookBridge.h"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <unistd.h>

using namespace sputnik::notebook;
using namespace std::chrono_literals;
static void check(bool value, const std::string &message) { if (!value) throw std::runtime_error(message); }
static std::string snapshot(SputnikNotebook *host) {
  char *error = nullptr;
  char *raw = sputnik_notebook_snapshot(host, &error);
  const std::string failure = error ? error : "snapshot failed";
  sputnik_notebook_string_free(error);
  check(raw != nullptr, failure);
  std::string result(raw); sputnik_notebook_string_free(raw); return result;
}
static std::string command(SputnikNotebook *host, const char *action, const char *component = "timer",
                           const char *text = "dashboard", const char *tab = "sheet:main") {
  char *error = nullptr;
  const auto ok = sputnik_notebook_command(host, action, tab, component, text, &error);
  const std::string result = error ? error : ok ? "" : "command failed";
  sputnik_notebook_string_free(error); return result;
}
static void succeeds(SputnikNotebook *host, const char *action, const char *component = "timer",
                     const char *text = "dashboard") { const auto message = command(host, action, component, text); check(message.empty(), message); }
template<class F> static void rejects(F function) {
  try { function(); } catch (const std::exception &) { return; }
  throw std::runtime_error("invalid periodic settings accepted");
}
static ProjectDocument fixture() {
  auto doc = make_project_document("Periodic Work");
  doc.version = 2;
  doc.sheets[0].cells.resize(1);
  doc.sheets[0].cells[0].source = "raise \"controller must remain inert\"\n";
  doc.modules = {{"jobs", "jobs.s", {}}};
  doc.boards = {parse_project_board(R"({"id":"dashboard","title":"Jobs","sheet":"main","rows":[],"components":[
    {"id":"timer","kind":"periodic_work","title":"Counter","module_id":"jobs","function":"tick","period_seconds":0.05,"timing":"fixed_rate","retention":"tail","tail_limit":2},
    {"id":"other","kind":"periodic_work","title":"Other","module_id":"jobs","function":"tick"}]})")};
  return doc;
}
static void validation() {
  auto doc = fixture();
  const auto encoded = serialize_project_document(doc);
  check(serialize_project_document(parse_project_document(encoded)) == encoded, "nonvisual services roundtrip without rows");
  for (const auto &[key, value] : std::vector<std::pair<std::string, std::string>>{
      {"period_seconds", "0"}, {"period_seconds", "-1"}, {"period_seconds", "31536001"},
      {"period_seconds", "\"fast\""}, {"tail_limit", "0"}, {"tail_limit", "1.5"},
      {"timing", "\"overlap\""}, {"retention", "\"latest\""}, {"store_errors", "1"},
      {"function", "\"tick(); raise 1\""}, {"module_id", "\"jobs.child\""}}) {
    auto bad = doc; bad.boards[0].components[0].extra[key] = value;
    rejects([&] { serialize_project_document(bad); });
  }
  auto bad = doc; bad.boards[0].rows = std::vector<ProjectBoardRow>{{"row", {}, {}}};
  bad.boards[0].components[0].row = "row";
  rejects([&] { serialize_project_document(bad); });
  bad = doc; bad.boards[0].components[0].cell = 1;
  rejects([&] { serialize_project_document(bad); });
  bad = doc; bad.boards[0].components[0].panels = std::vector<ProjectBoardPanel>{};
  rejects([&] { serialize_project_document(bad); });
  const auto settings = project_periodic_work_settings(doc.boards[0].components[1]);
  check(settings.period_seconds == 60 && settings.retention == "tail" && settings.tail_limit == 100 &&
        settings.pause_when_hidden && !settings.stop_on_error, "defaults are stable");
}
static const char *jobs = "package jobs\nimport task\n"
    "class Counter:\n  def init(): @value = 0\n  def next():\n    @value += 1\n    @value\n"
    "State = Counter()\n"
    "def tick(): State.next()\n"
    "def fail(): raise \"periodic boom\"\n"
    "def child():\n  task.spawn:\n    task.sleep(80)\n  42\n"
    "def endless():\n  while true:\n    x = 1\n"
    "export tick, fail, child, endless\n";
static void execution(const std::filesystem::path &root, const char *worker) {
  auto doc = fixture();
  auto project = create_project(root, make_project_document("Bootstrap"));
  std::ofstream(root / "jobs.s") << jobs;
  save_project(&project, doc);
  const auto disk = serialize_project_document(doc);
  auto *host = sputnik_notebook_open(root.c_str(), 0, nullptr, nullptr);
  check(host, "open periodic fixture");
  auto *control = worker ? sputnik_notebook_enable_worker(host, worker, nullptr) : nullptr;
  check(!worker || control, "enable worker");
  const auto before = snapshot(host);
  check(before.find("\"periodic_results\":[]") != std::string::npos, "opening never invokes services");
  succeeds(host, "periodic_run");
  auto state = snapshot(host);
  check(state.find("\"id\":\"dashboard:timer\",\"ok\":true,\"result\":\"1\"") != std::string::npos,
        "exported function returns first counter value: " + state);
  succeeds(host, "periodic_tick");
  state = snapshot(host);
  check(state.find("\"result\":\"2\"") != std::string::npos, "module state survives ticks");
  succeeds(host, "periodic_run", "other");
  state = snapshot(host);
  check(state.find("\"id\":\"dashboard:other\",\"ok\":true,\"result\":\"1\"") != std::string::npos,
        "components have independent persistent runtimes");
  check(state.find("controller must remain inert") != std::string::npos && state.find("\"dirty\":true") != std::string::npos,
        "controller source and results are untouched");
  check(serialize_project_document(load_project(root).document) == disk, "invocations never rewrite project");
  doc.boards[0].components[0].extra["future"] = "1.234567890123456789";
  succeeds(host, "save_board", nullptr, serialize_project_board(doc.boards[0]).c_str());
  auto defaults = doc.boards[0];
  defaults.components[0].extra.erase("timing"); defaults.components[0].extra.erase("period_seconds");
  defaults.components[0].extra.erase("future");
  succeeds(host, "save_board", nullptr, serialize_project_board(defaults).c_str());
  const auto saved = load_project(root).document.boards[0].components[0];
  check(project_periodic_work_settings(saved).timing == "fixed_delay" &&
        project_periodic_work_settings(saved).period_seconds == 60 &&
        saved.extra.at("future") == "1.234567890123456789", "known settings reset while unknown metadata survives");
  std::ofstream(root / "jobs.s") << jobs << "\n# saved module change\n";
  check(command(host, "periodic_tick").find("Modules changed") != std::string::npos,
        "automatic ticks refuse to execute changed module generations");
  succeeds(host, "periodic_run");
  check(snapshot(host).find("\"id\":\"dashboard:timer\",\"ok\":true,\"result\":\"1\"") != std::string::npos,
        "explicit invocation installs changed saved module sources");
  doc.boards[0].components[0].extra["function"] = "\"fail\"";
  succeeds(host, "save_board", nullptr, serialize_project_board(doc.boards[0]).c_str());
  succeeds(host, "periodic_run");
  check(snapshot(host).find("periodic boom") != std::string::npos, "runtime errors are returned");
  doc.boards[0].components[0].extra["function"] = "\"child\"";
  succeeds(host, "save_board", nullptr, serialize_project_board(doc.boards[0]).c_str());
  const auto start = std::chrono::steady_clock::now();
  succeeds(host, "periodic_run");
  check(std::chrono::steady_clock::now() - start >= 70ms && snapshot(host).find("\"result\":\"42\"") != std::string::npos,
        "completion waits for child work before scheduling another invocation");
  if (control) {
    doc.boards[0].components[0].extra["function"] = "\"endless\"";
    succeeds(host, "save_board", nullptr, serialize_project_board(doc.boards[0]).c_str());
    std::string failure;
    std::thread owner([&] { failure = command(host, "periodic_run"); });
    const auto deadline = std::chrono::steady_clock::now() + 5s;
    while (sputnik_notebook_control_phase(control) < 2 && std::chrono::steady_clock::now() < deadline) std::this_thread::sleep_for(1ms);
    check(sputnik_notebook_control_phase(control) >= 2, "periodic execution is stoppable");
    check(sputnik_notebook_control_stop(control, 1), "Force Stop periodic worker");
    owner.join(); check(!failure.empty(), "force stop reports failure");
    std::thread retry([&] { failure = command(host, "periodic_run"); });
    const auto retry_deadline = std::chrono::steady_clock::now() + 5s;
    while (sputnik_notebook_control_phase(control) < 2 && std::chrono::steady_clock::now() < retry_deadline) std::this_thread::sleep_for(1ms);
    check(sputnik_notebook_control_phase(control) >= 2, "explicit retry recovers unchanged interrupted worker");
    check(sputnik_notebook_control_stop(control, 0), "cooperative Stop addresses retried periodic invocation");
    retry.join(); check(failure.empty(), failure);
    doc.boards[0].components[0].extra["function"] = "\"tick\"";
    succeeds(host, "save_board", nullptr, serialize_project_board(doc.boards[0]).c_str());
    succeeds(host, "periodic_run");
    check(snapshot(host).find("\"id\":\"dashboard:timer\",\"ok\":true,\"result\":\"1\"") != std::string::npos,
          "explicit Start recovers an interrupted service without replaying sheets");
  }
  // Missing exports are diagnostics, while unknown modules fail the command.
  doc.boards[0].components[0].extra["function"] = "\"missing\"";
  succeeds(host, "save_board", nullptr, serialize_project_board(doc.boards[0]).c_str());
  succeeds(host, "periodic_run");
  check(snapshot(host).find("\"id\":\"dashboard:timer\",\"ok\":false") != std::string::npos, "missing export is visible");
  doc.boards[0].components[0].extra["module_id"] = "\"deleted\"";
  succeeds(host, "save_board", nullptr, serialize_project_board(doc.boards[0]).c_str());
  check(command(host, "periodic_run").find("module unavailable") != std::string::npos, "broken module binding stays editable");
  succeeds(host, "periodic_dispose");
  doc.boards[0].components[0].extra["module_id"] = "\"jobs\"";
  doc.boards[0].components[0].extra["function"] = "\"input_value\"";
  succeeds(host, "new_input", nullptr, R"({"id":"gain","title":"Gain","type":"integer","default":17})");
  std::ofstream(root / "jobs.s") << jobs << "\ndef input_value(): notebook.input(\"gain\")\nexport input_value\n";
  succeeds(host, "save_board", nullptr, serialize_project_board(doc.boards[0]).c_str());
  if (!worker) succeeds(host, "set_input", "gain", "23");
  succeeds(host, "periodic_run");
  check(snapshot(host).find(worker ? "\"result\":\"17\"" : "\"result\":\"23\"") != std::string::npos,
        "each invocation sees a project input snapshot, including worker execution");
  doc.boards[0].components.erase(doc.boards[0].components.begin());
  succeeds(host, "save_board", nullptr, serialize_project_board(doc.boards[0]).c_str());
  check(snapshot(host).find("\"id\":\"dashboard:timer\"") == std::string::npos,
        "deleting a service retires its runtime and latest result");
  sputnik_notebook_destroy(host); sputnik_notebook_control_destroy(control);
}
int main(int argc, char **argv) {
  alarm(40);
  char pattern[] = "/tmp/sputnik-periodic-XXXXXX";
  const auto root = std::filesystem::path(mkdtemp(pattern));
  try {
    validation(); execution(root / "local.sputnikbook", nullptr);
    if (argc > 1) execution(root / "worker.sputnikbook", argv[1]);
    std::filesystem::remove_all(root);
    std::cout << "notebook periodic tests passed\n";
  } catch (const std::exception &error) {
    std::cerr << "notebook periodic tests failed: " << error.what() << '\n'; return 1;
  }
}

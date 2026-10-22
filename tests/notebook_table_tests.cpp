#include "tools/isputnik/tabs.h"
#include "tools/notebook-worker/process.h"
#include "tools/notebook-worker/presentation.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <unistd.h>

using namespace sputnik::notebook;
using namespace sputnik::notebook::worker;
using namespace std::chrono_literals;
static void check(bool value, const std::string &message) {
  if (!value) throw std::runtime_error(message);
}
static const std::string source = R"(from notebook.ui import DataTableView, Stopwatch
from ui_probe import measured
measured()
Stopwatch.measure: 42
rows = [{name: "before|value\n<x>", count: 9223372036854775806, score: 0.5, enabled: true, missing: null}]
view = DataTableView(rows, columns: [:name, :count, :score, :enabled, :missing])
csv = view.to_csv()
markdown = view.to_markdown()
notebook.show(view, id: "frozen", caption: "Frozen", live: false, order: 2)
rows[0].merge!({name: "changed"})
notebook.show(DataTableView([["old"]], columns: ["state"]), id: "replace", live: false, order: 3)
notebook.show(DataTableView([["latest"]], columns: ["state"]), id: "replace", live: false, order: 3)
notebook.show(DataTableView([], columns: ["empty A", "empty B"]), id: "empty", caption: "Empty", live: false, order: 1)
42
)";
static Presentation receive(Process &process, RequestId request, unsigned *live_count = nullptr) {
  PresentationAssembler terminal(request.generation, request.request);
  std::optional<PresentationAssembler> live;
  const auto deadline = std::chrono::steady_clock::now() + 15s;
  while (std::chrono::steady_clock::now() < deadline) {
    const auto message = process.receive(1s);
    if (!message) continue;
    if (message->kind == Kind::Error) throw std::runtime_error(message->fields.at(0));
    if (message->kind == Kind::Started || message->kind == Kind::Draining) continue;
    if (message->kind == Kind::LiveBegin || message->kind == Kind::LiveChunk || message->kind == Kind::LiveEnd) {
      if (!live) live.emplace(request.generation, request.request, true);
      if (const auto snapshot = live->accept(*message)) {
        if (live_count) for (const auto &cell : snapshot->cells) for (const auto &display : cell.displays)
          if (display.mime == "application/vnd.sputnik.table+json" && display.id == "live") ++*live_count;
        live.reset();
      }
    } else if (auto result = terminal.accept(*message)) return *result;
  }
  throw std::runtime_error("table worker timeout");
}
int main(int argc, char **argv) {
  char pattern[] = "/tmp/sputnik-datatable-XXXXXX";
  const auto directory = std::filesystem::path(mkdtemp(pattern));
  struct Cleanup { std::filesystem::path path; ~Cleanup() { std::filesystem::remove_all(path); } } cleanup{directory};
  try {
    auto document = make_project_document("DataTableView tests"); document.version = 3;
    document.sheets[0].cells.resize(1);
    document.sheets[0].cells[0].id = 1; document.sheets[0].cells[0].source = source;
    document.dependencies.push_back({(std::filesystem::path(SPUTNIK_SOURCE_ROOT) / "packages/notebook_ui").string(), false, {}});
    document.boards.push_back(parse_project_board(R"({"id":"tables","title":"Tables","sheet":"main","components":[{"id":"table","kind":"table","title":"Table","cell":"1","table_id":"frozen"}]})"));
    auto invalid = document;
    invalid.boards[0].components[0].extra["table_id"] = "42";
    bool rejected = false;
    try { serialize_project_document(invalid); } catch (const std::exception &) { rejected = true; }
    check(rejected, "table channel binding must be text");
    auto project = create_project(directory / "Tables.sputnikbook", document);
    std::filesystem::create_directories(project.directory / "modules");
    std::ofstream(project.directory / "modules/ui_probe.s") << R"(package ui_probe
from notebook.ui import Stopwatch, publish_point, image, publish_images, clear_images
export measured
def measured():
  Stopwatch.measure("module"):
    publish_point("probe", 1, 2)
    publish_images("probe", [image([0], width: 1, height: 1, format: :gray)])
    clear_images("probe")
    42
)";
    ProjectModule probe; probe.id = "ui_probe"; probe.path = "modules/ui_probe.s";
    document.modules.push_back(probe);
    save_project(&project, document);
    ProjectTabs tabs(project);
    auto board = document.boards[0]; board.components[0].extra.erase("table_id"); tabs.save_board(board);
    check(!load_project(project.directory).document.boards[0].components[0].extra.count("table_id"), "clearing a table channel does not resurrect old metadata");
    auto &session = tabs.tabs()[0]->session;
    evaluate_from(&session, 0, true, false, false);
    auto cell = [&]() -> Cell & { return session.cells[0]; };
    check(cell().ok, cell().error + session.environment_error);
    check(cell().result == "42" && cell().result_format.table_json.empty(), "show is independent from scalar result inspection");
    const auto baseline = cell().displays;
    check(baseline.size() == 3 && baseline[0].id == "empty" && baseline[1].id == "frozen" && baseline[2].id == "replace", "multiple ordered tables retain named identities");
    check(baseline[0].bytes.find("empty A") != std::string::npos && baseline[0].bytes.find("\"rows\":[]") != std::string::npos, "empty table retains declared schema");
    check(baseline[1].bytes.find("before|value") != std::string::npos && baseline[1].bytes.find("changed") == std::string::npos, "publication freezes mutable source data");
    check(baseline[1].bytes.find("9223372036854775806") != std::string::npos && baseline[1].bytes.find("true,null") != std::string::npos, "typed cells survive publication");
    check(baseline[2].bytes.find("latest") != std::string::npos && baseline[2].bytes.find("old") == std::string::npos, "static id replacement retains only the last table");
    auto local = [&](const std::string &name) { for (const auto &v : cell().locals) if (v.name == name) return v.text_value; return std::string(); };
    check(local("csv") == "\"name\",\"count\",\"score\",\"enabled\",\"missing\"\r\n\"before|value\n<x>\",\"9223372036854775806\",\"0.5\",\"true\",\"\"\r\n", "CSV methods preserve scalar values, quotes and line endings");
    check(local("markdown").find("before\\|value<br>&lt;x&gt;") != std::string::npos, "Markdown methods escape pipes, HTML and newlines");
    cell().source = "from notebook.ui import DataTableView\nnotebook.show(DataTableView([[1]], columns: [\"x\"]))\n1 / 0\n";
    evaluate_from(&session, 0, true, false, false);
    check(!cell().ok && cell().displays.size() == baseline.size() && cell().displays[1].bytes == baseline[1].bytes, "failed runs retain the prior successful table batch");
    for (const auto &bad : {"notebook.show([])\n", "from notebook.ui import DataTableView\nnotebook.show(DataTableView([[1, 2]], columns: [\"x\"]))\n", "from notebook.ui import DataTableView\nnotebook.show(DataTableView([[1, 2]], columns: [\"x\", \"x\"]))\n"}) {
      cell().source = bad; evaluate_from(&session, 0, true, false, false);
      check(!cell().ok && cell().displays.size() == baseline.size(), "invalid object/schema cannot replace prior tables");
    }
    if (argc > 1) {
      auto live_document = document;
      live_document.modules.clear();
      live_document.sheets[0].cells[0].source = R"(from notebook.ui import DataTableView, Stopwatch
import task
Stopwatch.measure("worker"): 42
notebook.show(DataTableView([[1]], columns: ["step"]), id: "live")
task.sleep(250)
notebook.show(DataTableView([[2]], columns: ["step"]), id: "live")
task.sleep(250)
42
)";
      auto live_project = create_project(directory / "Live.sputnikbook", live_document);
      Process process; process.start(std::filesystem::absolute(argv[1]).string());
      check(process.receive(5s)->kind == Kind::Ready, "worker Ready");
      receive(process, process.send(Kind::Load, {live_project.directory.string(), "main", "0"}));
      unsigned frames = 0;
      const auto result = receive(process, process.send(Kind::Run, {"1", "1"}), &frames);
      check(result.environment_error.empty() && result.cells[0].ok, result.environment_error + result.cells[0].error);
      check(frames >= 2 && result.cells[0].displays.size() == 1 && result.cells[0].displays[0].id == "live" && result.cells[0].displays[0].bytes.find("[2]") != std::string::npos, "worker transports intermediate tables and the final replacement");
      process.send(Kind::Shutdown);
    }
    std::cout << "DataTableView tests passed: object exports, explicit show, immutable typed snapshots, channels, failures and live worker updates\n";
  } catch (const std::exception &error) { std::cerr << "DataTableView tests failed: " << error.what() << '\n'; return 1; }
}

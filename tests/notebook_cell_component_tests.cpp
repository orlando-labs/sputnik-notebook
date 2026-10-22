#include "notebook/project.h"
#include "tools/isputnik/tabs.h"
#include "tools/notebook-macos/NotebookBridge.h"
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <unistd.h>

using namespace sputnik::notebook;
static void check(bool ok, const std::string &message) { if (!ok) throw std::runtime_error(message); }
template<class F> static void rejects(F function, const std::string &message) {
  try { function(); } catch (const std::exception &) { return; }
  throw std::runtime_error(message);
}
static std::string ui(const std::string &value = "2") {
  return R"({"inputs":[{"id":"gain","title":"Gain","type":"integer","default_json":")" + value + R"(","minimum":0,"maximum":100},{"id":"exact","title":"Exact","type":"integer","default_json":"9223372036854775806"}],"pre":[{"id":"form","kind":"parameter_form","title":"Parameters","fields":[{"input":"gain","control":{"style":"stepper","step":1}},{"input":"exact","control":{"style":"number"}}]}],"post":[{"id":"metric","kind":"metric","title":"Result"},{"id":"table","kind":"table","title":"Table","table_id":"view"},{"id":"chart","kind":"live_chart","title":"Live","chart_id":"shared"},{"id":"image","kind":"image","title":"Image","image_id":"shared"}],"future":12345678901234567890})";
}
static ProjectDocument fixture() {
  auto document = make_project_document("Cell components"); document.version = 4;
  document.dependencies.push_back({(std::filesystem::path(SPUTNIK_SOURCE_ROOT) / "packages/notebook_ui").string(), false, {}});
  document.inputs = {{"gain", "Global gain", "integer", std::int64_t(1000), {}, {}, {}}};
  document.sheets[0].cells = {
    {1, "code", R"(from notebook.ui import publish_point, publish_image, image, DataTableView
gain1 = notebook.cell_input("gain")
publish_point("shared", 0, gain1)
publish_image("shared", image([gain1], width: 1, height: 1, format: :gray))
notebook.show(DataTableView([[gain1]], columns: ["gain"]), id: "view")
gain1 * 2
)", CellMode::Watch, {{"cell_ui", ui()}}, {}},
    {2, "code", "gain2 = notebook.cell_input(\"gain\")\ngain2 * 3\n", CellMode::Watch, {{"cell_ui", ui("5")}}, {}},
    {3, "code", "gain1 + gain2\n", CellMode::Watch, {}, {}},
    {4, "code", "notebook.cell_input(\"gain\") + 100\n", CellMode::Manual, {{"cell_ui", ui("1")}}, {}},
    {5, "code", "notebook.input(\"gain\")\n", CellMode::Watch, {}, {}}};
  auto first = parse_project_cell_ui(document.sheets[0].cells[0].extra.at("cell_ui"));
  first.inputs.push_back({"only_first", "Private", "integer", std::int64_t(17), {}, {}, {}});
  document.sheets[0].cells[0].extra["cell_ui"] = serialize_project_cell_ui(first);
  return document;
}
static std::string snapshot(SputnikNotebook *book) {
  char *error = nullptr; char *raw = sputnik_notebook_snapshot(book, &error);
  const std::string detail = error ? error : "snapshot unavailable";
  sputnik_notebook_string_free(error); check(raw, detail);
  std::string result(raw); sputnik_notebook_string_free(raw); return result;
}
static std::string cell_snapshot(SputnikNotebook *book, unsigned id) {
  const auto state = snapshot(book);
  const auto start = state.find("{\"id\":\"" + std::to_string(id) + "\",\"kind\":\"code\"");
  check(start != std::string::npos, "missing cell snapshot");
  const auto end = state.find("{\"id\":\"", start + 1);
  // Nested result content may contain IDs; the result/error fields precede it.
  return state.substr(start, end == std::string::npos ? end : end - start);
}
static void result(SputnikNotebook *book, unsigned id, const std::string &expected) {
  check(cell_snapshot(book, id).find("\"result\":\"" + expected + "\"") != std::string::npos,
        "cell " + std::to_string(id) + " expected result " + expected + ": " + cell_snapshot(book, id));
}
static bool command(SputnikNotebook *book, const char *action, const char *cell = "1", const char *text = "", bool expected = true) {
  char *error = nullptr;
  const bool ok = sputnik_notebook_command(book, action, "sheet:main", cell, text, &error);
  const std::string detail = error ? error : ""; sputnik_notebook_string_free(error);
  check(ok == expected, std::string(action) + ": " + detail); return ok;
}
static void validation() {
  auto document = fixture();
  check(parse_project_document(serialize_project_document(document)).version == 4, "v4 roundtrip");
  document.version = 3;
  rejects([&] { serialize_project_document(document); }, "local semantics require v4");
  document = fixture();
  auto config = parse_project_cell_ui(ui());
  for (const auto &kind : {"periodic_work", "progress", "run", "action", "execution_controls", "tabs"}) {
    auto bad = config; bad.post[0].kind = kind;
    rejects([&] { validate_project_cell_ui(bad, 1); }, "unsupported cell component accepted");
  }
  auto bad = config; bad.post[0].cell = 2;
  rejects([&] { validate_project_cell_ui(bad, 1); }, "cross-cell source accepted");
  bad = config; bad.post[0].id = bad.pre[0].id;
  rejects([&] { validate_project_cell_ui(bad, 1); }, "duplicate identity accepted across zones");
  bad = config; bad.inputs.push_back(bad.inputs[0]);
  rejects([&] { validate_project_cell_ui(bad, 1); }, "duplicate local parameter accepted");
  bad = config; bad.post[3].extra["image_allow_read"] = "true";
  rejects([&] { validate_project_cell_ui(bad, 1); }, "cell image display became input");
  // Placement does not change availability or execution semantics.
  std::swap(config.pre, config.post); validate_project_cell_ui(config, 1);
}
static void runtime(const std::filesystem::path &root, const char *worker) {
  const auto path = root / (worker ? "Worker.sputnikbook" : "Local.sputnikbook");
  auto project = create_project(path, fixture());
  char *error = nullptr; auto *book = sputnik_notebook_open(path.c_str(), 0, nullptr, &error);
  check(book, error ? error : "open failed"); sputnik_notebook_string_free(error);
  SputnikNotebookControl *control = nullptr;
  if (worker) {
    control = sputnik_notebook_enable_worker(book, worker, &error);
    check(control, error ? error : "enable worker failed"); sputnik_notebook_string_free(error);
  }
  struct Cleanup { SputnikNotebook *book; SputnikNotebookControl *control; ~Cleanup() { sputnik_notebook_destroy(book); sputnik_notebook_control_destroy(control); } } cleanup{book, control};
  command(book, "set_cell_inputs", "1", R"({"gain":"3"})");
  check(snapshot(book).find("\"ok\":true") == std::string::npos, "input edits initialized a sheet");
  command(book, "run_all");
  result(book, 1, "6"); result(book, 2, "15"); result(book, 3, "8"); result(book, 4, "101"); result(book, 5, "1000");
  command(book, "set_cell_inputs", "1", R"({"gain":"7","exact":"9223372036854775807"})");
  result(book, 1, "14"); result(book, 2, "15"); result(book, 3, "12"); result(book, 5, "1000");
  const auto accepted = snapshot(book);
  check(accepted.find("9223372036854775807") != std::string::npos, "Int64 value rounded");
  command(book, "set_cell_inputs", "1", R"({"gain":"8","exact":"9223372036854775808"})", false);
  result(book, 1, "14"); check(snapshot(book) == accepted, "rejected batch mutated state");
  command(book, "set_cell_inputs", "1", R"({"gain":"7"})");
  check(snapshot(book) == accepted, "equal batch changed state");
  command(book, "set_cell_inputs", "4", R"({"gain":"9"})");
  check(cell_snapshot(book, 4).find("\"dirty\":true") != std::string::npos, "Manual cell not stale");
  command(book, "run", "4"); result(book, 4, "109");
  // UI-only changes preserve accepted values, previous output and unknown metadata.
  auto config = parse_project_cell_ui(ui()); config.post.erase(config.post.begin()); config.extra.clear();
  const auto saved = serialize_project_cell_ui(config);
  command(book, "save_cell_ui", "1", saved.c_str()); result(book, 1, "14");
  auto disk = load_project(path).document;
  const auto reopened = parse_project_cell_ui(disk.sheets[0].cells[0].extra.at("cell_ui"));
  check(reopened.extra.at("future") == "12345678901234567890", "opaque UI metadata lost");
  check(std::get<std::int64_t>(reopened.inputs[0].initial) == 2, "accepted values overwrote defaults");
  command(book, "source", "2", "gain2 = notebook.cell_input(\"only_first\")\n");
  command(book, "run", "2");
  check(cell_snapshot(book, 2).find("unknown or unavailable cell input") != std::string::npos, "missing local input did not fail");
  command(book, "source", "2", "gain2 = notebook.input(\"exact\")\n");
  command(book, "run", "2");
  check(cell_snapshot(book, 2).find("unknown or unavailable project input") != std::string::npos, "local parameter leaked into project scope");
  command(book, "move_down", "1"); command(book, "save");
  disk = load_project(path).document;
  check(disk.sheets[0].cells[1].id == 1 && disk.sheets[0].cells[1].extra.count("cell_ui"), "moving detached cell UI");

  // Stable ID edits migrate authored bindings and accepted local parameters,
  // including nested board panels, without running or saving source buffers.
  config = parse_project_cell_ui(disk.sheets[0].cells[1].extra.at("cell_ui"));
  config.post[0].cell = 1;
  command(book, "save_cell_ui", "1", serialize_project_cell_ui(config).c_str());
  ProjectComponent direct; direct.id = "direct"; direct.kind = "result"; direct.title = "Result"; direct.cell = 1;
  ProjectComponent nested = direct; nested.id = "nested"; nested.row = "row";
  ProjectBoardPanel panel; panel.id = "panel"; panel.title = "Panel";
  panel.rows.push_back({"row", {}, {}}); panel.components.push_back(nested);
  ProjectComponent tabs; tabs.id = "tabs"; tabs.kind = "tabs"; tabs.title = "Tabs";
  tabs.panels = std::vector<ProjectBoardPanel>{panel};
  ProjectBoard board; board.id = "dashboard"; board.title = "Dashboard"; board.sheet = "main";
  board.components = {direct, tabs};
  command(book, "save_board", "", serialize_project_board(board).c_str());
  command(book, "new_sheet", "", "other");
  const auto other = std::to_string(load_project(path).document.sheets.back().cells[0].id);
  const auto before = snapshot(book);
  for (const auto &invalid : {"", "0", "-1", "+5", "1.5", "abc", "18446744073709551615", "18446744073709551616", "2"}) {
    command(book, "set_cell_id", "1", invalid, false);
    check(snapshot(book) == before, "invalid Hard ID changed notebook state");
  }
  command(book, "set_cell_id", "1", other.c_str(), false);
  check(snapshot(book) == before, "cross-sheet duplicate Hard ID changed notebook state");
  command(book, "set_cell_id", "1", "1");
  check(snapshot(book) == before, "equal Hard ID changed notebook state");
  command(book, "source", "2", "gain2 = notebook.cell_input(\"gain\")\ngain2 * 3\n");
  command(book, "source", "1", "gain1 = notebook.cell_input(\"gain\")\ngain1 * 4\n");
  const auto saved_source = load_project(path).document.sheets[0].cells[1].source;
  command(book, "set_cell_id", "1", "7001");
  result(book, 7001, "14");
  disk = load_project(path).document;
  check(disk.sheets[0].cells[1].id == 7001 && disk.sheets[0].cells[1].source == saved_source,
        "Hard ID edit saved an unrelated source buffer");
  check(disk.boards[0].components[0].cell == 7001 && disk.boards[0].components[1].panels->at(0).components[0].cell == 7001,
        "Hard ID edit detached board bindings");
  const auto renamed_ui = parse_project_cell_ui(disk.sheets[0].cells[1].extra.at("cell_ui"));
  check(renamed_ui.post[0].cell == 7001 && renamed_ui.extra.at("future") == "12345678901234567890",
        "Hard ID edit lost owned component bindings or opaque metadata");
  command(book, "run", "7001"); result(book, 7001, "28");
  command(book, "set_cell_inputs", "7001", R"({"gain":"8"})"); result(book, 7001, "32");
  command(book, "move_up", "7001"); command(book, "save", "7001");
  disk = load_project(path).document;
  check(disk.sheets[0].cells[0].id == 7001 && disk.boards[0].components[0].cell == 7001,
        "reordering changed a Hard ID or binding");
  command(book, "add_text", "7001");
  // The new text cell has no persisted metadata yet.
  const auto state = snapshot(book);
  const auto text_start = state.find("\"kind\":\"text\"");
  const auto id_start = state.rfind("\"id\":\"", text_start) + 6;
  const auto text_id = state.substr(id_start, state.find('"', id_start) - id_start);
  command(book, "set_cell_id", text_id.c_str(), "7102");
  check(load_project(path).document.sheets[0].cells.back().id == 7102, "new text cell Hard ID was not persisted");
  command(book, "set_cell_id", "7001", "9007199254740993");
  disk = load_project(path).document;
  check(disk.sheets[0].cells[0].id == 9007199254740993ULL && disk.boards[0].components[0].cell == 9007199254740993ULL,
        "Hard ID lost 64-bit precision");
  command(book, "save", "9007199254740993");
  char *open_error = nullptr;
  auto *again = sputnik_notebook_open(path.c_str(), 0, nullptr, &open_error);
  check(again, open_error ? open_error : "reopen renamed cell failed"); sputnik_notebook_string_free(open_error);
  check(snapshot(again).find("\"id\":\"9007199254740993\"") != std::string::npos, "reopen lost Hard ID");
  sputnik_notebook_destroy(again);
}
int main(int argc, char **argv) {
  char pattern[] = "/tmp/sputnik-cell-components-XXXXXX";
  const auto root = std::filesystem::path(mkdtemp(pattern));
  struct Cleanup { std::filesystem::path root; ~Cleanup() { std::filesystem::remove_all(root); } } cleanup{root};
  try {
    validation(); runtime(root, nullptr); if (argc > 1) runtime(root, argv[1]);
    std::cout << "Cell component tests passed: schema, scope, exact values, atomic Apply, Watch/Manual, worker and persistence\n";
  } catch (const std::exception &error) { std::cerr << "Cell component tests failed: " << error.what() << '\n'; return 1; }
}

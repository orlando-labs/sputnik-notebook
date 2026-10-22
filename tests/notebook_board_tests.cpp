#include "notebook/project.h"
#include "tools/isputnik/tabs.h"
#include "tools/notebook-macos/NotebookBridge.h"
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <unistd.h>
#include <thread>

using namespace sputnik::notebook;
static void check(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
template<class F> static void rejects(F f, const char *message) {
  bool rejected = false; try { f(); } catch (const std::exception &) { rejected = true; }
  check(rejected, message);
}
static ProjectDocument fixture() {
  auto doc = make_project_document("Board test"); doc.version = 2;
  doc.inputs = {{"gain", "Gain", "number", 2.0, 0.0, 100.0, {}},
                {"enabled", "Enabled", "boolean", true, {}, {}, {}},
                {"label", "Label", "string", std::string("Привет"), {}, {}, {}}};
  doc.sheets[0].cells = {
      {1, "code", "gain = notebook.input(\"gain\")\ngain\n", CellMode::Watch, {}, {}},
      {2, "code", "value = gain * 21\nvalue\n", CellMode::Watch, {}, {}},
      {3, "code", "manual = notebook.input(\"gain\") * 100\nmanual\n", CellMode::Manual, {}, {}},
      {4, "code", "manual + 1\n", CellMode::Watch, {}, {}},
      {5, "code", "42\n", CellMode::Watch, {}, {}}};
  doc.boards = {{"dashboard", "Dashboard", "main", 2,
                 {{"gain", "input", "Gain", "gain", 0, "", {}},
                  {"value", "text", "Result", "", 2, "value", {}},
                  {"run", "run", "Recompute", "", 3, "", {}},
                  {"loss", "live_chart", "Training loss", "", 0, "",
                   {{"chart_id", "\"loss\""}, {"x_label", "\"Step\""},
                    {"y_label", "\"Loss\""}, {"stroke", "\"#d97706\""},
                    {"caption", "\"Training cross-entropy\""},
                    {"y_min", "0"}, {"y_max", "100"}}}}, {}}};
  return doc;
}
static void presentation_component_tests(const std::filesystem::path &root) {
  auto doc = fixture();
  auto board = parse_project_board(R"({"id":"presentation","title":"Presentation","sheet":"main","rows":[{"id":"notes"},{"id":"outputs","height":180}],"components":[
    {"id":"note","kind":"rich_text","title":"Note","row":"notes","span":12,"text_mode":"richtext","text_content":{"source":"Answer: {{value}}","formatting":{"version":1,"runs":[{"start":0,"length":6,"style":"heading1"}]}},"future":12345678901234567890},
    {"id":"inspect","kind":"result","title":"Result","cell":"2","row":"outputs","span":8},
    {"id":"progress","kind":"progress","title":"Progress","cell":"2","row":"outputs","span":4,"progress_id":"training"}
  ]})");
  doc.boards = {board};
  auto roundtrip = parse_project_document(serialize_project_document(doc));
  check(roundtrip.boards[0].components.size() == 3 &&
        roundtrip.boards[0].components[0].extra.at("text_content") == board.components[0].extra.at("text_content"),
        "shared text source/formatting and explicit result/progress layout roundtrip");
  auto bad = doc;
  bad.boards[0].components[0].extra["text_content"] = R"({"source":"🙂","formatting":{"version":1,"runs":[{"start":1,"length":1,"style":"body"}]}})";
  rejects([&] { serialize_project_document(bad); }, "board text uses sheet UTF-16 formatting validation");
  bad = doc; bad.boards[0].components[0].extra.erase("text_content");
  rejects([&] { serialize_project_document(bad); }, "text source must be explicit");
  bad = doc; bad.boards[0].components[0].extra["text_mode"] = "\"html\"";
  rejects([&] { serialize_project_document(bad); }, "unsupported text modes rejected");
  bad = doc; bad.boards[0].components[0].cell = 2;
  rejects([&] { serialize_project_document(bad); }, "owned text does not mix cell bindings");
  bad = doc; bad.boards[0].components[1].cell = 0;
  rejects([&] { serialize_project_document(bad); }, "inspector requires a source cell");
  bad = doc; bad.boards[0].components[2].extra["progress_id"] = "42";
  rejects([&] { serialize_project_document(bad); }, "progress channel must be text");
  const auto project = create_project(root / "Presentation.sputnikbook", doc);
  ProjectTabs tabs(project);
  board.components[0].extra["text_mode"] = "\"markdown\"";
  board.components[0].extra["text_content"] = R"({"source":"# Answer\n\n{{value}}"})";
  board.components[0].extra.erase("future");
  board.components[2].extra.erase("progress_id");
  tabs.save_board(board);
  const auto saved = load_project(project.directory).document.boards[0];
  check(saved.components[0].extra.at("text_mode") == "\"markdown\"" &&
        !parse_project_text_content(saved.components[0].extra.at("text_content")).formatting.size() &&
        saved.components[0].extra.at("future") == "12345678901234567890" &&
        !saved.components[2].extra.count("progress_id"),
        "text edits and clearing progress selectors do not resurrect old fields; opaque metadata survives");
}

static void p0_validation_tests(const std::filesystem::path &root) {
  auto doc = fixture();
  doc.boards = {parse_project_board(R"({"id":"p0","title":"P0","sheet":"main","rows":[{"id":"r"}],"components":[
    {"id":"slider","kind":"input","title":"Slider","input":"gain","row":"r","span":4,"control":{"style":"slider","step":0.5}},
    {"id":"form","kind":"parameter_form","title":"Form","row":"r","span":4,"fields":[{"input":"label","control":{"style":"select","options":[{"label":"Greeting","value_json":"\"Привет\""}]}}]},
    {"id":"table","kind":"table","title":"Table","cell":"2","row":"r","span":4}]})")};
  serialize_project_document(doc);
  auto bad = doc; bad.boards[0].components[0].extra["control"] = R"({"style":"slider","minimum":100,"maximum":0})";
  rejects([&] { serialize_project_document(bad); }, "slider range must overlap project bounds");
  bad = doc; bad.boards[0].components[0].extra["control"] = R"({"style":"stepper","step":0})";
  rejects([&] { serialize_project_document(bad); }, "step must be positive");
  bad = doc; bad.boards[0].components[1].extra["fields"] = R"([{"input":"missing","control":{"style":"automatic"}}])";
  rejects([&] { serialize_project_document(bad); }, "form bindings are validated");
  bad = doc; bad.boards[0].components[1].extra["fields"] = R"([{"input":"label","control":{"style":"select","options":[{"label":"Wrong","value_json":"42"}]}}])";
  rejects([&] { serialize_project_document(bad); }, "choice option types match the input");
  bad = doc; bad.boards[0].components[1].extra["fields"] = R"([{"input":"label","control":{"style":"automatic"}},{"input":"label","control":{"style":"automatic"}}])";
  rejects([&] { serialize_project_document(bad); }, "form cannot duplicate an input");
  ProjectTabs tabs(create_project(root / "P0.sputnikbook", doc));
  const auto old = tabs.inputs();
  rejects([&] { tabs.set_inputs({{"gain", "3"}, {"label", "false"}}); }, "invalid batch is rejected atomically");
  check(tabs.inputs() == old, "all old values survive a rejected batch");
  check(tabs.set_inputs({{"gain", "3"}, {"label", "\"updated\""}}), "valid batch accepted");
  check(!tabs.set_inputs({{"gain", "3.0"}, {"label", "\"updated\""}}), "equal publication is quiet");
  check(!tabs.active().session.cells[0].ok, "changing a batch does not start an uninitialized sheet");
  rejects([] { parse_project_input_edits(R"({"gain":"1","gain":"2"})"); }, "duplicate batch IDs rejected");
}

static void p1_validation_tests(const std::filesystem::path &root) {
  auto doc = fixture();
  doc.boards = {parse_project_board(R"({"id":"p1","title":"P1","sheet":"main","rows":[{"id":"r"}],"components":[
    {"id":"presets","kind":"parameter_presets","title":"Presets","row":"r","span":4,"p1":{"preset_inputs":["gain","label"],"presets":[{"id":"base","title":"Base","values":{"gain":"3.0","label":"\"Test\""}}]}},
    {"id":"action","kind":"action","title":"Action","row":"r","span":4,"module_id":"work","function":"compute","p1":{"arguments":[{"id":"a","input":"gain"},{"id":"b","value_json":"9223372036854775807"},{"id":"c","name":"label","value_json":"\"x); raise Error()\""}]}},
    {"id":"group","kind":"group","title":"Details","row":"r","span":4,"panels":[{"id":"content","title":"Content","rows":[{"id":"inside"}],"components":[{"id":"log","kind":"log","title":"Output","row":"inside","cell":"1"}]}]}]})")};
  const auto encoded = serialize_project_document(doc);
  check(serialize_project_document(parse_project_document(encoded)) == encoded, "P1 nested components roundtrip");
  const auto call = project_action_invocation(doc.boards[0].components[1], *project_input_defaults(doc));
  check(call.source.find("raise Error") == std::string::npos && call.source.find("label: notebook.input(") != std::string::npos,
        "action constants never enter executable source");
  bool exact = false;
  for (const auto &entry : *call.inputs) if (const auto number = std::get_if<std::int64_t>(&entry.second)) exact = exact || *number == 9223372036854775807LL;
  check(exact, "action constant preserves exact Int64");
  auto bad = doc; bad.boards[0].components[0].extra["p1"] = R"({"presets":[{"id":"p","title":"P","values":{"gain":"false"}}]})";
  rejects([&] { serialize_project_document(bad); }, "preset type mismatch rejected");
  bad = doc; bad.boards[0].components[1].extra["p1"] = R"({"arguments":[{"input":"gain","value_json":"1"}]})";
  rejects([&] { serialize_project_document(bad); }, "action requires unambiguous argument source");
  bad = doc; bad.boards[0].components[1].extra["function"] = "\"x); bad()\"";
  rejects([&] { serialize_project_document(bad); }, "action function cannot inject source");
  bad = doc; bad.boards[0].components[2].panels->push_back(bad.boards[0].components[2].panels->front());
  rejects([&] { serialize_project_document(bad); }, "group requires a single grid");
  bad = doc; bad.boards[0].components[0].extra["p1"] = R"({"series":[{"id":"a","title":"A","stroke":"#ffffff"},{"id":"a","title":"B","stroke":"#000000"}]})";
  rejects([&] { serialize_project_document(bad); }, "series identities must be unique");
  ProjectTabs tabs(create_project(root / "P1.sputnikbook", doc));
  auto board = tabs.project().document.boards[0]; board.components[0].extra.erase("p1");
  tabs.save_board(board);
  check(!load_project(tabs.project().directory).document.boards[0].components[0].extra.count("p1"), "clearing P1 settings cannot resurrect saved presets");
}

static void p1_inprocess_action_tests(const std::filesystem::path &root) {
  const auto destination = root / "P1Action.sputnikbook";
  std::filesystem::copy("tools/notebook-macos/Samples/Workstation.sputnikbook", destination, std::filesystem::copy_options::recursive);
  char *error = nullptr;
  std::unique_ptr<SputnikNotebook, decltype(&sputnik_notebook_destroy)> host(
      sputnik_notebook_open(destination.c_str(), 0, nullptr, &error), &sputnik_notebook_destroy);
  check(host != nullptr, error ? error : "open in-process P1 fixture");
  const auto invoke = [&](const char *expected) {
    check(sputnik_notebook_command(host.get(), "action_run", "sheet:main", "action", "workstation", &error), error ? error : "in-process action command");
    auto json = sputnik_notebook_snapshot(host.get(), &error);
    check(json != nullptr, "in-process action snapshot");
    const std::string snapshot(json); sputnik_notebook_string_free(json);
    check(snapshot.find(expected) != std::string::npos, "in-process action freezes arguments and retains its own module state");
  };
  invoke("\"result\":\"[12, 1]\""); invoke("\"result\":\"[12, 2]\"");
  check(sputnik_notebook_command(host.get(), "set_inputs", nullptr, nullptr, R"({"gain":"3.0","offset":"4"})", &error), "in-process batch publication");
  invoke("\"result\":\"[34, 3]\"");
}

static void range_input_tests(const std::filesystem::path &root) {
  auto doc = fixture();
  const auto initial = R"({"start":0,"finish":15,"inclusive_end":false,"step":3})";
  doc.inputs.push_back(parse_project_input(std::string(R"({"id":"some_range","title":"Range","type":"range","default":)") + initial + "}"));
  doc.boards = {parse_project_board(R"({"id":"ranges","title":"Ranges","sheet":"main","components":[{"id":"range","kind":"range_input","title":"Range","input":"some_range"}]})")};
  doc.sheets[0].cells = {{1, "code", "r = notebook.input(\"some_range\")\nr.to_array()\n", CellMode::Watch, {}, {}}};
  const auto serialized = serialize_project_document(doc);
  check(serialize_project_document(parse_project_document(serialized)) == serialized, "Range defaults and bindings roundtrip");
  const auto project = create_project(root / "Range.sputnikbook", doc);
  ProjectTabs tabs(project);
  auto &session = tabs.active().session;
  auto run = [&](const char *expected) {
    evaluate_from(&session, 0, true, false, false);
    if (!session.cells[0].ok || session.cells[0].result != expected)
      throw std::runtime_error("Range execution: " + session.cells[0].result + " / " + session.cells[0].error);
  };
  run("[0, 3, 6, 9, 12]");
  const auto frozen = session.project_inputs;
  check(tabs.set_inputs({{"some_range", R"({"start":0,"finish":15,"inclusive_end":true,"step":3})"}}), "Range apply");
  check(session.cells[0].result == "[0, 3, 6, 9, 12, 15]" && !std::get<sputnik::runtime::NotebookInputRange>(frozen->at("some_range")).inclusive_end,
        "Range apply refreshes Watch consumers and preserves the frozen snapshot");
  run("[0, 3, 6, 9, 12, 15]");
  const auto accepted = tabs.inputs().at("some_range");
  for (const auto invalid : {
      R"({"start":0,"finish":15,"inclusive_end":true,"step":0})",
      R"({"start":0,"finish":15,"inclusive_end":true,"step":0.5})",
      R"({"start":0,"finish":15,"inclusive_end":true,"step":1e999})",
      R"({"start":0,"finish":9223372036854775808,"inclusive_end":true,"step":1})",
      R"({"start":0,"finish":15,"inclusive_end":"true","step":1})",
      R"({"start":0,"finish":15,"inclusive_end":true})", "[0,15]", "15"}) {
    rejects([&] { tabs.set_inputs({{"gain", "3"}, {"some_range", invalid}}, false); }, "invalid Range rejects whole batch");
    check(tabs.inputs().at("some_range") == accepted && std::get<double>(tabs.inputs().at("gain")) == 2.0, "rejection preserves all inputs");
  }
  tabs.set_inputs({{"some_range", R"({"start":15,"finish":0,"inclusive_end":false,"step":-3})"}}, false);
  run("[15, 12, 9, 6, 3]");
  tabs.set_inputs({{"some_range", R"({"start":0.0,"finish":1.0,"inclusive_end":false,"step":0.25})"}}, false);
  run("[0, 0.25, 0.5, 0.75]");
  tabs.set_inputs({{"some_range", R"({"start":9007199254740993,"finish":9007199254740997,"inclusive_end":true,"step":2})"}}, false);
  run("[9007199254740993, 9007199254740995, 9007199254740997]");
  const auto restored = serialize_project_input_value(accepted);
  tabs.restore_inputs({{"project:some_range", restored}});
  run("[0, 3, 6, 9, 12, 15]");
  rejects([&] { tabs.delete_input("some_range"); }, "bound Range cannot be deleted");
  check(std::get<sputnik::runtime::NotebookInputRange>(load_project(project.directory).document.inputs.back().initial).inclusive_end == false,
        "runtime edits preserve saved default");
  auto bad = doc; bad.boards[0].components[0].input = "gain";
  rejects([&] { serialize_project_document(bad); }, "Range control requires a Range parameter");
  auto slider = doc.boards[0];
  slider.components[0].extra["control"] = R"({"style":"slider","minimum":0,"maximum":30,"step":1})";
  tabs.save_board(slider);
  const auto before_slider = tabs.inputs().at("some_range");
  for (const auto invalid : {
      R"({"start":10,"finish":5,"inclusive_end":true,"step":1})",
      R"({"start":-1,"finish":15,"inclusive_end":true,"step":1})",
      R"({"start":0,"finish":31,"inclusive_end":true,"step":1})"}) {
    rejects([&] { tabs.set_inputs({{"gain", "3"}, {"some_range", invalid}}, false); }, "shared slider enforces both bounds and endpoint order");
    rejects([&] { tabs.restore_inputs({{"project:some_range", invalid}}); }, "Restore cannot bypass slider constraints");
    check(tabs.inputs().at("some_range") == before_slider && std::get<double>(tabs.inputs().at("gain")) == 2.0, "slider rejection is atomic");
  }
  slider.components[0].extra["control"] = R"({"style":"range_sliders","start_minimum":0,"start_maximum":10,"finish_minimum":5,"finish_maximum":20,"step":1})";
  tabs.save_board(slider);
  check(load_project(project.directory).document.boards[0].components[0].extra.at("control").find("range_sliders") != std::string::npos,
        "separate slider domains persist");
  for (const auto invalid : {
      R"({"start":9,"finish":7,"inclusive_end":true,"step":1})",
      R"({"start":11,"finish":15,"inclusive_end":true,"step":1})",
      R"({"start":0,"finish":4,"inclusive_end":true,"step":1})"})
    rejects([&] { tabs.set_inputs({{"some_range", invalid}}, false); }, "separate sliders enforce their own domains and endpoint order");
  check(tabs.set_inputs({{"some_range", R"({"start":8,"finish":8,"inclusive_end":true,"step":1})"}}, false), "sliders allow equal endpoints");
  for (const auto invalid : {
      R"({"style":"range_sliders","start_minimum":20,"start_maximum":30,"finish_minimum":0,"finish_maximum":10})",
      R"({"style":"slider","minimum":0,"maximum":30,"step":0})",
      R"({"style":"slider","minimum":0,"maximum":9007199254740992})",
      R"({"style":"range_sliders","start_minimum":0,"start_maximum":10})"}) {
    auto broken = slider; broken.components[0].extra["control"] = invalid;
    rejects([&] { tabs.save_board(broken); }, "invalid slider configuration is rejected");
  }
  // The same control options work on a regular Range-typed Input and in forms.
  slider.components[0].kind = "input"; tabs.save_board(slider);
  rejects([&] { tabs.set_inputs({{"some_range", R"({"start":9,"finish":7,"inclusive_end":true,"step":1})"}}, false); }, "regular Range input enforces slider order");
  slider.components = {parse_project_board(R"({"id":"b","title":"B","sheet":"main","components":[{"id":"form","kind":"parameter_form","title":"Form","fields":[{"input":"some_range","control":{"style":"slider","minimum":0,"maximum":30}}]}]})").components[0]};
  tabs.save_board(slider);
  rejects([&] { tabs.set_inputs({{"some_range", R"({"start":0,"finish":31,"inclusive_end":true,"step":1})"}}, false); }, "form Range slider enforces domain");
  auto local = doc;
  local.version = 4;
  local.boards.clear();
  local.sheets[0].cells[0].extra["cell_ui"] = R"({"inputs":[{"id":"local_range","title":"Local Range","type":"range","default_json":"{\"start\":0,\"finish\":15,\"inclusive_end\":true,\"step\":1}"}],"pre":[{"id":"local","kind":"input","title":"Local","input":"local_range","control":{"style":"slider","minimum":0,"maximum":30}}],"post":[]})";
  ProjectTabs local_tabs(create_project(root / "LocalRange.sputnikbook", local));
  rejects([&] { local_tabs.set_cell_inputs(1, {{"local_range", R"({"start":10,"finish":5,"inclusive_end":true,"step":1})"}}, false); }, "cell Range slider enforces order");
  local_tabs.set_cell_inputs(1, {{"local_range", R"({"start":5,"finish":25,"inclusive_end":true,"step":1})"}}, false);
  auto local_ui = parse_project_cell_ui(local.sheets[0].cells[0].extra.at("cell_ui"));
  local_ui.pre[0].extra["control"] = R"({"style":"slider","minimum":0,"maximum":20})";
  rejects([&] { local_tabs.save_cell_ui(1, serialize_project_cell_ui(local_ui)); }, "narrowing cell slider domains validates the accepted value before saving");
  const auto legacy = parse_project_document(R"({"format":"sputnik-notebook","version":3,"title":"Legacy","dependencies":[],"active_sheet":"main","sheets":[{"id":"main","title":"Main","cells":[]}],"modules":[],"auto_imports":[],"inputs":[{"id":"low","title":"Low","type":"integer","default":9007199254740993},{"id":"high","title":"High","type":"integer","default":9007199254740997}],"boards":[{"id":"b","title":"Board","sheet":"main","components":[{"id":"some_range","title":"Range","kind":"range_input","range_lower":"low","range_upper":"high"}]}]})");
  check(legacy.inputs.size() == 3 && legacy.boards[0].components[0].input == "some_range" &&
        std::get<std::int64_t>(std::get<sputnik::runtime::NotebookInputRange>(legacy.inputs.back().initial).start) == 9007199254740993LL,
        "legacy pairs upgrade without losing Int64 or existing parameter definitions");
  check(parse_project_document(serialize_project_document(legacy)).inputs.size() == 3, "legacy upgrade is stable");
}

static void tabs_tests(const std::filesystem::path &root) {
  auto doc = fixture();
  doc.boards = {parse_project_board(R"({"id":"tabs_board","title":"Tabs","sheet":"main","rows":[{"id":"root"}],"components":[
    {"id":"tabs","kind":"tabs","title":"Workspace","row":"root","span":12,"panels":[
      {"id":"controls","title":"Controls","rows":[{"id":"content","height":160}],"components":[
        {"id":"tab_input","kind":"input","title":"Gain","input":"gain","row":"content","span":4},
        {"id":"tab_value","kind":"text","title":"Result","cell":"2","binding":"value","row":"content","span":8}]},
      {"id":"charts","title":"Charts","rows":[{"id":"content"}],"components":[
        {"id":"nested","kind":"tabs","title":"Views","row":"content","span":12,"panels":[
          {"id":"loss","title":"Loss","rows":[{"id":"content","height":240}],"components":[
            {"id":"tab_chart","kind":"live_chart","title":"Loss","chart_id":"loss","y_min":0,"y_max":100,"row":"content","span":12}]},
          {"id":"empty","title":"Empty","rows":[],"components":[]}]}]}]}]})")};
  auto encoded = serialize_project_document(doc);
  auto decoded = parse_project_document(encoded);
  check(serialize_project_document(decoded) == encoded, "nested tabs stable roundtrip");
  check(decoded.boards[0].components[0].cell == 0 &&
        decoded.boards[0].components[0].panels->at(0).components[1].binding == "value" &&
        decoded.boards[0].components[0].panels->at(1).components[0].panels->at(0).rows[0].height == 240,
        "tabs own grids and retain nested bindings and geometry without a cell");
  auto bad = doc;
  bad.boards[0].components[0].panels.reset();
  rejects([&] { serialize_project_document(bad); }, "tabs without panels rejected");
  bad = doc; bad.boards[0].components[0].panels->clear();
  rejects([&] { serialize_project_document(bad); }, "tabs without any panel rejected");
  bad = doc; bad.boards[0].components[0].panels->at(0).components[0].span = 5;
  rejects([&] { serialize_project_document(bad); }, "nested panel row overflow rejected");
  bad = doc; bad.boards[0].components[0].panels->at(0).components[0].row = "root";
  rejects([&] { serialize_project_document(bad); }, "panel cannot refer to a parent row");
  bad = doc; bad.boards[0].components[0].panels->at(0).components[0].input = "missing";
  rejects([&] { serialize_project_document(bad); }, "nested input bindings validated");
  bad = doc; bad.boards[0].components[0].panels->at(1).id = "controls";
  rejects([&] { serialize_project_document(bad); }, "duplicate sibling panel ids rejected");
  bad = doc; bad.boards[0].components[0].panels->at(0).components[0].id = "tabs";
  rejects([&] { serialize_project_document(bad); }, "component ids unique across all panel grids");
  bad = doc; bad.boards[0].components[0].panels->at(0).rows[0].height = 5000;
  rejects([&] { serialize_project_document(bad); }, "nested row height validated");
  bad = doc; bad.boards[0].components[0].kind = "text"; bad.boards[0].components[0].cell = 1;
  rejects([&] { serialize_project_document(bad); }, "leaf components cannot own panels");
  bad = doc;
  auto *container = &bad.boards[0].components[0];
  for (unsigned depth = 0; depth < 9; ++depth) {
    ProjectComponent nested; nested.id = "deep_" + std::to_string(depth); nested.kind = "tabs";
    nested.row = "r"; nested.panels = std::vector<ProjectBoardPanel>{{"p", "Panel", {{"r", {}, {}}}, {}, {}}};
    container->panels = std::vector<ProjectBoardPanel>{{"p", "Panel", {{"r", {}, {}}}, {nested}, {}}};
    container = &container->panels->at(0).components[0];
  }
  rejects([&] { serialize_project_document(bad); }, "tabs nesting is bounded");
  bad = doc;
  auto &large_panel = bad.boards[0].components[0].panels->at(0);
  large_panel.rows.clear(); large_panel.components.clear();
  for (unsigned i = 0; i < 256; ++i) large_panel.rows.push_back({"r_" + std::to_string(i), {}, {}});
  rejects([&] { serialize_project_document(bad); }, "row budget spans all panels");
  large_panel.rows.resize(22);
  for (unsigned i = 0; i < 256; ++i) {
    ProjectComponent c; c.id = "extra_" + std::to_string(i); c.kind = "text"; c.cell = 1;
    c.row = large_panel.rows[i / 12].id; c.span = 1; large_panel.components.push_back(c);
  }
  rejects([&] { serialize_project_document(bad); }, "component budget spans all panels");
  rejects([] { parse_project_board(R"({"id":"b","title":"B","sheet":"main","components":[{"id":"c","kind":"tabs","title":"T","panels":[{"id":"p","title":"P","components":[]}]}]})"); },
          "panel rows are required");
  rejects([] { parse_project_board(R"({"id":"b","title":"B","sheet":"main","components":[{"id":"c","kind":"tabs","title":"T","panels":{}}]})"); },
          "panels must be an array");

  auto &panel = doc.boards[0].components[0].panels->at(0);
  panel.extra["future"] = "1.23456789012345678901234567890";
  panel.rows[0].extra["future"] = "{\"n\":12345678901234567890}";
  panel.components[0].extra["future"] = "true";
  const auto project = create_project(root / "Tabs.sputnikbook", doc);
  ProjectTabs tabs(project);
  auto edited = tabs.project().document.boards[0];
  auto &edited_panel = edited.components[0].panels->at(0);
  edited_panel.extra.clear(); edited_panel.rows[0].extra.clear(); edited_panel.components[0].extra.clear();
  edited_panel.title = "Parameters"; edited_panel.rows[0].height.reset();
  edited.components[0].panels->at(1).components[0].panels->at(0).components[0].extra.erase("y_max");
  tabs.save_board(edited);
  const auto saved = load_project(project.directory).document.boards[0];
  const auto &saved_panel = saved.components[0].panels->at(0);
  check(saved_panel.title == "Parameters" && saved_panel.extra.at("future") == panel.extra.at("future") &&
        saved_panel.rows[0].extra == panel.rows[0].extra && !saved_panel.rows[0].height &&
        saved_panel.components[0].extra.at("future") == "true", "panel and nested grid metadata preserved exactly");
  check(!saved.components[0].panels->at(1).components[0].panels->at(0).components[0].extra.count("y_max"),
        "cleared nested chart bounds stay automatic");
  char *error = nullptr;
  auto host = sputnik_notebook_open(project.directory.c_str(), 0, nullptr, &error);
  check(host != nullptr, error ? error : "tabs bridge open");
  auto snapshot = sputnik_notebook_snapshot(host, &error);
  check(snapshot && std::string(snapshot).find("\"panels\":[") != std::string::npos &&
        std::string(snapshot).find("Parameters") != std::string::npos, "bridge snapshot includes panel grids");
  sputnik_notebook_string_free(snapshot);
  edited.components[0].panels->erase(edited.components[0].panels->begin() + 1);
  const auto payload = serialize_project_board(edited);
  check(sputnik_notebook_command(host, "save_board", nullptr, nullptr, payload.c_str(), &error),
        error ? error : "bridge saves tabs");
  check(load_project(project.directory).document.boards[0].components[0].panels->size() == 1,
        "deleted panel and subtree stay deleted");
  sputnik_notebook_destroy(host);
}

int main(int argc, char **argv) {
  char pattern[] = "/tmp/sputnik-board-tests-XXXXXX";
  const auto temp = mkdtemp(pattern); check(temp, "mkdtemp");
  const auto root = std::filesystem::path(temp);
  try {
    auto values = std::make_shared<sputnik::runtime::NotebookInputSnapshot>();
    values->emplace("gain", 2.0);
    sputnik::runtime::NotebookInputCapture capture(values);
    std::thread worker([&] { check(!capture.read("gain"), "foreign thread must not read root inputs"); });
    worker.join();
    check(capture.read("gain").has_value(), "root thread input capture");
    check(capture.read("gain").has_value() && capture.finish().size() == 1, "duplicate reads collapse");
    check(!capture.read("gain"), "closed capture rejects delayed reads");
    tabs_tests(root);
    presentation_component_tests(root);
    p0_validation_tests(root);
    p1_validation_tests(root);
    p1_inprocess_action_tests(root);
    range_input_tests(root);
    auto doc = fixture();
    auto encoded = serialize_project_document(doc);
    auto decoded = parse_project_document(encoded);
    check(decoded.version == 2 && decoded.boards.size() == 1 && decoded.inputs.size() == 3, "v2 roundtrip");
    check(std::get<bool>(decoded.inputs[1].initial), "true must survive JSON roundtrip");
    check(serialize_project_document(decoded) == encoded, "stable v2 serialization");
    check(!decoded.boards[0].rows, "legacy boards remain unchanged on opening");
    auto row_doc = doc;
    auto &row_board = row_doc.boards[0];
    row_board.rows = std::vector<ProjectBoardRow>{{"controls", 180, {}}, {"outputs", 420, {}}};
    for (std::size_t i = 0; i < row_board.components.size(); ++i) {
      auto &component = row_board.components[i];
      component.row = i < 2 ? "controls" : "outputs";
      component.span = i % 2 == 0 ? 4 : 8;
      component.h_align = "center"; component.v_align = "bottom";
    }
    const auto row_roundtrip = parse_project_document(serialize_project_document(row_doc));
    check(row_roundtrip.boards[0].rows->at(1).height == 420 &&
          row_roundtrip.boards[0].components[1].span == 8 &&
          row_roundtrip.boards[0].components[1].h_align == "center" &&
          row_roundtrip.boards[0].components[1].v_align == "bottom", "row geometry round trip");
    auto bad_rows = row_doc;
    bad_rows.boards[0].components[0].span = 5;
    rejects([&] { serialize_project_document(bad_rows); }, "row overflow rejected");
    bad_rows = row_doc; bad_rows.boards[0].components[0].row = "missing";
    rejects([&] { serialize_project_document(bad_rows); }, "missing layout row rejected");
    bad_rows = row_doc; bad_rows.boards[0].rows->at(1).id = "controls";
    rejects([&] { serialize_project_document(bad_rows); }, "duplicate row rejected");
    bad_rows = row_doc; bad_rows.boards[0].rows->at(0).height = 0;
    rejects([&] { serialize_project_document(bad_rows); }, "invalid row height rejected");
    bad_rows = row_doc; bad_rows.boards[0].components[0].v_align = "middle";
    rejects([&] { serialize_project_document(bad_rows); }, "invalid cell alignment rejected");
    rejects([&] { parse_project_board(R"({"id":"b","title":"B","sheet":"main","rows":[{"id":"r","height":"tall"}],"components":[]})"); },
            "non-numeric row height rejected");
    rejects([&] { parse_project_board(R"({"id":"b","title":"B","sheet":"main","components":[{"id":"c","title":"C","kind":"text","span":1.5}]})"); },
            "fractional span rejected");
    const auto &chart = decoded.boards[0].components[3];
    check(chart.kind == "live_chart" && chart.cell == 0 && chart.extra.at("chart_id") == "\"loss\"",
          "board-owned chart settings round trip without requiring a cell");
    check(chart.extra.at("caption") == "\"Training cross-entropy\"", "live chart caption round trip");
    auto invalid_chart = doc;
    invalid_chart.boards[0].components[3].extra["caption"] = "42";
    rejects([&] { serialize_project_document(invalid_chart); }, "numeric chart caption rejected");
    invalid_chart = doc;
    invalid_chart.boards[0].components[3].extra["chart_id"] = "42";
    rejects([&] { serialize_project_document(invalid_chart); }, "numeric chart channel rejected");
    invalid_chart = doc;
    invalid_chart.boards[0].components[3].extra["stroke"] = "\"orange\"";
    rejects([&] { serialize_project_document(invalid_chart); }, "invalid chart color rejected");
    invalid_chart = doc;
    invalid_chart.boards[0].components[3].extra["y_min"] = "101";
    rejects([&] { serialize_project_document(invalid_chart); }, "reversed chart axis range rejected");
    check(decoded.boards[0].components[3].extra.at("y_max") == "100", "chart axis limits round trip");
    check(std::get<std::int64_t>(parse_project_input_value("9223372036854775807")) == INT64_MAX, "exact int64 input");
    rejects([] { parse_project_input_value("9223372036854775808"); }, "overflow rejected");
    rejects([] { parse_project_input_value("1e999"); }, "nonfinite rejected");
    auto invalid = doc; invalid.version = 1;
    rejects([&] { serialize_project_document(invalid); }, "v1 must not silently carry executable inputs");
    invalid = doc; invalid.inputs[0].initial = 101.0;
    rejects([&] { serialize_project_document(invalid); }, "default bounds validated");
    invalid = doc; invalid.boards[0].components[0].input = "missing";
    rejects([&] { serialize_project_document(invalid); }, "missing input rejected");
    auto project = create_project(root / "Test.sputnikbook", doc);
    ProjectTabs tabs(project);
    auto &s = tabs.active().session;
    check(s.cells[0].dirty && !s.cells[0].ok, "opening must not execute");
    tabs.set_input("gain", "3");
    check(!s.cells[0].ok, "changing input must not start unopened runtime");
    evaluate_from(&s, 0, true, false, false);
    if (!s.cells[1].ok) std::cerr << s.cells[1].error << ' ' << s.status << '\n';
    check(s.cells[1].ok && s.cells[1].result == "63", "cell reads typed project input");
    s.cells[4].result = "unchanged";
    check(tabs.set_input("gain", "4.0"), "changed input accepted");
    check(s.cells[1].ok && s.cells[1].result == "84", "dependent Watch cell reruns");
    check(!s.cells[2].ok && !s.cells[3].ok, "Manual and descendants stay stale");
    check(s.cells[4].result == "unchanged", "unrelated cells must not rerun");
    check(!tabs.set_input("gain", "4"), "equal numeric publication is quiet");
    rejects([&] { tabs.set_input("gain", "101"); }, "invalid input rejected");
    check(std::get<double>(tabs.inputs().at("gain")) == 4.0, "invalid input retains committed value");
    tabs.save_active();
    check(std::get<double>(load_project(project.directory).document.inputs[0].initial) == 2.0, "runtime input not persisted as default");
    // Failed new read paths retry after another input event without dropping
    // the last successful capture or publishing a partial slot transaction.
    s.cells[0].source = "gain = notebook.input(\"gain\") / (notebook.input(\"gain\") - 4)\ngain\n";
    evaluate_from(&s, 0, true, false, false);
    check(!s.cells[0].ok, "faulting input cell");
    tabs.set_input("gain", "5");
    check(s.cells[0].ok && s.cells[1].ok && s.cells[1].result == "105", "input event recovers failed consumer");
    s.cells[0].source = "gain = 7\ngain\n";
    evaluate_from(&s, 0, true, false, false);
    s.cells[0].result = "capture-cleared";
    tabs.set_input("gain", "6");
    check(s.cells[0].result == "capture-cleared", "successful empty capture removes input edge");
    s.cells[0].source = "gain = notebook.input(\"gain\")\ngain\n";
    tabs.set_input("gain", "7");
    check(s.cells[0].dirty && s.cells[0].result == "capture-cleared", "input change cannot execute edited source");
    char *error = nullptr;
    auto host = sputnik_notebook_open(project.directory.c_str(), 0, nullptr, &error);
    check(host != nullptr, error ? error : "bridge open");
    auto json = sputnik_notebook_snapshot(host, &error);
    check(json && std::string(json).find("\"boards\":[{") != std::string::npos, "bridge exposes boards");
    sputnik_notebook_string_free(json);
    check(sputnik_notebook_command(host, "set_input", nullptr, "gain", "8", &error), "bridge input command");
    check(sputnik_notebook_command(host, "new_input", nullptr, nullptr,
          R"({"id":"large","title":"Large","type":"integer","default":9223372036854775807})", &error), "bridge creates exact integer input");
    json = sputnik_notebook_snapshot(host, &error);
    check(json && std::string(json).find("9223372036854775807") != std::string::npos, "snapshot preserves int64");
    sputnik_notebook_string_free(json);
    auto edited_board = load_project(project.directory).document.boards.front();
    edited_board.rows = row_board.rows;
    for (std::size_t i = 0; i < edited_board.components.size(); ++i) {
      edited_board.components[i].row = row_board.components[i].row;
      edited_board.components[i].span = row_board.components[i].span;
      edited_board.components[i].h_align = row_board.components[i].h_align;
      edited_board.components[i].v_align = row_board.components[i].v_align;
    }
    edited_board.components[3].extra["stroke"] = "\"#059669\"";
    edited_board.components[3].extra["x_label"] = "\"Optimizer step\"";
    edited_board.components[3].extra["caption"] = "\"Every optimizer step\"";
    const auto board_json = serialize_project_board(edited_board);
    check(sputnik_notebook_command(host, "save_board", nullptr, nullptr, board_json.c_str(), &error),
          error ? error : "bridge saves chart settings");
    const auto saved_chart = load_project(project.directory).document.boards[0].components[3];
    check(saved_chart.row == "outputs" && saved_chart.span == 8 && saved_chart.v_align == "bottom",
          "bridge saves component geometry");
    check(saved_chart.extra.at("stroke") == "\"#059669\"" &&
          saved_chart.extra.at("x_label") == "\"Optimizer step\"" &&
          saved_chart.extra.at("caption") == "\"Every optimizer step\"", "chart edits and caption survive save and reopen");
    edited_board.components[3].extra.erase("y_min"); edited_board.components[3].extra.erase("y_max");
    edited_board.components[3].extra.erase("caption");
    const auto automatic_board = serialize_project_board(edited_board);
    check(sputnik_notebook_command(host, "save_board", nullptr, nullptr, automatic_board.c_str(), &error),
          "bridge returns chart axes to automatic range");
    check(!load_project(project.directory).document.boards[0].components[3].extra.count("y_max"),
          "cleared chart bounds must not be restored as opaque metadata");
    check(!load_project(project.directory).document.boards[0].components[3].extra.count("caption"),
          "cleared caption must not be restored as opaque metadata");
    sputnik_notebook_destroy(host);
    // Editing understood properties must preserve exact opaque metadata.
    ProjectTabs reopened(load_project(project.directory));
    auto board = reopened.project().document.boards.front();
    board.extra["future"] = "1.23456789012345678901234567890";
    board.components[0].extra["future"] = "{\"x\":17}";
    board.rows->at(0).extra["future"] = "1.234567890123456789";
    reopened.save_board(board);
    board.extra.clear(); board.components[0].extra.clear(); board.rows->at(0).extra.clear();
    board.rows->at(0).height.reset(); board.title = "Changed";
    reopened.save_board(board);
    check(reopened.project().document.boards.front().extra.count("future"), "board editor preserves extras");
    check(reopened.project().document.boards.front().components[0].extra.count("future"), "component editor preserves extras");
    check(reopened.project().document.boards.front().rows->at(0).extra.count("future") &&
          !reopened.project().document.boards.front().rows->at(0).height,
          "row metadata survives while clearing height restores automatic sizing");
    // Project values are shared, but each sheet executes in its own world.
    reopened.create_sheet("other");
    reopened.active().session.cells[0].source = "notebook.input(\"label\")\n";
    evaluate_from(&reopened.active().session, 0, true, false, false);
    reopened.set_input("label", "\"Мир\"");
    check(reopened.active().session.cells[0].ok && reopened.active().session.cells[0].result.find("Мир") != std::string::npos,
          "new sheets share portable project input snapshot");
    auto &other = reopened.active().session;
    other.cells[0].source = "notebook.input(\"large\")\n";
    evaluate_from(&other, 0, true, false, false);
    check(other.cells[0].ok && other.cells[0].result == "9223372036854775807", "Int64 reaches VM without truncation");
    other.cells[0].source = "notebook.input(\"enabled\")\n";
    evaluate_from(&other, 0, true, false, false);
    reopened.set_input("enabled", "false");
    check(other.cells[0].ok && other.cells[0].result == "false", "boolean input remains boolean in VM");
    other.cells[0].source = "notebook.input(42)\n";
    evaluate_from(&other, 0, true, false, false);
    check(!other.cells[0].ok, "non-string input key rejected by VM");
    other.cells[0].source = "notebook.input(\"unknown\")\n";
    evaluate_from(&other, 0, true, false, false);
    check(!other.cells[0].ok && other.cells[0].error.find("unknown") != std::string::npos, "unknown input rejected");
    if (argc == 2) {
      auto showcase = sputnik_notebook_open(argv[1], 0, nullptr, &error);
      check(showcase != nullptr, error ? error : "actual showcase opens through native bridge");
      json = sputnik_notebook_snapshot(showcase, &error);
      check(json && std::string(json).find("\"live_chart\"") != std::string::npos &&
            std::string(json).find("\"chart_id\":\"accuracy\"") != std::string::npos,
            "actual showcase exposes its live-chart components");
      sputnik_notebook_string_free(json);
      sputnik_notebook_destroy(showcase);
    }
    std::filesystem::remove_all(root);
    std::cout << "notebook board tests passed\n";
  } catch (const std::exception &e) {
    std::cerr << "notebook board tests failed: " << e.what() << '\n';
    return 1;
  }
}

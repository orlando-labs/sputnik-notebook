#include "tools/isputnik/tabs.h"
#include "runtime/notebook_image.h"
#include "runtime/audio.h"
#include <filesystem>
#include <iostream>
#include <unistd.h>
using namespace sputnik::notebook;
using namespace sputnik::runtime;
static void check(bool ok, const std::string &message) { if (!ok) throw std::runtime_error(message); }
template<class F> void rejects(F fn) { bool failed = false; try { fn(); } catch (...) { failed = true; } check(failed, "invalid component data accepted"); }
int main() {
  char path[] = "/tmp/sputnik-component-data-XXXXXX";
  const auto root = std::filesystem::path(mkdtemp(path));
  struct Cleanup { std::filesystem::path path; ~Cleanup(){ std::filesystem::remove_all(path); } } cleanup{root};
  try {
    auto doc = make_project_document("Selection and annotations"); doc.version = 3;
    doc.dependencies.push_back({std::filesystem::canonical(SPUTNIK_SOURCE_ROOT "/packages/notebook_ui").string(), false, {}});
    doc.sheets[0].cells.resize(1);
    doc.sheets[0].cells[0].source = "from notebook.ui import DataTableView\nnotebook.show(DataTableView([{id: 9007199254740993, name: \"sample\"}], columns: [:id, :name]), id: \"rows\")\n42\n";
    doc.boards.push_back(parse_project_board(R"({"id":"data","title":"Data","sheet":"main","components":[{"id":"rows","title":"Rows","kind":"table","cell":"1","table_id":"rows","selection_id":"record","selection_key":"id"},{"id":"image","title":"Image","kind":"image","image_id":"frame","image_allow_load":true,"image_allow_read":true,"image_annotator":true,"annotation_id":"labels"}]})"));
    ProjectTabs tabs(create_project(root / "Data.sputnikbook", doc));
    auto &session = tabs.tabs()[0]->session;
    evaluate_from(&session, 0, true, false, false);
    check(session.cells[0].ok, session.cells[0].error + " / " + session.environment_error);
    const auto source = notebook_asset_id(session.cells[0].displays[0].bytes);
    const auto selection = "{\"version\":1,\"source\":\"" + source + "\",\"key\":9007199254740993,\"row\":{\"id\":9007199254740993,\"name\":\"sample\"}}";
    tabs.edit_component_data({"data", "rows", "selection", selection});
    check(session.cells[0].result == "42", "Apply must not run code");
    auto frozen = session.project_inputs;
    session.cells[0].source = "notebook.selection(\"record\")[\"key\"] == 9007199254740993\n";
    evaluate_from(&session, 0, true, false, false);
    check(session.cells[0].ok && session.cells[0].result == "true", "selection exact integer reaches next run");
    tabs.edit_component_data({"data", "rows", "selection", "null"});
    check(std::get<std::string>(frozen->at(notebook_component_data_key("selection", "record"))) == selection, "accepted data snapshots are immutable");
    evaluate_from(&session, 0, true, false, false);
    check(!session.cells[0].ok, "cleared selection read is null");
    rejects([&]{ tabs.edit_component_data({"data", "rows", "selection", selection}); }); // old table publication no longer exists
    NotebookDisplay image; image.mime = "image/png"; image.width = 32; image.height = 16;
    image.bytes = notebook_pixels_png(std::string(32*16, '\x40'), 32, 16, 1);
    tabs.edit_images({"data", "image", "Frame", 0, {image}});
    auto labels = "{\"version\":1,\"asset\":\"" + notebook_asset_id(image.bytes) + "\",\"channel\":\"frame\",\"width\":32,\"height\":16,\"shapes\":[{\"id\":\"a\",\"kind\":\"rect\",\"label\":\"object\",\"x\":1,\"y\":2,\"width\":10,\"height\":8}]}";
    tabs.edit_component_data({"data", "image", "annotations", labels});
    for (const auto &[field, number] : std::vector<std::pair<std::string, std::string>>{{"x", "1"}, {"y", "2"}, {"width", "10"}, {"height", "8"}}) {
      auto fractional = labels;
      const auto token = "\"" + field + "\":" + number;
      const auto offset = fractional.rfind(token);
      fractional.replace(offset, token.size(), token + ".25");
      rejects([&]{ tabs.edit_component_data({"data", "image", "annotations", fractional}); });
      auto legacy = tabs.project().document;
      legacy.boards[0].components[1].extra["annotations"] = fractional;
      const auto inputs = project_input_defaults(legacy);
      check(std::get<std::string>(inputs->at(notebook_component_data_key("annotations", "labels"))) == "null", "legacy fractional labels require pixel review before consumption");
      check(legacy.boards[0].components[1].extra.at("annotations") == fractional, "legacy fractional drafts remain available for repair");
      const auto legacyRoot = root / ("Legacy-" + field + ".sputnikbook");
      create_project(legacyRoot, legacy);
      std::filesystem::copy(root / "Data.sputnikbook" / "images", legacyRoot / "images", std::filesystem::copy_options::recursive);
      ProjectTabs reopenedLegacy(load_project(legacyRoot));
      check(std::get<std::string>(reopenedLegacy.inputs().at(notebook_component_data_key("annotations", "labels"))) == "null", "fractional legacy notebooks still reopen");
    }
    auto point = labels;
    point.replace(point.find("\"kind\":\"rect\""), 13, "\"kind\":\"point\"");
    tabs.edit_component_data({"data", "image", "annotations", point});
    point.replace(point.find("\"x\":1"), 5, "\"x\":1.5");
    rejects([&]{ tabs.edit_component_data({"data", "image", "annotations", point}); });
    tabs.edit_component_data({"data", "image", "annotations", labels});
    const auto schema = std::string(R"([{"id":"object","title":"Object","attributes":[{"id":"type","title":"Type","type":"choice","options":["A","B"]}]}])");
    auto configured = tabs.project().document.boards[0]; configured.components[1].extra["annotation_classes"] = schema; tabs.save_board(configured);
    check(std::get<std::string>(tabs.inputs().at(notebook_component_data_key("annotations", "labels"))) == "null", "designer image schema invalidates legacy labels for review");
    rejects([&]{ tabs.edit_component_data({"data", "image", "annotations", labels}); });
    labels.insert(labels.find("\"shapes\""), "\"classes\":" + schema + ",");
    labels.insert(labels.find("\"x\":1"), R"("classes":["object"],"attributes":{"object":{"type":"A"}},)");
    tabs.edit_component_data({"data", "image", "annotations", labels});
    auto bad = labels; bad.replace(bad.find("\"type\":\"A\""), 10, "\"type\":\"C\"");
    rejects([&]{ tabs.edit_component_data({"data", "image", "annotations", bad}); });
    session.cells[0].source = "notebook.annotations(\"labels\")[\"shapes\"].count\n";
    evaluate_from(&session, 0, true, false, false);
    check(session.cells[0].ok && session.cells[0].result == "1", "annotations available as ordinary notebook values");
    auto board = tabs.project().document.boards[0]; board.title = "Edited title"; tabs.save_board(board);
    check(std::get<std::string>(tabs.inputs().at(notebook_component_data_key("annotations", "labels"))) == labels, "designer roundtrip preserves labels");
    auto rebound = tabs.project().document.boards[0]; rebound.components[1].extra["image_id"] = "\"other_frame\""; tabs.save_board(rebound);
    check(std::get<std::string>(tabs.inputs().at(notebook_component_data_key("annotations", "labels"))) == "null", "changing the configured image channel invalidates old labels");
    rebound.components[1].extra["image_id"] = "\"frame\""; tabs.save_board(rebound);
    session.cells[0].source = "from notebook.ui import image, publish_image\npublish_image(\"frame\", image([0, 255], width: 2, height: 1, format: :gray))\nnotebook.annotations(\"labels\") == null\n";
    evaluate_from(&session, 0, true, false, false);
    check(session.cells[0].ok && session.cells[0].result == "true", "runtime image replacement makes old annotations unavailable");
    rejects([&]{ tabs.edit_component_data({"data", "image", "annotations", labels}); });
    auto invalid = labels; invalid.replace(invalid.find("\"x\":1"), 5, "\"x\":99");
    rejects([&]{ tabs.edit_component_data({"data", "image", "annotations", invalid}); });
    image.bytes = notebook_pixels_png(std::string(32*16, '\x80'), 32, 16, 1);
    tabs.edit_images({"data", "image", "New frame", 0, {image}});
    check(std::get<std::string>(tabs.inputs().at(notebook_component_data_key("annotations", "labels"))) == "null", "replacing source clears old labels instead of reattaching them");
    rejects([&]{ tabs.edit_component_data({"data", "image", "annotations", labels}); });
    session.cells[0].source = "notebook.annotations(\"labels\") == null\n";
    evaluate_from(&session, 0, true, false, false);
    check(session.cells[0].ok && session.cells[0].result == "true", "new image has no inherited annotations");
    session.cells[0].source = "from audio import AudioTrack\nAudioTrack.from_pcm(Bytes.new(\"AA\"), sample_format: :s16le, sample_rate: 8000, channels: 1).asset_id()\n";
    evaluate_from(&session, 0, true, false, false);
    check(session.cells[0].ok && session.cells[0].result.find(notebook_asset_id(audio_wav("AA", "s16le", 8000, 1))) != std::string::npos, "PCM AudioTrack identity matches exported WAV bytes");
    ProjectTabs reopened(load_project(root / "Data.sputnikbook"));
    check(std::get<std::string>(reopened.inputs().at(notebook_component_data_key("annotations", "labels"))) == "null", "cleared labels stay cleared on reopen");
    std::cout << "Component data passed: typed stable keys, immutable snapshots, inert Apply/Clear, source identities, annotations, bounds and reopen\n";
  } catch (const std::exception &e) { std::cerr << "Component data failed: " << e.what() << '\n'; return 1; }
}

#include "tools/notebook-worker/presentation.h"
#include "tools/notebook-worker/process.h"
#include "tools/isputnik/tabs.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <unistd.h>

using namespace sputnik::notebook;
using namespace sputnik::notebook::worker;
using namespace sputnik::runtime;
using namespace std::chrono_literals;
static void check(bool ok, const std::string &message) {
  if (!ok) throw std::runtime_error(message);
}
template<class F> static void rejects(F action) {
  bool rejected = false; try { action(); } catch (const std::exception &) { rejected = true; }
  check(rejected, "invalid image payload was accepted");
}
static Presentation receive(Process &process, RequestId request) {
  PresentationAssembler terminal(request.generation, request.request);
  std::optional<PresentationAssembler> live;
  for (;;) {
    const auto message = process.receive(10s);
    check(message.has_value(), "worker timeout");
    if (message->kind == Kind::Error) throw std::runtime_error(message->fields.at(0));
    if (message->kind == Kind::Started || message->kind == Kind::Draining) continue;
    if (message->kind == Kind::LiveBegin || message->kind == Kind::LiveChunk || message->kind == Kind::LiveEnd) {
      if (!live) live.emplace(request.generation, request.request, true);
      if (live->accept(*message)) live.reset();
    } else if (auto value = terminal.accept(*message)) return std::move(*value);
  }
}
int main(int argc, char **argv) {
  char pattern[] = "/tmp/sputnik-images-XXXXXX";
  const auto temp = mkdtemp(pattern);
  try {
    check(temp, "temporary project");
    const std::filesystem::path root(temp);
    NotebookDisplay image{"image/png", notebook_pixels_png(std::string("\0\xff", 2), 2, 1, 1), "Кадр 🦊", 2, 1, {}};
    notebook_validate_image(image);
    std::ofstream(root / "gray.png", std::ios::binary) << image.bytes;
    for (unsigned channels : {3U, 4U}) {
      auto color = image;
      color.bytes = notebook_pixels_png(std::string(2 * channels, '\xff'), 2, 1, channels);
      notebook_validate_image(color);
      std::ofstream(root / (channels == 3 ? "rgb.png" : "rgba.png"), std::ios::binary) << color.bytes;
    }
    if (argc > 2) {
      std::filesystem::create_directories(argv[2]);
      for (const auto *name : {"gray.png", "rgb.png", "rgba.png"})
        std::filesystem::copy_file(root / name, std::filesystem::path(argv[2]) / name, std::filesystem::copy_options::overwrite_existing);
    }
    auto store = std::make_shared<NotebookLiveStore>();
    const auto generation = store->begin_cell(1);
    check(store->publish_images(1, generation, "gallery", {image}, "Серия") == NotebookLivePublishResult::Accepted, "publish series");
    const auto retained = store->snapshot_cell(1);
    check(store->publish_images(1, generation, "gallery", {image}, {}, true) == NotebookLivePublishResult::Accepted, "append frame");
    check(retained[0].images.size() == 1 && store->snapshot_cell(1)[0].images.size() == 2 &&
          store->snapshot_cell(1)[0].caption == "Серия", "immutable snapshots and preserved series caption");
    check(store->publish_images(1, generation, "gallery", std::vector<NotebookDisplay>(63, image), {}, true) == NotebookLivePublishResult::LimitExceeded &&
          store->snapshot_cell(1)[0].images.size() == 2, "failed append leaves prior series intact");
    const auto next = store->begin_cell(1);
    check(store->snapshot_cell(1).empty() && store->publish_images(1, generation, "gallery", {image}, {}) == NotebookLivePublishResult::Closed, "rerun rejects stale producers");
    check(store->publish_images(1, next, "gallery", {}, "") == NotebookLivePublishResult::Accepted, "explicit clear");
    store->close();
    check(store->publish_images(1, next, "gallery", {image}, {}) == NotebookLivePublishResult::Closed, "closed run");

    auto doc = make_project_document("Image channels"); doc.version = 3;
    doc.dependencies.push_back({std::filesystem::canonical(SPUTNIK_SOURCE_ROOT "/packages/notebook_ui").string(), false, {}});
    doc.sheets[0].cells.resize(1);
    const std::string imports = "from notebook.ui import image, publish_image, publish_images, add_image, clear_images, read_image, read_images\n";
    const std::string source = imports +
        "publish_image(\"cover\", image([255, 0, 0, 0, 255, 0], width: 2, height: 1, format: :rgb, caption: \"Cover\"))\n"
        "publish_images(\"gallery\", [image([0, 255], width: 2, height: 1, format: :gray, caption: \"Кадр 🦊\")], caption: \"Серия\")\n"
        "add_image(\"gallery\", image([255, 0], width: 2, height: 1, format: :gray, caption: \"Second\"))\n42\n";
    doc.sheets[0].cells[0].source = source;
    ProjectBoard board; board.id = "images"; board.title = "Images"; board.sheet = doc.sheets[0].id;
    board.components = {{"cover", "image", "Cover", {}, 0, {}, {{"image_mode", "\"fill\""}}},
                        {"gallery", "image_carousel", "Gallery", {}, 0, {}, {{"image_id", "\"gallery\""}, {"image_mode", "\"auto-height\""}, {"caption", "\"Default\""}}}};
    doc.boards.push_back(board);
    const auto parsed = parse_project_document(serialize_project_document(doc));
    check(parsed.boards[0].components[1].extra.at("image_mode") == "\"auto-height\"", "board image properties round trip");
    auto invalid = doc; invalid.boards[0].components[0].extra["image_mode"] = "\"stretch\"";
    rejects([&] { serialize_project_document(invalid); });
    invalid = doc; invalid.boards[0].components[0].extra["image_id"] = "42";
    rejects([&] { serialize_project_document(invalid); });
    auto project = create_project(root / "Images.sputnikbook", doc);
    ProjectTabs tabs(project);
    auto &session = tabs.active().session;
    evaluate_from(&session, 0, true, false, false);
    const auto &cell = session.cells[0];
    check(cell.ok, cell.error + session.environment_error);
    check(cell.result == "42" && cell.images.size() == 2 && cell.images[1].images.size() == 2 &&
          cell.images[1].images[0].caption == "Кадр 🦊" && cell.images[1].caption == "Серия", "real package publication");
    const auto decoded = decode_presentation(encode_presentation(presentation_from_session(session, {}, false)));
    check(decoded.cells[0].images[1].images[0].bytes == cell.images[1].images[0].bytes &&
          decoded.cells[0].images[1].caption == "Серия", "IPC retains frames and both caption levels");
    auto malformed = decoded; malformed.cells[0].images[0].images[0].width = 1;
    rejects([&] { encode_presentation(malformed); });
    auto unchanged = Presentation{}; CellPresentation delta; delta.id = cell.id;
    delta.images_updated = false; delta.displays_updated = delta.progress_updated = delta.charts_updated = false;
    unchanged.cells.push_back(delta);
    auto merged = decoded; merge_live_presentation(merged, unchanged);
    check(merged.cells[0].images.size() == 2, "progress-only packet preserves images");
    unchanged.cells[0].images_updated = true; merge_live_presentation(merged, unchanged);
    check(merged.cells[0].images.empty(), "cell reset clears image channels");

    auto run = [&](const std::string &body, bool success) {
      session.cells[0].source = imports + body; session.cells[0].dirty = true;
      evaluate_from(&session, 0, true, false, false);
      check(session.cells[0].ok == success, body + "\n" + session.cells[0].error + "\n" + session.environment_error);
    };
    run("publish_images(\"gallery\", [])\n", true);
    check(session.cells[0].images.size() == 1 && session.cells[0].images[0].images.empty(), "rerun and clear do not retain prior cover");
    run("publish_image(\"gallery\", image([256], width: 1, height: 1, format: :gray))\n", false);
    run("publish_image(\"gallery\", image([0], width: 2, height: 1, format: :gray))\n", false);
    run("publish_image(\"gallery\", image([0], width: 1, height: 1, format: :gray, caption: 1))\n", false);
    std::string png_samples = "[";
    for (unsigned char byte : image.bytes) { if (png_samples.size() > 1) png_samples += ','; png_samples += std::to_string(byte); }
    png_samples += ']';
    run("publish_image(\"gallery\", image(" + png_samples + ", caption: \"PNG dimensions inferred\"))\n", true);
    check(session.cells[0].images[0].images[0].width == 2 && session.cells[0].images[0].images[0].height == 1,
          "encoded PNG dimensions inferred by real package");
    run("publish_image(\"gallery\", image(" + png_samples + ", width: 1))\n", false);
    run("publish_image(\"gallery\", image(Bytes.new(\"A\"), width: 1, height: 1, format: :gray))\n", true);
    check(session.cells[0].images[0].images[0].width == 1, "Bytes payload crosses VM image boundary");
    run("read_images(\"gallery\")\n", false);
    auto editable = tabs.project().document.boards[0];
    editable.components[1].extra["image_allow_read"] = "true";
    editable.components[1].extra["image_allow_load"] = "true";
    editable.components[1].extra["image_allow_save"] = "true";
    tabs.save_board(editable);
    auto second_image = image; second_image.caption = "Second loaded";
    second_image.bytes = notebook_pixels_png(std::string("\xff\0", 2), 2, 1, 1);
    ProjectImageEdit edit{"images", "gallery", "Loaded series", 1, {image, second_image}};
    tabs.edit_images(edit);
    check(session.project_images->at("gallery").readable, "edited channel retains read permission");
    check(session.cells[0].images.empty(), "UI image edit replaces runtime output");
    run("frames = read_images(\"gallery\")\nread_image(\"gallery\")[:caption] == \"Second loaded\" and frames.count == 2\n", true);
    check(session.cells[0].result == "true", "sheet reads selected loaded frame and ordered array");
    run("publish_image(\"gallery\", read_image(\"gallery\", index: 0))\nread_image(\"gallery\")[:caption] == \"Кадр 🦊\"\n", true);
    check(session.cells[0].result == "true", "read descriptors round-trip into code publications and read their live state");
    tabs.edit_images(edit);
    run("add_image(\"gallery\", image([42], width: 1, height: 1, format: :gray))\nframes = read_images(\"gallery\")\nframes.count\n", true);
    check(session.cells[0].result == "3" && session.cells[0].images[0].caption == "Loaded series", "code appends to loaded images preserving series caption");
    tabs.edit_images(edit);
    tabs.select_image(doc.sheets[0].id, "gallery", 0);
    run("read_image(\"gallery\")[:caption] == \"Кадр 🦊\"\n", true);
    check(session.cells[0].result == "true", "current selection is captured by the next cell run");
    tabs.select_image(doc.sheets[0].id, "gallery", 1);
    evaluate_from(&session, 0, false, false, false);
    check(session.cells[0].ok && session.cells[0].result == "false", "explicit run reads a changed selection without a source edit");
    run("read_image(\"gallery\", index: 9)\n", false);
    run("read_images(\"missing\")\n", false);
    rejects([&] { tabs.select_image(doc.sheets[0].id, "gallery", 64); });
    auto denied = edit; denied.component = "cover";
    rejects([&] { tabs.edit_images(denied); });
    auto bad_option = tabs.project().document; bad_option.boards[0].components[1].extra["image_allow_read"] = "1";
    rejects([&] { serialize_project_document(bad_option); });
    auto bad_path = tabs.project().document; bad_path.boards[0].components[1].extra["image_items"] = "[{\"path\":\"images/../../outside.png\"}]";
    rejects([&] { serialize_project_document(bad_path); });
    edit.images = {second_image, image}; edit.selected = 0;
    tabs.edit_images(edit);
    auto restored = load_project(project.directory);
    auto restored_inputs = load_project_image_inputs(restored.document, restored.directory, doc.sheets[0].id);
    check(restored_inputs->at("gallery").images[0].caption == "Second loaded" && restored_inputs->at("gallery").selected == 0 &&
          restored_inputs->at("gallery").images[1].bytes == image.bytes, "loaded bytes, captions and reordered series persist");
    if (argc > 1) {
      Process process; process.start(argv[1]);
      const auto ready = process.receive(5s);
      check(ready && ready->kind == Kind::Ready, "worker ready");
      receive(process, process.send(Kind::Load, {project.directory.string(), ""}));
      const auto cell_id = std::to_string(doc.sheets[0].cells[0].id);
      const auto result = receive(process, process.send(Kind::Run, {cell_id, "1"}));
      check(result.cells[0].ok && result.cells[0].images.size() == 2 && result.cells[0].images[1].images.size() == 2,
            "real worker publishes captioned image series");
      const auto clear = process.send(Kind::Source, {cell_id, imports + "clear_images(\"gallery\")\n", "1"});
      receive(process, clear);
      const auto cleared = receive(process, process.send(Kind::Run, {cell_id, "1"}));
      check(cleared.cells[0].images.size() == 1 && cleared.cells[0].images[0].images.empty(), "worker rerun clears old channels");
      auto synchronized = tabs.project().document;
      synchronized.sheets[0].cells[0].source = imports + "frames = read_images(\"gallery\")\nframes.count == 0\n";
      synchronized.boards[0].components[1].extra["image_selection"] = "1";
      receive(process, process.send(Kind::Sync, {serialize_project_document(synchronized), "0"}));
      const auto read_loaded = receive(process, process.send(Kind::Run, {cell_id, "1"}));
      check(read_loaded.cells[0].ok && read_loaded.cells[0].result == "true", "explicit cleared runtime channel takes precedence over loaded fallback");
      edit.images = {image}; edit.selected = 0; tabs.edit_images(edit);
      synchronized = tabs.project().document;
      synchronized.sheets[0].cells[0].source = imports + "frames = read_images(\"gallery\")\nframes.count\n";
      receive(process, process.send(Kind::Sync, {serialize_project_document(synchronized), "0"}));
      const auto edited_read = receive(process, process.send(Kind::Run, {cell_id, "1"}));
      check(edited_read.cells[0].ok && edited_read.cells[0].result == "1", "worker receives an edited collection before execution");
      synchronized.boards[0].components[1].extra["image_allow_read"] = "false";
      receive(process, process.send(Kind::Sync, {serialize_project_document(synchronized), "0"}));
      const auto denied_read = receive(process, process.send(Kind::Run, {cell_id, "1"}));
      check(!denied_read.cells[0].ok && denied_read.cells[0].error.find("disabled") != std::string::npos, "worker enforces the read setting");
    }
    edit.images.clear(); edit.selected = 0; tabs.edit_images(edit);
    check(load_project_image_inputs(tabs.project().document, project.directory, doc.sheets[0].id)->at("gallery").images.empty(), "removing the last image persists an empty collection");
    std::cout << "notebook_image_tests: ok\n";
    std::filesystem::remove_all(root);
  } catch (const std::exception &e) { std::cerr << "image tests: " << e.what() << '\n'; return 1; }
}

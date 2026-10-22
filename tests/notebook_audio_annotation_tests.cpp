#include "tools/isputnik/tabs.h"
#include "runtime/audio.h"
#include "runtime/notebook_image.h"
#include <filesystem>
#include <iostream>
#include <unistd.h>
using namespace sputnik::notebook;
using namespace sputnik::runtime;
static void check(bool ok, const std::string &text) { if (!ok) throw std::runtime_error(text); }
template<class F> void rejects(F fn) { bool failed = false; try { fn(); } catch (...) { failed = true; } check(failed, "invalid audio annotations accepted"); }
int main() {
  char path[] = "/tmp/sputnik-audio-labels-XXXXXX";
  const auto root = std::filesystem::path(mkdtemp(path));
  struct Cleanup { std::filesystem::path root; ~Cleanup(){ std::filesystem::remove_all(root); } } cleanup{root};
  try {
    auto document = make_project_document("Audio annotations"); document.version = 3;
    document.dependencies.push_back({std::filesystem::canonical(SPUTNIK_SOURCE_ROOT "/packages/notebook_ui").string(), false, {}});
    document.sheets[0].cells[0].source = "from audio import AudioTrack\nnotebook.player(AudioTrack.from_input(\"clip\"), id: \"processed\")\n42\n";
    document.boards.push_back(parse_project_board(R"({"id":"audio","title":"Audio","sheet":"main","components":[{"id":"clip","title":"File","kind":"audio_annotator","audio_id":"clip","annotation_id":"labels"},{"id":"linked","title":"Input","kind":"audio_annotator","audio_source":"input","audio_id":"clip","annotation_id":"linked"},{"id":"output","title":"Output","kind":"audio_annotator","audio_source":"cell","cell":"1","audio_id":"processed","annotation_id":"output"}]})"));
    ProjectTabs tabs(create_project(root / "Audio.sputnikbook", document));
    std::string pcm(8000 * 2, '\0');
    for (int frame = 0; frame < 8000; ++frame) { const auto sample = std::int16_t(10000 * std::sin(frame * 6.283185307179586 * 1000 / 8000)); pcm[frame*2] = char(sample); pcm[frame*2+1] = char(sample >> 8); }
    AudioDisplay audio; audio.bytes = audio_wav(pcm, "s16le", 8000, 1); audio.format = "wav";
    tabs.edit_audio({"audio", "clip", "Tone.wav", audio});
    auto &session = tabs.tabs()[0]->session;
    evaluate_from(&session, 0, true, false, false); check(session.cells[0].ok, session.cells[0].error + session.environment_error);
    const auto labels = std::string(R"({"version":1,"asset":")") + notebook_asset_id(audio.bytes) + R"(","source":"input","channel":"clip","cell":0,"sample_rate":8000,"channels":1,"frames":8000,"transcript":"Whole transcript","classes":[{"id":"speech","title":"Speech","attributes":[{"id":"speaker","title":"Speaker","type":"choice","options":["A","B"]},{"id":"confidence","title":"Confidence","type":"number","options":[]},{"id":"clean","title":"Clean","type":"boolean","options":[]}]}],"segments":[{"id":"first","title":"Phrase","start_frame":1,"end_frame":4000,"low_hz":100,"high_hz":2300,"classes":["speech"],"attributes":{"speech":{"speaker":"A","confidence":0.95,"clean":true}},"transcript":"Hello"}]})";
    const auto classes_at = labels.find("\"classes\":") + 10;
    const auto schema = labels.substr(classes_at, labels.find(",\"segments\"") - classes_at);
    auto configured = tabs.project().document.boards[0];
    for (auto &component : configured.components) component.extra["annotation_classes"] = schema;
    tabs.save_board(configured);
    tabs.edit_component_data({"audio", "clip", "audio_annotations", labels});
    tabs.edit_component_data({"audio", "linked", "audio_annotations", labels});
    check(session.cells[0].result == "42", "Apply must not run code");
    auto frozen = session.project_inputs;
    auto output = labels;
    output.replace(output.find("\"source\":\"input\""), 16, "\"source\":\"cell\"");
    output.replace(output.find("\"channel\":\"clip\""), 16, "\"channel\":\"processed\"");
    output.replace(output.find("\"cell\":0"), 8, "\"cell\":1");
    tabs.edit_component_data({"audio", "output", "audio_annotations", output});
    session.cells[0].source = "notebook.audio_annotations(\"labels\")[\"segments\"][0][\"attributes\"][\"speech\"][\"speaker\"] == \"A\"\n";
    evaluate_from(&session, 0, true, false, false); check(session.cells[0].ok && session.cells[0].result == "true", "typed attributes and transcript cross VM boundary");
    const auto changed = [&](const std::string &from, const std::string &to) { auto value = labels; const auto at = value.find(from); check(at != std::string::npos, "test field not found"); value.replace(at, from.size(), to); return value; };
    rejects([&]{ tabs.edit_component_data({"audio", "clip", "audio_annotations", changed("\"title\":\"Speech\"", "\"title\":\"Invented class\"")}); });
    auto policy = tabs.project().document.boards[0];
    policy.components[0].extra["audio_transcript_required"] = "true";
    policy.components[0].extra["audio_segment_transcript_required"] = "true";
    tabs.save_board(policy);
    rejects([&]{ tabs.edit_component_data({"audio", "clip", "audio_annotations", changed("Whole transcript", "   ")}); });
    rejects([&]{ tabs.edit_component_data({"audio", "clip", "audio_annotations", changed("Hello", "")}); });
    policy.components[0].extra["audio_segment_transcript_required"] = "false";
    policy.components[0].extra["audio_segment_transcript_allowed"] = "false";
    tabs.save_board(policy);
    check(std::get<std::string>(tabs.inputs().at(notebook_component_data_key("audio_annotations", "labels"))) == "null" && session.cells[0].dirty, "designer policy changes invalidate consumers without losing the old draft");
    rejects([&]{ tabs.edit_component_data({"audio", "clip", "audio_annotations", labels}); });
    tabs.edit_component_data({"audio", "clip", "audio_annotations", changed("Hello", "")});
    policy = tabs.project().document.boards[0];
    policy.components[0].extra["audio_transcript_required"] = "false";
    policy.components[0].extra["audio_transcript_allowed"] = "false";
    policy.components[0].extra["audio_segment_transcript_allowed"] = "true";
    tabs.save_board(policy);
    rejects([&]{ tabs.edit_component_data({"audio", "clip", "audio_annotations", labels}); });
    tabs.edit_component_data({"audio", "clip", "audio_annotations", changed("Whole transcript", "")});
    auto invalid_policy = tabs.project().document.boards[0]; invalid_policy.components[0].extra["audio_transcript_required"] = "true";
    rejects([&]{ tabs.save_board(invalid_policy); });
    invalid_policy.components[0].extra["audio_transcript_required"] = "123";
    rejects([&]{ tabs.save_board(invalid_policy); });
    policy = tabs.project().document.boards[0];
    policy.components[0].extra["audio_transcript_allowed"] = "true";
    policy.components[0].extra["annotation_classes"] = "[]"; tabs.save_board(policy);
    check(std::get<std::string>(tabs.inputs().at(notebook_component_data_key("audio_annotations", "labels"))) == "null", "removed classes invalidate previously accepted metadata");
    rejects([&]{ tabs.edit_component_data({"audio", "clip", "audio_annotations", labels}); });
    policy.components[0].extra["annotation_classes"] = schema; tabs.save_board(policy);
    tabs.edit_component_data({"audio", "clip", "audio_annotations", labels});
    ProjectTabs policy_reopened(load_project(root / "Audio.sputnikbook"));
    check(policy_reopened.project().document.boards[0].components[0].extra.at("annotation_classes") == schema, "designer class/attribute schema persists on reopen");
    for (const auto &invalid : {changed("\"end_frame\":4000", "\"end_frame\":9000"), changed("\"high_hz\":2300", "\"high_hz\":5000"), changed("\"confidence\":0.95", "\"confidence\":\"bad\""), changed("\"speaker\":\"A\"", "\"speaker\":\"C\""), changed("\"frames\":8000", "\"frames\":7999"), changed("\"cell\":0", "\"cell\":1")}) {
      rejects([&]{ tabs.edit_component_data({"audio", "clip", "audio_annotations", invalid}); });
    }
    auto rebound = tabs.project().document.boards[0]; rebound.components[1].extra["audio_id"] = "\"another\""; tabs.save_board(rebound);
    check(std::get<std::string>(tabs.inputs().at(notebook_component_data_key("audio_annotations", "linked"))) == "null", "channel rebinding does not reuse old labels");
    audio.bytes = audio_wav(std::string(16000, '\0'), "s16le", 8000, 1);
    tabs.edit_audio({"audio", "clip", "New.wav", audio});
    rejects([&]{ tabs.edit_component_data({"audio", "clip", "audio_annotations", labels}); });
    session.cells[0].source = "notebook.audio_annotations(\"labels\") == null\n";
    evaluate_from(&session, 0, true, false, false); check(session.cells[0].ok && session.cells[0].result == "true", "new audio makes old labels unavailable");
    check(std::get<std::string>(frozen->at(notebook_component_data_key("audio_annotations", "labels"))) == labels, "frozen labels stay immutable");
    tabs.edit_component_data({"audio", "clip", "audio_annotations", "null"});
    ProjectTabs reopened(load_project(root / "Audio.sputnikbook"));
    check(std::get<std::string>(reopened.inputs().at(notebook_component_data_key("audio_annotations", "labels"))) == "null", "Clear persists on reopen");
    std::cout << "Audio annotation contracts passed: designer schemas and transcript policies, file/input/output sources, frame/Hz bounds, typed classes, stale identities, frozen Apply and reopen\n";
  } catch (const std::exception &e) { std::cerr << "Audio annotation contracts failed: " << e.what() << '\n'; return 1; }
}

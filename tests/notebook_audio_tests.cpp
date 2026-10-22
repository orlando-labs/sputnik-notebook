#include "tools/isputnik/tabs.h"
#include "tools/notebook-worker/presentation.h"
#include "runtime/audio.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <unistd.h>

using namespace sputnik::notebook;
static void check(bool value, const std::string &message) { if (!value) throw std::runtime_error(message); }
int main() {
  char pattern[] = "/tmp/sputnik-audio-XXXXXX";
  const auto root = std::filesystem::path(mkdtemp(pattern));
  struct Cleanup { std::filesystem::path root; ~Cleanup() { std::filesystem::remove_all(root); } } cleanup{root};
  try {
    using namespace sputnik::runtime;
    std::string pcm(4800 * 4, '\0');
    for (unsigned i=0; i<4800; ++i) {
      const auto sample = std::int16_t(std::sin(i * 6.283185307179586 * 440 / 48000) * 1000);
      pcm[i*4] = pcm[i*4+2] = char(sample); pcm[i*4+1] = pcm[i*4+3] = char(sample >> 8);
    }
    const auto wav = audio_wav(pcm, "s16le", 48000, 2);
    auto document = make_project_document("Audio tests"); document.version = 3;
    document.sheets[0].cells.resize(1);
    document.sheets[0].cells[0].source = R"(from audio import AudioTrack
from notebook.ui import AudioPlayer
track = AudioTrack.from_file("tone.wav")
notebook.player(track, id: "file", live: false, show_waveform: false)
raw = AudioTrack.from_pcm(fs.read_bytes("tone.pcm"), sample_format: :s16le, sample_rate: 48000, channels: 2)
notebook.show(AudioPlayer.for(raw, position: 0.02, volume: 0.25), id: "raw", live: false)
notebook.player(AudioTrack.from_data(fs.read_bytes("tone.wav").to_str(), format: ".WAV"), caption: "Memory")
player = notebook.component("player", board: "audio")
player.seek(0.01)
player.set_volume(0.2)
player.play()
player.pause()
exported = raw.to_wav()
converted = track.to_pcm(sample_format: :s16le).to_wav()
raise ValueError("system decode/conversion differs") unless exported.hex == converted.hex
42
)";
    document.dependencies.push_back({(std::filesystem::path(SPUTNIK_SOURCE_ROOT)/"packages/notebook_ui").string(), false, {}});
    document.boards.push_back(parse_project_board(R"({"id":"audio","title":"Audio","sheet":"main","components":[{"id":"player","kind":"audio","title":"Player","cell":"1","audio_id":"file","show_waveform":false},{"id":"stream_player","title":"Stream","kind":"audio","cell":"1","audio_id":"live"}]})"));
    auto project = create_project(root / "Audio.sputnikbook", document);
    std::ofstream(project.directory / "tone.wav", std::ios::binary).write(wav.data(), wav.size());
    std::ofstream(project.directory / "tone.pcm", std::ios::binary).write(pcm.data(), pcm.size());
    ProjectTabs tabs(project);
    auto &session = tabs.tabs()[0]->session;
    session.runtime_capability_grants = {{"fs.read", "*"}};
    for (const auto &name : {"tone.wav", "tone.pcm"}) {
      const auto at = session.cells[0].source.find(std::string("\"") + name + "\"");
      if (at != std::string::npos) session.cells[0].source.replace(at + 1, std::strlen(name), (project.directory / name).string());
    }
    const auto last = session.cells[0].source.find("\"tone.wav\"");
    if (last != std::string::npos) session.cells[0].source.replace(last + 1, 8, (project.directory / "tone.wav").string());
    evaluate_from(&session, 0, true, false, false);
    const auto &cell = session.cells.front();
    check(cell.ok, "execution: " + cell.error + " / " + session.environment_error + " / " + session.status); check(cell.result == "42", "player preserves scalar result");
    check(cell.audio_controls.size() == 1 && cell.audio_controls[0].audio_control.playback == 2 && cell.audio_controls[0].audio_control.position == 0.01, "hard ID seek/volume/play/pause survives coalescing");
    check(cell.displays.size() == 3, "all three publications survive");
    const auto first = audio_decode(cell.displays[0].bytes), second = audio_decode(cell.displays[1].bytes);
    check(first.bytes == wav && first.format == "wav" && !first.waveform, "file content and waveform option");
    check(second.bytes == wav && second.position == 0.02 && second.volume == 0.25, "raw PCM and player settings");
    auto presentation = worker::presentation_from_session(session, {}, false);
    const auto restored = worker::decode_presentation(worker::encode_presentation(presentation));
    check(restored.cells[0].displays[0].bytes == cell.displays[0].bytes, "binary worker presentation roundtrip");
    auto bad = document; bad.boards[0].components[0].extra["show_waveform"] = "1";
    bool rejected = false; try { serialize_project_document(bad); } catch (...) { rejected = true; }
    check(rejected, "invalid waveform setting rejected");
    // Typed PCM deltas survive coalescing, replay, finish and reset.
    auto store = std::make_shared<NotebookLiveStore>();
    const auto gen = store->begin_cell(1);
    const auto handle = store->begin_audio(1, gen, "s16le", 48000, 2);
    store->bind_audio(handle, 1, gen, "stream", AudioDisplay{}, "live");
    std::uint64_t revision = 0; NotebookLiveStore::Delta delta;
    store->changes_since(&revision, &delta);
    check(delta.events.size() == 1 && delta.events[0].audio.replace && delta.events[0].audio.frames == 0, "empty stream starts immediately");
    auto retained = delta.events[0].audio;
    store->append_audio(handle, pcm);
    store->changes_since(&revision, &delta);
    check(!delta.events[0].audio.replace && delta.events[0].audio.offset == 0, "first chunk is a delta");
    audio_merge_event(retained, delta.events[0].audio);
    store->append_audio(handle, pcm);
    store->changes_since(&revision, &delta);
    auto pending = delta.events[0].audio;
    store->append_audio(handle, pcm); store->finish_audio(handle);
    store->changes_since(&revision, &delta);
    audio_merge_event(pending, delta.events[0].audio);
    check(!pending.replace && pending.offset == 4800 && pending.frames == 14400, "coalescing retains delta offset");
    audio_merge_event(retained, pending);
    check(retained.bytes == pcm + pcm + pcm && retained.finished, "append/finish preserve every PCM frame");
    audio_merge_event(retained, pending);
    check(retained.frames == 14400, "replayed delta is idempotent");
    auto reconnect = store->snapshot_cell(1).at(0);
    check(reconnect.audio.replace && reconnect.audio.bytes == retained.bytes, "reconnect is a complete retained snapshot");
    worker::Presentation streaming; worker::CellPresentation streamCell; streamCell.id = 1;
    streamCell.audio = {reconnect}; streaming.cells = {streamCell};
    const auto streamRoundtrip = worker::decode_presentation(worker::encode_presentation(streaming));
    check(streamRoundtrip.cells[0].audio[0].audio.bytes == retained.bytes, "PCM transport is binary exact");
    bool closedAppend = false; try { store->append_audio(handle, pcm); } catch (...) { closedAppend = true; }
    check(closedAppend, "append after finish rejected");
    store->reset_audio(handle); store->append_audio(handle, pcm);
    const auto reset = store->snapshot_cell(1)[0].audio;
    check(reset.token != retained.token && reset.frames == 4800 && !reset.finished, "reset establishes a fresh playback epoch");
    bool full = false;
    try { store->append_audio(handle, std::string(kAudioMaxBytes, '\0')); } catch (...) { full = true; }
    check(full && store->snapshot_cell(1)[0].audio.frames == 4800, "buffer limit rejects whole chunk without data loss");
    store->begin_cell(1);
    closedAppend = false; try { store->append_audio(handle, pcm); } catch (...) { closedAppend = true; }
    check(closedAppend, "old generation cannot publish"); store->close();
    session.cells[0].source = R"(from audio import AudioTrack
stream = AudioTrack.stream(sample_format: :s16le, sample_rate: 48000, layout: :stereo)
notebook.player(stream, id: "live", volume: 0.2)
handle = notebook.component("stream_player", board: "audio")
handle.append(fs.read_bytes("PCM_PATH"))
handle.finish()
42
)";
    const auto streamPath = session.cells[0].source.find("PCM_PATH");
    session.cells[0].source.replace(streamPath, 8, (project.directory / "tone.pcm").string());
    evaluate_from(&session, 0, true, false, false);
    check(session.cells[0].ok, "stream package execution: " + session.cells[0].error);
    check(session.cells[0].audio.size() == 1 && session.cells[0].audio[0].audio.bytes == pcm && session.cells[0].audio[0].audio.finished, "source stream append/finish is retained");
    session.cells[0].source = "from audio import AudioTrack\nAudioTrack.from_pcm(\"bad\", sample_format: :s16le, sample_rate: 48000, channels: 2)\n";
    evaluate_from(&session, 0, true, false, false);
    check(!session.cells[0].ok && session.cells[0].audio.size() == 1, "invalid PCM keeps committed result");
    auto inputBoard = parse_project_board(R"({"id":"inputs","title":"Audio inputs","sheet":"main","components":[{"id":"voice_input","title":"Voice","kind":"audio_input","audio_id":"voice"}]})");
    tabs.save_board(inputBoard);
    const auto emptyInput = session.project_audio_inputs;
    check(emptyInput && emptyInput->at("voice").audio.bytes.empty(), "new Audio Input is empty");
    AudioDisplay inputAudio; inputAudio.format = "wav"; inputAudio.bytes = wav;
    tabs.edit_audio(ProjectAudioEdit{"inputs", "voice_input", "Voice.wav", inputAudio});
    const auto frozen = session.project_audio_inputs;
    check(frozen->at("voice").audio.bytes == wav && emptyInput->at("voice").audio.bytes.empty(), "Apply replaces an immutable input snapshot");
    check(std::filesystem::exists(project.directory / frozen->at("voice").revision), "accepted audio is a managed member");
    session.runtime_capability_grants.clear();
    session.cells[0].watch = true;
    session.cells[0].source = R"(from audio import AudioTrack
accepted = AudioTrack.from_input("voice")
notebook.player(accepted)
42
)";
    evaluate_from(&session, 0, true, false, false);
    check(session.cells[0].ok && audio_decode(session.cells[0].displays[0].bytes).bytes == wav, "accepted AudioTrack reads without fs capability: " + session.cells[0].error);
    tabs.edit_audio(ProjectAudioEdit{"inputs", "voice_input", "", {}});
    check(session.project_audio_inputs->at("voice").audio.bytes.empty() && frozen->at("voice").audio.bytes == wav, "Clear preserves previously captured immutable bytes");
    check(session.cells[0].ok && session.cells[0].result == "42" && session.cells[0].dirty, "Audio Input Apply invalidates Watch consumers without running them");
    evaluate_from(&session, 0, true, false, false);
    check(!session.cells[0].ok && session.cells[0].error.find("Audio Input is empty") != std::string::npos, "empty input fails explicitly");
    auto unsafeInput = inputBoard; unsafeInput.components[0].extra["audio_asset"] = "\"audio/../outside.wav\"";
    bool unsafe = false; try { tabs.save_board(unsafeInput); } catch (...) { unsafe = true; }
    check(unsafe, "managed audio rejects path traversal");
    ProjectInput when; when.id = "when"; when.title = "When"; when.type = "string"; when.initial = std::string("2024-02-29T12:00:00Z"); tabs.create_input(when);
    tabs.save_board(parse_project_board(R"({"id":"controls","title":"Controls","sheet":"main","components":[{"id":"when","kind":"date_input","title":"When","input":"when","date_mode":"date_time","date_time_zone":"UTC"}]})"));
    bool invalidDate = false; try { tabs.set_inputs({{"when", "\"2023-02-29T12:00:00Z\""}}, false); } catch (...) { invalidDate = true; }
    check(invalidDate && std::get<std::string>(tabs.inputs().at("when")) == "2024-02-29T12:00:00Z", "calendar validation rejects invalid leap days");
    bool invalidRestore = false;
    try { tabs.restore_inputs({{"project:when", "\"invalid\""}}); } catch (...) { invalidRestore = true; }
    check(invalidRestore && std::get<std::string>(tabs.inputs().at("when")) == "2024-02-29T12:00:00Z", "restore validates the whole parameter batch before publication");
    std::cout << "Audio tests passed: package API, file/PCM/stream, hard IDs, binary protocol, managed inputs and validation\n";
  } catch (const std::exception &e) { std::cerr << "Audio test failed: " << e.what() << '\n'; return 1; }
}

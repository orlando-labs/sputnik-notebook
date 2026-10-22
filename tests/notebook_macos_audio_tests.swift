import AppKit
import SwiftUI

private struct AudioTestFailure: Error { let message: String }
@main private enum AudioTests {
    static func option(_ key: String) -> String? { CommandLine.arguments.firstIndex(of: key).flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw AudioTestFailure(message: message) } }
    @MainActor static func inputTest(_ model: NotebookModel, storage: URL) async throws {
        let source = URL(fileURLWithPath: "tools/notebook-macos/Samples/Audio Input.sputnikbook")
        let project = storage.appendingPathComponent("Input.sputnikbook")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: project)
        let manifest = project.appendingPathComponent("project.json")
        var doc = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        doc["dependencies"] = [["path": URL(fileURLWithPath: "../sputnik-lang/packages/notebook_ui").standardizedFileURL.path, "auto_import": false]]
        try JSONSerialization.data(withJSONObject: doc).write(to: manifest)
        let opened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
        try check(opened, model.error ?? "input example open")
        let run = await withCheckedContinuation { c in model.perform("run_all") { c.resume(returning: $0) } }
        try check(run && model.activeTab!.cells[0].ok, model.activeTab!.cells[0].error + (model.error ?? ""))
        let accepted = model.snapshot!.audio_inputs!.first!
        try check(accepted.name == "Example.wav" && accepted.panels.count == 1, "managed audio snapshot is exposed to client")
        let wav = try Data(contentsOf: project.appendingPathComponent("audio/example.wav"))
        let board = model.snapshot!.boards!.first!, component = board.components.first { $0.kind == "audio_input" }!
        let replaced = await withCheckedContinuation { c in model.editAudio(board: board, component: component, data: wav, format: "wav", name: "Applied.wav") { c.resume(returning: $0) } }
        try check(replaced, model.error ?? "apply imported audio")
        try check(model.snapshot!.audio_inputs!.first!.name == "Applied.wav", "Apply persists accepted metadata")
        let reran = await withCheckedContinuation { c in model.perform("run_all") { c.resume(returning: $0) } }
        try check(reran && model.activeTab!.cells[0].ok, "worker reloads the applied frozen asset without fs.read")
        if let output = option("--output") {
            let directory = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil); defer { window.close() }
            let view = NSHostingView(rootView: NotebookBoardView(model: model, board: model.snapshot!.boards![0], onDesign: {}))
            window.contentView = view; try await Task.sleep(nanoseconds: 400_000_000); view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!; view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("audio-input.png"))
        }
        let cleared = await withCheckedContinuation { c in model.editAudio(board: board, component: component, data: Data(), format: "wav", name: "") { c.resume(returning: $0) } }
        try check(cleared && model.snapshot!.audio_inputs!.first!.panels.isEmpty, "Clear accepts an empty input")
        let emptyRan = await withCheckedContinuation { c in model.perform("run_all") { c.resume(returning: $0) } }
        try check(emptyRan && !model.activeTab!.cells[0].ok && model.activeTab!.cells[0].error.contains("Audio Input is empty"), "empty accepted input has a visible error")
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("audio-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        let model = NotebookModel(workerExecutable: option("--worker"), remoteStorage: storage)
        do {
            if CommandLine.arguments.contains("--input-only") {
                try await inputTest(model, storage: storage)
                await withCheckedContinuation { c in model.shutdown { c.resume() } }
                print("Native Audio Input passed: managed assets, Apply/Clear, frozen snapshots, worker read without filesystem grant and board rendering"); return
            }
            let project = URL(fileURLWithPath: "tools/notebook-macos/Samples/Audio.sputnikbook")
            let original = try Data(contentsOf: project.appendingPathComponent("project.json"))
            let opened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
            try check(opened, model.error ?? "open failed")
            let settings = try await model.workerSettings(for: model.activeTab!)
            try await model.configureWorker(model.activeTab!, text: "fs.read", settings: settings)
            let ran = await withCheckedContinuation { c in model.perform("run_all") { c.resume(returning: $0) } }
            let tab = model.activeTab!, cell = tab.cells[0]
            try check(ran && cell.ok, cell.error + (model.error ?? ""))
            try check(cell.result == "42", "audio does not replace the scalar result")
            let panels = cell.displays!.filter { $0.mime == NotebookAudioPayload.mime }
            try check(panels.count == 2, "file and PCM player publication")
            let controller = model.audioSession.controller("test")
            controller.load(panels[0], waveform: false)
            for _ in 0..<100 { if !controller.loading { break }; try await Task.sleep(nanoseconds: 20_000_000) }
            try check(controller.error == nil && abs(controller.duration - 2.0) < 0.001, controller.error ?? "system decoder duration")
            try check(controller.peaks.isEmpty && !controller.playing, "compact and no autoplay")
            controller.seek(0.15); controller.setVolume(0.02); controller.play()
            for _ in 0..<25 {
                try await Task.sleep(nanoseconds: 50_000_000); controller.tick()
                if controller.position > 0.15 { break }
            }
            try check(controller.position > 0.15, controller.error ?? "system playback advances: \(controller.position), playing=\(controller.playing), asset=\(controller.asset != nil), busy=\(model.busy)")
            controller.pause(); let paused = controller.position
            controller.load(panels[0], waveform: true)
            for _ in 0..<100 { if !controller.peaks.isEmpty { break }; try await Task.sleep(nanoseconds: 20_000_000) }
            try check(!controller.peaks.isEmpty && abs(controller.position - paused) < 0.005 && !controller.playing, "waveform toggle preserves player position and pause")
            try check(model.snapshot!.boards![0].components.filter { $0.kind == "audio" }.map(\.show_waveform) == [true, false], "designer waveform options survive project loading")
            if let output = option("--output") {
                let directory = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil); defer { window.close() }
                for scheme in [ColorScheme.light, .dark] {
                    let view = NSHostingView(rootView: NotebookBoardView(model: model, board: model.snapshot!.boards![0], onDesign: {}).environment(\.colorScheme, scheme))
                    window.contentView = view; try await Task.sleep(nanoseconds: 300_000_000); view.layoutSubtreeIfNeeded()
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!; view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(scheme == .light ? "audio-light.png" : "audio-dark.png"))
                }
            }
            let saved = try Data(contentsOf: project.appendingPathComponent("project.json"))
            try check(saved == original, "playback keeps authored defaults unchanged")
            let streamProject = URL(fileURLWithPath: "tools/notebook-macos/Samples/Audio Streaming.sputnikbook")
            let streamOpened = await withCheckedContinuation { c in model.open(url: streamProject) { c.resume(returning: $0) } }
            try check(streamOpened, model.error ?? "stream project open")
            let streamSettings = try await model.workerSettings(for: model.activeTab!)
            try await model.configureWorker(model.activeTab!, text: "fs.read", settings: streamSettings)
            let running = Task { @MainActor in await withCheckedContinuation { c in model.perform("run_all") { c.resume(returning: $0) } } }
            var live: NotebookAudioStream?
            for _ in 0..<500 {
                try await Task.sleep(nanoseconds: 20_000_000)
                if let tab = model.activeTab, let first = model.audioStreams(for: tab.cells[0], in: tab).first, first.frames > 0 {
                    live = first; break
                }
                if !model.busy { break }
            }
            try check(live != nil && model.executingWorker && live!.frames < 60000, "PCM arrives before Run ends: \(model.activeTab?.cells[0].error ?? "no cell") \(model.error ?? "")")
            let streamController = model.audioSession.controller("stream-test")
            streamController.load(live!, waveform: false); streamController.setVolume(0.02); streamController.play()
            let initialFrames = live!.frames
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 40_000_000)
                if let tab = model.activeTab, let next = model.audioStreams(for: tab.cells[0], in: tab).first {
                    streamController.load(next, waveform: false); live = next
                }
                streamController.tick()
            }
            try check(streamController.position > 0 && live!.frames > initialFrames, streamController.error ?? "PCM playback and appends advance")
            let streamRan = await running.value
            let streamTab = model.activeTab!, streamCell = streamTab.cells[0]
            try check(streamRan && streamCell.ok, streamCell.error + (model.error ?? ""))
            let terminal = streamCell.audio!.first!
            streamController.pause(); let playhead = streamController.position
            streamController.load(terminal, waveform: true)
            try check(terminal.finished && terminal.frames == 60000 && terminal.data.count == 120000, "terminal PCM is complete")
            try check(abs(streamController.position - playhead) < 0.15 && !streamController.peaks.isEmpty, "terminal snapshot/waveform keeps the playback state")
            streamController.apply(NotebookAudioControl(cell: "1", channel: "stream", playback_revision: UInt64.max - 1, seek_revision: UInt64.max - 2, volume_revision: UInt64.max - 3, playback: 2, position: 0.25, volume: 0.02))
            try check(abs(streamController.position - 0.25) < 0.001 && !streamController.playing, "coalesced hard ID commands preserve seek and pause")
            await withCheckedContinuation { c in model.shutdown { c.resume() } }
            print("Native audio passed: isolated worker, file/PCM playback, live streaming before Run ends, seek/pause, waveform toggle, hard-ID control state and themes")
        } catch { await withCheckedContinuation { c in model.shutdown { c.resume() } }; fputs("Native audio failed: \(error)\n", stderr); exit(1) }
    }
}

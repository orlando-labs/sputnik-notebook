import AppKit
import SwiftUI
import Accelerate

private struct AudioAnnotationFailure: Error { let message: String }
@main private enum AudioAnnotationTests {
    static func check(_ ok: @autoclosure () -> Bool, _ message: String) throws { if !ok() { throw AudioAnnotationFailure(message: message) } }
    static func option(_ key: String) -> String? { CommandLine.arguments.firstIndex(of: key).flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } }
    @MainActor static func coordinateInputTests(payload: NotebookAudioPayload, labels: NotebookAudioAnnotations) async throws -> NotebookAudioAnnotations {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 790), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil); defer { window.close() }
        var result = labels
        for mode in ["waveform", "spectrogram"] {
            var applied: NotebookAudioAnnotations?
            let binding = NotebookAudioAnnotationBinding(source: labels.source, channel: labels.channel, cell: labels.cell, accepted: labels, disabled: false, apply: { value, done in applied = value; done(true) })
            window.contentView = NSHostingView(rootView: NotebookAudioAnnotatorView(payload: payload, binding: binding, initialView: mode, fftSize: 1024).environment(\.locale, Locale(identifier: "en_US_POSIX")))
            try await Task.sleep(nanoseconds: 800_000_000)
            let start = mode == "waveform" ? "0.3" : "0,3", end = mode == "waveform" ? "1.1" : "1,1"
            for (name, value) in [("Start (s)", start), ("End (s)", end), ("Low (Hz)", "350"), ("High (Hz)", "620")] {
                try AnnotationSheetTestSupport.edit(name, text: value, window: window)
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            try AnnotationSheetTestSupport.edit("Start (s)", text: "NaN", window: window)
            try await Task.sleep(nanoseconds: 30_000_000)
            try AnnotationSheetTestSupport.click("audio-annotations-apply", window: window)
            try check(applied == nil, "invalid timestamp disables Apply")
            try AnnotationSheetTestSupport.edit("Start (s)", text: start, window: window)
            try await Task.sleep(nanoseconds: 30_000_000)
            try AnnotationSheetTestSupport.click("audio-annotations-apply", window: window)
            try await Task.sleep(nanoseconds: 80_000_000)
            guard let value = applied else { throw AudioAnnotationFailure(message: "native time/frequency inputs were not applied: " + mode) }
            let first = value.segments[0]
            try check(first.start_frame == 4800 && first.end_frame == 17600 && first.low_hz == 350 && first.high_hz == 620, "time/frequency input edits reach exact sample/Hz Apply values in \(mode): \(first.start_frame)..\(first.end_frame), \(String(describing: first.low_hz))..\(String(describing: first.high_hz))")
            result = value
        }
        return result
    }
    @MainActor static func transcriptPolicyTests(payload: NotebookAudioPayload, labels: NotebookAudioAnnotations) async throws {
        let policies = [NotebookAudioTranscriptPolicy(trackAllowed: false, trackRequired: false, segmentAllowed: true, segmentRequired: true),
                        NotebookAudioTranscriptPolicy(trackAllowed: true, trackRequired: true, segmentAllowed: false, segmentRequired: false),
                        NotebookAudioTranscriptPolicy(trackAllowed: false, trackRequired: false, segmentAllowed: false, segmentRequired: false)]
        for policy in policies {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 790), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil); defer { window.close() }
            var initial = labels; initial.segments = [labels.segments[0]]
            if policy.trackRequired { initial.transcript = "" }
            if policy.segmentRequired { initial.segments[0].transcript = "" }
            var applied: NotebookAudioAnnotations?
            let binding = NotebookAudioAnnotationBinding(source: labels.source, channel: labels.channel, cell: labels.cell, accepted: initial, disabled: false, apply: { value, done in applied = value; done(true) }, classes: labels.classes, transcriptPolicy: policy)
            window.contentView = NSHostingView(rootView: NotebookAudioAnnotatorView(payload: payload, binding: binding, initialView: "waveform", fftSize: 1024))
            try await Task.sleep(nanoseconds: 700_000_000)
            if policy.trackRequired || policy.segmentRequired {
                try AnnotationSheetTestSupport.click("audio-annotations-apply", window: window)
                try check(applied == nil, "required empty transcript prevents native Apply")
                try AnnotationSheetTestSupport.editTranscript("Required transcript", window: window)
                try await Task.sleep(nanoseconds: 80_000_000)
            } else { try check(AnnotationSheetTestSupport.textViews(window.contentView!).filter(\.isEditable).isEmpty, "disallowed transcript editors are absent") }
            try AnnotationSheetTestSupport.click("audio-annotations-apply", window: window)
            try await Task.sleep(nanoseconds: 80_000_000)
            guard let value = applied else { throw AudioAnnotationFailure(message: "valid required transcript did not enable Apply") }
            try check(policy.validationError(value) == nil, "native transcript data follows designer policy")
            if policy.trackRequired { try check(value.transcript == "Required transcript" && value.segments[0].transcript.isEmpty, "required whole transcript, disabled segment transcript") }
            if policy.segmentRequired { try check(value.transcript.isEmpty && value.segments[0].transcript == "Required transcript", "required segment transcript, disabled whole transcript") }
        }
    }
    static func analysisTests() throws {
        let samples = (0..<8000).map { Float(0.25 * sin(Double($0) * 2 * .pi * 1000 / 8000)) }
        let setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!; defer { vDSP_destroy_fftsetup(setup) }
        let spectrum = NotebookAudioRender.fftDB(samples, center: 4000, size: 1024, setup: setup)
        let peak = spectrum.indices.max { spectrum[$0] < spectrum[$1] }!
        try check(peak == 128 && abs(spectrum[peak] - (-12.0412)) < 0.02, "system FFT frequency bin and dBFS normalization")
        let viewport = NotebookAudioViewport(start: 100, end: 200, low: 0, high: 4000)
        let selection = viewport.segment(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 80, y: 80), size: CGSize(width: 100, height: 100), spectral: true)!
        try check(selection.start_frame == 110 && selection.end_frame == 180 && selection.low_hz == 800 && selection.high_hz == 3200, "rectangle maps to source frames and Hz")
        let reversed = viewport.segment(from: CGPoint(x: 80, y: 80), to: CGPoint(x: 10, y: 20), size: CGSize(width: 100, height: 100), spectral: true)!
        try check(reversed.start_frame == selection.start_frame && reversed.low_hz == selection.low_hz, "reverse drag keeps the same region")
        var zoom = viewport
        for _ in 0..<12 { zoom = zoom.zoom(2, frames: 8000) }
        try check(zoom.length == 1 && zoom.start >= 100 && zoom.end <= 200, "zoom reaches individual source samples")
        try check(viewport.panned(9000, frames: 8000).end == 8000, "pan clamps at source end")
        let peaks = NotebookAudioRender.waveform(samples, viewport: .init(start: 0, end: 8000, low: 0, high: 4000), width: 100)
        try check(peaks.count == 100 && peaks[20].minimum < -0.24 && peaks[20].maximum > 0.24, "waveform retains extrema")
        let rendered = try NotebookAudioRender.build(samples: samples, rate: 8000, viewport: .init(start: 0, end: 8000, low: 500, high: 2500), fftSize: 1024, spectral: true, floorDB: -90, width: 120)
        try check(rendered.spectrogram?.width == 120 && rendered.spectrogram!.height > 0, "spectrogram renders the selected frequency viewport")
        let dark = NotebookPlasma.rgb(0), bright = NotebookPlasma.rgb(1)
        try check(NotebookPlasma.bytes.count == 768 && dark.0 == 13 && dark.2 == 135 && bright.0 == 240 && bright.1 == 249, "canonical plasma LUT")
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-annotation-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NotebookModel(workerExecutable: option("--worker"), remoteStorage: root.appendingPathComponent("settings"))
        do {
            try analysisTests()
            let project = root.appendingPathComponent("Audio.sputnikbook")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "tools/notebook-macos/Samples/Audio Annotations.sputnikbook"), to: project)
            let path = project.appendingPathComponent("project.json")
            var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
            manifest["dependencies"] = [["path": URL(fileURLWithPath: "../sputnik-lang/packages/notebook_ui").standardizedFileURL.path, "auto_import": false]]
            try JSONSerialization.data(withJSONObject: manifest).write(to: path)
            let opened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
            try check(opened, model.error ?? "open audio annotation sample")
            var board = model.snapshot!.boards![0], component = board.components.first { $0.kind == "audio_annotator" }!
            let panel = model.audioInput("clip", sheet: "main")!.panels[0]
            let payload = try NotebookAudioPayload.decode(panel.data), analysis = try NotebookAudioAnalysis.decode(payload)
            try check(analysis.frames == 64000 && analysis.rate == 16000, "managed file system decode")
            var labels = NotebookAudioAnnotations(asset: notebookAssetID(payload.data), source: "input", channel: "clip", cell: 0, sample_rate: analysis.rate, channels: analysis.channels, frames: analysis.frames)
            let speaker = NotebookAudioAnnotations.Attribute(id: "speaker", title: "Speaker", type: "choice", options: ["Alice", "Bob"])
            let confidence = NotebookAudioAnnotations.Attribute(id: "confidence", title: "Confidence", type: "number", options: [])
            labels.classes = [.init(id: "speech", title: "Speech", attributes: [speaker, confidence]), .init(id: "noise", title: "Noise", attributes: [])]
            labels.transcript = "Reference tone, silence, rising chirp."
            labels.segments = [.init(id: "tone", title: "Reference tone", start_frame: 3200, end_frame: 20000, low_hz: 300, high_hz: 650, classes: ["speech"], attributes: ["speech": ["speaker": .text("Alice"), "confidence": .number(0.97)]], transcript: "Tone"), .init(id: "chirp", title: "Rising chirp", start_frame: 35200, end_frame: 60000, classes: ["noise"], transcript: "Chirp")]
            component.annotation_classes = labels.classes
            component = try await AnnotationSheetTestSupport.designerConfiguration(component)
            labels.classes = component.annotationClasses
            board.components[board.components.firstIndex { $0.id == component.id }!] = component
            let saved = await withCheckedContinuation { c in model.saveBoard(board) { c.resume(returning: $0) } }
            try check(saved, model.error ?? "designer audio schema save")
            board = model.snapshot!.boards![0]; component = board.components.first { $0.kind == "audio_annotator" }!
            try check(component.annotation_classes == labels.classes, "audio designer schema roundtrip")
            var draft = NotebookAudioAnnotationDraft(value: labels)
            var next = labels; next.segments[0].transcript = "Edited"
            draft.replace(next); draft.undoEdit(); try check(draft.value == labels, "Undo restores exact bounds and metadata")
            draft.redoEdit(); try check(draft.value.segments[0].transcript == "Edited", "Redo")
            labels = try await coordinateInputTests(payload: payload, labels: labels)
            try await transcriptPolicyTests(payload: payload, labels: labels)
            let applied = await withCheckedContinuation { c in model.editComponentData(labels, kind: "audio_annotations", board: board, component: component) { c.resume(returning: $0) } }
            try check(applied, model.error ?? "Apply audio labels")
            try check(model.acceptedComponentData(NotebookAudioAnnotations.self, kind: "audio_annotations", channel: component.annotation_id ?? component.id + "_labels")?.segments == labels.segments, "typed time/frequency bounds survive backend persistence")
            try check(model.activeTab!.cells[0].dirty, "Apply does not execute the consumer")
            let ran = await withCheckedContinuation { c in model.perform("run_all") { c.resume(returning: $0) } }
            try check(ran && model.activeTab!.cells[0].ok && model.activeTab!.cells[0].result.contains("Alice"), model.activeTab!.cells[0].error + " / " + (model.error ?? "kernel labels"))
            let record = try model.runHistory.load(model.runHistory.runs[0].id)
            try check(record.acceptedData?.contains { $0.kind == "audio_annotations" && $0.json.contains("Alice") } == true, "Run History captures accepted audio labels")
            if let output = option("--output") {
                let directory = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 790), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil); defer { window.close() }
                let binding = NotebookAudioAnnotationBinding(source: "input", channel: "clip", cell: 0, accepted: labels, disabled: false, apply: { _, done in done(true) })
                for (name, viewMode, scheme) in [("waveform-light", "waveform", ColorScheme.light), ("spectrogram-light", "spectrogram", .light), ("spectrogram-dark", "spectrogram", .dark)] {
                    let view = NSHostingView(rootView: NotebookAudioAnnotatorView(payload: payload, binding: binding, initialView: viewMode, fftSize: 1024).environment(\.colorScheme, scheme))
                    window.contentView = view; try await Task.sleep(nanoseconds: 1_000_000_000); view.layoutSubtreeIfNeeded()
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!; view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
                }
            }
            let sheetWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
            sheetWindow.isReleasedWhenClosed = false; sheetWindow.makeKeyAndOrderFront(nil)
            let componentHost = NSHostingView(rootView: NotebookAudioAnnotatorComponent(model: model, board: model.snapshot!.boards![0], component: model.snapshot!.boards![0].components.first { $0.kind == "audio_annotator" }!, tab: model.activeTab!).padding(20))
            sheetWindow.contentView = componentHost
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let sheetPNG = option("--output").map { URL(fileURLWithPath: $0).appendingPathComponent("audio-sheet-click.png") }
            try await AnnotationSheetTestSupport.opens(window: sheetWindow, button: "audio-annotate", editor: "audio-annotation-editor", discard: "audio-annotations-discard", output: sheetPNG)
            try await AnnotationSheetTestSupport.opens(window: sheetWindow, button: "audio-annotate", editor: "audio-annotation-editor", discard: "audio-annotations-discard")
            sheetWindow.close()
            await withCheckedContinuation { c in model.shutdown { c.resume() } }
            print("Audio annotations passed: system FFT/dBFS, plasma, sample/Hz selection, zoom, native time/frequency inputs in both views, typed metadata, immutable Apply, worker, history and native themes")
        } catch { fputs("Audio annotations failed: \(error) · \(model.error ?? "")\n", stderr); exit(1) }
    }
}

import AppKit
import SwiftUI
import AVFoundation
import AudioToolbox
import CoreAudio
import UniformTypeIdentifiers

struct NotebookAudioDraft: Equatable {
    var data: Data, format: String, name: String
    var panel: NotebookFigurePanel? {
        guard !data.isEmpty else { return nil }
        return NotebookFigurePanel(mime: NotebookAudioPayload.mime, caption: name, width: 0, height: 0,
            data: NotebookAudioPayload.encode(data, format: format), id: "draft")
    }
}

/// The microphone is opened only by an explicit Record action. Tap data stays
/// in a temporary WAV until Stop; Apply owns the separate project transaction.
final class NotebookAudioRecorder: ObservableObject {
    struct Device: Identifiable { let id: AudioDeviceID, name: String }
    @Published var devices: [Device] = []
    @Published var selected: AudioDeviceID = 0
    @Published var recording = false
    @Published var requesting = false
    @Published var elapsed = 0.0
    @Published var peak: Float = 0
    @Published var rms: Float = 0
    @Published var clipped = false
    @Published var error: String?
    @Published var captured: NotebookAudioDraft?
    private var engine: AVAudioEngine?
    private var timer: Timer?
    private var url: URL?
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frames: Int64 = 0
    private var lastPeak: Float = 0, lastRMS: Float = 0
    private var clipSeen = false, writeError: String?
    private var rate = 48000.0
    private var request = UUID()

    func refreshDevices() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return }
        devices = ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var count: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &count) == noErr, count > 0 else { return nil }
            var name: CFString = "Microphone" as CFString
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            _ = AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name)
            return Device(id: id, name: name as String)
        }
        if selected != 0 && !devices.contains(where: { $0.id == selected }) { selected = 0 }
    }
    func start() {
        guard !recording, !requesting else { return }
        requesting = true; error = nil; captured = nil; request = UUID(); let current = request
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self, self.request == current else { return }; self.requesting = false
                guard allowed else { self.error = "Microphone access was denied. Enable it in System Settings to record."; return }
                self.beginCapture()
            }
        }
    }
    private func beginCapture() {
        do {
            let engine = AVAudioEngine(), input = engine.inputNode
            if selected != 0 {
                guard let unit = input.audioUnit else { throw recorderError("Selected microphone is unavailable.") }
                var device = selected
                guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
                    throw recorderError("Could not open the selected microphone.")
                }
            }
            let format = input.outputFormat(forBus: 0)
            guard (1...2).contains(format.channelCount), (8000...192000).contains(format.sampleRate) else {
                throw recorderError("Recording requires a mono/stereo input at 8–192 kHz.")
            }
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
            let file = try AVAudioFile(forWriting: target, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false],
                commonFormat: .pcmFormatFloat32, interleaved: false)
            self.url = target; self.engine = engine; self.rate = format.sampleRate
            lock.lock(); self.file = file; frames = 0; lastPeak = 0; lastRMS = 0; clipSeen = false; writeError = nil; lock.unlock()
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                guard let file = self.file, self.writeError == nil else { return }
                let remaining = Int64(self.rate * 30) - self.frames
                guard remaining > 0 else { return }
                buffer.frameLength = min(buffer.frameLength, AVAudioFrameCount(remaining))
                var peak: Float = 0, sum: Double = 0
                if let samples = buffer.floatChannelData {
                    for channel in 0..<Int(buffer.format.channelCount) { for i in 0..<Int(buffer.frameLength) {
                        let value = samples[channel][i]
                        guard value.isFinite else { self.writeError = "Microphone returned invalid PCM samples."; return }
                        peak = max(peak, abs(value)); sum += Double(value) * Double(value)
                    } }
                }
                do { try file.write(from: buffer); self.frames += Int64(buffer.frameLength) }
                catch { self.writeError = error.localizedDescription }
                self.lastPeak = peak; self.lastRMS = Float(sqrt(sum / Double(max(1, Int(buffer.frameLength) * Int(buffer.format.channelCount)))))
                self.clipSeen = self.clipSeen || peak >= 1
            }
            try engine.start(); recording = true; elapsed = 0; clipped = false
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.poll() }
        } catch { self.error = error.localizedDescription; discard() }
    }
    private func poll() {
        lock.lock(); let frames = self.frames, peak = lastPeak, rms = lastRMS, clip = clipSeen, failure = writeError; lock.unlock()
        elapsed = Double(frames) / rate; self.peak = peak; self.rms = rms; clipped = clip
        if let failure { error = failure; discard() }
        else if elapsed >= 30 { stop() }
        else if let engine, !engine.isRunning { error = "Microphone disconnected or audio capture stopped."; stop() }
    }
    func stop() {
        guard recording else { return }
        endCapture()
        guard let url else { return }
        defer { try? FileManager.default.removeItem(at: url); self.url = nil }
        do {
            let data = try Data(contentsOf: url)
            guard data.count > 44, data.count <= 16 * 1024 * 1024 - 64 else { throw recorderError("Recording is empty or exceeds the audio limit.") }
            captured = NotebookAudioDraft(data: data, format: "wav", name: "Recording.wav")
        } catch { self.error = error.localizedDescription }
    }
    func discard() {
        request = UUID(); requesting = false; endCapture(); captured = nil
        if let url { try? FileManager.default.removeItem(at: url) }; url = nil
    }
    private func endCapture() {
        timer?.invalidate(); timer = nil
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }; engine = nil
        lock.lock(); file = nil; lock.unlock(); recording = false; peak = 0; rms = 0
    }
    private func recorderError(_ text: String) -> NSError { NSError(domain: "NotebookRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    deinit { timer?.invalidate(); engine?.stop(); if let url { try? FileManager.default.removeItem(at: url) } }
}

struct NotebookAudioInputView: View {
    @ObservedObject var model: NotebookModel
    let board: NotebookBoard, component: NotebookBoardComponent
    @StateObject private var recorder = NotebookAudioRecorder()
    @StateObject private var preview = NotebookAudioController()
    @State private var draft: NotebookAudioDraft?
    @State private var importing = false
    @State private var error: String?
    private var channel: String { component.audio_id ?? component.id }
    private var accepted: NotebookAudioInput? { model.audioInput(channel, sheet: board.sheet) }
    private var panel: NotebookFigurePanel? { draft?.panel ?? (draft == nil ? accepted?.panels.first : nil) }
    private var disabled: Bool { model.busy || (model.remote.isSelected && model.remote.active) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Choose audio…", systemImage: "waveform.badge.plus", action: choose).disabled(disabled || recorder.recording || recorder.requesting || importing)
                Button("Clear") { draft = NotebookAudioDraft(data: Data(), format: "wav", name: "") }.disabled(disabled || recorder.recording || recorder.requesting)
                Spacer()
                if draft != nil { Text("Draft").font(.caption).foregroundStyle(NotebookPalette.sputnik) }
            }
            if component.audio_recording ?? true {
                HStack {
                    Picker("Microphone", selection: $recorder.selected) {
                        Text("System default").tag(AudioDeviceID(0))
                        ForEach(recorder.devices) { Text($0.name).tag($0.id) }
                    }.disabled(disabled || recorder.recording || recorder.requesting)
                    if recorder.recording {
                        Button("Stop", systemImage: "stop.circle.fill") { recorder.stop() }
                    } else {
                        Button("Record", systemImage: "record.circle") { preview.pause(); recorder.start() }.disabled(disabled || importing || recorder.requesting)
                    }
                }
                if recorder.recording {
                    HStack {
                        ProgressView(value: min(1, recorder.peak)).tint(recorder.clipped ? NotebookPalette.error : NotebookPalette.sputnik)
                        Text(String(format: "%.1f / 30 s · RMS %.1f dBFS", recorder.elapsed, 20 * log10(max(0.000001, recorder.rms))))
                            .font(.system(.caption, design: .monospaced))
                        if recorder.clipped { Text("Clipping").font(.caption).foregroundStyle(NotebookPalette.error) }
                    }
                }
            }
            if let panel { NotebookAudioView(controller: preview, panel: panel, showWaveform: true) }
            else { Text(draft == nil ? "Choose or record audio, then Apply." : "Audio will be cleared on Apply.").font(.callout).foregroundStyle(NotebookPalette.muted) }
            HStack {
                Button("Apply") { apply() }
                    .disabled(disabled || draft == nil || recorder.recording || recorder.requesting || importing || preview.loading || (draft?.data.isEmpty == false && preview.error != nil))
                Button("Discard") { recorder.discard(); draft = nil; error = nil }.disabled(draft == nil && !recorder.recording && !recorder.requesting)
                Text(draft == nil ? "Accepted input for the next Run" : "Apply accepts this clip for the next Run").font(.caption).foregroundStyle(NotebookPalette.muted)
                if importing || recorder.requesting { ProgressView().controlSize(.small) }
            }
            if let error = error ?? recorder.error { Text(error).font(.caption).foregroundStyle(NotebookPalette.error) }
        }
        .onAppear { recorder.refreshDevices() }
        .onDisappear { recorder.discard(); preview.close() }
        .onChange(of: recorder.captured) { if let value = $0 { draft = value; error = nil } }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !disabled, !recorder.recording, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { DispatchQueue.main.async { importAudio(url) } } }; return true
        }
    }
    private func choose() {
        let chooser = NSOpenPanel(); chooser.canChooseDirectories = false; chooser.allowsMultipleSelection = false; chooser.allowedContentTypes = [.audio]
        if chooser.runModal() == .OK, let url = chooser.url { importAudio(url) }
    }
    private func importAudio(_ url: URL) {
        guard url.isFileURL else { return }; importing = true; error = nil
        Task { @MainActor in
            do {
                let value = try await Task.detached { () -> NotebookAudioDraft in
                    let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard info.isRegularFile == true, let size = info.fileSize, size > 0, size <= 16 * 1024 * 1024 - 64 else {
                        throw CocoaError(.fileReadTooLarge)
                    }
                    let data = try Data(contentsOf: url), format = url.pathExtension.lowercased()
                    let value = NotebookAudioDraft(data: data, format: format, name: url.lastPathComponent)
                    let payload = try NotebookAudioPayload.decode(NotebookAudioPayload.encode(data, format: format))
                    let checked = try NotebookDecodedAudio.prepare(payload, waveform: false)
                    try? FileManager.default.removeItem(at: checked.url)
                    return value
                }.value
                draft = value
            } catch { self.error = error.localizedDescription }
            importing = false
        }
    }
    private func apply() {
        guard let draft else { return }
        model.editAudio(board: board, component: component, data: draft.data, format: draft.format, name: draft.name) { success in
            if success { self.draft = nil; recorder.captured = nil; preview.close() }
        }
    }
}

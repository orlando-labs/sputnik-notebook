import SwiftUI

struct NotebookAudioView: View {
    @ObservedObject var controller: NotebookAudioController
    var panel: NotebookFigurePanel? = nil
    var stream: NotebookAudioStream? = nil
    var showWaveform: Bool? = nil
    var stale = false
    private var waveform: Bool { showWaveform ?? stream?.waveform ?? controller.payload?.waveform ?? true }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(controller.playing ? "Pause" : "Play", systemImage: controller.playing ? "pause.fill" : "play.fill") {
                    if controller.playing { controller.pause() } else { controller.play() }
                }.disabled(controller.loading || !controller.canPlay)
                Button("Stop", systemImage: "stop.fill") { controller.stop(); controller.seek(0) }.disabled(!controller.canPlay)
                Text("\(time(controller.position)) / \(time(controller.duration))").font(.system(.caption, design: .monospaced))
                Spacer()
                NotebookObjectMenu(title: "Audio actions") {
                    if stream == nil { Button("Save original…") { controller.save(original: true) } }
                    Button("Export WAV…") { controller.save(original: false) }
                    Button("Copy metadata") {
                        if let stream {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("PCM \(stream.sample_format) · \(stream.rate) Hz · \(stream.channels) channels", forType: .string); return
                        }
                        guard let asset = controller.asset, let payload = controller.payload else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(payload.format) · \(asset.rate) Hz · \(asset.channels) channels · \(asset.duration) s", forType: .string)
                    }
                }.disabled(!controller.canPlay)
            }
            if waveform && !controller.peaks.isEmpty {
                Canvas { context, size in
                    var path = Path()
                    for (index, value) in controller.peaks.enumerated() {
                        let x = CGFloat(index) * size.width / CGFloat(controller.peaks.count)
                        let y = CGFloat(value) * size.height * 0.48
                        path.move(to: CGPoint(x: x, y: size.height / 2 - y)); path.addLine(to: CGPoint(x: x, y: size.height / 2 + y))
                    }
                    context.stroke(path, with: .color(NotebookPalette.sputnik), lineWidth: 1)
                    let x = controller.duration > 0 ? controller.position / controller.duration * size.width : 0
                    context.stroke(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(NotebookPalette.ink))
                }.frame(height: 90).accessibilityLabel("Audio waveform")
            }
            Slider(value: Binding(get: { min(controller.duration, controller.position) }, set: { controller.seek($0) }), in: 0...max(0.001, controller.duration)).accessibilityLabel("Playback position")
            HStack {
                Image(systemName: "speaker.wave.2")
                Slider(value: Binding(get: { Double(controller.volume) }, set: { controller.setVolume(Float($0)) }), in: 0...1)
                    .frame(maxWidth: 180).accessibilityLabel("Audio volume")
                if controller.buffering { Text("Buffering…").font(.caption) }
                if controller.loading { ProgressView().controlSize(.small); Text("Preparing audio…").font(.caption) }
                if stale { Label("Previous audio · stale", systemImage: "clock").font(.caption).foregroundStyle(NotebookPalette.sputnik) }
            }
            if let caption = stream?.caption ?? panel?.caption, !caption.isEmpty { Text(caption).font(.caption).textSelection(.enabled) }
            if let error = controller.error { Text(error).font(.caption).foregroundStyle(NotebookPalette.error) }
        }
        .onAppear { load() }
        .onDisappear { controller.pause() }
        .onChange(of: panel) { _ in load() }
        .onChange(of: stream) { _ in load() }
        .onChange(of: showWaveform) { _ in load() }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in controller.tick() }
    }
    private func load() {
        if let stream { controller.load(stream, waveform: showWaveform) }
        else if let panel { controller.load(panel, waveform: showWaveform) }
    }
    private func time(_ value: Double) -> String { String(format: "%02d:%04.1f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60)) }
}

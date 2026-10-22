import SwiftUI
import AppKit

struct NotebookAudioAnnotationBinding {
    let source: String, channel: String
    let cell: UInt64
    let accepted: NotebookAudioAnnotations?
    let disabled: Bool
    let apply: (NotebookAudioAnnotations, @escaping (Bool) -> Void) -> Void
    var classes: [NotebookAnnotationClass]? = nil
    var transcriptPolicy = NotebookAudioTranscriptPolicy()
}

private struct NotebookAudioAnnotationPresentation: Identifiable {
    let id = UUID()
    let payload: NotebookAudioPayload
    let binding: NotebookAudioAnnotationBinding
    let initialView: String
    let fftSize: Int
}

struct NotebookAudioAnnotatorComponent: View {
    @ObservedObject var model: NotebookModel
    let board: NotebookBoard, component: NotebookBoardComponent, tab: NotebookTab
    @State private var annotationEditor: NotebookAudioAnnotationPresentation?
    @State private var error: String?
    private var source: String { component.audio_source ?? "file" }
    private var panel: NotebookFigurePanel? {
        let channel = component.audio_id ?? component.id
        if source == "cell", let cell = tab.cells.first(where: { $0.id == component.cell }) {
            return model.presentation(for: cell, in: tab).figures.first { $0.mime == NotebookAudioPayload.mime && $0.id == channel }
        }
        return model.audioInput(channel, sheet: board.sheet)?.panels.first
    }
    private var binding: NotebookAudioAnnotationBinding {
        .init(source: source == "cell" ? "cell" : "input", channel: component.audio_id ?? component.id, cell: source == "cell" ? UInt64(component.cell ?? "") ?? 0 : 0,
            accepted: model.acceptedComponentData(NotebookAudioAnnotations.self, kind: "audio_annotations", channel: component.annotation_id ?? component.id + "_labels") ?? component.audio_annotations, disabled: model.busy || model.remote.isSelected,
            apply: { model.editComponentData($0, kind: "audio_annotations", board: board, component: component, completion: $1) }, classes: component.annotationClasses, transcriptPolicy: component.transcriptPolicy)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if source == "file" {
                NotebookAudioInputView(model: model, board: board, component: fileComponent)
            } else if let panel {
                NotebookAudioView(controller: model.audioSession.controller("annotator:" + board.id + ":" + component.id), panel: panel, showWaveform: true)
            } else { Label("Choose an Audio Input or publish a completed track from the source cell", systemImage: "waveform").foregroundStyle(NotebookPalette.muted) }
            HStack {
                Button("Annotate audio…", systemImage: "waveform.badge.magnifyingglass") {
                    guard let panel else { return }
                    do { annotationEditor = .init(payload: try NotebookAudioPayload.decode(panel.data), binding: binding, initialView: component.audio_view ?? "waveform", fftSize: component.audio_fft_size ?? 1024); error = nil }
                    catch { self.error = error.localizedDescription }
                }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(panel == nil || binding.disabled).accessibilityIdentifier("audio-annotate")
                if let accepted = binding.accepted, let panel, let payload = try? NotebookAudioPayload.decode(panel.data) {
                    Text(accepted.matches(payload.data) ? "\(accepted.segments.count) segments" : "Audio changed · previous labels belong to another version").font(.caption).foregroundStyle(NotebookPalette.muted)
                }
            }
            if let error { Text(error).foregroundStyle(NotebookPalette.error) }
        }
        .sheet(item: $annotationEditor) { editor in
            NotebookAudioAnnotatorView(payload: editor.payload, binding: editor.binding, initialView: editor.initialView, fftSize: editor.fftSize)
        }
    }
    private var fileComponent: NotebookBoardComponent { var value = component; value.audio_recording = false; return value }
}

struct NotebookAudioAnnotatorView: View {
    let payload: NotebookAudioPayload
    let binding: NotebookAudioAnnotationBinding
    let initialView: String, fftSize: Int
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = NotebookAudioController()
    @State private var analysis: NotebookAudioAnalysis?
    @State private var draft: NotebookAudioAnnotationDraft?
    @State private var viewport = NotebookAudioViewport(start: 0, end: 1, low: 0, high: 4000)
    @State private var render: NotebookAudioRender?
    @State private var renderTask: Task<Void, Never>?
    @State private var spectrum = false
    @State private var fft = 1024
    @State private var floorDB = -90.0
    @State private var audioChannel = 0
    @State private var selected: String?
    @State private var preview: NotebookAudioAnnotations.Segment?
    @State private var wholeTranscriptOpen = false
    @State private var saving = false
    @State private var rendering = false
    @State private var error: String?
    @State private var playEnd: Double?
    @State private var invalidCoordinates: Set<String> = []
    private var segment: NotebookAudioAnnotations.Segment? { draft?.value.segments.first { $0.id == selected } }
    private var dirty: Bool { draft.map { $0.value != binding.accepted } ?? false }
    private var policyError: String? { draft.flatMap { binding.transcriptPolicy.validationError($0.value) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Audio annotations").font(.title2.bold())
                if let analysis { Text("\(analysis.rate) Hz · \(analysis.channels) ch · \(String(format: "%.3f", analysis.duration)) s").font(.caption).foregroundStyle(NotebookPalette.muted) }
                Spacer()
                if rendering { ProgressView().controlSize(.small) }
                Text("\((binding.classes ?? binding.accepted?.classes ?? []).count) classes · configured in Board Designer").font(.caption).foregroundStyle(NotebookPalette.muted)
            }
            if let analysis, let draft {
                toolbar(analysis)
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        plot(analysis, value: draft.value)
                        navigation(analysis)
                        segmentList(draft.value)
                        if binding.transcriptPolicy.trackAllowed { DisclosureGroup(binding.transcriptPolicy.trackRequired ? "Whole-track transcript *" : "Whole-track transcript", isExpanded: $wholeTranscriptOpen) {
                            TextEditor(text: Binding(get: { self.draft?.value.transcript ?? "" }, set: { text in
                                guard text.utf8.count <= 65536, !text.contains("\0") else { return }; update { $0.transcript = text }
                            })).font(.body).frame(height: 65).accessibilityIdentifier("audio-track-transcript")
                        }.font(.caption) }
                    }
                    ScrollView { inspector(analysis, value: draft.value).padding(4) }.frame(width: 265)
                }
                footer
            } else {
                ProgressView("Decoding audio…").frame(maxWidth: .infinity, maxHeight: .infinity)
                if let error { Text(error).foregroundStyle(NotebookPalette.error) }
                Button("Close") { dismiss() }
            }
        }.padding(18).frame(width: 1180, height: 790).background(NotebookPalette.canvas).foregroundStyle(NotebookPalette.ink).disabled(saving)
            .task { await prepare() }
            .onDisappear { renderTask?.cancel(); player.close() }
            .onChange(of: spectrum) { rebuild() }.onChange(of: fft) { rebuild() }.onChange(of: floorDB) { rebuild() }.onChange(of: audioChannel) { rebuild() }
            .onReceive(Timer.publish(every: 0.025, on: .main, in: .common).autoconnect()) { _ in
                player.tick(); if let end = playEnd, player.position >= end { player.pause(); playEnd = nil }
            }
            .interactiveDismissDisabled().accessibilityIdentifier("audio-annotation-editor")
    }
    private func toolbar(_ analysis: NotebookAudioAnalysis) -> some View {
        HStack(spacing: 10) {
            Picker("Display", selection: $spectrum) { Text("Waveform").tag(false); Text("Spectrogram · plasma").tag(true) }.pickerStyle(.segmented).frame(width: 280)
            if analysis.channels > 1 { Picker("Channel", selection: $audioChannel) { Text("Channel 1").tag(0); Text("Channel 2").tag(1); Text("Mono mix").tag(-1) }.frame(width: 155) }
            if spectrum {
                Picker("FFT", selection: $fft) { ForEach([256, 512, 1024, 2048, 4096], id: \.self) { Text(String($0)).tag($0) } }.frame(width: 130)
                Picker("Range", selection: $floorDB) { Text("60 dB").tag(-60.0); Text("90 dB").tag(-90.0); Text("120 dB").tag(-120.0) }.frame(width: 125)
            }
            Spacer()
            Button("Undo") { self.draft?.undoEdit() }.disabled(draft?.undo.isEmpty ?? true)
            Button("Redo") { self.draft?.redoEdit() }.disabled(draft?.redo.isEmpty ?? true)
        }.controlSize(.small)
    }
    private func plot(_ analysis: NotebookAudioAnalysis, value: NotebookAudioAnnotations) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                if spectrum {
                    VStack { Text(hz(viewport.high)); Spacer(); Text(hz((viewport.high + viewport.low) / 2)); Spacer(); Text(hz(viewport.low)) }.font(.system(.caption2, design: .monospaced)).frame(width: 58)
                }
                GeometryReader { geometry in
                    Canvas { context, size in
                        if spectrum, let image = render?.spectrogram { context.draw(Image(decorative: image, scale: 1), in: CGRect(origin: .zero, size: size)) }
                        else if let peaks = render?.waveform {
                            var path = Path()
                            for (index, peak) in peaks.enumerated() {
                                let x = (Double(index) + 0.5) / Double(peaks.count) * size.width
                                path.move(to: CGPoint(x: x, y: (1 - Double(max(-1, min(1, peak.maximum)))) * size.height / 2))
                                path.addLine(to: CGPoint(x: x, y: (1 - Double(max(-1, min(1, peak.minimum)))) * size.height / 2))
                            }
                            context.stroke(path, with: .color(NotebookPalette.sputnik), lineWidth: 1)
                        }
                        for item in value.segments + (preview.map { [$0] } ?? []) where item.end_frame > viewport.start && item.start_frame < viewport.end {
                            let rect = segmentRect(item, size: size)
                            let color: Color = item.id == selected ? .orange : .white
                            context.fill(Path(rect), with: .color(color.opacity(spectrum ? 0.08 : 0.13)))
                            context.stroke(Path(rect), with: .color(spectrum ? color : item.id == selected ? .orange : NotebookPalette.sputnik), lineWidth: item.id == selected ? 2 : 1)
                            let title = item.title.isEmpty ? item.classes.compactMap { key in value.classes.first { $0.id == key }?.title }.joined(separator: ", ") : item.title
                            if rect.width > 25 { context.draw(Text(title).font(.caption.bold()).foregroundColor(spectrum ? .white : NotebookPalette.ink), at: CGPoint(x: rect.minX + 3, y: rect.minY + 3), anchor: .topLeading) }
                        }
                        let frame = player.position * Double(analysis.rate)
                        if frame >= Double(viewport.start) && frame <= Double(viewport.end) {
                            let x = (frame - Double(viewport.start)) / Double(viewport.length) * size.width
                            context.stroke(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.orange))
                        }
                    }.background(NotebookPalette.canvas.opacity(0.6)).clipped().contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 3).onChanged { drag in preview = viewport.segment(from: drag.startLocation, to: drag.location, size: geometry.size, spectral: spectrum) }.onEnded { drag in
                            if let item = viewport.segment(from: drag.startLocation, to: drag.location, size: geometry.size, spectral: spectrum), value.segments.count < 1000 { update { $0.segments.append(item) }; selected = item.id }
                            preview = nil
                        })
                        .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                            if let item = value.segments.reversed().first(where: { segmentRect($0, size: geometry.size).contains(tap.location) }) { selected = item.id }
                            else { player.seek(Double(viewport.start) / Double(analysis.rate) + tap.location.x / geometry.size.width * Double(viewport.length) / Double(analysis.rate)) }
                        })
                        .accessibilityLabel(spectrum ? "Audio spectrogram. Drag to annotate a time and frequency rectangle." : "Audio waveform. Drag to annotate a time segment.")
                }
            }.frame(height: 285)
            HStack { ForEach(0..<5, id: \.self) { index in
                if index > 0 { Spacer() }
                Text(String(format: "%.4f s", Double(viewport.start + index * viewport.length / 4) / Double(analysis.rate))).font(.system(.caption2, design: .monospaced))
            } }
            if spectrum { HStack(spacing: 6) { Text("\(Int(floorDB)) dBFS"); LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.05).map { let c = NotebookPlasma.rgb($0); return Color(red: Double(c.0)/255, green: Double(c.1)/255, blue: Double(c.2)/255) }, startPoint: .leading, endPoint: .trailing).frame(width: 145, height: 8); Text("0 dBFS · Hann · Δf \(String(format: "%.1f", Double(analysis.rate)/Double(fft))) Hz") }.font(.caption2).foregroundStyle(NotebookPalette.muted) }
        }
    }
    private func segmentRect(_ item: NotebookAudioAnnotations.Segment, size: CGSize) -> CGRect {
        let x = Double(item.start_frame - viewport.start) / Double(viewport.length) * size.width
        let width = Double(item.end_frame - item.start_frame) / Double(viewport.length) * size.width
        let low = max(viewport.low, item.low_hz ?? viewport.low), high = min(viewport.high, item.high_hz ?? viewport.high)
        if spectrum && high <= low { return .zero }
        return CGRect(x: x, y: spectrum ? (viewport.high - high) / (viewport.high - viewport.low) * size.height : 0, width: max(1, width), height: spectrum ? (high - low) / (viewport.high - viewport.low) * size.height : size.height)
    }
    private func navigation(_ analysis: NotebookAudioAnalysis) -> some View {
        VStack(spacing: 8) {
            HStack {
                Button("−") { viewport = viewport.zoom(0.5, frames: analysis.frames); rebuild() }.help("Zoom out").accessibilityLabel("Zoom out")
                Button("+") { viewport = viewport.zoom(2, frames: analysis.frames); rebuild() }.help("Zoom in to individual samples").accessibilityLabel("Zoom in")
                Button("Fit") { viewport = .init(start: 0, end: analysis.frames, low: 0, high: Double(analysis.rate) / 2); rebuild() }
                Button("Zoom to selection") { if let segment { viewport = .init(start: segment.start_frame, end: segment.end_frame, low: spectrum ? segment.low_hz ?? viewport.low : viewport.low, high: spectrum ? segment.high_hz ?? viewport.high : viewport.high); rebuild() } }.disabled(segment == nil)
                Slider(value: Binding(get: { Double(viewport.start) }, set: { value in viewport = viewport.panned(Int(value) - viewport.start, frames: analysis.frames); rebuild() }), in: 0...Double(max(1, analysis.frames - viewport.length))).disabled(viewport.length >= analysis.frames).accessibilityLabel("Timeline pan")
            }
            HStack {
                Button(player.playing ? "Pause" : "Play", systemImage: player.playing ? "pause.fill" : "play.fill") { playEnd = nil; if player.playing { player.pause() } else { player.play() } }.disabled(player.loading || !player.canPlay)
                Button("Play selection") { if let segment { player.seek(Double(segment.start_frame) / Double(analysis.rate)); playEnd = Double(segment.end_frame) / Double(analysis.rate); player.play() } }.disabled(segment == nil || player.loading || !player.canPlay)
                Text(String(format: "%.4f s", player.position)).font(.system(.caption, design: .monospaced))
                Spacer()
                Button("Add segment") { let item = NotebookAudioAnnotations.Segment(start_frame: viewport.start, end_frame: viewport.end); update { $0.segments.append(item) }; selected = item.id }.disabled((draft?.value.segments.count ?? 0) >= 1000)
            }
        }.buttonStyle(.bordered).controlSize(.small)
    }
    private func segmentList(_ value: NotebookAudioAnnotations) -> some View {
        List(selection: $selected) {
            ForEach(value.segments.sorted { $0.start_frame < $1.start_frame }) { item in
                HStack {
                    Text(item.title.isEmpty ? item.classes.compactMap { key in value.classes.first { $0.id == key }?.title }.joined(separator: ", ").isEmpty ? "Unclassified segment" : item.classes.compactMap { key in value.classes.first { $0.id == key }?.title }.joined(separator: ", ") : item.title).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.4f–%.4f s", Double(item.start_frame) / Double(value.sample_rate), Double(item.end_frame) / Double(value.sample_rate))).monospacedDigit()
                    if let low = item.low_hz, let high = item.high_hz { Text("\(hz(low))–\(hz(high))") }
                }.font(.caption).tag(item.id)
            }
        }.frame(height: 105).accessibilityIdentifier("audio-annotation-segments")
    }
    @ViewBuilder private func inspector(_ analysis: NotebookAudioAnalysis, value: NotebookAudioAnnotations) -> some View {
        if let segment {
            VStack(alignment: .leading, spacing: 12) {
                Text("Selected segment").font(.headline)
                TextField("Label", text: textBinding(\.title, limit: 256))
                timeField("Start (s)", start: true, analysis: analysis)
                timeField("End (s)", start: false, analysis: analysis)
                Toggle("Frequency bounds", isOn: Binding(get: { self.segment?.low_hz != nil }, set: { enabled in editSegment { $0.low_hz = enabled ? viewport.low : nil; $0.high_hz = enabled ? viewport.high : nil } }))
                if segment.low_hz != nil {
                    frequencyField("Low (Hz)", low: true, rate: analysis.rate)
                    frequencyField("High (Hz)", low: false, rate: analysis.rate)
                }
                Divider()
                Text("Classes").font(.headline)
                if value.classes.isEmpty { Text("No allowed classes. Configure them in Board Designer.").font(.caption).foregroundStyle(NotebookPalette.muted) }
                ForEach(value.classes) { definition in
                    Toggle(definition.title, isOn: Binding(get: { self.segment?.classes.contains(definition.id) == true }, set: { enabled in editSegment { item in
                        item.classes.removeAll { $0 == definition.id }; item.attributes.removeValue(forKey: definition.id)
                        if enabled { item.classes.append(definition.id); item.attributes[definition.id] = Dictionary(uniqueKeysWithValues: definition.attributes.map { ($0.id, defaultValue($0)) }) }
                    } }))
                    if segment.classes.contains(definition.id) { ForEach(definition.attributes) { attribute in
                        NotebookAnnotationAttributeField(attribute: attribute, value: Binding(get: { self.segment?.attributes[definition.id]?[attribute.id] ?? defaultValue(attribute) }, set: { scalar in editSegment { $0.attributes[definition.id, default: [:]][attribute.id] = scalar } }), validity: { valid in
                            let key = definition.id + ":" + attribute.id
                            if valid { invalidCoordinates.remove(key) } else { invalidCoordinates.insert(key) }
                        }).id((selected ?? "") + definition.id + attribute.id)
                    } }
                }
                if binding.transcriptPolicy.segmentAllowed {
                    Divider(); Text(binding.transcriptPolicy.segmentRequired ? "Segment transcript *" : "Segment transcript").font(.headline)
                    TextEditor(text: textBinding(\.transcript, limit: 8192)).frame(height: 95).font(.body).accessibilityIdentifier("audio-segment-transcript")
                }
                Button("Delete segment", role: .destructive) { update { $0.segments.removeAll { $0.id == selected } }; selected = nil }
            }.textFieldStyle(.roundedBorder)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Draw a segment").font(.headline)
                Text(spectrum ? "Drag a rectangle across time and frequency. Select a region or list row to edit exact bounds, classes, attributes and transcript." : "Drag across the waveform to select a fragment. Zoom in for sample-accurate bounds; select a segment to edit its metadata.")
                Text("Frequency bounds annotate the region; playback previews its time range.").font(.caption).foregroundStyle(NotebookPalette.muted)
            }.font(.callout)
        }
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = error ?? player.error { Text(error).font(.caption).foregroundStyle(NotebookPalette.error).textSelection(.enabled) }
            if let policyError { Text(policyError).font(.caption).foregroundStyle(NotebookPalette.error) }
            if let accepted = binding.accepted, !accepted.matches(payload.data) { Text("Audio changed. Applying replaces the labels for the previous version.").font(.caption).foregroundStyle(NotebookPalette.sputnik) }
            HStack {
                Button("Export JSON…") { export() }
                Text("\(draft?.value.segments.count ?? 0) segments · \(dirty ? "Draft" : "Accepted") · Apply saves without Run").font(.caption).foregroundStyle(NotebookPalette.muted)
                Spacer(); Button("Discard", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("audio-annotations-discard")
                Button("Apply") { apply() }.buttonStyle(.borderedProminent).disabled(saving || binding.disabled || rendering || draft == nil || !invalidCoordinates.isEmpty || policyError != nil).keyboardShortcut(.defaultAction).accessibilityIdentifier("audio-annotations-apply")
            }
        }
    }
    private func timeField(_ title: String, start: Bool, analysis: NotebookAudioAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption)
            NotebookAnnotationNumberField(title: title, value: Binding<Double>(get: { Double(start ? segment?.start_frame ?? 0 : segment?.end_frame ?? 1) / Double(analysis.rate) }, set: { seconds in
                guard seconds.isFinite, seconds >= 0, seconds <= analysis.duration else { return }
                let frame = Int((seconds * Double(analysis.rate)).rounded())
                editSegment { item in if start { item.start_frame = max(0, min(item.end_frame - 1, frame)) } else { item.end_frame = min(analysis.frames, max(item.start_frame + 1, frame)) } }
            }), validity: { valid in if valid { invalidCoordinates.remove(title) } else { invalidCoordinates.insert(title) } })
                .id((selected ?? "") + title).accessibilityIdentifier(start ? "audio-start-seconds" : "audio-end-seconds")
        }
    }
    private func frequencyField(_ title: String, low: Bool, rate: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption)
            NotebookAnnotationNumberField(title: title, value: Binding<Double>(get: { low ? segment?.low_hz ?? 0 : segment?.high_hz ?? Double(rate)/2 }, set: { hz in
                guard hz.isFinite, hz >= 0, hz <= Double(rate)/2 else { return }
                editSegment { item in if low { if hz < (item.high_hz ?? Double(rate)/2) { item.low_hz = hz } } else if hz > (item.low_hz ?? 0) { item.high_hz = hz } }
            }), validity: { valid in if valid { invalidCoordinates.remove(title) } else { invalidCoordinates.insert(title) } })
                .id((selected ?? "") + title).accessibilityIdentifier(low ? "audio-low-hz" : "audio-high-hz")
        }
    }
    private func textBinding(_ key: WritableKeyPath<NotebookAudioAnnotations.Segment, String>, limit: Int) -> Binding<String> {
        Binding(get: { segment?[keyPath: key] ?? "" }, set: { value in guard value.utf8.count <= limit, !value.contains("\0") else { return }; editSegment { $0[keyPath: key] = value } })
    }
    private func defaultValue(_ attribute: NotebookAudioAnnotations.Attribute) -> NotebookTableValue {
        switch attribute.type { case "number": return .number(0); case "boolean": return .boolean(false); case "choice": return .text(attribute.options.first ?? ""); default: return .text("") }
    }
    private func editSegment(_ action: (inout NotebookAudioAnnotations.Segment) -> Void) { update { value in if let index = value.segments.firstIndex(where: { $0.id == selected }) { action(&value.segments[index]) } } }
    private func update(_ action: (inout NotebookAudioAnnotations) -> Void) { guard var value = draft?.value else { return }; action(&value); draft?.replace(value) }
    private func hz(_ value: Double) -> String { value >= 1000 ? String(format: "%.1f kHz", value / 1000) : String(format: "%.0f Hz", value) }
    private func prepare() async {
        spectrum = initialView == "spectrogram"; fft = fftSize
        let decode = Task.detached(priority: .userInitiated) { try NotebookAudioAnalysis.decode(payload) }
        do {
            let result = try await withTaskCancellationHandler(operation: { try await decode.value }, onCancel: { decode.cancel() })
            guard !Task.isCancelled else { return }
            analysis = result; viewport = .init(start: 0, end: result.frames, low: 0, high: Double(result.rate)/2)
            let accepted = binding.accepted.flatMap { $0.matches(payload.data) && $0.source == binding.source && $0.channel == binding.channel && $0.cell == binding.cell ? $0 : nil }
            var value = accepted ?? NotebookAudioAnnotations(asset: notebookAssetID(payload.data), source: binding.source, channel: binding.channel, cell: binding.cell, sample_rate: result.rate, channels: result.channels, frames: result.frames)
            value.classes = binding.classes ?? value.classes; value.normalizeClasses()
            if !binding.transcriptPolicy.trackAllowed { value.transcript = "" }
            if !binding.transcriptPolicy.segmentAllowed { for index in value.segments.indices { value.segments[index].transcript = "" } }
            draft = .init(value: value); wholeTranscriptOpen = binding.transcriptPolicy.trackRequired
            selected = draft?.value.segments.first?.id
            let panel = NotebookFigurePanel(mime: NotebookAudioPayload.mime, caption: "", width: 0, height: 0, data: NotebookAudioPayload.encode(payload.data, format: payload.format), id: nil)
            player.load(panel, waveform: false); rebuild()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    private func rebuild() {
        guard let analysis else { return }; renderTask?.cancel(); rendering = true
        let viewport = viewport, fft = fft, spectrum = spectrum, floorDB = floorDB, channel = audioChannel
        render = nil
        renderTask = Task {
            let worker = Task.detached(priority: .userInitiated) { try NotebookAudioRender.build(samples: analysis.channel(channel), rate: analysis.rate, viewport: viewport, fftSize: fft, spectral: spectrum, floorDB: floorDB) }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled else { return }; render = result; rendering = false
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription; rendering = false } }
        }
    }
    private func apply() {
        guard let value = draft?.value, policyError == nil, invalidCoordinates.isEmpty else { return }; saving = true; player.pause()
        binding.apply(value) { success in saving = false; if success { dismiss() } else { error = "Could not apply annotations. The audio version or binding may have changed; check the notebook error and reopen the current track." } }
    }
    private func export() {
        guard let value = draft?.value else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "audio-annotations.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(value).write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
    }
}

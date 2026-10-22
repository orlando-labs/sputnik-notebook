import SwiftUI

struct NotebookRangeControlView: View {
    @Binding var text: String
    var control = NotebookInputControl()
    @State private var draft = NotebookRangeValue()
    private var rules: NotebookRangeSliderRules? { try? NotebookRangeSliderRules(control: control, value: draft) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if NotebookRangeSliderRules.applies(control) {
                if let rules {
                    if control.style == "range_sliders" {
                        endpointSlider(start: true, rules: rules)
                        endpointSlider(start: false, rules: rules)
                    } else {
                        NotebookSharedRangeSlider(value: $draft, rules: rules)
                    }
                } else {
                    Text("Configure the allowed slider ranges in the inspector.").font(.caption).foregroundStyle(NotebookPalette.error)
                }
            } else {
                HStack {
                    TextField("Start", text: $draft.start).accessibilityLabel("Range start")
                    Text(draft.inclusive ? ".." : "...")
                    TextField("Finish", text: $draft.finish).accessibilityLabel("Range finish")
                }
            }
            ViewThatFits(in: .horizontal) {
                rangeOptions(showLabel: true).fixedSize(horizontal: true, vertical: false)
                rangeOptions(showLabel: false)
            }
        }.textFieldStyle(.roundedBorder)
            .onAppear { sync() }
            .onChange(of: draft) { _, value in text = value.expression }
            .onChange(of: text) { _, value in if value != draft.expression { sync() } }
    }
    private var upperBoundPicker: some View {
        Picker("Upper bound", selection: $draft.inclusive) {
            Text("Exclusive (...)").tag(false)
            Text("Inclusive (..)").tag(true)
        }.accessibilityLabel("Range upper bound")
    }
    private func rangeOptions(showLabel: Bool) -> some View {
        HStack(spacing: 12) {
            if showLabel { upperBoundPicker.fixedSize() }
            else { upperBoundPicker.labelsHidden().fixedSize() }
            HStack(spacing: 6) {
                Text("Step")
                TextField("Step", text: $draft.step).accessibilityLabel("Range step").frame(width: 64)
            }
        }
    }
    private func endpointSlider(start: Bool, rules: NotebookRangeSliderRules) -> some View {
        let domain = start ? rules.startDomain : rules.finishDomain
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(start ? "Start" : "Finish")
                Spacer()
                Text(start ? draft.start : draft.finish).monospacedDigit()
            }.font(.callout)
            Slider(value: Binding(get: {
                min(domain.upperBound, max(domain.lowerBound, Double(start ? draft.start : draft.finish) ?? domain.lowerBound))
            }, set: { draft = rules.moving(draft, start: start, to: $0) }), in: domain)
                .accessibilityLabel(start ? "Range start slider" : "Range finish slider")
            HStack { Text(domain.lowerBound.formatted()); Spacer(); Text(domain.upperBound.formatted()) }
                .font(.caption).foregroundStyle(NotebookPalette.muted)
        }
    }
    private func sync() { if let value = try? NotebookRangeValue.parse(text) { draft = value } }
}

private struct NotebookSharedRangeSlider: View {
    @Binding var value: NotebookRangeValue
    let rules: NotebookRangeSliderRules
    @State private var activeStart: Bool?
    @State private var release: Task<Void, Never>?
    private var domain: ClosedRange<Double> { rules.startDomain }
    private var start: Double { min(domain.upperBound, max(domain.lowerBound, Double(value.start) ?? domain.lowerBound)) }
    private var finish: Double { min(domain.upperBound, max(start, Double(value.finish) ?? domain.upperBound)) }
    var body: some View {
        VStack(spacing: 4) {
            HStack { Text("Start: \(value.start)"); Spacer(); Text("Finish: \(value.finish)") }.font(.callout).monospacedDigit()
            if #available(macOS 26.0, *) {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let track = max(1, width - 20)
                    let a = 10 + track * (start - domain.lowerBound) / (domain.upperBound - domain.lowerBound)
                    let b = 10 + track * (finish - domain.lowerBound) / (domain.upperBound - domain.lowerBound)
                    let midpoint = (a + b) / 2
                    // Keep the native glass thumb visible as it grows during
                    // tracking, including when both endpoints meet.
                    let seam = min(width, max(0, activeStart == true ? max(midpoint, a + 18) : activeStart == false ? min(midpoint, b - 18) : midpoint))
                    HStack(spacing: 0) {
                        endpoint(start: true)
                            .frame(width: width)
                            .padding(.vertical, 24)
                            .frame(width: seam, alignment: .leading)
                            .clipped().padding(.vertical, -24).contentShape(Rectangle())
                        endpoint(start: false)
                            .frame(width: width)
                            .padding(.vertical, 24)
                            .frame(width: width - seam, alignment: .trailing)
                            .clipped().padding(.vertical, -24).contentShape(Rectangle())
                    }
                }.frame(height: 20)
            } else {
                Slider(value: binding(start: true), in: domain).accessibilityLabel("Range start slider")
                Slider(value: binding(start: false), in: domain).accessibilityLabel("Range finish slider")
            }
            HStack { Text(domain.lowerBound.formatted()); Spacer(); Text(domain.upperBound.formatted()) }
                .font(.caption).foregroundStyle(NotebookPalette.muted)
        }.accessibilityIdentifier("range-shared-slider")
            .onDisappear { release?.cancel() }
    }
    private func binding(start: Bool) -> Binding<Double> {
        Binding(get: { start ? self.start : finish }, set: { value = rules.moving(value, start: start, to: $0) })
    }
    @available(macOS 26.0, *)
    private func endpoint(start: Bool) -> some View {
        Slider(value: binding(start: start), in: domain,
            neutralValue: start ? finish : self.start,
            enabledBounds: start ? domain.lowerBound...finish : self.start...domain.upperBound,
            label: { EmptyView() }, onEditingChanged: { editing in
                release?.cancel()
                if editing { activeStart = start }
                else {
                    release = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        if !Task.isCancelled { activeStart = nil }
                    }
                }
            })
            .accessibilityLabel(start ? "Range start slider" : "Range finish slider")
            .accessibilityIdentifier(start ? "range-shared-start" : "range-shared-finish")
    }
}

struct NotebookRangeInputView: View {
    @ObservedObject var model: NotebookModel
    let input: NotebookProjectInput
    var control = NotebookInputControl()
    var body: some View { NotebookBoardInputView(model: model, input: input, control: control) }
}

struct NotebookDateInputView: View {
    @ObservedObject var model: NotebookModel
    let input: NotebookProjectInput
    let mode: String, zone: String
    @State private var date = Date()
    @State private var edited = false
    private var supportedZone: Bool { TimeZone(identifier: zone) != nil }
    private var timeZone: TimeZone { TimeZone(identifier: zone) ?? TimeZone(secondsFromGMT: 0)! }
    private var dateFormatter: DateFormatter {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.calendar = Calendar(identifier: .gregorian)
        value.timeZone = timeZone; value.dateFormat = "yyyy-MM-dd"; return value
    }
    private var serialized: String { mode == "date" ? dateFormatter.string(from: date) : ISO8601DateFormatter().string(from: date) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker(input.title, selection: Binding(get: { date }, set: { date = $0; edited = true }), displayedComponents: mode == "date" ? [.date] : [.date, .hourAndMinute])
                .environment(\.timeZone, timeZone)
                .disabled(!supportedZone)
            if supportedZone {
                Text(mode == "date" ? "Calendar date · \(zone)" : "Display: \(zone) · stored as ISO 8601 UTC").font(.caption).foregroundStyle(NotebookPalette.muted)
            } else {
                Label("Unknown time zone: \(zone). Choose a valid zone in the designer.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(NotebookPalette.error)
            }
            HStack {
                Button("Apply") {
                    let value = String(decoding: try! JSONEncoder().encode(serialized), as: UTF8.self)
                    model.setProjectInputs([input.id: value]) { success in if success { edited = false } }
                }.disabled(!supportedZone || model.busy || model.remote.isSelected || (!edited && !input.editingText.isEmpty))
                Button("Reset draft", action: reset).disabled(model.busy)
                Text(input.editingText.isEmpty ? "No accepted date" : input.editingText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
        }.onAppear(perform: reset).onChange(of: input.value_json) { _, _ in reset() }
    }
    private func reset() {
        let parsed = mode == "date" ? dateFormatter.date(from: input.editingText) : ISO8601DateFormatter().date(from: input.editingText)
        date = parsed ?? Date(); edited = false
    }
}

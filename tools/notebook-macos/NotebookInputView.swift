import SwiftUI

enum NotebookInputEditing {
    static func minimum(_ input: NotebookProjectInput, _ control: NotebookInputControl) -> Double? {
        [input.minimum, control.minimum].compactMap { $0 }.max()
    }
    static func maximum(_ input: NotebookProjectInput, _ control: NotebookInputControl) -> Double? {
        [input.maximum, control.maximum].compactMap { $0 }.min()
    }
    static func error(_ text: String, input: NotebookProjectInput, control: NotebookInputControl) -> String? {
        if input.type == "range" {
            do {
                let value = try NotebookRangeValue.parse(text)
                if NotebookRangeSliderRules.applies(control) {
                    let rules = try NotebookRangeSliderRules(control: control, value: value)
                    if let error = rules.error(value) { return error }
                }
            } catch { return error.localizedDescription }
        } else if input.type == "string" {
            if text.utf8.count > 65536 || text.utf8.contains(0) { return "Text must fit 64 KiB and contain no NUL." }
            if control.style == "json", let error = NotebookConfigJSON.error(text, format: control.configFormat) { return error }
        } else if input.type == "boolean" {
            if text != "true" && text != "false" { return "Choose true or false." }
        } else {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if input.type == "integer" && Int64(clean) == nil { return "Enter a whole number in the Int64 range." }
            guard let number = Double(clean), number.isFinite else { return "Enter a finite number." }
            if let minimum = minimum(input, control), below(clean, bound: minimum, integer: input.type == "integer") { return "Minimum: \(minimum.formatted())." }
            if let maximum = maximum(input, control), above(clean, bound: maximum, integer: input.type == "integer") { return "Maximum: \(maximum.formatted())." }
        }
        if ["select", "segmented", "radio"].contains(control.style) {
            let values = (control.options ?? []).compactMap { optionText($0, type: input.type) }
            if !values.contains(text) { return "Choose one of the available options." }
        }
        return nil
    }
    private static func below(_ text: String, bound: Double, integer: Bool) -> Bool {
        if integer, let value = Decimal(string: text), let limit = Decimal(string: String(bound)) { return value < limit }
        return (Double(text) ?? .infinity) < bound
    }
    private static func above(_ text: String, bound: Double, integer: Bool) -> Bool {
        if integer, let value = Decimal(string: text), let limit = Decimal(string: String(bound)) { return value > limit }
        return (Double(text) ?? .infinity) > bound
    }
    static func optionText(_ option: NotebookInputOption, type: String) -> String? {
        if type == "string" { return try? JSONDecoder().decode(String.self, from: Data(option.value_json.utf8)) }
        if type == "integer", let value = try? JSONDecoder().decode(Int64.self, from: Data(option.value_json.utf8)) { return String(value) }
        return nil
    }
    static func stepped(_ text: String, by direction: Int, input: NotebookProjectInput, control: NotebookInputControl) -> String? {
        let result: String
        if input.type == "integer" {
            guard let current = Int64(text), let step = Int64(exactly: control.step ?? 1) else { return nil }
            let (next, overflow) = direction > 0 ? current.addingReportingOverflow(step) : current.subtractingReportingOverflow(step)
            guard !overflow else { return nil }
            result = String(next)
        } else {
            guard let current = Double(text) else { return nil }
            let next = current + Double(direction) * (control.step ?? 1)
            guard next.isFinite else { return nil }
            result = String(next)
        }
        return error(result, input: input, control: control) == nil ? result : nil
    }
    static func display(_ text: String, input: NotebookProjectInput, control: NotebookInputControl) -> String {
        // Integers retain exact spelling; Double formatting is only for display.
        if input.type == "number", let number = Double(text), let precision = control.precision {
            return number.formatted(.number.precision(.fractionLength(precision)))
        }
        return text
    }
}

/// Editing changes only the binding. Its host decides when to publish: a
/// standalone control commits an explicit action, a form commits the full batch.
struct NotebookInputControlView: View {
    let input: NotebookProjectInput
    let control: NotebookInputControl
    @Binding var text: String
    var commit: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if input.type == "string" && control.style == "json" {
                NotebookConfigEditor(text: $text, title: input.title, format: control.configFormat)
            } else if input.type == "range" {
                NotebookRangeControlView(text: $text, control: control)
            } else if input.type == "boolean" {
                Toggle(input.title, isOn: Binding(get: { text == "true" }, set: { text = $0 ? "true" : "false"; commit() }))
            } else if ["select", "segmented"].contains(control.style) {
                if control.style == "segmented" { choices.pickerStyle(.segmented) }
                else { choices.pickerStyle(.menu) }
            } else if control.style == "radio" {
                choices.pickerStyle(.radioGroup)
            } else if control.style == "slider", let minimum = NotebookInputEditing.minimum(input, control),
                      let maximum = NotebookInputEditing.maximum(input, control), minimum < maximum {
                Slider(value: Binding(get: { min(maximum, max(minimum, Double(text) ?? minimum)) },
                    set: { text = input.type == "integer" ? String(Int64($0.rounded())) : String($0) }),
                    in: minimum...maximum, step: control.step ?? (input.type == "integer" ? 1 : (maximum - minimum) / 100),
                    onEditingChanged: { editing in if !editing { commit() } })
                    .accessibilityLabel(input.title)
                Text(NotebookInputEditing.display(text, input: input, control: control) + (control.unit.map { " \($0)" } ?? ""))
                    .font(.system(.callout, design: .monospaced))
            } else {
                HStack {
                    TextField(input.title, text: $text).textFieldStyle(.roundedBorder).onSubmit(commit)
                        .accessibilityLabel(input.title)
                    if control.style == "stepper" {
                        Button { step(-1) } label: { Image(systemName: "minus") }
                            .disabled(NotebookInputEditing.stepped(text, by: -1, input: input, control: control) == nil)
                            .accessibilityLabel("Decrease \(input.title)")
                        Button { step(1) } label: { Image(systemName: "plus") }
                            .disabled(NotebookInputEditing.stepped(text, by: 1, input: input, control: control) == nil)
                            .accessibilityLabel("Increase \(input.title)")
                    }
                    if let unit = control.unit, !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(NotebookPalette.muted) }
                }
            }
        }
        .tint(NotebookPalette.categoryControls)
    }
    private var choices: some View {
        Picker(input.title, selection: Binding(get: { text }, set: { text = $0; commit() })) {
            if !(control.options ?? []).contains(where: { NotebookInputEditing.optionText($0, type: input.type) == text }) {
                Text("Choose…").tag(text)
            }
            ForEach(control.options ?? []) { option in
                if let value = NotebookInputEditing.optionText(option, type: input.type) { Text(option.label).tag(value) }
            }
        }.labelsHidden().accessibilityLabel(input.title)
    }
    private func step(_ direction: Int) {
        if let value = NotebookInputEditing.stepped(text, by: direction, input: input, control: control) { text = value; commit() }
    }
}

struct NotebookBoardInputView: View {
    @ObservedObject var model: NotebookModel
    let input: NotebookProjectInput
    var control = NotebookInputControl()
    var onCommit: ((String, @escaping (Bool) -> Void) -> Void)? = nil
    @State private var draft = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if control.style == "json" {
                NotebookConfigEditor(text: $draft, title: input.title, format: control.configFormat, onApply: applyConfig)
            } else {
                NotebookInputControlView(input: input, control: control, text: $draft, commit: submit)
            }
            if input.type != "boolean" && control.style != "json" {
                HStack {
                    Text("Current: \(NotebookInputEditing.display(input.editingText, input: input, control: control))").font(.caption).foregroundStyle(NotebookPalette.muted)
                    Spacer()
                    Button("Apply", action: submit).disabled(draft == input.editingText || NotebookInputEditing.error(draft, input: input, control: control) != nil)
                        .accessibilityIdentifier("input-apply")
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(NotebookPalette.error) }
            else if input.type == "range", let message = NotebookInputEditing.error(draft, input: input, control: control) {
                Text(message).font(.caption).foregroundStyle(NotebookPalette.error)
            }
        }
        .onAppear { draft = input.editingText }
        .onChange(of: input.value_json) { draft = input.editingText; error = nil }
        .disabled(model.busy)
    }
    private func submit() {
        error = NotebookInputEditing.error(draft, input: input, control: control)
        if error == nil && draft != input.editingText {
            if let onCommit { onCommit(draft) { success in if !success { error = model.error } } }
            else { model.setProjectInput(input, text: draft) }
        }
    }
    private func applyConfig(_ text: String, completed: @escaping (String?) -> Void) {
        do {
            if let error = NotebookInputEditing.error(text, input: input, control: control) { completed(error); return }
            let value = try NotebookProjectInput.valueJSON(text, type: input.type)
            let finish: (Bool) -> Void = { success in completed(success ? nil : model.error ?? "Could not apply config.") }
            if let onCommit { onCommit(text, finish) }
            else { model.setProjectInputs([input.id: value], completion: finish) }
        } catch { completed(error.localizedDescription) }
    }
}

struct NotebookParameterFormView: View {
    @ObservedObject var model: NotebookModel
    let fields: [NotebookFormField]
    var height: CGFloat? = nil
    var localInputs: [NotebookProjectInput]? = nil
    var onApply: (([String: String], @escaping (Bool) -> Void) -> Void)? = nil
    @State private var drafts: [String: String] = [:]
    @State private var submissionError: String?
    private var inputs: [NotebookProjectInput] { localInputs ?? model.snapshot?.inputs ?? [] }
    private var pending: Bool { fields.contains { field in input(field).map { (drafts[field.id] ?? $0.editingText) != $0.editingText } ?? false } }
    private var valid: Bool { fields.allSatisfy { field in input(field).map { NotebookInputEditing.error(drafts[field.id] ?? $0.editingText, input: $0, control: field.control) == nil } ?? false } }
    var body: some View {
        if let height { ScrollView { content }.frame(height: height) }
        else { content }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if fields.isEmpty { Text("Add project parameters in the designer.").foregroundStyle(NotebookPalette.muted) }
            ForEach(fields) { field in
                if let input = input(field) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(input.title).font(.callout.weight(.medium))
                        NotebookInputControlView(input: input, control: field.control,
                            text: Binding(get: { drafts[field.id] ?? input.editingText }, set: { drafts[field.id] = $0; submissionError = nil }))
                        if field.control.style != "json", let error = NotebookInputEditing.error(drafts[field.id] ?? input.editingText, input: input, control: field.control) {
                            Text(error).font(.caption).foregroundStyle(NotebookPalette.error)
                        }
                    }
                } else { Text("Parameter unavailable").foregroundStyle(NotebookPalette.error) }
            }
            if let submissionError { Text(submissionError).font(.caption).foregroundStyle(NotebookPalette.error) }
            HStack {
                Button("Reset to current") { drafts = [:]; submissionError = nil }
                Button("Defaults") { for field in fields { if let input = input(field), let value = input.default_json {
                    drafts[field.id] = input.type == "string" ? ((try? JSONDecoder().decode(String.self, from: Data(value.utf8))) ?? "") : value
                } } }
                Spacer()
                Button("Apply", action: apply).buttonStyle(.borderedProminent).tint(NotebookPalette.categoryControls)
                    .disabled(!pending || !valid).accessibilityIdentifier("board-form-apply")
            }.controlSize(.small)
        }.disabled(model.busy)
    }
    private func input(_ field: NotebookFormField) -> NotebookProjectInput? { inputs.first { $0.id == field.input } }
    private func apply() {
        do {
            var values: [String: String] = [:]
            for field in fields { if let input = input(field) {
                let text = drafts[field.id] ?? input.editingText
                guard NotebookInputEditing.error(text, input: input, control: field.control) == nil else { return }
                values[input.id] = try NotebookProjectInput.valueJSON(text, type: input.type)
            } }
            let completed: (Bool) -> Void = { success in
                if success { drafts = [:]; submissionError = nil }
                else { submissionError = model.error }
            }
            if let onApply { onApply(values, completed) }
            else { model.setProjectInputs(values, completion: completed) }
        } catch { submissionError = error.localizedDescription }
    }
}

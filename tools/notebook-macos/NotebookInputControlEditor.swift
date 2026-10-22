import SwiftUI

struct NotebookInputControlEditor: View {
    let input: NotebookProjectInput
    @Binding var control: NotebookInputControl
    private var numeric: Bool { input.type == "number" || input.type == "integer" }
    private var choice: Bool { ["select", "segmented", "radio"].contains(control.style) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Value type", value: NotebookProjectInput.typeTitle(input.type))
                .font(.caption).foregroundStyle(NotebookPalette.muted)
            NotebookPlotField(title: "Control") {
                Picker("Control", selection: $control.style) {
                    Text(input.type == "string" ? "String field" : input.type == "boolean" ? "Boolean toggle" : "Automatic").tag("automatic")
                    if input.type == "string" { Text("Config Editor").tag("json") }
                    if numeric {
                        Text(input.type == "integer" ? "Integer field" : "Number field").tag("number"); Text("Slider").tag("slider"); Text("Stepper").tag("stepper")
                    }
                    if input.type == "range" {
                        Text("Range slider · shared bounds").tag("slider")
                        Text("Two sliders · separate bounds").tag("range_sliders")
                    }
                    if input.type == "string" || input.type == "integer" {
                        Text("Select").tag("select"); Text("Segmented").tag("segmented"); Text("Radio").tag("radio")
                    }
                }.labelsHidden()
                .onChange(of: control.style) {
                    if choice && control.options?.isEmpty != false {
                        control.options = [NotebookInputOption(label: input.editingText, value_json: input.value_json)]
                    }
                    if control.style == "slider" {
                        if input.type == "range" { initializeRangeBounds() }
                        else {
                            if NotebookInputEditing.minimum(input, control) == nil { control.minimum = min(0, Double(input.editingText) ?? 0) }
                            if NotebookInputEditing.maximum(input, control) == nil { control.maximum = max(100, Double(input.editingText) ?? 100) }
                        }
                    }
                    if control.style == "range_sliders" { initializeRangeBounds() }
                }
            }
            if control.style == "json" {
                NotebookConfigSettings(format: $control.config_format)
            }
            if input.type == "range" && NotebookRangeSliderRules.applies(control) {
                if control.style == "slider" {
                    NotebookPlotField(title: "Minimum") { TextField("Required", value: $control.minimum, format: .number).accessibilityLabel("Range slider minimum") }
                    NotebookPlotField(title: "Maximum") { TextField("Required", value: $control.maximum, format: .number).accessibilityLabel("Range slider maximum") }
                } else {
                    NotebookPlotField(title: "Start minimum") { TextField("Required", value: $control.start_minimum, format: .number).accessibilityLabel("Range start minimum") }
                    NotebookPlotField(title: "Start maximum") { TextField("Required", value: $control.start_maximum, format: .number).accessibilityLabel("Range start maximum") }
                    NotebookPlotField(title: "Finish minimum") { TextField("Required", value: $control.finish_minimum, format: .number).accessibilityLabel("Range finish minimum") }
                    NotebookPlotField(title: "Finish maximum") { TextField("Required", value: $control.finish_maximum, format: .number).accessibilityLabel("Range finish maximum") }
                }
                NotebookPlotField(title: "Slider increment") { TextField("Automatic", value: $control.step, format: .number) }
                Text("Finish stays greater than or equal to start. Slider increment controls dragging; Step in the value controls Range iteration.")
                    .font(.caption).foregroundStyle(NotebookPalette.muted)
                if let error = NotebookInputEditing.error(input.editingText, input: input, control: control) {
                    Text(error).font(.caption).foregroundStyle(NotebookPalette.error)
                }
            }
            if numeric && !choice {
                NotebookPlotField(title: "Minimum") { TextField("Project bound", value: $control.minimum, format: .number) }
                NotebookPlotField(title: "Maximum") { TextField("Project bound", value: $control.maximum, format: .number) }
                NotebookPlotField(title: "Step") { TextField("1", value: $control.step, format: .number) }
                NotebookPlotField(title: "Unit") { TextField("Optional", text: Binding(get: { control.unit ?? "" }, set: { control.unit = $0 })) }
                if input.type == "number" {
                    NotebookPlotField(title: "Display precision") {
                        Picker("Display precision", selection: Binding(get: { control.precision ?? -1 }, set: { control.precision = $0 < 0 ? nil : $0 })) {
                            Text("Automatic").tag(-1)
                            ForEach(0...12, id: \.self) { Text(String($0)).tag($0) }
                        }.labelsHidden()
                    }
                }
            }
            if choice {
                Text("Options").font(.caption.weight(.semibold))
                ForEach(Array((control.options ?? []).indices), id: \.self) { index in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Label", text: Binding(get: { option(index).label }, set: { value in
                                if control.options?.indices.contains(index) == true { control.options?[index].label = value }
                            }))
                            Button(role: .destructive) { control.options?.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        }
                        TextField("Value", text: Binding(get: {
                            NotebookInputEditing.optionText(option(index), type: input.type) ?? option(index).value_json
                        }, set: { value in
                            guard let json = try? NotebookProjectInput.valueJSON(value, type: input.type), control.options?.indices.contains(index) == true else { return }
                            control.options?[index].value_json = json
                        }))
                    }
                }
                Button("Add Option", systemImage: "plus") {
                    let count = (control.options?.count ?? 0) + 1
                    let text = input.type == "integer" ? String(count) : "Option \(count)"
                    let json = (try? NotebookProjectInput.valueJSON(text, type: input.type)) ?? "0"
                    if control.options == nil { control.options = [] }
                    control.options?.append(NotebookInputOption(label: "Option \(count)", value_json: json))
                }.disabled((control.options?.count ?? 0) >= 256)
            }
        }.textFieldStyle(.roundedBorder).controlSize(.small)
    }
    private func initializeRangeBounds() {
        let range = try? NotebookRangeValue.parse(input.editingText)
        let start = range.flatMap { Double($0.start) } ?? 0
        let finish = range.flatMap { Double($0.finish) } ?? 15
        let low = min(0, start, finish), high = max(100, start, finish)
        if control.style == "slider" {
            if control.minimum == nil { control.minimum = low }
            if control.maximum == nil { control.maximum = high }
        } else {
            if control.start_minimum == nil { control.start_minimum = control.minimum ?? low }
            if control.start_maximum == nil { control.start_maximum = control.maximum ?? high }
            if control.finish_minimum == nil { control.finish_minimum = control.minimum ?? low }
            if control.finish_maximum == nil { control.finish_maximum = control.maximum ?? high }
        }
    }
    private func option(_ index: Int) -> NotebookInputOption {
        guard control.options?.indices.contains(index) == true else { return NotebookInputOption(label: "", value_json: "") }
        return control.options![index]
    }
}

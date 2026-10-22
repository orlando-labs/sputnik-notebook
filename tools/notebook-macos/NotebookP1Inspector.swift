import SwiftUI

struct NotebookP1Inspector: View {
    @ObservedObject var model: NotebookModel
    let board: NotebookBoard
    @Binding var item: NotebookBoardComponent
    private var settings: Binding<NotebookP1Settings> { Binding(get: { item.settings }, set: { item.p1 = $0 }) }
    private var inputs: [NotebookProjectInput] { model.snapshot?.inputs ?? [] }
    private var cells: [NotebookCell] { model.controller(for: board)?.cells.filter { $0.kind == "code" } ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch item.kind {
            case "metric": metric
            case "status", "execution_controls": target
            case "file_input":
                NotebookProjectInputPicker(model: model, allowedTypes: ["string"],
                    selection: Binding(get: { item.input ?? "" }, set: { item.input = $0 }))
                field("Allowed extensions (comma separated)", value: settings.extensions)
                Text("Selection publishes an external file path through the String parameter. CSV and JSON previews are bounded; code reads the file explicitly.").font(.caption).foregroundStyle(NotebookPalette.muted)
            case "action": action
            case "parameter_presets": presets
            case "group":
                Toggle("Initially collapsed", isOn: Binding(get: { item.settings.collapsed ?? false }, set: { settings.wrappedValue.collapsed = $0 }))
                Text("Open Edit Grid to arrange the group's contents. Expanding or collapsing never runs code.").font(.caption).foregroundStyle(NotebookPalette.muted)
            case "live_chart": series
            default: EmptyView()
            }
        }.textFieldStyle(.roundedBorder)
    }
    private var metric: some View {
        VStack(alignment: .leading, spacing: 12) {
            NotebookPlotField(title: "Numeric value") {
                Picker("Numeric value", selection: Binding(get: { item.binding ?? "" }, set: { item.binding = $0 })) {
                    Text("Cell result").tag("")
                    if let cell = cells.first(where: { $0.id == item.cell }) {
                        ForEach(cell.locals.filter { $0.role == "module_cell" && Double($0.text_value ?? $0.value) != nil }, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    if let binding = item.binding, !binding.isEmpty,
                       !cells.flatMap(\.locals).contains(where: { $0.name == binding }) { Text(binding + " · unavailable").tag(binding) }
                }.labelsHidden()
            }
            field("Variable name (optional)", value: $item.binding)
            field("Unit", value: settings.unit)
            Toggle("Percentage (value × 100)", isOn: Binding(get: { item.settings.percentage ?? false }, set: { settings.wrappedValue.percentage = $0 }))
            NotebookPlotField(title: "Decimal places (empty = automatic)") { TextField("Automatic", value: settings.precision, format: .number) }
            NotebookPlotField(title: "Target (optional)") { TextField("None", value: settings.target, format: .number) }
            NotebookPlotField(title: "Delta baseline (optional)") { TextField("None", value: settings.baseline, format: .number) }
            Picker("Improvement", selection: Binding(get: { item.settings.improvement ?? "neutral" }, set: { settings.wrappedValue.improvement = $0 })) {
                Text("Neutral").tag("neutral"); Text("Higher is better").tag("higher"); Text("Lower is better").tag("lower")
            }
        }
    }
    private var target: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Execution target", selection: Binding(get: { item.settings.target_kind ?? "sheet" }, set: { settings.wrappedValue.target_kind = $0 })) {
                Text("Controller sheet").tag("sheet"); Text("Cell").tag("cell"); Text("Service").tag("service"); Text("Action").tag("action"); if item.kind == "status" { Text("Runtime / connection").tag("runtime") }
            }
            if item.settings.target_kind == "cell" {
                Picker("Cell", selection: Binding(get: { item.cell ?? "" }, set: { item.cell = $0 })) {
                    Text("Choose…").tag("")
                    ForEach(cells) { Text(model.controller(for: board)?.cellLabel(for: $0.id) ?? "Cell").tag($0.id) }
                }
            } else if ["service", "action"].contains(item.settings.target_kind ?? "") {
                Picker("Target", selection: Binding(get: { item.settings.target_component ?? "" }, set: { settings.wrappedValue.target_component = $0 })) {
                    Text("Choose…").tag("")
                    ForEach(board.allComponents.filter { item.settings.target_kind == "service" ? $0.isService : $0.kind == "action" }) { Text($0.title).tag($0.id) }
                }
            }
        }
    }
    private var action: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Module", selection: Binding(get: { item.module_id ?? "" }, set: { item.module_id = $0 })) {
                Text("Choose module…").tag("")
                ForEach(model.snapshot?.tabs.filter { $0.kind == "module" } ?? []) { Text($0.title).tag(String($0.id.dropFirst(7))) }
            }
            field("Exported function", value: $item.function)
            if !exports.isEmpty {
                Menu("Exported names") { ForEach(exports, id: \.self) { name in Button(name) { item.function = name } } }
            }
            Text("Arguments are frozen from accepted inputs and scalar constants when Run is pressed. Positional arguments precede named arguments.").font(.caption).foregroundStyle(NotebookPalette.muted)
            ForEach(Array((item.settings.arguments ?? []).enumerated()), id: \.element.id) { index, arg in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Argument \(index + 1)").font(.caption.bold())
                    TextField("Name (empty = positional)", text: argument(arg).name.orEmpty)
                    Picker("Value", selection: Binding(get: { arg.input == nil ? "constant" : "input" }, set: { value in
                        var v = argument(arg).wrappedValue
                        v.input = value == "input" ? inputs.first?.id ?? "" : nil
                        v.value_json = value == "constant" ? "0" : nil; argument(arg).wrappedValue = v
                    })) { Text("Input").tag("input"); Text("Scalar JSON").tag("constant") }
                    if arg.input != nil {
                        Picker("Input", selection: argument(arg).input.orEmpty) { ForEach(inputs) { Text($0.title).tag($0.id) } }
                    } else { TextField("Scalar JSON", text: argument(arg).value_json.orEmpty) }
                    HStack {
                        Button("Up") { settings.wrappedValue.arguments?.swapAt(index, index - 1) }.disabled(index == 0)
                        Button("Remove", role: .destructive) { settings.wrappedValue.arguments?.removeAll { $0.id == arg.id } }
                    }.controlSize(.small)
                }.padding(8).background(NotebookPalette.canvas, in: RoundedRectangle(cornerRadius: 5))
            }
            Button("Add argument") {
                if settings.wrappedValue.arguments == nil { settings.wrappedValue.arguments = [] }
                settings.wrappedValue.arguments?.append(.init(id: NotebookBoard.newID("arg"), value_json: "0"))
            }.disabled((item.settings.arguments?.count ?? 0) >= 64)
        }
    }
    private var presets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capture, rename, import and apply named sets on the running board. Presets are saved in this project.").font(.caption).foregroundStyle(NotebookPalette.muted)
            Toggle("Include all parameters", isOn: Binding(get: { item.settings.preset_inputs?.isEmpty != false }, set: { settings.wrappedValue.preset_inputs = $0 ? nil : inputs.prefix(1).map(\.id) }))
            if item.settings.preset_inputs?.isEmpty == false {
                ForEach(inputs) { input in
                    Toggle(input.title, isOn: Binding(get: { item.settings.preset_inputs?.contains(input.id) == true }, set: { selected in
                        var ids = item.settings.preset_inputs ?? []; if selected { ids.append(input.id) } else { ids.removeAll { $0 == input.id } }; settings.wrappedValue.preset_inputs = ids
                    }))
                }
            }
            Text("\(item.settings.presets?.count ?? 0) saved sets · saved defaults stay separate").font(.caption).foregroundStyle(NotebookPalette.muted)
        }
    }
    private var series: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Series use separate publish_point channels with shared axes and independent history limits.").font(.caption).foregroundStyle(NotebookPalette.muted)
            ForEach(item.settings.series ?? []) { series in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Channel", text: seriesBinding(series).id)
                    TextField("Legend title", text: seriesBinding(series).title)
                    TextField("Color #rrggbb", text: seriesBinding(series).stroke)
                    Button("Remove series", role: .destructive) { settings.wrappedValue.series?.removeAll { $0.id == series.id } }.controlSize(.small)
                }
            }
            Button("Add series") {
                if settings.wrappedValue.series == nil { settings.wrappedValue.series = [] }
                let count = item.settings.series?.count ?? 0
                let colors = ["#86505f", "#87512c", "#75516d", "#54594d"]
                settings.wrappedValue.series?.append(.init(id: "series_\(count + 1)", title: "Series \(count + 1)", stroke: colors[count % colors.count]))
            }.disabled((item.settings.series?.count ?? 0) >= 16)
        }
    }
    private var exports: [String] {
        guard let tab = model.snapshot?.tabs.first(where: { $0.id == "module:" + (item.module_id ?? "") }) else { return [] }
        return tab.cells.flatMap { $0.source.components(separatedBy: .newlines) }.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("export ") }
            .flatMap { $0.trimmingCharacters(in: .whitespaces).dropFirst(7).split { $0 == "," || $0.isWhitespace }.map(String.init) }
            .filter { $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil }
    }
    private func field(_ title: String, value: Binding<String?>) -> some View { NotebookPlotField(title: title) { TextField(title, text: value.orEmpty) } }
    private func argument(_ argument: NotebookActionArgument) -> Binding<NotebookActionArgument> {
        Binding(get: { item.settings.arguments?.first { $0.id == argument.id } ?? argument }, set: { value in if let i = item.settings.arguments?.firstIndex(where: { $0.id == argument.id }) { settings.wrappedValue.arguments?[i] = value } })
    }
    private func seriesBinding(_ series: NotebookChartSeries) -> Binding<NotebookChartSeries> {
        Binding(get: { item.settings.series?.first { $0.id == series.id } ?? series }, set: { value in if let i = item.settings.series?.firstIndex(where: { $0.id == series.id }) { settings.wrappedValue.series?[i] = value } })
    }
}
private extension Binding where Value == String? {
    var orEmpty: Binding<String> { Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0.isEmpty ? nil : $0 }) }
}

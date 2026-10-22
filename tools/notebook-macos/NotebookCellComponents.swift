import SwiftUI

struct NotebookCellComponentsView: View {
    @ObservedObject var model: NotebookModel
    let cell: NotebookCell
    let tab: NotebookTab
    let components: [NotebookBoardComponent]
    private var running: Bool { model.executingCells[tab.id] == cell.id }
    private var inputsDisabled: Bool {
        model.remote.isSelected && (!model.remote.connected || model.remote.busy ||
            model.remote.runs.contains { $0.active && "sheet:" + $0.sheet == tab.id })
    }
    var body: some View {
        ForEach(components) { component in
            VStack(alignment: .leading, spacing: 10) {
                if component.kind != "live_chart" { Text(component.title).font(.headline) }
                content(component)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NotebookPalette.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("cell-component-\(cell.id)-\(component.id)")
        }
    }
    @ViewBuilder private func content(_ component: NotebookBoardComponent) -> some View {
        switch component.kind {
        case "input":
            if let input = cell.cell_inputs?.first(where: { $0.id == component.input }) {
                NotebookBoardInputView(model: model, input: input, control: component.control ?? NotebookInputControl(), onCommit: { text, completed in
                    do {
                        let value = try NotebookProjectInput.valueJSON(text, type: input.type)
                        model.setCellInputs([input.id: value], cell: cell, tab: tab, completion: completed)
                    } catch { model.error = error.localizedDescription; completed(false) }
                }).disabled(inputsDisabled)
            } else { waiting("Local parameter unavailable") }
        case "parameter_form":
            NotebookParameterFormView(model: model, fields: component.fields ?? [], localInputs: cell.cell_inputs ?? [],
                onApply: { values, completed in model.setCellInputs(values, cell: cell, tab: tab, completion: completed) }).disabled(inputsDisabled)
        case "audio":
            NotebookCellDisplay(model: model, cell: cell, tab: tab, kind: .audio,
                audioID: component.audio_id ?? "", showWaveform: component.show_waveform, showEmpty: true)
        case "table":
            NotebookCellDisplay(model: model, cell: cell, tab: tab, kind: .table,
                                tableID: component.table_id ?? "", showEmpty: true)
        case "metric":
            NotebookMetricView(model: model, component: component, tab: tab, cell: cell)
        case "live_chart":
            if component.settings.series?.isEmpty == false {
                NotebookMultiSeriesView(model: model, component: component, tab: tab, sourceCell: cell)
            } else {
                let channel = component.chart_id ?? component.id
                NotebookLiveChartView(chart: model.cellChart(channel, cell: cell, tab: tab) ??
                    NotebookLiveChart(id: channel, points: [], total_points: 0, replace_chart: true),
                    title: component.title, caption: component.caption ?? "",
                    xLabel: component.x_label ?? "X", yLabel: component.y_label ?? "Y", stroke: component.stroke ?? "#86505f",
                    yMin: component.y_min, yMax: component.y_max, xMin: component.x_min, xMax: component.x_max,
                    running: running).equatable()
            }
            staleLabel
        case "image":
            let channel = component.image_id ?? component.id
            NotebookImageView(series: model.cellImages(channel, cell: cell, tab: tab) ??
                NotebookImageSeries(id: channel, caption: "", images: []), carousel: false,
                mode: component.image_mode ?? "fit", caption: component.caption ?? "",
                allowSave: component.image_allow_save ?? true)
            staleLabel
        default: waiting("Component unavailable")
        }
    }
    @ViewBuilder private var staleLabel: some View {
        if !running && model.figureIsStale(for: cell, in: tab) {
            Label("Previous data · stale", systemImage: "clock").font(.caption).foregroundStyle(NotebookPalette.sputnik)
        }
    }
    private func waiting(_ message: String) -> some View {
        Label(message, systemImage: "clock").font(.callout).foregroundStyle(NotebookPalette.muted)
    }
}

private struct NotebookCellEditorItem: Identifiable {
    var component: NotebookBoardComponent
    var after: Bool
    var id: String { component.id }
}

struct NotebookCellComponentEditor: View {
    @ObservedObject var model: NotebookModel
    let cell: NotebookCell
    let tab: NotebookTab
    @Environment(\.dismiss) private var dismiss
    @State private var parameters: [NotebookCellInputDefinition]
    @State private var items: [NotebookCellEditorItem]
    @State private var selected: String?
    @State private var error: String?
    private let document: UUID
    init(model: NotebookModel, cell: NotebookCell, tab: NotebookTab) {
        self.model = model; self.cell = cell; self.tab = tab; document = model.documentIdentity
        let ui = cell.cell_ui ?? NotebookCellUI()
        _parameters = State(initialValue: ui.inputs)
        _selected = State(initialValue: ui.pre.first?.id ?? ui.post.first?.id)
        _items = State(initialValue: ui.pre.map { .init(component: $0, after: false) } + ui.post.map { .init(component: $0, after: true) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Components · \(tab.cellLabel(for: cell.id))").font(.title2.bold())
            Text("Local parameters are read with notebook.cell_input(\"name\"). Add a component below the code to enable collapsing.")
                .font(.callout).foregroundStyle(NotebookPalette.muted)
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack { Text("Local parameters").font(.headline); Spacer(); Button("Add", systemImage: "plus", action: addParameter) }
                        ForEach(parameters.indices, id: \.self) { index in parameterEditor(index) }
                    }.padding(8)
                }.frame(minWidth: 270, idealWidth: 300, maxHeight: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Components").font(.headline)
                        Spacer()
                        Menu("Add component", systemImage: "plus") {
                            ForEach(NotebookCellUI.paletteKinds, id: \.self) { kind in
                                Button(NotebookComponentTool.tool(kind).title) { addComponent(kind) }
                            }
                        }
                    }
                    List(selection: $selected) {
                        ForEach(items) { item in
                            Label("\(item.after ? "Post-cell" : "Pre-cell") · \(item.component.title)",
                                  systemImage: NotebookComponentTool.tool(for: item.component).symbol).tag(item.id)
                        }
                    }.frame(height: 170)
                    if let index = items.firstIndex(where: { $0.id == selected }) {
                        ScrollView { componentEditor(index).padding(6) }
                        HStack {
                            Button("Move up", systemImage: "arrow.up") { items.swapAt(index, index - 1) }.disabled(index == 0)
                            Button("Move down", systemImage: "arrow.down") { items.swapAt(index, index + 1) }.disabled(index == items.count - 1)
                            Spacer()
                            Button("Remove", role: .destructive) { items.remove(at: index); selected = nil }
                        }
                    } else {
                        ContentUnavailableView("Select a component", systemImage: "square.grid.2x2")
                    }
                }.padding(8).frame(minWidth: 380, maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxHeight: .infinity)
            if let error { Text(error).foregroundStyle(NotebookPalette.error).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Components", action: save).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("save-cell-components")
            }
        }
        .padding(22).frame(width: 850, height: 700).textFieldStyle(.roundedBorder)
        .background(NotebookPalette.canvas).foregroundStyle(NotebookPalette.ink)
        .disabled(model.busy).interactiveDismissDisabled()
    }
    private func parameterEditor(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                TextField("Name", text: Binding(get: { parameters[index].id }, set: { name in
                    let previous = parameters[index].id
                    parameters[index].id = name
                    for item in items.indices {
                        if items[item].component.input == previous { items[item].component.input = name }
                        if var fields = items[item].component.fields {
                            for field in fields.indices where fields[field].input == previous { fields[field].input = name }
                            items[item].component.fields = fields
                        }
                    }
                })).accessibilityLabel("Parameter name")
                Button(role: .destructive) { parameters.remove(at: index) } label: { Image(systemName: "minus.circle") }
            }
            TextField("Title", text: $parameters[index].title)
            if !usesJSONParameter(parameters[index].id) {
                Picker("Type", selection: $parameters[index].type) {
                    ForEach(NotebookProjectInput.types, id: \.self) { Text(NotebookProjectInput.typeTitle($0)).tag($0) }
                }.onChange(of: parameters[index].type) {
                    parameters[index].default_json = (try? NotebookProjectInput.valueJSON(NotebookProjectInput.initialText(for: parameters[index].type), type: parameters[index].type)) ?? "0"
                    parameters[index].minimum = nil; parameters[index].maximum = nil
                }
            }
            if parameters[index].type == "string" && usesJSONParameter(parameters[index].id) {
                NotebookConfigEditor(text: Binding(get: { parameters[index].preview.editingText }, set: { text in
                    parameters[index].default_json = (try? NotebookProjectInput.valueJSON(text, type: "string")) ?? text
                }), title: "Default config", format: parameterConfigFormat(parameters[index].id))
            } else {
                TextField("Default value", text: Binding(get: { parameters[index].preview.editingText }, set: { text in
                    parameters[index].default_json = (try? NotebookProjectInput.valueJSON(text, type: parameters[index].type)) ?? text
                })).accessibilityLabel("Default value")
            }
            if ["number", "integer"].contains(parameters[index].type) {
                TextField("Minimum (optional)", value: $parameters[index].minimum, format: .number)
                TextField("Maximum (optional)", value: $parameters[index].maximum, format: .number)
            }
            Divider()
        }
    }
    @ViewBuilder private func componentEditor(_ index: Int) -> some View {
        let component = items[index].component
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $items[index].component.title)
            Picker("Placement", selection: $items[index].after) {
                Text("Pre-cell · above code").tag(false); Text("Post-cell · below code").tag(true)
            }
            if component.kind == "input" {
                Picker("Local parameter", selection: optionalText($items[index].component.input)) {
                    Text("Choose…").tag("")
                    ForEach(parameters.filter { component.control?.style != "json" || $0.type == "string" }) { Text($0.title).tag($0.id) }
                }
                if component.control?.style == "json" {
                    NotebookConfigSettings(format: Binding(get: { items[index].component.control?.config_format }, set: { items[index].component.control?.config_format = $0 }))
                } else if let input = parameters.first(where: { $0.id == component.input }) {
                    NotebookInputControlEditor(input: input.preview, control: Binding(
                        get: { items[index].component.control ?? NotebookInputControl() },
                        set: { items[index].component.control = $0 }))
                }
            } else if component.kind == "parameter_form" {
                ForEach(parameters) { input in
                    Toggle(input.title, isOn: Binding(get: { items[index].component.fields?.contains { $0.input == input.id } == true }, set: { enabled in
                        var fields = items[index].component.fields ?? []
                        fields.removeAll { $0.input == input.id }
                        if enabled { fields.append(NotebookFormField(input: input.id, control: NotebookInputControl())) }
                        items[index].component.fields = fields
                    }))
                    if let fieldIndex = items[index].component.fields?.firstIndex(where: { $0.input == input.id }) {
                        NotebookInputControlEditor(input: input.preview, control: Binding(
                            get: { items[index].component.fields?[fieldIndex].control ?? NotebookInputControl() },
                            set: { items[index].component.fields?[fieldIndex].control = $0 }))
                    }
                }
            } else if component.kind == "live_chart" {
                TextField("Channel ID", text: optionalText($items[index].component.chart_id))
                TextField("X label", text: optionalText($items[index].component.x_label))
                TextField("Y label", text: optionalText($items[index].component.y_label))
                TextField("Line color (#RRGGBB)", text: optionalText($items[index].component.stroke))
                TextField("X minimum", value: $items[index].component.x_min, format: .number)
                TextField("X maximum", value: $items[index].component.x_max, format: .number)
                TextField("Y minimum", value: $items[index].component.y_min, format: .number)
                TextField("Y maximum", value: $items[index].component.y_max, format: .number)
            } else if component.kind == "audio" {
                TextField("Audio channel (empty: all)", text: optionalText($items[index].component.audio_id))
                Toggle("Show waveform", isOn: Binding(get: { items[index].component.show_waveform ?? true }, set: { items[index].component.show_waveform = $0 }))
            } else if component.kind == "table" {
                TextField("Table ID (empty: published tables or result)", text: optionalText($items[index].component.table_id))
            } else if component.kind == "image" {
                TextField("Image channel ID", text: optionalText($items[index].component.image_id))
                Picker("Sizing", selection: Binding(get: { items[index].component.image_mode ?? "fit" }, set: { items[index].component.image_mode = $0 })) {
                    Text("Fit").tag("fit"); Text("Fill").tag("fill"); Text("Auto height").tag("auto-height")
                }
            } else if component.kind == "metric" {
                TextField("Published variable (empty: result)", text: optionalText($items[index].component.binding))
                TextField("Unit", text: Binding(get: { items[index].component.p1?.unit ?? "" }, set: { value in
                    var settings = items[index].component.settings; settings.unit = value; items[index].component.p1 = settings
                }))
            }
        }
    }
    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0 })
    }
    private func addParameter() {
        var number = parameters.count + 1
        while parameters.contains(where: { $0.id == "parameter\(number)" }) { number += 1 }
        parameters.append(.init(id: "parameter\(number)", title: "Parameter \(number)"))
    }
    private func usesJSONParameter(_ id: String) -> Bool {
        items.contains { item in
            (item.component.input == id && item.component.control?.style == "json") ||
                item.component.fields?.contains { $0.input == id && $0.control.style == "json" } == true
        }
    }
    private func parameterConfigFormat(_ id: String) -> NotebookConfigFormat {
        for item in items {
            if item.component.input == id && item.component.control?.style == "json" { return item.component.control?.configFormat ?? .json }
            if let field = item.component.fields?.first(where: { $0.input == id && $0.control.style == "json" }) { return field.control.configFormat }
        }
        return .json
    }
    private func addComponent(_ kind: String) {
        if ["input", "parameter_form"].contains(kind) && parameters.isEmpty { addParameter() }
        let id = NotebookBoard.newID("component")
        var component = NotebookBoardComponent(id: id, kind: NotebookComponentTool.tool(kind).componentKind, title: NotebookComponentTool.tool(kind).title)
        if kind == "input" { component.input = parameters.first?.id }
        if kind == "config_editor" {
            var number = 1
            while parameters.contains(where: { $0.id == "config\(number)" }) { number += 1 }
            let name = "config\(number)"
            parameters.append(.init(id: name, title: "Config \(number)", type: "string", default_json: "\"{}\""))
            component.input = name; component.control = NotebookInputControl(style: "json")
        }
        if kind == "parameter_form" { component.fields = parameters.map { .init(input: $0.id, control: NotebookInputControl()) } }
        if kind == "live_chart" { component.chart_id = "loss"; component.stroke = "#86505f" }
        if kind == "image" { component.image_id = "image" }
        items.append(.init(component: component, after: !["input", "config_editor", "parameter_form"].contains(kind)))
        selected = id
    }
    private func save() {
        guard document == model.documentIdentity else { error = "Project changed. Close this editor."; return }
        let ui = NotebookCellUI(inputs: parameters, pre: items.filter { !$0.after }.map(\.component), post: items.filter(\.after).map(\.component))
        model.saveCellUI(ui, cell: cell, tab: tab) { success in
            if success { dismiss() } else { error = model.error ?? "Could not save components."; model.clearError() }
        }
    }
}

/// Native button keeps source collapse accessible inside a complex cell card.
struct NotebookSourceCollapseButton: NSViewRepresentable {
    let collapsed: Bool
    let cellID: String
    let action: () -> Void
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func press(_ sender: NSButton) { action() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false; button.imagePosition = .imageOnly
        button.setButtonType(.momentaryPushIn)
        button.target = context.coordinator; button.action = #selector(Coordinator.press(_:))
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        let label = collapsed ? "Show source code" : "Collapse source code"
        button.image = NSImage(systemSymbolName: collapsed ? "chevron.down" : "chevron.up", accessibilityDescription: label)
        button.contentTintColor = NSColor.secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier("cell-collapse-" + cellID)
    }
}

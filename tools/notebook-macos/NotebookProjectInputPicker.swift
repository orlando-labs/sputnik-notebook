import SwiftUI

/// Parameter selection and creation stay next to the control that uses them.
struct NotebookProjectInputPicker: View {
    @ObservedObject var model: NotebookModel
    var title = "Parameter"
    var allowedTypes = NotebookProjectInput.types
    var excludedIDs: [String] = []
    var configJSON = false
    var configFormat: NotebookConfigFormat = .json
    @Binding var selection: String
    @State private var creating = false
    @State private var managing = false

    private var inputs: [NotebookProjectInput] {
        (model.snapshot?.inputs ?? []).filter { allowedTypes.contains($0.type) && !excludedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NotebookPlotField(title: title) {
                Picker(title, selection: $selection) {
                    Text(configJSON ? "Choose config…" : "Choose parameter…").tag("")
                    ForEach(inputs) { Text(configJSON ? "\($0.title) · \($0.id)" : "\($0.title) · \($0.id) · \(NotebookProjectInput.typeTitle($0.type))").tag($0.id) }
                    if !selection.isEmpty && !inputs.contains(where: { $0.id == selection }) {
                        Text("\(selection) · unavailable").tag(selection)
                    }
                }.labelsHidden().accessibilityIdentifier("project-input-picker")
            }
            Button(configJSON ? "New config…" : "New parameter…", systemImage: "plus") { creating = true }
                .accessibilityIdentifier("project-input-create")
            Button("Manage project inputs…", systemImage: "slider.horizontal.3") { managing = true }
                .accessibilityIdentifier("project-input-manage")
            if selection.isEmpty && inputs.isEmpty {
                Text("Create a parameter to connect this control.")
                    .font(.caption).foregroundStyle(NotebookPalette.muted)
            }
        }
        .sheet(isPresented: $creating) {
            NotebookInputEditor(model: model, document: model.documentIdentity, allowedTypes: allowedTypes, configJSON: configJSON, configFormat: configFormat) { id in
                selection = id
            }
        }
        .sheet(isPresented: $managing) { NotebookProjectInputsView(model: model) }
    }
}

struct NotebookInputEditor: View {
    @ObservedObject var model: NotebookModel
    let document: UUID
    var allowedTypes: [String]
    var configJSON: Bool
    var configFormat: NotebookConfigFormat
    var onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var id = ""
    @State private var title = ""
    @State private var type: String
    @State private var initial: String
    @State private var minimum = ""
    @State private var maximum = ""
    @State private var error: String?

    init(model: NotebookModel, document: UUID, allowedTypes: [String] = NotebookProjectInput.types, configJSON: Bool = false, configFormat: NotebookConfigFormat = .json,
         onCreate: @escaping (String) -> Void = { _ in }) {
        self.model = model; self.document = document; self.allowedTypes = allowedTypes; self.onCreate = onCreate; self.configJSON = configJSON
        self.configFormat = configFormat
        let type = configJSON ? "string" : allowedTypes.first ?? "number"
        _type = State(initialValue: type)
        _initial = State(initialValue: configJSON ? configFormat.initialText : NotebookProjectInput.initialText(for: type))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(configJSON ? "New Config" : "New Parameter").font(.title2.bold())
            Text("This parameter is shared across the project. Creating it saves its definition; cancelling the board designer does not delete it.")
                .font(.callout).foregroundStyle(NotebookPalette.muted)
            TextField("Name used in notebook.input(…)", text: $id)
                .accessibilityIdentifier("project-input-name")
            TextField("Display title", text: $title)
                .accessibilityIdentifier("project-input-title")
            if !configJSON {
                Picker("Type", selection: $type) {
                    ForEach(allowedTypes, id: \.self) { Text(NotebookProjectInput.typeTitle($0)).tag($0) }
                }.pickerStyle(.menu)
                    .onChange(of: type) { initial = NotebookProjectInput.initialText(for: type); minimum = ""; maximum = "" }
                    .accessibilityIdentifier("project-input-type")
            }
            if configJSON {
                NotebookConfigEditor(text: $initial, title: "Default config", format: configFormat)
            } else if type == "range" {
                NotebookRangeControlView(text: $initial)
                Text(initial).font(.system(.caption, design: .monospaced))
            } else {
                TextField("Default value", text: $initial)
                    .accessibilityIdentifier("project-input-default")
            }
            if type == "number" || type == "integer" {
                HStack {
                    NotebookPlotField(title: "Minimum (optional)") { TextField("None", text: $minimum) }
                    NotebookPlotField(title: "Maximum (optional)") { TextField("None", text: $maximum) }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(configJSON ? "Create Config" : "Create Parameter") { create() }.keyboardShortcut(.defaultAction).disabled(id.isEmpty || (configJSON && NotebookConfigJSON.error(initial, format: configFormat) != nil))
                    .accessibilityIdentifier("project-input-save")
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 480).disabled(model.busy).interactiveDismissDisabled()
    }

    private func create() {
        guard model.documentIdentity == document else { error = "Project changed. Close this editor."; return }
        do {
            if configJSON { _ = try NotebookConfigJSON.process(initial, format: configFormat) }
            func quote(_ value: String) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
            let createdID = id
            var json = try "{\"id\":\(quote(id)),\"title\":\(quote(title.isEmpty ? id : title)),\"type\":\(quote(type)),\"default\":\(NotebookProjectInput.valueJSON(initial, type: type))"
            if type == "number" || type == "integer" {
                if !minimum.isEmpty { json += ",\"minimum\":" + minimum }
                if !maximum.isEmpty { json += ",\"maximum\":" + maximum }
            }
            json += "}"
            model.perform("new_input", text: json) { success in
                if success { onCreate(createdID); dismiss() } else { error = model.error; model.clearError() }
            }
        } catch { self.error = error.localizedDescription }
    }
}

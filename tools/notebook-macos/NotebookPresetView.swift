import AppKit
import SwiftUI

enum NotebookPresetEditing {
    static func validate(_ preset: NotebookParameterPreset, inputs: [NotebookProjectInput], selected: [String]?) -> String? {
        if preset.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || preset.title.utf8.count > 256 { return "Name must contain 1–256 bytes." }
        if preset.values.isEmpty { return "Preset has no parameter values." }
        for (id, json) in preset.values {
            guard let input = inputs.first(where: { $0.id == id }), selected == nil || selected!.isEmpty || selected!.contains(id) else { return "A saved parameter is unavailable in this preset component." }
            let data = Data(json.utf8)
            let text: String
            switch input.type {
            case "string": guard let v = try? JSONDecoder().decode(String.self, from: data) else { return "\(input.title): expected text." }; text = v
            case "integer": guard (try? JSONDecoder().decode(Int64.self, from: data)) != nil else { return "\(input.title): expected an Int64 integer." }; text = json
            case "range": guard let v = try? NotebookRangeValue.decode(json) else { return "\(input.title): expected a Range." }; text = v.expression
            case "number": guard let v = try? JSONDecoder().decode(Double.self, from: data), v.isFinite else { return "\(input.title): expected a finite number." }; text = json
            default: guard (try? JSONDecoder().decode(Bool.self, from: data)) != nil else { return "\(input.title): expected true or false." }; text = json
            }
            if let message = NotebookInputEditing.error(text, input: input, control: NotebookInputControl()) { return "\(input.title): \(message)" }
        }
        return nil
    }
}

struct NotebookPresetView: View {
    @ObservedObject var model: NotebookModel
    let board: NotebookBoard, component: NotebookBoardComponent
    @State private var selected = ""
    @State private var name = ""
    @State private var message: String?
    @State private var confirmDelete = false
    private var inputs: [NotebookProjectInput] { model.snapshot?.inputs ?? [] }
    private var presets: [NotebookParameterPreset] { component.settings.presets ?? [] }
    private var preset: NotebookParameterPreset? { presets.first { $0.id == selected } }
    private var validation: String? { preset.flatMap { NotebookPresetEditing.validate($0, inputs: inputs, selected: component.settings.preset_inputs) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Preset", selection: $selected) {
                Text("Choose preset…").tag("")
                ForEach(presets) { Text($0.title).tag($0.id) }
            }.onChange(of: selected) { name = preset?.title ?? ""; message = nil }
            if let preset {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(preset.values.keys.sorted(), id: \.self) { id in
                            let input = inputs.first { $0.id == id }
                            let value = preset.values[id] ?? ""
                            let changed = input?.value_json != value
                            Text("\(input?.title ?? "Parameter unavailable"): \(readable(input?.value_json ?? "")) → \(readable(value))" + (changed ? "" : " · unchanged"))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(changed ? NotebookPalette.ink : NotebookPalette.muted).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 140)
                if let validation { Text(validation).font(.caption).foregroundStyle(NotebookPalette.error) }
                Button("Apply preset") { model.setProjectInputs(preset.values) { success in message = success ? "Parameters applied together. Manual cells refresh with Run." : model.error } }
                    .buttonStyle(.borderedProminent).tint(NotebookPalette.categoryControls).disabled(validation != nil)
            }
            HStack {
                TextField("Preset name", text: $name).textFieldStyle(.roundedBorder)
                Button("Capture current") { capture() }.disabled(presets.count >= 128 || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                Button("Rename") { if var value = preset { value.title = name; update(presets.map { $0.id == value.id ? value : $0 }) } }.disabled(preset == nil || name.isEmpty)
                Button("Delete", role: .destructive) { confirmDelete = true }.disabled(preset == nil)
                Spacer()
                Menu("Transfer") { Button("Import presets…", action: importPresets); Button("Export presets…", action: exportPresets).disabled(presets.isEmpty) }
            }.controlSize(.small)
            if let message { Text(message).font(.caption).foregroundStyle(NotebookPalette.muted) }
        }.disabled(model.busy)
        .confirmationDialog("Delete this saved preset?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { update(presets.filter { $0.id != selected }); selected = "" }
        }
    }
    private func readable(_ json: String) -> String { (try? JSONDecoder().decode(String.self, from: Data(json.utf8))) ?? json }
    private func capture() {
        let selection = component.settings.preset_inputs ?? []
        let values = Dictionary(uniqueKeysWithValues: inputs.filter { selection.isEmpty || selection.contains($0.id) }.map { ($0.id, $0.value_json) })
        let value = NotebookParameterPreset(id: NotebookBoard.newID("preset"), title: name, values: values)
        if let error = NotebookPresetEditing.validate(value, inputs: inputs, selected: selection) { message = error; return }
        update(presets + [value], select: value.id)
    }
    private func update(_ values: [NotebookParameterPreset], select: String? = nil) {
        for value in values { if let error = NotebookPresetEditing.validate(value, inputs: inputs, selected: component.settings.preset_inputs) { message = error; return } }
        var edited = component; var settings = edited.settings; settings.presets = values; edited.p1 = settings
        model.saveComponent(edited, board: board) { success in
            message = success ? "Presets saved in the project." : model.error
            if success, let select { selected = select; name = values.first { $0.id == select }?.title ?? "" }
        }
    }
    private func importPresets() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 1024 * 1024 else { throw NSError(domain: "Presets", code: 1, userInfo: [NSLocalizedDescriptionKey: "Preset file exceeds 1 MiB."]) }
            var imported = try JSONDecoder().decode([NotebookParameterPreset].self, from: Data(contentsOf: url))
            guard imported.count + presets.count <= 128 else { message = "At most 128 presets per component."; return }
            for i in imported.indices {
                if let error = NotebookPresetEditing.validate(imported[i], inputs: inputs, selected: component.settings.preset_inputs) { message = error; return }
                imported[i].id = NotebookBoard.newID("preset")
            }
            update(presets + imported)
        } catch { message = error.localizedDescription }
    }
    private func exportPresets() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "parameter-presets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(presets).write(to: url, options: .atomic) }
        catch { message = error.localizedDescription }
    }
}

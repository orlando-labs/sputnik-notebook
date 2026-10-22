import SwiftUI

struct NotebookAnnotationClassesView: View {
    typealias AudioClass = NotebookAnnotationClass
    @Environment(\.dismiss) private var dismiss
    @State private var classes: [AudioClass]
    let onSave: ([AudioClass]) -> Void
    init(classes: [AudioClass], onSave: @escaping ([AudioClass]) -> Void) { _classes = State(initialValue: classes); self.onSave = onSave }
    private var invalid: Bool {
        classes.contains { item in
            item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.title.utf8.count > 128 || item.title.contains("\0") || item.attributes.contains {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.title.utf8.count > 128 || $0.title.contains("\0") || ($0.type == "choice" && ($0.options.isEmpty || $0.options.count > 64 || Set($0.options).count != $0.options.count || $0.options.contains { $0.isEmpty || $0.utf8.count > 128 || $0.contains("\0") }))
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Allowed classes and attributes").font(.title2.bold()); Spacer(); Button("Add class") { classes.append(.init(title: "Class \(classes.count + 1)")) }.disabled(classes.count >= 32).accessibilityIdentifier("annotation-add-class") }
            Text("Board Designer defines the allowed classes for every region. Each class owns text, number, Boolean or choice attributes.").font(.callout).foregroundStyle(NotebookPalette.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(classes.indices, id: \.self) { index in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    TextField("Class name", text: $classes[index].title).font(.headline)
                                    Button("Remove", role: .destructive) { classes.remove(at: index) }
                                }
                                ForEach(classes[index].attributes.indices, id: \.self) { attribute in
                                    attributeEditor(index, attribute)
                                }
                                Button("Add attribute", systemImage: "plus") { classes[index].attributes.append(.init(title: "Attribute \(classes[index].attributes.count + 1)")) }
                                    .disabled(classes[index].attributes.count >= 16)
                            }.padding(6)
                        }
                    }
                }
            }
            if invalid { Text("Names must be nonempty (at most 128 UTF-8 bytes); choices must be unique and nonempty.").font(.caption).foregroundStyle(NotebookPalette.error) }
            HStack {
                Text("Save Board to apply the schema. Existing labels with an older schema must be reviewed and reapplied.").font(.caption).foregroundStyle(NotebookPalette.muted)
                Spacer(); Button("Cancel", role: .cancel) { dismiss() }
                Button("Use classes") { onSave(classes); dismiss() }.buttonStyle(.borderedProminent).disabled(invalid).keyboardShortcut(.defaultAction).accessibilityIdentifier("annotation-schema-save")
            }
        }.padding(20).frame(width: 790, height: 650).textFieldStyle(.roundedBorder).background(NotebookPalette.canvas).foregroundStyle(NotebookPalette.ink).accessibilityIdentifier("annotation-schema-editor")
    }
    private func attributeEditor(_ index: Int, _ attribute: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Attribute name", text: $classes[index].attributes[attribute].title)
                Picker("Type", selection: Binding(get: { classes[index].attributes[attribute].type }, set: { type in
                    classes[index].attributes[attribute].type = type
                    classes[index].attributes[attribute].options = type == "choice" ? ["Option 1"] : []
                })) { Text("Text").tag("text"); Text("Number").tag("number"); Text("Boolean").tag("boolean"); Text("Choice").tag("choice") }.frame(width: 170)
                Button { classes[index].attributes.remove(at: attribute) } label: { Image(systemName: "minus.circle") }.accessibilityLabel("Remove attribute")
            }
            if classes[index].attributes[attribute].type == "choice" {
                TextField("Options, separated by commas", text: Binding(get: { classes[index].attributes[attribute].options.joined(separator: ", ") }, set: {
                    classes[index].attributes[attribute].options = $0.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                }))
            }
        }
    }
}

struct NotebookAnnotationAttributeField: View {
    let attribute: NotebookAnnotationAttribute
    @Binding var value: NotebookTableValue
    var validity: (Bool) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if attribute.type != "boolean" { Text(attribute.title).font(.caption).foregroundStyle(NotebookPalette.muted) }
            switch attribute.type {
            case "boolean": Toggle(attribute.title, isOn: Binding(get: { if case .boolean(let v) = value { return v }; return false }, set: { value = .boolean($0) }))
            case "number": NotebookAnnotationNumberField(title: attribute.title, value: Binding<Double>(get: { Double(value.text) ?? 0 }, set: { if $0.isFinite { value = .number($0) } }), validity: validity)
            case "choice": Picker(attribute.title, selection: Binding(get: { value.text }, set: { value = .text($0) })) { ForEach(attribute.options, id: \.self) { Text($0).tag($0) } }.labelsHidden()
            default: TextField(attribute.title, text: Binding(get: { value.text }, set: { if $0.utf8.count <= 2048 && !$0.contains("\0") { value = .text($0) } }))
            }
        }.textFieldStyle(.roundedBorder)
    }
}

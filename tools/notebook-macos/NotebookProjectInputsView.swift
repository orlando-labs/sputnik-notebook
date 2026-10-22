import SwiftUI

struct NotebookProjectInputsView: View {
    @ObservedObject var model: NotebookModel
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var deleting: NotebookProjectInput?
    @State private var error: String?
    private let document: UUID

    init(model: NotebookModel) {
        self.model = model; document = model.documentIdentity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Project Inputs").font(.title2.bold())
                Spacer()
                Button("New Parameter…", systemImage: "plus") { creating = true }
                    .accessibilityIdentifier("project-inputs-create")
            }
            Text("Shared parameters read with notebook.input(\"name\").")
                .font(.callout).foregroundStyle(NotebookPalette.muted)
            List {
                if model.snapshot?.inputs?.isEmpty != false {
                    Text("No project inputs yet.").foregroundStyle(NotebookPalette.muted)
                }
                ForEach(model.snapshot?.inputs ?? []) { input in
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(input.title).font(.headline)
                            Text(input.id).font(.system(.caption, design: .monospaced))
                                .foregroundStyle(NotebookPalette.muted)
                        }
                        Spacer()
                        Text(NotebookProjectInput.typeTitle(input.type)).font(.callout)
                        Button("Delete…", role: .destructive) { deleting = input }
                            .accessibilityIdentifier("project-input-delete-\(input.id)")
                    }.padding(.vertical, 5)
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 660, height: 460)
            .background(NotebookPalette.canvas).foregroundStyle(NotebookPalette.ink)
            .disabled(model.busy || model.documentIdentity != document)
            .interactiveDismissDisabled(model.busy)
            .accessibilityIdentifier("project-inputs-manager")
            .onChange(of: model.documentIdentity) { dismiss() }
            .sheet(isPresented: $creating) { NotebookInputEditor(model: model, document: document) }
            .confirmationDialog("Delete project input \(deleting?.title ?? "")?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible) {
                Button("Delete Input", role: .destructive) {
                    guard let input = deleting, model.documentIdentity == document else { return }
                    deleting = nil
                    model.deleteProjectInput(input) { success in
                        if success { error = nil }
                        else { error = model.error; model.clearError() }
                    }
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text("The definition and its value will be removed from the project. Remove board bindings first and update any code that reads this input.")
            }
    }
}

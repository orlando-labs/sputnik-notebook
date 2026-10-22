import AppKit
import SwiftUI

struct NotebookCellIDEditor: View {
    @ObservedObject var model: NotebookModel
    let cell: NotebookCell, tab: NotebookTab
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var value: String
    @State private var error: String?
    private let document: UUID

    init(model: NotebookModel, cell: NotebookCell, tab: NotebookTab) {
        self.model = model; self.cell = cell; self.tab = tab
        document = model.documentIdentity
        _value = State(initialValue: cell.id)
    }

    private var normalized: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validation: String? { model.cellIDValidationError(normalized, cell: cell) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hard ID · \(tab.cellLabel(for: cell.id))").font(.title2.bold())
            Text("Components bind to this permanent ID. Moving the cell changes its visible number and keeps its Hard ID.")
                .font(.callout).foregroundStyle(NotebookPalette.muted)
            HStack {
                TextField("Hard ID", text: $value).textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced)).focused($focused)
                    .accessibilityIdentifier("cell-hard-id-field")
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(normalized, forType: .string)
                }
                .disabled(validation != nil)
                .accessibilityIdentifier("copy-cell-hard-id")
            }
            Text("Changing this ID also updates existing component bindings. The new ID must be unique in this notebook.")
                .font(.caption).foregroundStyle(NotebookPalette.muted)
            if let message = validation ?? error {
                Text(message).font(.callout).foregroundStyle(NotebookPalette.error)
                    .textSelection(.enabled).accessibilityIdentifier("cell-hard-id-error")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).disabled(validation != nil)
                    .accessibilityIdentifier("save-cell-hard-id")
            }
        }
        .padding(24).frame(width: 520)
        .background(NotebookPalette.canvas).foregroundStyle(NotebookPalette.ink)
        .disabled(model.busy).interactiveDismissDisabled(model.busy)
        .onAppear { focused = true }
        .onChange(of: value) { error = nil }
    }

    private func save() {
        guard document == model.documentIdentity,
              model.snapshot?.tabs.first(where: { $0.id == tab.id })?.cells.contains(where: { $0.id == cell.id }) == true else {
            error = "This cell is no longer available. Close this window and select the cell again."
            return
        }
        model.setCellID(normalized, cell: cell, tab: tab) { saved in
            if saved { dismiss() }
            else { error = model.error ?? "Could not save the Hard ID."; model.clearError() }
        }
    }
}

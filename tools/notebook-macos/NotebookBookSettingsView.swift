import SwiftUI

struct NotebookBookSettingsView: View {
    @ObservedObject var model: NotebookModel
    @Environment(\.dismiss) private var dismiss
    @State private var manageMedia = false
    @State private var manageDependencies = false
    @State private var retainResults: Bool

    init(model: NotebookModel) {
        self.model = model
        _retainResults = State(initialValue: model.retainCellResults)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Notebook Settings").font(.title2)
            Text(model.snapshot?.title ?? "").font(.headline)
            Button("Manage Dependencies…") { manageDependencies = true }
                .accessibilityIdentifier("notebook-manage-dependencies")
            Toggle("Keep results from the previous run", isOn: $retainResults)
                .accessibilityIdentifier("notebook-retain-cell-results")
            Text("Keep the last successful cell result available for inspection while editing or running again, including after an error. Previous results are labelled and cleared when the notebook or worker restarts.")
                .font(.callout).foregroundStyle(NotebookPalette.muted)
            Text("This option is saved in this sputnikbook. Result snapshots stay in memory.")
                .font(.caption).foregroundStyle(NotebookPalette.muted)
            Button("Manage unused media…") { manageMedia = true }.disabled(model.remote.isSelected)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { model.setRetainCellResults(retainResults) { if $0 { dismiss() } } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 480)
        .disabled(model.busy || model.remote.busy)
        .foregroundStyle(NotebookPalette.ink).background(NotebookPalette.canvas)
        .interactiveDismissDisabled(model.busy)
        .sheet(isPresented: $manageMedia) { NotebookMediaAssetsView(model: model) }
        .sheet(isPresented: $manageDependencies) { NotebookDependenciesView(model: model) }
    }
}

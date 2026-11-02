import SwiftUI

struct NotebookBookSettingsView: View {
    @ObservedObject var model: NotebookModel
    @Environment(\.dismiss) private var dismiss
    @State private var manageMedia = false
    @State private var manageDependencies = false
    @State private var resourcePolicy: NotebookResourcePolicy
    @State private var retainResults: Bool

    init(model: NotebookModel) {
        self.model = model
        _retainResults = State(initialValue: model.retainCellResults)
        _resourcePolicy = State(initialValue: model.bookResourcePolicy)
    }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
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
            Divider()
            Text("Resource Limits for This Notebook").font(.headline)
            if model.remote.isSelected && model.remote.connected && !model.remote.supportsResourcePolicy {
                Text("Update the remote core to enforce resource limits on the server.")
                    .foregroundStyle(.orange)
            }
            if model.remote.isSelected {
                Text(model.remote.allowsBookPolicyOverrides
                     ? "This server allows notebook settings to replace app defaults. Server limits still apply."
                     : "This server only allows stricter notebook limits. Raising app defaults requires the server's book override mode.")
                    .font(.caption).foregroundStyle(NotebookPalette.muted)
            }
            NotebookResourcePolicyForm(policy: $resourcePolicy, parent: model.appResourcePolicy,
                restrictive: model.remote.isSelected && !model.remote.allowsBookPolicyOverrides)
            Button("Use App Defaults for All Fields") { resourcePolicy = .init() }
            Text("Saved in this sputnikbook. The server can impose stricter limits. Local execution time used: " + String(format: "%.1f s", model.resourceUsage.current))
                .font(.caption).foregroundStyle(NotebookPalette.muted)
            Button("Manage unused media…") { manageMedia = true }.disabled(model.remote.isSelected)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    model.setBookResourcePolicy(resourcePolicy) { saved in
                        if saved { model.setRetainCellResults(retainResults) { if $0 { dismiss() } } }
                    }
                }.disabled(resourcePolicy.validationError != nil).accessibilityIdentifier("save-book-resource-policy")
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24) }.frame(width: 610, height: 680)
        .disabled(model.busy || model.remote.busy)
        .foregroundStyle(NotebookPalette.ink).background(NotebookPalette.canvas)
        .interactiveDismissDisabled(model.busy)
        .sheet(isPresented: $manageMedia) { NotebookMediaAssetsView(model: model) }
        .sheet(isPresented: $manageDependencies) { NotebookDependenciesView(model: model) }
    }
}

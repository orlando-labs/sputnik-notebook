import SwiftUI

struct NotebookWorkerSettingsEditor: View {
    @ObservedObject var model: NotebookModel
    @ObservedObject var remote: NotebookRemoteController
    let tab: NotebookTab
    let document: UUID
    let execution: String?
    @Environment(\.dismiss) private var dismiss
    @State private var settings: NotebookWorkerSettings?
    @State private var text = ""
    @State private var environmentDirectory = ""
    @State private var loading = true
    @State private var applying = false
    @State private var message: String?

    private var current: Bool { model.documentIdentity == document && remote.selected == execution }
    private var validation: String? {
        do { _ = try normalizedWorkerGrants(text); return nil }
        catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Worker Settings").font(.title2)
            Text("\(tab.title) · \(execution == nil ? "This Mac" : remote.serverName)")
                .font(.callout).foregroundStyle(.secondary)
            Text("Environment directory").font(.headline)
            TextField("Automatic", text: $environmentDirectory)
                .textFieldStyle(.roundedBorder).disabled(loading || applying)
                .accessibilityLabel("Worker environment directory")
            Text(execution == nil
                ? "Automatic uses .venv or venv and Gemfile in this notebook. A custom path must be an absolute directory on this Mac."
                : "Automatic prepares a persistent server environment from requirements.lock / requirements.txt and Gemfile.lock. A custom path selects an existing directory on the server.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Runtime grants").font(.headline)
            Text("Enter one capability per line: capability=target. Omit =target to allow all targets. An empty list removes explicit grants.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 190).padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(NotebookPalette.rule))
                .disabled(loading || applying)
                .accessibilityLabel("Worker runtime grants")
            HStack {
                Button("Clear grants") { text = "" }
                Spacer()
                if loading || applying { ProgressView().controlSize(.small) }
            }.disabled(loading || applying)
            Text("Examples: fs.read=/data, fs.write=/output, net.connect=api.example.com:443, device.gpu")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Text(execution == nil
                ? "Saved on this Mac for this notebook and worker. Native package trust also grants ffi.call, ffi.load and fs.read."
                : "Saved on the server for this project's sheet. Reconnecting uses the server's settings.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Applying restarts this worker and clears its runtime state. Drafts and displayed results stay; run cells again when ready.")
                .font(.callout)
            if let error = message ?? validation { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if message != nil { Button("Reload settings") { Task { await load() } }.disabled(applying || model.busy || remote.busy) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(applying)
                Button("Apply and Restart Worker") {
                    guard let settings, current else { return }
                    applying = true; message = nil
                    Task { @MainActor in
                        do { try await model.configureWorker(tab, text: text, environmentDirectory: environmentDirectory, settings: settings); dismiss() }
                        catch { message = error.localizedDescription; applying = false }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(settings == nil || loading || applying || validation != nil || !current || model.busy || remote.busy || model.executingCurrentWorker)
            }
        }.padding(24).frame(width: 650)
            .background(NotebookPalette.canvas)
            .foregroundStyle(NotebookPalette.ink)
            .tint(NotebookPalette.sputnik)
            .task { await load() }
    }
    @MainActor private func load() async {
        guard current else { return }
        loading = true; message = nil
        do { let value = try await model.workerSettings(for: tab); settings = value; text = value.grants.joined(separator: "\n"); environmentDirectory = value.environment_directory ?? "" }
        catch { message = error.localizedDescription }
        loading = false
    }
}

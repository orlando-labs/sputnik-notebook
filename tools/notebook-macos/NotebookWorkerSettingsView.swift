import SwiftUI

struct NotebookWorkerSettingsEditor: View {
    @ObservedObject var model: NotebookModel
    @ObservedObject var remote: NotebookRemoteController
    let tab: NotebookTab?
    let document: UUID
    let execution: String?
    @Environment(\.dismiss) private var dismiss
    @State private var settings: NotebookWorkerSettings?
    @State private var text = ""
    @State private var environmentDirectory = ""
    @State private var loading = true
    @State private var applying = false
    @State private var message: String?
    @State private var showingGrantCatalog = false
    @State private var grantSearch = ""
    @State private var grantName = ""
    @State private var grantTarget = ""
    private let grantCatalog = workerGrantCatalog()

    private var current: Bool { model.documentIdentity == document && remote.selected == execution }
    private var validation: String? {
        do { _ = try normalizedWorkerGrants(text); return nil }
        catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tab == nil ? "Notebook Permissions" : "Worker Settings").font(.title2)
            Text("\(tab?.title ?? model.snapshot?.title ?? "Notebook") · \(execution == nil ? "This Mac" : remote.serverName)")
                .font(.callout).foregroundStyle(.secondary)
            if tab != nil {
                Text("Environment directory").font(.headline)
                TextField("Automatic", text: $environmentDirectory)
                    .textFieldStyle(.roundedBorder).disabled(loading || applying)
                    .accessibilityLabel("Worker environment directory")
                Text(execution == nil
                    ? "Automatic uses .venv or venv and Gemfile in this notebook. A custom path must be an absolute directory on this Mac."
                    : "Automatic prepares a persistent server environment from requirements.lock / requirements.txt and Gemfile.lock. A custom path selects an existing directory on the server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Runtime grants").font(.headline)
            HStack {
                Button(grantName.isEmpty ? "Choose a grant…" : grantName) {
                    grantSearch = ""
                    showingGrantCatalog.toggle()
                }
                .popover(isPresented: $showingGrantCatalog) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Search available grants", text: $grantSearch).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Search available grants")
                        let matches = grantCatalog.filter { grantSearch.isEmpty || $0.localizedCaseInsensitiveContains(grantSearch) }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                if matches.isEmpty { Text("No matching grants").foregroundStyle(.secondary) }
                                ForEach(matches, id: \.self) { name in
                                    Button {
                                        grantName = name
                                        grantTarget = ""
                                        showingGrantCatalog = false
                                    } label: {
                                        Text(name).font(.system(.body, design: .monospaced))
                                            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.frame(height: 220)
                    }.padding(12).frame(width: 300)
                }
                TextField("Target (optional, all if empty)", text: $grantTarget)
                    .textFieldStyle(.roundedBorder).disabled(grantName.isEmpty)
                Button("Add to Draft") {
                    let target = grantTarget.trimmingCharacters(in: .whitespacesAndNewlines)
                    let grant = grantName + "=" + (target.isEmpty ? "*" : target)
                    do {
                        let existing = try normalizedWorkerGrants(text).split(separator: "\n").map(String.init)
                        let additions = try missingWorkerGrants([grant], from: existing)
                        text = try normalizedWorkerGrants((existing + additions).joined(separator: "\n"))
                        message = nil
                    } catch { message = error.localizedDescription }
                }.disabled(grantName.isEmpty || grantTarget.contains(where: \.isNewline))
            }.disabled(loading || applying)
            Text("Enter one capability per line: capability=target. Omit =target to allow all targets. An empty list removes explicit grants.")
                .font(.callout).foregroundStyle(.secondary)
            if let inherited = settings?.inherited_grants, !inherited.isEmpty {
                Text("Also granted by this notebook: " + inherited.joined(separator: ", ") + ". Edit Notebook Permissions in Dependencies to change those grants.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
            Text(tab == nil ? "Applies to all current and future sheets in this notebook. Saved for this notebook on the execution machine and retained after reopening. Individual sheet grants are preserved." : execution == nil
                ? "Saved on this Mac for this notebook and worker. Native package trust also grants ffi.call, ffi.load and fs.read."
                : "Saved on the server for this project's sheet. Reconnecting uses the server's settings.")
                .font(.caption).foregroundStyle(.secondary)
            Text(tab == nil ? "Applying restarts this notebook's workers. Run cells again when ready." : "Applying restarts this worker and clears its runtime state. Drafts and displayed results stay; run cells again when ready.")
                .font(.callout)
            if let error = message ?? validation { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if message != nil { Button("Reload settings") { Task { await load() } }.disabled(applying || model.busy || remote.busy) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(applying)
                Button(tab == nil ? "Apply and Restart Workers" : "Apply and Restart Worker") {
                    guard let settings, current else { return }
                    applying = true; message = nil
                    Task { @MainActor in
                        do {
                            if let tab { try await model.configureWorker(tab, text: text, environmentDirectory: environmentDirectory, settings: settings) }
                            else { try await model.configureBookWorkerGrants(text.split(separator: "\n").map(String.init), settings: settings) }
                            dismiss()
                        }
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
        do {
            let value: NotebookWorkerSettings
            if let tab { value = try await model.workerSettings(for: tab) }
            else { value = try await model.bookWorkerSettings() }
            settings = value; text = (value.own_grants ?? value.grants).joined(separator: "\n"); environmentDirectory = value.environment_directory ?? ""
        }
        catch { message = error.localizedDescription }
        loading = false
    }
}

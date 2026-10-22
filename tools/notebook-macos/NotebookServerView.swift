import AppKit
import SwiftUI

struct NotebookServerBar: View {
    @ObservedObject var model: NotebookModel
    @ObservedObject var remote: NotebookRemoteController
    @State private var editServer = false
    @State private var browse = false
    @State private var publish = false
    @State private var workerSettings: NotebookTab?
    @State private var bookSettings = false
    private var workerTab: NotebookTab? { model.activeBoard.flatMap { model.controller(for: $0) } ?? model.activeTab }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: remote.isSelected ? "server.rack" : "laptopcomputer")
                Picker("Execution", selection: Binding(get: { remote.selected ?? "local" }, set: { remote.choose($0 == "local" ? nil : $0) })) {
                    Text("This Mac").tag("local")
                    if let id = remote.selected, !remote.servers.contains(where: { $0.id == id }) {
                        Text("Unavailable server").tag(id)
                    }
                    ForEach(remote.servers) { server in Text(server.name).tag(server.id) }
                }.labelsHidden().frame(maxWidth: 220).disabled(model.busy || remote.busy)
                Button("Servers…") { editServer = true }.disabled(model.busy || remote.busy)
                Button("Worker Settings…") { workerSettings = workerTab }
                    .disabled(workerTab == nil || model.busy || remote.busy || model.executingCurrentWorker ||
                        (remote.isSelected && (!remote.connected || workerTab?.kind != "sheet")))
                Button("Notebook Settings…", systemImage: "gearshape") { bookSettings = true }
                    .labelStyle(.iconOnly).help("Notebook Settings…")
                    .accessibilityLabel("Notebook Settings")
                    .disabled(model.busy || remote.busy)
                if remote.isSelected {
                    if remote.busy { ProgressView().controlSize(.small) }
                    Text(remote.status).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if remote.connected {
                        Button("Sync") { remote.sync() }.disabled(remote.busy || remote.conflict)
                        Button("Projects…") { remote.reloadProjects(); browse = true }.disabled(remote.busy)
                        Button("Disconnect") { remote.detach() }.disabled(remote.busy)
                    } else {
                        if remote.hasPending { Button("Reconnect without resending") { remote.discardPending() }.disabled(remote.busy) }
                        Button("Reconnect") { remote.reconnect() }.disabled(remote.busy)
                    }
                } else { Spacer() }
            }
            if remote.conflict {
                HStack {
                    Text("The server has a different revision. Your local edits are retained.").font(.system(size: 11))
                    Spacer()
                    Button("Server copies…") { remote.reloadProjects(); browse = true }
                    Button("Publish local version…") { publish = true }.disabled(remote.busy || !remote.connected)
                }.foregroundStyle(NotebookPalette.categoryControls)
            }
        }
        .padding(.horizontal, 19).padding(.vertical, 9)
        .background(NotebookPalette.topBar)
        .sheet(isPresented: $editServer) { NotebookServerEditor(remote: remote) }
        .sheet(isPresented: $bookSettings) { NotebookBookSettingsView(model: model) }
        .sheet(isPresented: $browse) { NotebookRemoteProjects(remote: remote) }
        .sheet(item: $workerSettings) { tab in
            NotebookWorkerSettingsEditor(model: model, remote: remote, tab: tab,
                document: model.documentIdentity, execution: remote.selected)
        }
        .confirmationDialog("Publish the local version?", isPresented: $publish, titleVisibility: .visible) {
            Button("Publish local version") { remote.sync(publish: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This updates the server from your local modules, sheets, boards and resources. The previous server revision stays in history. A concurrent server edit will still cause a conflict.")
        }
    }
}

private struct NotebookServerEditor: View {
    @ObservedObject var remote: NotebookRemoteController
    @Environment(\.dismiss) private var dismiss
    @State private var server = NotebookServer()
    @State private var token = ""
    @State private var configuration = "new"
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Notebook servers").font(.title2)
            if !remote.servers.isEmpty {
                Picker("Configuration", selection: Binding(get: { configuration }, set: { value in
                    configuration = value; server = remote.servers.first { $0.id == value } ?? NotebookServer(); token = ""
                })) {
                    Text("New server").tag("new")
                    ForEach(remote.servers) { Text($0.name).tag($0.id) }
                }
            }
            Form {
                TextField("Name", text: $server.name)
                Picker("Connection", selection: $server.ssh) {
                    Text("SSH tunnel").tag(true); Text("Direct HTTPS").tag(false)
                }.pickerStyle(.segmented)
                if server.ssh {
                    TextField("SSH host", text: $server.host).help("Host or user@host, using your existing SSH key and known_hosts.")
                    TextField("SSH port", value: $server.sshPort, formatter: NumberFormatter())
                    TextField("Core port", value: $server.remotePort, formatter: NumberFormatter())
                    TextField("State directory", text: $server.root)
                    Text("The app opens a loopback tunnel and reads the core credential through SSH. Disconnecting or closing the app leaves server work running.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Server URL", text: $server.url)
                    SecureField("Access token", text: $token)
                    Text("Leave the token empty to retain an existing credential. Credentials are kept in private local files, outside notebook documents.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.textFieldStyle(.roundedBorder)
            if let message { Text(message).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save and Connect") {
                    do { let id = try remote.addServer(server, token: token); remote.choose(id); dismiss() }
                    catch { message = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 570)
    }
}

private struct NotebookRemoteProjects: View {
    @ObservedObject var remote: NotebookRemoteController
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Projects on \(remote.serverName)").font(.title2)
            Text("Download a server copy to reconnect to its existing workers and restore results. Your current notebook stays in place.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(remote.projects.indices, id: \.self) { index in
                        let project = remote.projects[index]
                        if let id = project["id"] as? String, let revision = project["head"] as? String {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(project["title"] as? String ?? id).font(.body)
                                    Text(id).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    Text(project["state"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Download…") { download(id, revision) }
                                    .disabled(saving || remote.busy || project["state"] as? String != "active")
                            }
                        }
                    }
                }.padding(1)
            }.frame(minHeight: 180, maxHeight: 360)
            if !remote.runtimes.isEmpty {
                Text("Current project workers").font(.headline)
                ForEach(remote.runtimes.indices, id: \.self) { index in
                    let runtime = remote.runtimes[index]
                    Text("\(runtime["sheet_id"] as? String ?? "") · \(runtime["state"] as? String ?? "") · epoch \(String((runtime["epoch"] as? String ?? "").prefix(8)))")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 650)
    }
    private func download(_ project: String, _ revision: String) {
        let panel = NSSavePanel()
        panel.title = "Download server notebook"
        panel.nameFieldStringValue = project + ".sputnikbook"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saving = true
        remote.download(project: project, revision: revision, to: url) { success in
            saving = false
            if success { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

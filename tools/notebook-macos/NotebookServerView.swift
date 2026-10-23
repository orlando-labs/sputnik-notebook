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
    @State private var confirmForceStop = false
    private var workerTab: NotebookTab? { model.activeBoard.flatMap { model.controller(for: $0) } ?? model.activeTab }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                workerToolbar(compact: false)
                workerToolbar(compact: true)
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
        .font(.system(size: 11))
        .controlSize(.small)
        .padding(.horizontal, 19).padding(.vertical, 6)
        .background(NotebookPalette.topBar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Worker toolbar")
        .sheet(isPresented: $editServer) { NotebookServerEditor(remote: remote) }
        .sheet(isPresented: $bookSettings) { NotebookBookSettingsView(model: model) }
        .sheet(isPresented: $browse) { NotebookRemoteProjects(remote: remote) }
        .sheet(item: $workerSettings) { tab in
            NotebookWorkerSettingsEditor(model: model, remote: remote, tab: tab,
                document: model.documentIdentity, execution: remote.selected)
        }
        .confirmationDialog("Terminate this sheet's worker?", isPresented: $confirmForceStop, titleVisibility: .visible) {
            Button("Force Stop", role: .destructive) { model.stopExecution(force: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runtime state will be lost. Drafts and the last displayed results stay here. Restart Worker will be required; cells will not be replayed automatically.")
        }
        .confirmationDialog("Publish the local version?", isPresented: $publish, titleVisibility: .visible) {
            Button("Publish local version") { remote.sync(publish: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This updates the server from your local modules, sheets, boards and resources. The previous server revision stays in history. A concurrent server edit will still cause a conflict.")
        }
    }

    private func workerToolbar(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: remote.isSelected ? "server.rack" : "laptopcomputer")
                .foregroundStyle(NotebookPalette.muted)
            Picker("Execution", selection: Binding(get: { remote.selected ?? "local" }, set: { remote.choose($0 == "local" ? nil : $0) })) {
                Text("This Mac").tag("local")
                if let id = remote.selected, !remote.servers.contains(where: { $0.id == id }) {
                    Text("Unavailable server").tag(id)
                }
                ForEach(remote.servers) { server in Text(server.name).tag(server.id) }
            }
            .labelsHidden().frame(maxWidth: compact ? 132 : 170)
            .disabled(model.busy || remote.busy)

            if model.isolatedExecution {
                Text(model.executionLabel)
                    .fontWeight(.medium)
                    .fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(NotebookPalette.sputnik.opacity(0.08), in: Capsule())
                    .accessibilityLabel("Execution · \(model.executionLabel)")
                if let label = model.executingCellLabel {
                    ProgressView().controlSize(.mini)
                    Button { model.showExecutingCell() } label: {
                        Label(label, systemImage: "location.fill").lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canNavigate)
                    .help("Show Running Cell · \(label)")
                    .accessibilityLabel("Show Running Cell")
                    .accessibilityValue(label)
                }
            }
            if remote.isSelected {
                if remote.busy { ProgressView().controlSize(.mini) }
                Text(remote.status).foregroundStyle(.secondary).lineLimit(1).help(remote.status)
            }
            Spacer(minLength: 8)

            Button { editServer = true } label: {
                toolbarLabel("Servers…", systemImage: "server.rack", compact: compact)
            }
            .disabled(model.busy || remote.busy)
            .help("Servers…").accessibilityLabel("Servers…")
            Button { workerSettings = workerTab } label: {
                toolbarLabel("Worker Settings…", systemImage: "slider.horizontal.3", compact: compact)
            }
            .disabled(workerTab == nil || model.busy || remote.busy || model.executingCurrentWorker ||
                (remote.isSelected && (!remote.connected || workerTab?.kind != "sheet")))
            .help("Worker Settings…").accessibilityLabel("Worker Settings…")
            Button("Notebook Settings…", systemImage: "gearshape") { bookSettings = true }
                .labelStyle(.iconOnly).help("Notebook Settings…")
                .accessibilityLabel("Notebook Settings")
                .disabled(model.busy || remote.busy)

            if remote.isSelected {
                if compact {
                    Menu { connectionButtons } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .fixedSize()
                    .help("Server actions").accessibilityLabel("Server actions")
                } else {
                    connectionButtons
                }
            }
            if model.isolatedExecution {
                if model.executingCurrentWorker {
                    Button("Stop") { model.stopExecution() }.disabled(!model.canStop)
                        .help("Cancel the current work")
                    Button("Force Stop…", role: .destructive) { confirmForceStop = true }
                        .disabled(!model.canForceStop)
                        .help("Terminate this sheet's worker")
                } else {
                    Button {
                        if let tab = workerTab { model.perform("restart_worker", tab: tab) }
                    } label: {
                        toolbarLabel("Restart Worker", systemImage: "arrow.clockwise", compact: compact)
                    }
                    .disabled(model.busy)
                    .help("Restart Worker").accessibilityLabel("Restart Worker")
                }
            }
        }
    }

    @ViewBuilder private func toolbarLabel(_ title: String, systemImage: String, compact: Bool) -> some View {
        if compact { Image(systemName: systemImage) }
        else { Text(title).fixedSize() }
    }

    @ViewBuilder private var connectionButtons: some View {
        if remote.connected {
            Button("Sync") { remote.sync() }.disabled(remote.busy || remote.conflict)
            Button("Projects…") { remote.reloadProjects(); browse = true }.disabled(remote.busy)
            Button("Disconnect") { remote.detach() }.disabled(remote.busy)
        } else {
            if remote.hasPending { Button("Reconnect without resending") { remote.discardPending() }.disabled(remote.busy) }
            Button("Reconnect") { remote.reconnect() }.disabled(remote.busy)
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

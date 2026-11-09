import AppKit
import SwiftUI

struct NotebookMarkdownPage: View {
    @ObservedObject var model: NotebookModel
    @Environment(\.colorScheme) private var colorScheme
    let path: String
    @State private var preview = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(path.dropFirst("docs/".count))).font(.headline)
                    Text(path).font(.caption.monospaced()).foregroundStyle(NotebookPalette.muted)
                }
                Spacer()
                if model.markdownDrafts[path]?.modified == true {
                    Text("Modified").font(.caption).foregroundStyle(NotebookPalette.sputnik)
                }
                Button(preview ? "Edit Markdown" : "Preview Markdown") { preview.toggle() }
                Button("Show in Finder") { model.revealBookFile(path) }
                Button("Save Document") { model.perform("save") }
                    .disabled(model.busy || model.markdownDrafts[path]?.modified != true)
            }
            if preview {
                NotebookMarkdownPreview(source: model.markdownDrafts[path]?.source ?? "",
                                        theme: NotebookMarkdownPreview.colors(dark: colorScheme == .dark))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeEditor(text: Binding(
                    get: { model.markdownDrafts[path]?.source ?? "" },
                    set: { model.editMarkdown(path, source: $0) }
                ), language: .markdown, fillsHeight: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
    }
}

struct NotebookAttachmentsPage: View {
    @ObservedObject var model: NotebookModel
    @State private var folder = "resources"
    @State private var items: [NotebookBookFiles.Item] = []
    @State private var moving: NotebookBookFiles.Item?
    @State private var removing: NotebookBookFiles.Item?
    @State private var name = ""
    @State private var naming = false
    private var importing: Bool { model.importingBookFiles }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if folder != "resources" {
                    Button("Up One Folder", systemImage: "arrow.up") {
                        folder = folder.split(separator: "/").dropLast().joined(separator: "/")
                        refresh()
                    }
                }
                Text(folder).font(.headline.monospaced()).lineLimit(1)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                Button("Show in Finder") { model.revealBookFile(folder) }
                Button("New Folder…") { name = ""; naming = true }
                Button("Attach Files or Folder…", action: attach)
            }
            .disabled(importing)
            if importing { ProgressView("Copying attachments…").controlSize(.small) }
            if items.isEmpty {
                Text("No attachments in this folder.").foregroundStyle(NotebookPalette.muted)
                Spacer()
            } else {
                List(items) { item in
                    HStack {
                        Button {
                            if item.directory { folder = item.path; refresh() }
                            else { open(item.path) }
                        } label: {
                            Label(item.name, systemImage: item.directory ? "folder" : "doc")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        Menu {
                            Button("Show in Finder") { model.revealBookFile(item.path) }
                            Button("Rename or Move…") { moving = item; name = item.path; naming = true }
                            Button("Move to Trash…", role: .destructive) { removing = item }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("Actions for " + item.name)
                    }
                }
                .scrollContentBackground(.hidden)
                .disabled(importing)
            }
        }
        .padding(18)
        .task { refresh() }
        .sheet(isPresented: $naming, onDismiss: { moving = nil }) {
            VStack(alignment: .leading, spacing: 12) {
                Text(moving == nil ? "New Folder" : "Rename or Move").font(.headline)
                TextField(moving == nil ? "Folder name" : "Path inside resources/", text: $name)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { naming = false }.keyboardShortcut(.cancelAction)
                    Button(moving == nil ? "Create" : "Move", action: commitName)
                        .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20).frame(width: 440)
        }
        .confirmationDialog("Move attachment to Trash?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let removing {
                    change { try $0.trash(removing.path) }
                }
                removing = nil
            }
        } message: { Text(removing?.path ?? "") }
    }

    private func refresh() {
        do { items = try model.bookFiles?.list(folder) ?? [] }
        catch { model.error = error.localizedDescription; items = [] }
    }

    private func change(_ operation: (NotebookBookFiles) throws -> Void) {
        guard let files = model.bookFiles else { return }
        do { try operation(files); model.bookFilesChanged(); refresh() }
        catch { model.error = error.localizedDescription }
    }

    private func commitName() {
        let path = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let moving {
            guard path.hasPrefix("resources/") else { model.error = "Choose a destination inside resources/."; return }
            change { try $0.move(moving.path, to: path) }
        } else {
            guard !path.contains("/") else { model.error = "Enter a single folder name."; return }
            change { try $0.makeFolder(folder + "/" + path) }
        }
        naming = false
    }

    private func open(_ path: String) {
        do {
            guard let url = try model.bookFiles?.url(path), NSWorkspace.shared.open(url) else {
                throw NotebookFailure(message: "Could not open this attachment.")
            }
        } catch { model.error = error.localizedDescription }
    }

    private func attach() {
        guard let files = model.bookFiles, !importing else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls, target = folder, identity = model.documentIdentity
        model.importingBookFiles = true
        Task { @MainActor in
            let errors = await Task.detached(priority: .userInitiated) {
                urls.compactMap { url -> String? in
                    do { try files.importItem(url, into: target); return nil }
                    catch { return "\(url.lastPathComponent): \(error.localizedDescription)" }
                }
            }.value
            model.importingBookFiles = false
            guard model.documentIdentity == identity else { return }
            model.bookFilesChanged()
            refresh()
            if !errors.isEmpty { model.error = errors.joined(separator: "\n") }
        }
    }
}

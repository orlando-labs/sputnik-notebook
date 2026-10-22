import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotebookFilePreview {
    let name: String, summary: String, text: String
    static func read(_ url: URL) throws -> Self {
        let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard metadata.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        let size = metadata.fileSize ?? 0
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 65536) ?? Data()
        var raw = String(data: bytes, encoding: .utf8)
        if raw == nil && size > bytes.count {
            for tail in 1...min(3, bytes.count) { if let text = String(data: bytes.dropLast(tail), encoding: .utf8) { raw = text; break } }
        }
        let ext = url.pathExtension.lowercased()
        var details = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        if ext == "json", size <= 65536, let object = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) {
            if let rows = object as? [Any] { details += " · JSON · \(rows.count) items" }
            else if let fields = object as? [String: Any] { details += " · JSON · \(fields.count) fields" }
            else { details += " · JSON scalar" }
        } else if ext == "csv", let raw {
            let records = csvShape(raw)
            details += " · CSV · \(records.columns) columns · \(size > bytes.count ? "at least " : "")\(records.rows) records"
        }
        if size > bytes.count { details += " · preview limited to 64 KiB" }
        return Self(name: url.lastPathComponent, summary: details, text: raw.map { String($0.prefix(16000)) } ?? "Binary file · no text preview")
    }
    static func csvShape(_ text: String) -> (rows: Int, columns: Int) {
        var quoted = false, rows = 0, columns = 1, width = 1, previousCR = false
        let chars = Array(text); var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { i += 1 }
                else { quoted.toggle() }
            } else if !quoted {
                if c == "," { width += 1 }
                if c == "\n" || c == "\r" || c == "\r\n" {
                    if !(c == "\n" && previousCR) { rows += 1; columns = max(columns, width); width = 1 }
                }
            }
            previousCR = !quoted && c == "\r"; i += 1
        }
        if !text.isEmpty && !text.hasSuffix("\n") && !text.hasSuffix("\r") && !text.hasSuffix("\r\n") { rows += 1; columns = max(columns, width) }
        return (rows, columns)
    }
}

struct NotebookFileInputView: View {
    @ObservedObject var model: NotebookModel
    let input: NotebookProjectInput
    let extensions: String
    @State private var preview: NotebookFilePreview?
    @State private var error: String?
    @State private var generation = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Choose file…", systemImage: "doc.badge.plus", action: choose).disabled(model.busy)
                if !input.editingText.isEmpty { Button("Clear") { model.setProjectInput(input, text: "") }.disabled(model.busy) }
            }
            Text(preview?.name ?? (input.editingText.isEmpty ? "Choose or drop a file" : URL(fileURLWithPath: input.editingText).lastPathComponent)).font(.callout).textSelection(.enabled)
            Text("External file reference · file contents are not copied into the project.").font(.caption2).foregroundStyle(NotebookPalette.muted)
            if let preview {
                Text(preview.summary).font(.caption).foregroundStyle(NotebookPalette.muted)
                DisclosureGroup("Preview") { ScrollView([.horizontal, .vertical]) { Text(preview.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 140) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(NotebookPalette.error) }
        }.onAppear(perform: refresh).onChange(of: input.value_json) { refresh() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !model.busy, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { DispatchQueue.main.async { accept(url) } } }
            return true
        }
    }
    private var allowed: [String] { extensions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ".", with: "") }.filter { !$0.isEmpty } }
    private func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if !allowed.isEmpty { panel.allowedContentTypes = allowed.compactMap { UTType(filenameExtension: $0) } }
        if panel.runModal() == .OK, let url = panel.url { accept(url) }
    }
    private func accept(_ url: URL) {
        guard url.isFileURL, allowed.isEmpty || allowed.contains(url.pathExtension.lowercased()) else { error = "Choose a file with an allowed extension: \(extensions)."; return }
        do { _ = try NotebookFilePreview.read(url); model.setProjectInput(input, text: url.path) }
        catch { self.error = error.localizedDescription }
    }
    private func refresh() {
        preview = nil; error = nil; generation = UUID()
        guard !input.editingText.isEmpty else { return }
        let url = URL(fileURLWithPath: input.editingText), revision = generation
        Task {
            let result = await Task.detached { Result { try NotebookFilePreview.read(url) } }.value
            guard revision == generation else { return }
            switch result { case .success(let value): preview = value; case .failure(let failure): error = failure.localizedDescription }
        }
    }
}

struct NotebookArtifact: Identifiable {
    let id: String, url: URL, title: String, caption: String
    func belongsToProject(_ project: String) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: project).resolvingSymlinksInPath().path + "/")
    }
    static func capture(_ table: NotebookTableSnapshot?, project: String) -> [Self] {
        guard let table, let path = table.columns.firstIndex(where: { $0.title == "path" }) else { return [] }
        let name = table.columns.firstIndex { $0.title == "name" }, caption = table.columns.firstIndex { $0.title == "caption" }
        return table.rows.prefix(128).compactMap { row in
            guard case .text(let value) = row.values[path], !value.isEmpty, !value.utf8.contains(0) else { return nil }
            let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : URL(fileURLWithPath: project).appendingPathComponent(value)
            return Self(id: row.id, url: url.standardizedFileURL, title: name.map { row.values[$0].text } ?? url.lastPathComponent, caption: caption.map { row.values[$0].text } ?? "")
        }
    }
}
struct NotebookArtifactBrowser: View {
    let cell: NotebookCell, project: String
    var stale = false
    var sourceLabel = "Cell result"
    var updatedAt: Date? = nil
    @State private var artifacts: [NotebookArtifact] = []
    @State private var selected: String?
    @State private var preview: NotebookFilePreview?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sourceLabel + (updatedAt.map { " · " + $0.formatted(date: .omitted, time: .standard) } ?? "")).font(.caption2).foregroundStyle(NotebookPalette.muted)
            if artifacts.isEmpty { Text("Return records with path, name and optional caption from the source cell.").font(.callout).foregroundStyle(NotebookPalette.muted) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(artifacts) { artifact in
                        let attributes = try? artifact.url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                        VStack(alignment: .leading, spacing: 5) {
                            Label(artifact.title, systemImage: attributes?.isRegularFile == true ? "doc" : "exclamationmark.triangle").font(.callout.bold())
                            if !artifact.caption.isEmpty { Text(artifact.caption).font(.caption) }
                            Text((artifact.belongsToProject(project) ? "Project file" : "External file") + " · " + (attributes?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "Unavailable"))
                                .font(.caption2).foregroundStyle(NotebookPalette.muted)
                            HStack {
                                Button("Preview") { do { preview = try NotebookFilePreview.read(artifact.url); selected = artifact.id; error = nil } catch { self.error = error.localizedDescription } }.disabled(attributes?.isRegularFile != true)
                                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([artifact.url]) }
                                Button("Save copy…") { save(artifact) }.disabled(attributes?.isRegularFile != true)
                            }.controlSize(.small)
                            if selected == artifact.id, let preview { ScrollView([.horizontal, .vertical]) { Text(preview.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(height: 120) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
            }.frame(maxHeight: 300)
            if stale { Label("Previous run · stale", systemImage: "clock").font(.caption).foregroundStyle(NotebookPalette.sputnik) }
            if artifacts.count == 128 { Text("Display limited to 128 files.").font(.caption2).foregroundStyle(NotebookPalette.muted) }
            if let error { Text(error).font(.caption).foregroundStyle(NotebookPalette.error) }
        }.onAppear(perform: refresh)
        .onChange(of: cell.result_format?.table_json) { selected = nil; preview = nil; refresh() }
    }
    private func refresh() { artifacts = NotebookArtifact.capture(NotebookTableSnapshot.decode(cell.result_format?.table_json ?? ""), project: project) }
    private func save(_ artifact: NotebookArtifact) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = artifact.url.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bytes = try Data(contentsOf: artifact.url, options: .mappedIfSafe)
            try bytes.write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
}

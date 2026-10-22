import SwiftUI
import AppKit

struct NotebookMediaAssetsView: View {
    @ObservedObject var model: NotebookModel
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [NotebookUnusedMedia] = []
    @State private var selected: Set<String> = []
    @State private var error: String?
    @State private var archived: URL?
    private var project: URL { URL(fileURLWithPath: model.snapshot?.path ?? "") }
    private var currentSources: String {
        (model.snapshot?.tabs ?? []).map { tab in tab.cells.map { model.source(for: $0, in: tab) }.joined(separator: "\n") }.joined(separator: "\n")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Unused media").font(.title2.bold())
            Text("Generated files with no references in the saved notebook or current code. Review the list, then move selected files into .notebook-unused inside this notebook. You can restore their original paths from that folder.")
                .font(.callout).foregroundStyle(NotebookPalette.muted)
            List(candidates, selection: $selected) { file in
                HStack { Text(file.id).font(.system(.caption, design: .monospaced)); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file)).foregroundStyle(NotebookPalette.muted) }.tag(file.id)
            }.frame(minHeight: 230)
            Text("\(candidates.count) files · \(selected.count) selected").font(.caption)
            if let error { Text(error).foregroundStyle(NotebookPalette.error) }
            if let archived { Button("Show archive in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: archived.path) } }
            HStack {
                Button("Refresh") { refresh() }
                Spacer()
                Button("Move selected to archive") {
                    do { archived = try NotebookUnusedMedia.archive(selected, project: project, sources: currentSources); refresh() }
                    catch { self.error = error.localizedDescription }
                }.disabled(selected.isEmpty || model.busy || model.remote.isSelected)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 700, height: 480).background(NotebookPalette.canvas).foregroundStyle(NotebookPalette.ink)
            .onAppear { refresh() }
    }
    private func refresh() {
        do { candidates = try NotebookUnusedMedia.scan(project: project, sources: currentSources); selected = []; error = nil }
        catch { self.error = error.localizedDescription }
    }
}

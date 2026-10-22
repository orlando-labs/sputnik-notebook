import AppKit
import SwiftUI

struct NotebookWelcomeView: View {
    let recentProjects: () -> [URL]
    let newProject: () -> Void
    let openProject: () -> Void
    let openRecentProject: (URL) -> Void
    @State private var projects: [URL] = []

    // AppKit persists the history and resolves moved documents. Keep its order,
    // while omitting missing packages and duplicate spellings of the same path.
    static func availableRecentProjects(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            guard url.isFileURL, url.pathExtension.lowercased() == "sputnikbook" else { return nil }
            let url = url.standardizedFileURL
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
                  directory.boolValue, seen.insert(url.path).inserted else { return nil }
            return url
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            ZStack {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .fill(NotebookPalette.sputnik.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(NotebookPalette.sputnik)
            }
            .padding(.bottom, 22)

            Text("Sputnik Notebook")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(NotebookPalette.ink)
            Text("A quiet workspace for interactive Sputnik programs.")
                .font(.system(size: 13))
                .foregroundStyle(NotebookPalette.muted)
                .padding(.top, 7)

            HStack(spacing: 10) {
                Button(action: newProject) {
                    Label("New Notebook", systemImage: "plus")
                        .frame(minWidth: 138)
                }
                .buttonStyle(.borderedProminent)
                .tint(NotebookPalette.sputnik)
                .help("Create a new Sputnik notebook project")

                Button(action: openProject) {
                    Label("Open Notebook", systemImage: "folder")
                        .frame(minWidth: 138)
                }
                .buttonStyle(.bordered)
                .help("Open an existing Sputnik notebook project")
            }
            .padding(.top, 24)

            VStack(alignment: .leading, spacing: 10) {
                Text("Recent Notebooks")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotebookPalette.slate)
                if projects.isEmpty {
                    Text("Notebooks you open will appear here.")
                        .font(.system(size: 12))
                        .foregroundStyle(NotebookPalette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(NotebookPalette.card, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(projects, id: \.path) { url in
                                NotebookRecentProjectRow(url: url) { openRecentProject(url) }
                            }
                        }
                        .padding(4)
                    }
                    .frame(height: min(CGFloat(projects.count) * 58 + 8, 240))
                    .background(NotebookPalette.card)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(NotebookPalette.rule.opacity(0.5), lineWidth: 1))
                    .accessibilityIdentifier("recent-notebooks")
                }
            }
            .frame(width: 480)
            .padding(.top, 24)

            Text("Projects keep sheets, bundled modules, and source files together.")
                .font(.system(size: 11))
                .foregroundStyle(NotebookPalette.muted)
                .padding(.top, 17)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotebookPalette.canvas.ignoresSafeArea())
        .onAppear(perform: refreshRecentProjects)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshRecentProjects()
        }
    }

    private func refreshRecentProjects() {
        projects = Self.availableRecentProjects(recentProjects())
    }
}

private struct NotebookRecentProjectRow: View {
    let url: URL
    let open: () -> Void
    @State private var hovering = false

    private var title: String { url.deletingPathExtension().lastPathComponent }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "book.closed")
                    .font(.system(size: 18))
                    .foregroundStyle(NotebookPalette.sputnik)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(NotebookPalette.ink)
                    Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11))
                        .foregroundStyle(NotebookPalette.muted)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotebookPalette.muted)
            }
            .padding(.horizontal, 12)
            .frame(height: 58)
            .contentShape(Rectangle())
            .background(NotebookPalette.sputnik.opacity(hovering ? 0.09 : 0),
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url.path)
        .accessibilityLabel("Open \(title)")
        .accessibilityValue(url.path)
        .accessibilityIdentifier("recent-notebook:\(url.path)")
    }
}

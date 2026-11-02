import AppKit
import SwiftUI

struct NotebookWelcomeView: View {
    @ObservedObject var library: NotebookLibrary
    let newProject: () -> Void
    let openProject: () -> Void
    let openLibraryProject: (URL) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(NotebookPalette.sputnik)
                    .frame(width: 72, height: 72)
                    .background(NotebookPalette.sputnik.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 21))
                    .padding(.bottom, 20)
                Text("Sputnik Notebook")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(NotebookPalette.ink)
                Text("A quiet workspace for interactive Sputnik programs.")
                    .font(.system(size: 13))
                    .foregroundStyle(NotebookPalette.muted)
                    .padding(.top, 7)
                HStack(spacing: 10) {
                    Button(action: newProject) {
                        Label("New Notebook", systemImage: "plus").frame(minWidth: 138)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(NotebookPalette.sputnik)
                    Button(action: openProject) {
                        Label("Open Notebook", systemImage: "folder").frame(minWidth: 138)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 24)
                libraryView.padding(.top, 28)
                Text("Projects keep sheets, bundled modules, and source files together.")
                    .font(.system(size: 11))
                    .foregroundStyle(NotebookPalette.muted)
                    .padding(.top, 17)
            }
            .frame(maxWidth: 680)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotebookPalette.canvas.ignoresSafeArea())
        .onAppear { library.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            library.refresh()
        }
        .alert("Notebook Library", isPresented: Binding(
            get: { library.error != nil }, set: { if !$0 { library.error = nil } }
        )) { Button("OK", role: .cancel) { library.error = nil } }
        message: { Text(library.error ?? "") }
    }

    private var libraryView: some View {
        let sorted = library.sortedProjects
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { library.expanded.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: library.expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).frame(width: 12)
                        Text("Notebook Library").font(.system(size: 14, weight: .semibold))
                        Text("\(library.projects.count)").font(.system(size: 12)).foregroundStyle(NotebookPalette.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(library.expanded ? "Collapse Notebook Library" : "Expand Notebook Library")
                .accessibilityIdentifier("notebook-library-toggle")
                Spacer()
                Button(action: chooseDirectory) { Label("Add from Folder…", systemImage: "folder.badge.plus") }
                    .disabled(library.scanning)
                    .help("Scan a folder and its subfolders for Sputnik notebooks")
                    .accessibilityIdentifier("notebook-library-scan")
            }
            if library.scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning folder and subfolders…").font(.system(size: 12))
                }
                .foregroundStyle(NotebookPalette.muted)
            } else if let message = library.scanMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(NotebookPalette.muted)
            }
            if library.expanded {
                HStack {
                    Text("Sort by").font(.system(size: 11)).foregroundStyle(NotebookPalette.muted)
                    Picker("Sort by", selection: $library.sort) {
                        ForEach(NotebookLibrarySort.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                    .accessibilityIdentifier("notebook-library-sort")
                    Spacer()
                    Button { library.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh file availability").accessibilityLabel("Refresh library")
                }
                if library.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your notebooks, together.").font(.system(size: 13, weight: .medium))
                        Text("Open a notebook or add a folder to build your library.")
                            .font(.system(size: 12)).foregroundStyle(NotebookPalette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(sorted) { project in
                            NotebookLibraryProjectRow(project: project, expanded: Binding(
                                get: { library.expandedProjects.contains(project.id) },
                                set: { if $0 { library.expandedProjects.insert(project.id) }
                                       else { library.expandedProjects.remove(project.id) } }
                            )) {
                                library.refresh()
                                if library.projects.first(where: { $0.id == project.id })?.missing == false {
                                    openLibraryProject(project.url)
                                }
                            }
                            if project.id != sorted.last?.id {
                                Divider().overlay(NotebookPalette.rule.opacity(0.4))
                            }
                        }
                    }
                    .background(NotebookPalette.card, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(NotebookPalette.rule.opacity(0.5)))
                    .accessibilityIdentifier("notebook-library")
                }
            }
        }
        .foregroundStyle(NotebookPalette.ink)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Add Notebooks from Folder"
        panel.message = "Notebooks in this folder and its subfolders will be added to your library."
        panel.prompt = "Scan Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        let accept: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            library.expanded = true
            library.scan(directory: url)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: accept) }
        else { panel.begin(completionHandler: accept) }
    }
}

struct NotebookLibraryProjectRow: View {
    let project: NotebookLibraryProject
    @Binding var expanded: Bool
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).frame(width: 16, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(expanded ? "Hide" : "Show") details for \(project.title)")
                .accessibilityIdentifier("library-details:\(project.path)")
                if project.missing {
                    projectLabel.help(project.path)
                } else {
                    Button(action: open) { projectLabel }
                        .buttonStyle(.plain)
                        .help(project.path)
                        .accessibilityLabel("Open \(project.title)")
                        .accessibilityIdentifier("library-notebook:\(project.path)")
                }
                if project.missing {
                    Text("Missing").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NotebookPalette.error)
                }
                Button { reveal() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).disabled(project.missing)
                    .help("Show in Finder").accessibilityLabel("Show \(project.title) in Finder")
            }
            .padding(.vertical, 12)
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(project.path).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 24) {
                        date("Last opened", project.lastOpened, fallback: project.importedRecent ? "Before library import" : "Never")
                        date("Created", project.created, fallback: "Unknown")
                    }
                    if project.missing {
                        Text("Notebook not found at this path. Reconnect its drive or restore the file, then refresh the library.")
                            .font(.system(size: 11)).foregroundStyle(NotebookPalette.error)
                    }
                    HStack {
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(project.path, forType: .string)
                        }
                        .accessibilityIdentifier("library-copy-path:\(project.path)")
                        Button("Show in Finder", action: reveal).disabled(project.missing)
                    }
                    .controlSize(.small)
                }
                .foregroundStyle(NotebookPalette.muted)
                .padding(.leading, 28).padding(.bottom, 16)
            }
        }
        .padding(.horizontal, 12)
    }

    private var projectLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: project.missing ? "exclamationmark.triangle" : "book.closed")
                .font(.system(size: 18))
                .foregroundStyle(project.missing ? NotebookPalette.error : NotebookPalette.sputnik)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(project.title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NotebookPalette.ink)
                Text((project.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11)).foregroundStyle(NotebookPalette.muted)
            }
            .lineLimit(1).truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    private func date(_ label: String, _ value: Date?, fallback: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10, weight: .medium))
            Text(value?.formatted(date: .abbreviated, time: .shortened) ?? fallback).font(.system(size: 11))
        }
    }
    private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
}

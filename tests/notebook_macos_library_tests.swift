import AppKit
import SwiftUI

private struct LibraryFailure: Error { let message: String }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw LibraryFailure(message: message) }
}

@main
private enum NotebookLibraryTests {
    @MainActor static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("sputnik-library-\(UUID().uuidString)")
        let domain = "org.sputniklang.notebook.library-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { try? manager.removeItem(at: root); defaults.removePersistentDomain(forName: domain) }
        do {
            let alpha = root.appendingPathComponent("Alpha.sputnikbook")
            let beta = root.appendingPathComponent("subfolder/Beta.sputnikbook")
            let missing = root.appendingPathComponent("Research Notes.sputnikbook")
            let ignored = root.appendingPathComponent("notes.txt")
            for url in [alpha, beta, alpha.appendingPathComponent("Internal.sputnikbook"),
                        root.appendingPathComponent(".hidden/Hidden.sputnikbook")] {
                try manager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            try Data("ordinary file".utf8).write(to: ignored)
            try Data().write(to: root.appendingPathComponent("Not a package.sputnikbook"))
            try manager.createSymbolicLink(at: root.appendingPathComponent("cycle"), withDestinationURL: root)
            let older = Date(timeIntervalSince1970: 1_600_000_000)
            let newer = older.addingTimeInterval(86_400)
            try manager.setAttributes([.creationDate: older], ofItemAtPath: alpha.path)
            try manager.setAttributes([.creationDate: newer], ofItemAtPath: beta.path)
            let duplicate = root.appendingPathComponent("subfolder/../Alpha.sputnikbook")
            let library = NotebookLibrary(defaults: defaults,
                recentProjects: [beta, missing, alpha, duplicate, ignored, URL(string: "https://example.com/a.sputnikbook")!])
            try check(library.projects.map(\.path) == [beta, missing, alpha].map(\.path), "migration preserves order, missing entries and unique file paths")
            try check(library.sort == .lastOpened && library.expanded, "library starts expanded in recent order")
            try check(library.projects[1].missing && !library.projects[0].missing, "missing projects are explicitly marked")
            try check(library.projects.allSatisfy { $0.lastOpened == nil }, "migration must not invent opening dates")
            library.sort = .name
            try check(library.sortedProjects.map(\.title) == ["Alpha", "Beta", "Research Notes"], "alphabetical sorting")
            library.sort = .created
            try check(library.sortedProjects.map(\.title) == ["Beta", "Alpha", "Research Notes"], "newest creation date first; unknown dates last")
            let scan = try NotebookLibraryScan.directory(root)
            try check(Set(scan.urls.map(\.path)) == Set([alpha.path, beta.path]), "recursive scanning skips hidden folders, symlinks, plain files and package contents: \(scan.urls.map(\.path)) vs \([alpha.path, beta.path])")
            let single = try NotebookLibraryScan.directory(alpha)
            try check(single.urls == [alpha], "scanning a notebook root adds just that package")
            let fresh = NotebookLibrary(defaults: nil)
            try check(fresh.add(scan.urls) == 2 && fresh.add(scan.urls) == 0, "repeat scans do not duplicate projects")
            try check(fresh.add([root.appendingPathComponent("cycle/Alpha.sputnikbook")]) == 0,
                      "the same notebook reached through a directory symlink must not be duplicated")
            try check(fresh.projects.allSatisfy { $0.lastOpened == nil && !$0.importedRecent }, "scanning never counts as opening")
            library.sort = .lastOpened
            library.recordOpened(alpha, at: newer)
            library.recordOpened(beta, at: older)
            try check(library.sortedProjects.first?.path == alpha.path, "recency uses opening date")
            library.recordOpened(beta, at: newer.addingTimeInterval(1))
            try check(library.sortedProjects.first?.path == beta.path && library.projects.count == 3, "reopening moves an existing entry without duplicates")
            let created = library.projects.first { $0.path == alpha.path }!.created
            try manager.removeItem(at: alpha)
            library.refresh()
            try check(library.projects.first { $0.path == alpha.path }?.missing == true, "deleted notebook remains marked missing")
            try check(library.projects.first { $0.path == alpha.path }?.name == "Alpha" &&
                      library.projects.first { $0.path == alpha.path }?.title == "Alpha",
                      "a missing file keeps its saved name; missing is a separate state")
            try check(library.projects.first { $0.path == alpha.path }?.created == created, "missing entry retains its creation date")
            library.sort = .name
            library.expanded = false
            let restored = NotebookLibrary(defaults: defaults, recentProjects: [])
            try check(restored.projects == library.projects && restored.sort == .name && !restored.expanded, "catalog, missing status, sorting and disclosure survive relaunch")
            try manager.createDirectory(at: alpha, withIntermediateDirectories: false)
            restored.refresh()
            try check(restored.projects.first { $0.path == alpha.path }?.missing == false, "restored notebook becomes available again")
            await withCheckedContinuation { continuation in
                restored.scan(directory: root) { continuation.resume() }
            }
            try check(!restored.scanning && restored.scanMessage?.contains("Added 0") == true, "async scan reports deduplication and finishes")
            let beforeFailure = restored.projects
            await withCheckedContinuation { continuation in
                restored.scan(directory: root.appendingPathComponent("does-not-exist")) { continuation.resume() }
            }
            try check(restored.error != nil && restored.projects == beforeFailure, "scan failure leaves the library intact")
            restored.error = nil
            try await render(library: restored)
            print("notebook macOS library tests passed")
        } catch {
            fputs("notebook library failure: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor private static func render(library: NotebookLibrary) async throws {
        library.expanded = true
        let view = NSHostingView(rootView: NotebookWelcomeView(library: library,
            newProject: {}, openProject: {}, openLibraryProject: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 250_000_000)
        try capture(view, name: "library.png")
        func buttons(_ parent: NSView) -> [NSButton] {
            (parent as? NSButton).map { [$0] } ?? parent.subviews.flatMap(buttons)
        }
        let missing = library.projects.first { $0.missing }!
        if let details = buttons(view).first(where: { $0.accessibilityIdentifier() == "library-details:\(missing.path)" }) {
            details.performClick(nil)
        } else {
            // Plain SwiftUI buttons have no NSButton backing. This fixed-size
            // fixture has three 60-point rows beginning at y=334.
            try click(window: window, x: 180, yFromTop: 486)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        try capture(view, name: "library-details.png")
        try check(library.expandedProjects.contains(missing.path), "missing project details can be expanded")
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: theme)
            window.setContentSize(NSSize(width: 930, height: 640))
            try await Task.sleep(nanoseconds: 150_000_000)
            try check(view.fittingSize.width <= 931, "welcome fits the minimum window width")
            try capture(view, name: "library-\(theme.rawValue).png")
        }
        if let toggle = buttons(view).first(where: { $0.accessibilityIdentifier() == "notebook-library-toggle" }) {
            toggle.performClick(nil)
        } else {
            // The header keeps the same top inset at the minimum window size.
            try click(window: window, x: 170, yFromTop: 270)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(!library.expanded, "library disclosure collapses the list")
        try capture(view, name: "library-collapsed.png")
        window.contentView = NSHostingView(rootView: NotebookWelcomeView(library: NotebookLibrary(defaults: nil),
            newProject: {}, openProject: {}, openLibraryProject: { _ in }))
        try await Task.sleep(nanoseconds: 150_000_000)
        try capture(window.contentView!, name: "library-empty.png")
    }

    @MainActor private static func click(window: NSWindow, x: CGFloat, yFromTop: CGFloat) throws {
        let view = window.contentView!
        let point = view.convert(NSPoint(x: x, y: view.isFlipped ? yFromTop : view.bounds.height - yFromTop), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw LibraryFailure(message: "Cannot synthesize disclosure click")
            }
            window.sendEvent(event)
        }
    }

    @MainActor private static func capture(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw LibraryFailure(message: "library did not render")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let index = CommandLine.arguments.firstIndex(of: "--output"), index + 1 < CommandLine.arguments.count else { return }
        let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}

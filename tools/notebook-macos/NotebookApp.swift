import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
enum SputnikNotebookApplication {
    static func main() {
        // A packaged OpenSSL build must not depend on Finder's working
        // directory or Homebrew's certificate path on the build machine.
        if getenv("SSL_CERT_FILE") == nil,
           let certificates = Bundle.main.path(forResource: "ca-certificates", ofType: "crt") {
            setenv("SSL_CERT_FILE", certificates, 0)
        }
        let application = NSApplication.shared
        let delegate = NotebookAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

final class NotebookAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let model = NotebookModel()
    private let preferences = NotebookPreferences(defaults:
        CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--showcase-test")
            ? nil : UserDefaults.standard)
    private var settingsWindow: NSWindow?
    private var window: NSWindow!
    private var allowClose = false
    private var terminating = false
    private var pendingOpen: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationIcon()
        preferences.applyAppearance()
        installMenus()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 840),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Sputnik Notebook"
        window.minSize = NSSize(width: 920, height: 600)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SputnikNotebookWorkspace")
        window.delegate = self
        window.contentView = NSHostingView(rootView: NotebookAppearanceView(
            preferences: preferences, content: NotebookView(model: model)))
        window.center()
        model.requestNew = { [weak self] in self?.newProject(nil) }
        model.requestOpen = { [weak self] in self?.openProject(nil) }
        model.requestDependency = { [weak self] in self?.addDependency() }
        model.onChange = { [weak self] in self?.refreshWindow() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--showcase-test"), arguments.count > index + 1 {
            runShowcase(project: URL(fileURLWithPath: arguments[index + 1]), arguments: arguments)
        } else if let index = arguments.firstIndex(of: "--smoke-test"), arguments.count > index + 1 {
            runSmoke(project: URL(fileURLWithPath: arguments[index + 1]), arguments: arguments)
        } else if let pendingOpen {
            open(pendingOpen)
        } else if let path = arguments.dropFirst().first(where: { $0.hasSuffix(".sputnikbook") }) {
            open(URL(fileURLWithPath: path))
        }
    }

    private func installApplicationIcon() {
        // Finder uses CFBundleIconFile for the .app. The unbundled executable
        // also needs explicit Dock content after AppKit has registered its tile.
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            ?? Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("AppIcon.icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApp.applicationIconImage = icon
        let tile = NSApp.dockTile
        let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
        view.image = icon
        view.imageScaling = .scaleProportionallyUpOrDown
        tile.contentView = view
        tile.display()
    }

    private func refreshWindow() {
        guard window != nil else { return }
        window.title = model.snapshot.map { "\($0.title) — Sputnik Notebook" } ?? "Sputnik Notebook"
        window.isDocumentEdited = model.hasUnsavedChanges
        window.representedURL = model.snapshot.map { URL(fileURLWithPath: $0.path) }
    }

    private func installMenus() {
        let menu = NSMenu()
        let app = NSMenu()
        add("About Sputnik Notebook", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), key: "", to: app, target: NSApp)
        app.addItem(.separator())
        add("Settings…", action: #selector(showSettings(_:)), key: ",", to: app)
        app.addItem(.separator())
        add("Quit Sputnik Notebook", action: #selector(NSApplication.terminate(_:)), key: "q", to: app, target: NSApp)
        attach("Sputnik Notebook", submenu: app, to: menu)

        let file = NSMenu(title: "File")
        add("New Notebook…", action: #selector(newProject(_:)), key: "n", to: file)
        add("Open…", action: #selector(openProject(_:)), key: "o", to: file)
        file.addItem(.separator())
        add("Save Current Tab", action: #selector(save(_:)), key: "s", to: file)
        let saveAll = add("Save All Tabs", action: #selector(saveAll(_:)), key: "s", to: file)
        saveAll.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        add("Close", action: #selector(closeWindow(_:)), key: "w", to: file)
        attach("File", submenu: file, to: menu)

        let edit = NSMenu(title: "Edit")
        add("Undo", action: Selector(("undo:")), key: "z", to: edit, target: nil)
        let redo = add("Redo", action: Selector(("redo:")), key: "z", to: edit, target: nil)
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            add(title, action: Selector(action), key: key, to: edit, target: nil)
        }
        attach("Edit", submenu: edit, to: menu)

        let notebook = NSMenu(title: "Notebook")
        add("Run Selected Cell", action: #selector(runCell(_:)), key: "\r", to: notebook)
        let all = add("Run All Cells", action: #selector(runAll(_:)), key: "\r", to: notebook)
        all.keyEquivalentModifierMask = [.command, .shift]
        add("Add Code Cell", action: #selector(addCell(_:)), key: "\r", to: notebook).keyEquivalentModifierMask = [.command, .option]
        add("Add Text Block", action: #selector(addText(_:)), key: "t", to: notebook).keyEquivalentModifierMask = [.command, .option]
        notebook.addItem(.separator())
        add("Apply Saved Modules", action: #selector(applyModules(_:)), key: "a", to: notebook).keyEquivalentModifierMask = [.command, .shift]
        notebook.addItem(.separator())
        add("Stop Execution", action: #selector(stopExecution(_:)), key: ".", to: notebook)
        attach("Notebook", submenu: notebook, to: menu)
        NSApp.mainMenu = menu
    }

    @discardableResult
    private func add(_ title: String, action: Selector, key: String, to menu: NSMenu,
                     target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        // Responder-chain actions deliberately have nil targets.
        item.target = target ?? (["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"].contains(NSStringFromSelector(action)) ? nil : self)
        menu.addItem(item)
        return item
    }
    private func attach(_ title: String, submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(showSettings(_:)) { return true }
        if let settingsWindow, item.action == #selector(closeWindow(_:)), NSApp.keyWindow === settingsWindow { return true }
        if item.action == #selector(stopExecution(_:)) { return model.canStop }
        guard !model.busy, !model.boardEditorOpen else { return false }
        switch item.action {
        case #selector(save(_:)), #selector(saveAll(_:)), #selector(runAll(_:)):
            return model.snapshot != nil
        case #selector(runCell(_:)):
            return model.activeBoard == nil && model.selectedCell?.kind == "code"
        case #selector(addCell(_:)), #selector(addText(_:)), #selector(applyModules(_:)):
            return model.activeBoard == nil && model.activeTab?.kind == "sheet"
        default: return true
        }
    }

    // Structural operations have already been saved explicitly. Discard here
    // refers only to unsaved editor buffers, never to deleting project files.
    private func resolveUnsaved(_ continuation: @escaping () -> Void) {
        guard !model.boardEditorOpen else {
            model.error = "Save or cancel the board designer before closing or replacing this project."
            return
        }
        guard !model.busy else {
            model.error = "An evaluation is still running. Wait for it to finish before closing or replacing this project."
            return
        }
        guard model.hasUnsavedChanges else { continuation(); return }
        let alert = NSAlert()
        alert.messageText = "Save changes to this notebook?"
        alert.informativeText = "Some tabs have unsaved source, text or formatting changes. Project structure changes that were already saved will remain."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.model.perform("save_all") { success in if success { continuation() } }
            } else if response == .alertThirdButtonReturn {
                do { try self.model.remote.discardLocalCheckpoint(); continuation() }
                catch { self.model.error = error.localizedDescription }
            }
        }
    }

    @objc private func newProject(_ sender: Any?) {
        resolveUnsaved { [weak self] in
            guard let self else { return }
            let panel = NSSavePanel()
            panel.title = "New Sputnik Notebook"
            panel.nameFieldStringValue = "Untitled.sputnikbook"
            panel.allowedContentTypes = [UTType(exportedAs: "org.sputniklang.notebook-project", conformingTo: .package)]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.beginSheetModal(for: self.window) { response in
                guard response == .OK, let url = panel.url else { return }
                self.model.open(url: url, create: true)
            }
        }
    }

    @objc private func openProject(_ sender: Any?) {
        resolveUnsaved { [weak self] in
            guard let self else { return }
            let panel = NSOpenPanel()
            panel.title = "Open Sputnik Notebook"
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.treatsFilePackagesAsDirectories = false
            panel.allowedContentTypes = [UTType(exportedAs: "org.sputniklang.notebook-project", conformingTo: .package)]
            panel.beginSheetModal(for: self.window) { response in
                guard response == .OK, let url = panel.url else { return }
                self.open(url)
            }
        }
    }
    private func open(_ url: URL) { model.open(url: url) }
    private func addDependency() {
        guard !model.busy, !model.boardEditorOpen else { return }
        let panel = NSOpenPanel()
        panel.title = "Link Package Directory"
        panel.message = "Choose a folder containing sputnik.toml or sputnik.build.yaml/json. Sources stay in that folder. Apply Modules to load changes."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.model.perform("add_dependency", text: url.path)
        }
    }
    @objc private func save(_ sender: Any?) {
        model.perform("save", tab: model.activeBoard.flatMap { model.controller(for: $0) })
    }
    @objc private func saveAll(_ sender: Any?) { model.perform("save_all") }
    @objc private func runCell(_ sender: Any?) { model.perform("run") }
    @objc private func stopExecution(_ sender: Any?) { model.stopExecution() }
    @objc private func runAll(_ sender: Any?) {
        model.perform("run_all", tab: model.activeBoard.flatMap { model.controller(for: $0) })
    }
    @objc private func addCell(_ sender: Any?) { model.perform("add_cell") }
    @objc private func addText(_ sender: Any?) { model.perform("add_text") }
    @objc private func applyModules(_ sender: Any?) { model.perform("apply") }
    @objc private func closeWindow(_ sender: Any?) { (NSApp.keyWindow ?? window).performClose(sender) }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 548, height: 660),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings.title = "Settings"
            settings.isReleasedWhenClosed = false
            settings.contentView = NSHostingView(rootView: NotebookAppearanceView(
                preferences: preferences, content: NotebookSettingsView(preferences: preferences)))
            settings.center()
            settingsWindow = settings
        }
        settingsWindow?.makeKeyAndOrderFront(sender)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose { return true }
        resolveUnsaved { [weak self] in
            guard let self else { return }
            self.allowClose = true
            self.window.close()
            NSApp.terminate(nil)
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        if model.boardEditorOpen {
            model.error = "Save or cancel the board designer before quitting."
            return .terminateCancel
        }
        if model.busy {
            model.error = model.isolatedExecution
                ? "An evaluation is still running. Use Stop or Force Stop before quitting."
                : "An evaluation is still running. Wait for completion before quitting."
            return .terminateCancel
        }
        // Returning cancel before presenting an asynchronous sheet avoids a
        // termination reply being stranded if the user chooses Cancel.
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            self.model.shutdown {
                self.terminating = true
                NSApp.terminate(nil)
            }
        }
        if allowClose { finish() } else { resolveUnsaved(finish) }
        return .terminateCancel
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard filenames.count == 1, let path = filenames.first else {
            sender.reply(toOpenOrPrint: .failure)
            return
        }
        let url = URL(fileURLWithPath: path)
        if window == nil { pendingOpen = url }
        else { resolveUnsaved { [weak self] in self?.open(url) } }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    // Deterministic GUI smoke harness: use ONLY a caller-provided temporary
    // fixture. It drives the real asynchronous model and renders the native
    // view, without screen-recording permission or arbitrary GUI scripting.
    private func runShowcase(project: URL, arguments: [String]) {
        model.open(url: project) { [weak self] opened in
            guard let self, opened, let board = self.model.snapshot?.boards?.first else {
                self?.finishSmoke(false); return
            }
            self.model.selectBoard(board)
            var previousFrame: Data?
            var liveFrames = 0
            var sawProgress = false
            var sawBoardProgress = false
            var captured = false
            let started = Date()
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                for cell in self.model.liveCells.values {
                    for p in cell.progress where p.current > 0 && p.current < p.total {
                        sawProgress = true
                    }
                    if let panel = cell.displays.first {
                        let frame = panel.data.isEmpty ? Data((panel.plot_scene ?? "").utf8) : panel.data
                        if frame != previousFrame { previousFrame = frame; liveFrames += 1 }
                    } else if let chart = cell.charts.first(where: { $0.id == "loss" }) {
                        let frame = Data(String(chart.total_points).utf8)
                        if frame != previousFrame { previousFrame = frame; liveFrames += 1 }
                    }
                }
                if let tab = self.model.controller(for: board) {
                    for component in board.allComponents where component.kind == "progress" {
                        guard let cell = tab.cells.first(where: { $0.id == component.cell }) else { continue }
                        let state = self.model.presentation(for: cell, in: tab)
                        if state.running && state.progress.contains(where: {
                            (component.progress_id?.isEmpty != false || $0.id == component.progress_id) &&
                            $0.current > 0 && $0.current < $0.total
                        }) { sawBoardProgress = true }
                    }
                }
                if !captured && sawBoardProgress && liveFrames >= 2,
                   let index = arguments.firstIndex(of: "--live-snapshot-png"), arguments.count > index + 1 {
                    captured = self.renderSnapshot(to: arguments[index + 1])
                }
                if Date().timeIntervalSince(started) > 1200 {
                    timer.invalidate(); self.model.stopExecution(force: true)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.model.perform("run_all", tab: self.model.controller(for: board)) { success in
                timer.invalidate()
                let cells = self.model.controller(for: board)?.cells ?? []
                let complete = cells.contains { cell in
                    cell.ok &&
                    cell.progress?.contains { $0.done && $0.current == $0.total && $0.total > 0 } == true
                }
                let imagesValid = cells.flatMap { $0.displays ?? [] }.allSatisfy { $0.image() != nil }
                let series = self.model.controller(for: board).flatMap { self.model.imageSeries("worst-validation", in: $0) }
                let validationValid = series?.images.count == 10 && series?.images.allSatisfy { $0.image() != nil && !$0.caption.isEmpty } == true
                let chartsComplete = ["loss", "accuracy"].allSatisfy { id in
                    self.model.controller(for: board).flatMap { self.model.liveChart(id, in: $0) }?.points.isEmpty == false
                }
                let boardComplete = self.model.controller(for: board).map { tab in
                    board.allComponents.contains { component in
                        guard component.kind == "progress", let cell = tab.cells.first(where: { $0.id == component.cell }), cell.ok else { return false }
                        return self.model.presentation(for: cell, in: tab).progress.contains {
                            (component.progress_id?.isEmpty != false || $0.id == component.progress_id) &&
                            $0.done && $0.current == $0.total && $0.total > 0
                        }
                    }
                } ?? false
                let verified = success && complete && boardComplete && imagesValid && validationValid && chartsComplete && sawProgress && sawBoardProgress && liveFrames >= 2
                print("MNIST GUI: \(liveFrames) live frames, progress \(sawProgress), board progress \(sawBoardProgress), completed \(complete), board completed \(boardComplete)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    var rendered = verified
                    if let index = arguments.firstIndex(of: "--snapshot-png"), arguments.count > index + 1 {
                        rendered = self.renderSnapshot(to: arguments[index + 1]) && rendered
                    }
                    self.finishSmoke(rendered)
                }
            }
        }
    }

    private func runSmoke(project: URL, arguments: [String]) {
        model.open(url: project) { [weak self] opened in
            guard let self else { return }
            guard opened else { self.finishSmoke(false); return }
            self.model.perform("run_all") { success in
                guard success, self.model.activeTab?.cells.last?.result == "42" else {
                    self.finishSmoke(false); return
                }
                let finish: () -> Void = {
                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    var rendered = self.model.activeBoard != nil || self.verifySmokeEditors()
                    if let index = arguments.firstIndex(of: "--expect-figure-panels"), arguments.count > index + 1 {
                        let count = self.model.activeTab?.cells.reduce(0) { $0 + ($1.displays?.count ?? 0) }
                        rendered = rendered && count == Int(arguments[index + 1])
                    }
                    if let index = arguments.firstIndex(of: "--expect-interactive-plots"), arguments.count > index + 1 {
                        let count = (self.model.activeTab?.cells ?? []).flatMap { $0.displays ?? [] }.filter {
                            NotebookPlotScene.decode($0.plot_scene, width: $0.width, height: $0.height) != nil
                        }.count
                        rendered = rendered && count == Int(arguments[index + 1])
                    }
                    if let index = arguments.firstIndex(of: "--snapshot-png"), arguments.count > index + 1 {
                        rendered = self.renderSnapshot(to: arguments[index + 1]) && rendered
                    }
                    if let index = arguments.firstIndex(of: "--snapshot-dock-icon-png"), arguments.count > index + 1 {
                        if let iconView = NSApp.dockTile.contentView {
                            let iconRendered = self.renderSnapshot(view: iconView, to: arguments[index + 1])
                            print(iconRendered ? "notebook Dock icon smoke ok" : "notebook Dock icon smoke FAILED")
                            rendered = iconRendered && rendered
                        } else {
                            fputs("Notebook Dock icon is missing\n", stderr)
                            rendered = false
                        }
                    }
                    self.finishSmoke(rendered)
                  }
                }
                if let index = arguments.firstIndex(of: "--smoke-board"), arguments.count > index + 1,
                   let board = self.model.snapshot?.boards?.first(where: { $0.id == arguments[index + 1] }) {
                    self.model.selectBoard(board)
                    let previous = self.model.activeTab?.cells.first?.displays?.first?.data
                    self.model.perform("set_input", text: "3", commandCellID: "gain") { changed in
                        guard changed, let first = self.model.activeTab?.cells.first,
                              first.result == "126", first.displays?.first?.image() != nil,
                              first.displays?.first?.data != previous else { self.finishSmoke(false); return }
                        finish()
                    }
                } else if arguments.contains("--theme-smoke-test") {
                    self.verifyThemeSwitching { success in
                        if success { finish() } else { self.finishSmoke(false) }
                    }
                } else {
                    finish()
                }
            }
        }
    }

    private func nativeEditors(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { nativeEditors(in: $0) }
    }

    private func verifyThemeSwitching(_ completion: @escaping (Bool) -> Void) {
        guard let root = window.contentView else { completion(false); return }
        root.layoutSubtreeIfNeeded()
        let editors = nativeEditors(in: root)
        guard !editors.isEmpty else { completion(false); return }
        let sources = editors.map(\.string)
        for editor in editors {
            editor.setSelectedRange(NSRange(location: min(2, editor.string.utf16.count), length: 0))
        }
        let selections = editors.map { $0.selectedRange() }
        let undoManagers = editors.map { $0.undoManager }
        for (editor, undo) in zip(editors, undoManagers) {
            undo?.registerUndo(withTarget: editor) { _ in }
        }
        let undoStates = undoManagers.map { $0?.canUndo ?? false }
        // Use the same Settings window and preference as the menu action.
        showSettings(nil)
        let states = [NotebookTheme.dark, .light].flatMap { theme in
            NotebookColorPreset.allCases.map { (theme, $0) }
        }
        var previousFrame: Data?
        func verifyState(_ index: Int) {
            guard index < states.count else {
                self.preferences.colorPreset = .sputnik
                self.preferences.theme = .light
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // Exercise Command-W when Settings owns focus.
                    if NSApp.keyWindow === self.settingsWindow { self.closeWindow(nil) }
                    else { self.settingsWindow?.performClose(nil) }
                    let current = self.nativeEditors(in: root)
                    let ok = self.verifySmokeEditors() && self.window.isVisible &&
                        self.settingsWindow?.isVisible == false &&
                        current.map(ObjectIdentifier.init) == editors.map(ObjectIdentifier.init) &&
                        current.map(\.string) == sources && current.map { $0.selectedRange() } == selections &&
                        undoManagers.map { $0?.canUndo ?? false } == undoStates
                    print(ok ? "notebook theme switching smoke ok" : "notebook theme switching smoke FAILED")
                    completion(ok)
                }
                return
            }
            let (theme, preset) = states[index]
            self.preferences.theme = theme
            self.preferences.colorPreset = preset
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let appearance: NSAppearance.Name = theme == .dark ? .darkAqua : .aqua
                let current = self.nativeEditors(in: root)
                var ok = self.verifySmokeEditors() &&
                    self.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance &&
                    self.settingsWindow?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance &&
                    current.map(ObjectIdentifier.init) == editors.map(ObjectIdentifier.init) &&
                    current.map(\.string) == sources && current.map { $0.selectedRange() } == selections &&
                    undoManagers.map { $0?.canUndo ?? false } == undoStates
                // Verify visible workspace colors change even when the theme
                // stays the same. Settings has its own hosting tree.
                if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    let frame = bitmap.representation(using: .png, properties: [:])
                    ok = ok && frame != nil && (previousFrame == nil || frame != previousFrame)
                    previousFrame = frame
                } else { ok = false }
                guard ok else {
                    fputs("Theme/preset smoke failed: \(theme.title), \(preset.title)\n", stderr)
                    completion(false)
                    return
                }
                verifyState(index + 1)
            }
        }
        verifyState(0)
    }

    private func verifySmokeEditors() -> Bool {
        guard let root = window.contentView, let tab = model.activeTab else { return false }
        root.layoutSubtreeIfNeeded()
        let views = nativeEditors(in: root)
        for cell in tab.cells where cell.kind == "code" || cell.kind == "text" {
            for panel in cell.displays ?? [] where panel.image() == nil {
                fputs("Figure image failed to decode in cell \(cell.id): \(panel.caption)\n", stderr)
                return false
            }
            guard let editor = views.first(where: { $0.string == cell.source && $0.isRichText == (cell.kind == "text") }),
                  let storage = editor.textStorage else {
                fputs("Native editor missing for cell \(cell.id)\n", stderr)
                return false
            }
            if cell.kind == "text" {
                do {
                    let expected = try RichTextCodec.encode(RichTextCodec.decode(text: cell.source, formatting: cell.formatting))
                    let actual = try RichTextCodec.encode(storage)
                    guard expected.text == actual.text && expected.formatting == actual.formatting else { return false }
                    if let scroll = editor.enclosingScrollView, let container = editor.textContainer {
                        guard abs(editor.frame.width - scroll.contentSize.width) < 2,
                              abs(container.containerSize.width - (editor.frame.width - 2 * editor.textContainerInset.width)) < 2,
                              scroll.frame.height + 2 >= RichTextLayout.height(storage, width: scroll.frame.width) else {
                            fputs("Rich-text editor geometry clipped or narrowed for cell \(cell.id)\n", stderr)
                            return false
                        }
                    }
                } catch { fputs("Rich-text rendering failed: \(error)\n", stderr); return false }
            } else {
                for token in SputnikSyntax.tokens(in: cell.source) {
                    let color = storage.attribute(.foregroundColor, at: token.range.location, effectiveRange: nil) as? NSColor
                    guard color == SputnikSyntax.color(for: token.category) else {
                        fputs("Missing syntax color in cell \(cell.id)\n", stderr)
                        return false
                    }
                }
            }
        }
        return model.error == nil
    }
    private func renderSnapshot(to path: String) -> Bool {
        guard let view = window.contentView else { return false }
        return renderSnapshot(view: view, to: path)
    }
    private func renderSnapshot(view: NSView, to path: String) -> Bool {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: URL(fileURLWithPath: path)); return true }
        catch { model.error = error.localizedDescription; return false }
    }
    private func finishSmoke(_ success: Bool) {
        if let error = model.error { fputs("\(error)\n", stderr) }
        print(success ? "notebook macOS UI smoke ok" : "notebook macOS UI smoke FAILED")
        model.shutdown { exit(success ? 0 : 1) }
    }
}

import AppKit
import Foundation
import SwiftUI

private struct CellComponentFailure: Error { let message: String }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CellComponentFailure(message: message) }
}
@main private enum CellComponentTests {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sputnik-cell-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var active: NotebookModel?
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let moduleModel = NotebookModel(); active = moduleModel
            try await moduleEditorHeight(moduleModel, project: root.appendingPathComponent("module-layout.sputnikbook"))
            await shutdown(moduleModel); active = nil
            let original = URL(fileURLWithPath: "tools/notebook-macos/Samples/Cell Components.sputnikbook").standardizedFileURL
            for isolated in [false, true] {
                guard !isolated || option("--worker") != nil else { continue }
                let project = root.appendingPathComponent(isolated ? "worker.sputnikbook" : "local.sputnikbook")
                try FileManager.default.copyItem(at: original, to: project)
                let file = project.appendingPathComponent("project.json")
                var document = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                document["dependencies"] = [["path": URL(fileURLWithPath: "../sputnik-lang/packages/notebook_ui").standardizedFileURL.path, "auto_import": false]]
                try JSONSerialization.data(withJSONObject: document).write(to: file)
                let model = NotebookModel(workerExecutable: isolated ? option("--worker") : nil); active = model
                try await exercise(model, project: project, render: !isolated)
                await shutdown(model); active = nil
            }
            print("Cell UI tests passed: cell inputs, own channels, Data Table, live updates, collapse eligibility, editor and native rendering")
        } catch {
            if let active { await shutdown(active) }
            fputs("Cell UI tests failed: \(error)\n", stderr); exit(1)
        }
    }
    @MainActor private static func moduleEditorHeight(_ model: NotebookModel, project: URL) async throws {
        let opened = await withCheckedContinuation { c in
            model.open(url: project, create: true) { c.resume(returning: $0) }
        }
        try check(opened, model.error ?? "create module layout fixture failed")
        let created = await withCheckedContinuation { c in
            model.perform("new_module", text: "training") { c.resume(returning: $0) }
        }
        try check(created, model.error ?? "create module failed")
        let tab = model.activeTab!, cell = tab.cells[0]
        let source = "package training\n" + String(repeating: "# Module source\n", count: 120)
        model.editSource(source, cell: cell, tab: tab)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 950),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let workspace = NSHostingView(rootView: NotebookView(model: model))
        workspace.sizingOptions = []
        window.contentView = workspace
        window.makeKeyAndOrderFront(nil)
        func findEditor(_ view: NSView) -> NSTextView? {
            if let text = view as? FocusTrackingTextView { return text }
            return view.subviews.lazy.compactMap(findEditor).first
        }
        for height: CGFloat in [700, 950, 1200] {
            window.setContentSize(NSSize(width: 1200, height: height))
            workspace.frame = NSRect(x: 0, y: 0, width: 1200, height: height)
            try await Task.sleep(nanoseconds: 150_000_000)
            workspace.layoutSubtreeIfNeeded()
            try check(abs(workspace.bounds.height - height) <= 1, "module workspace did not resize to \(height)")
            guard let editor = findEditor(workspace), let scroll = editor.enclosingScrollView else {
                throw CellComponentFailure(message: "module source editor missing")
            }
            let frame = scroll.convert(scroll.bounds, to: workspace)
            let bottomGap = workspace.isFlipped ? workspace.bounds.maxY - frame.maxY : frame.minY
            // Only the module/card padding and inter-view spacing may remain.
            try check(bottomGap <= 44, "module editor leaves \(bottomGap) points below source at window height \(height)")
        }
        try capture(workspace, name: "module-full-height.png")
        let failingSource = source + "value = \"😀\" + )\n"
        model.editSource(failingSource, cell: cell, tab: tab)
        let ran = await withCheckedContinuation { c in
            model.perform("run", tab: tab, cell: cell) { c.resume(returning: $0) }
        }
        try check(ran, model.error ?? "run module fixture failed")
        try await Task.sleep(nanoseconds: 150_000_000)
        workspace.layoutSubtreeIfNeeded()
        guard let current = model.activeTab?.cells.first,
              let index = current.diagnostics?.firstIndex(where: { $0.range != nil }),
              let range = current.diagnostics?[index].range else {
            throw CellComponentFailure(message: "module source diagnostic missing")
        }
        try capture(workspace, name: "module-source-error.png")
        for _ in 0..<2 {
            guard let editor = findEditor(workspace) else { throw CellComponentFailure(message: "module editor missing") }
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
            model.showSource(range, cell: current, tab: model.activeTab!)
            try await Task.sleep(nanoseconds: 150_000_000)
            try check((editor.string as NSString).substring(with: editor.selectedRange()) == ")", "source navigation did not select its characters")
            // Rendering tests can run without a WindowServer, where AppKit
            // reports an empty visibleRect and cannot scroll a visible region.
            if !editor.visibleRect.isEmpty {
                try check(editor.visibleRect.minY > 0, "source navigation did not scroll to its line")
            }
        }
        func collapseButton(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityIdentifier() == "cell-collapse-\(current.id)" { return button }
            return view.subviews.lazy.compactMap(collapseButton).first
        }
        guard let collapse = collapseButton(workspace) else { throw CellComponentFailure(message: "module collapse button missing") }
        collapse.performClick(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(findEditor(workspace) == nil, "module source did not collapse")
        model.showSource(range, cell: current, tab: model.activeTab!)
        try await Task.sleep(nanoseconds: 150_000_000)
        guard let revealed = findEditor(workspace) else { throw CellComponentFailure(message: "error click did not expand the module source") }
        try check((revealed.string as NSString).substring(with: revealed.selectedRange()) == ")", "expanded source did not reveal its diagnostic")
        try check(range.start_line == 121, "fixture must diagnose an offscreen line")
        try capture(workspace, name: "module-error-navigation.png")
    }
    @MainActor private static func exercise(_ model: NotebookModel, project: URL, render: Bool) async throws {
        let opened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
        try check(opened, model.error ?? "open failed")
        var tab = model.snapshot!.tabs.first!
        try check(tab.cells[1].canCollapseSource && !tab.cells[3].canCollapseSource, "only explicit post-cell components enable collapse before data exists")
        var completion: Bool? = nil
        var sawLiveChart = false
        model.perform("run_all", tab: tab) { completion = $0 }
        let deadline = Date().addingTimeInterval(20)
        while completion == nil && Date() < deadline {
            if let current = model.snapshot?.tabs.first, let computing = current.cells.first(where: { $0.id == "2" }),
               model.executingCells[current.id] == computing.id,
               let chart = model.cellChart("curve", cell: computing, tab: current), !chart.points.isEmpty {
                sawLiveChart = true
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try check(completion == true, model.error ?? "run failed or timed out")
        if model.isolatedExecution { try check(sawLiveChart, "post-cell chart did not update during execution") }
        tab = model.snapshot!.tabs.first!
        var cell = tab.cells[1]
        try check(cell.ok && Double(cell.result) == 21, cell.error + " expected score 21: " + cell.result)
        try check(model.cellChart("curve", cell: cell, tab: tab)?.points.last?.y == 9 && model.cellChart("curve", cell: tab.cells[2], tab: tab)?.points.last?.y == 50, "same channel IDs stay with their own cells")
        try check(model.cellImages("preview", cell: cell, tab: tab)?.images.count == 1, "cell image source missing")
        try check(cell.displays?.contains { $0.id == "values" && $0.mime == "application/vnd.sputnik.table+json" } == true, "explicit Data Table missing")
        // Missing local channels never resolve through another cell on the sheet.
        try check(model.cellImages("preview", cell: tab.cells[2], tab: tab) == nil, "image channel leaked across cells")
        if render { try await renderUI(model, tab: tab, cell: cell) }
        let changed = await withCheckedContinuation { c in model.setCellInputs(["gain": "3", "offset": "4"], cell: cell, tab: tab) { c.resume(returning: $0) } }
        try check(changed, model.error ?? "Apply failed")
        tab = model.snapshot!.tabs.first!; cell = tab.cells[1]
        try check(Double(cell.result) == 34 && Double(tab.cells[2].result) == 50, "local atomic Apply changed another cell")
        var config = cell.cell_ui!; config.post = []
        let saved = await withCheckedContinuation { c in model.saveCellUI(config, cell: cell, tab: tab) { c.resume(returning: $0) } }
        try check(saved && model.snapshot!.tabs.first!.cells[1].canCollapseSource == false, "removing final post component did not disable collapse")
        try check(Double(model.snapshot!.tabs.first!.cells[1].result) == 34, "UI edits executed or discarded results")
        let reopened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
        try check(reopened && Double(model.snapshot!.tabs.first!.cells[1].cell_inputs?.first?.editingText ?? "") == 2, "defaults and current values were conflated")
    }
    @MainActor private static func renderUI(_ model: NotebookModel, tab: NotebookTab, cell: NotebookCell) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1050), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil); defer { window.close() }
        for scheme in [ColorScheme.light, .dark] {
            let content = NSHostingView(rootView: ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Cell interface").font(.title)
                    NotebookCellComponentsView(model: model, cell: cell, tab: tab, components: cell.cell_ui!.pre)
                    NotebookCellComponentsView(model: model, cell: cell, tab: tab, components: cell.cell_ui!.post)
                }.padding(20)
            }.background(NotebookPalette.canvas).foregroundStyle(NotebookPalette.ink).environment(\.colorScheme, scheme))
            window.contentView = content
            try await Task.sleep(nanoseconds: 180_000_000); content.layoutSubtreeIfNeeded()
            try capture(content, name: scheme == .light ? "runtime-light.png" : "runtime-dark.png")
        }
        let table = NSHostingView(rootView: NotebookCellComponentsView(model: model, cell: cell, tab: tab,
            components: cell.cell_ui!.post.filter { $0.kind == "table" }).padding(20)
            .background(NotebookPalette.canvas).foregroundStyle(NotebookPalette.ink).environment(\.colorScheme, .light))
        window.contentView = table
        try await Task.sleep(nanoseconds: 100_000_000); table.layoutSubtreeIfNeeded()
        try capture(table, name: "table.png")
        window.setContentSize(NSSize(width: 850, height: 700))
        let editor = NSHostingView(rootView: NotebookCellComponentEditor(model: model, cell: cell, tab: tab).background(NotebookPalette.canvas).foregroundStyle(NotebookPalette.ink).environment(\.colorScheme, .light))
        window.contentView = editor
        try await Task.sleep(nanoseconds: 100_000_000); editor.layoutSubtreeIfNeeded()
        try capture(editor, name: "editor.png")
        window.setContentSize(NSSize(width: 1200, height: 950))
        let workspace = NSHostingView(rootView: NotebookView(model: model))
        window.contentView = workspace
        try await Task.sleep(nanoseconds: 150_000_000); workspace.layoutSubtreeIfNeeded()
        try capture(workspace, name: "workspace.png")
        func sourceViews() -> [NSTextView] {
            func all(_ view: NSView) -> [NSTextView] {
                (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(all)
            }
            return all(workspace).filter { $0.string == cell.source }
        }
        try check(!sourceViews().isEmpty, "source editor missing before collapse")
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let collapse = buttons(workspace).first { $0.accessibilityIdentifier() == "cell-collapse-2" }
        try check(collapse != nil, "collapse control missing for explicit post-cell components")
        try check(buttons(workspace).allSatisfy { $0.accessibilityIdentifier() != "cell-collapse-4" }, "implicit result enabled collapse")
        collapse!.performClick(nil)
        try await Task.sleep(nanoseconds: 150_000_000); workspace.layoutSubtreeIfNeeded()
        try check(sourceViews().isEmpty, "code did not collapse after clicking the header chevron")
        try capture(workspace, name: "collapsed.png")
        var ui = cell.cell_ui!; ui.post = []
        let saved = await withCheckedContinuation { c in model.saveCellUI(ui, cell: cell, tab: tab) { c.resume(returning: $0) } }
        try check(saved, model.error ?? "remove post components failed")
        try await Task.sleep(nanoseconds: 120_000_000); workspace.layoutSubtreeIfNeeded()
        try check(!sourceViews().isEmpty, "removing post components left source collapsed")
        let restored = await withCheckedContinuation { c in model.saveCellUI(cell.cell_ui!, cell: cell, tab: tab) { c.resume(returning: $0) } }
        try check(restored, "restore fixture failed")
    }
    @MainActor private static func capture(_ view: NSView, name: String) throws {
        guard let output = option("--output") else { return }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CellComponentFailure(message: "bitmap missing") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CellComponentFailure(message: "PNG missing") }
        let root = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try png.write(to: root.appendingPathComponent(name))
    }
    private static func option(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }
    @MainActor private static func shutdown(_ model: NotebookModel) async {
        await withCheckedContinuation { c in model.shutdown { c.resume() } }
    }
}

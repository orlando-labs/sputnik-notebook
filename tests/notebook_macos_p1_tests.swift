import AppKit
import SwiftUI

private struct P1Failure: Error { let message: String }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw P1Failure(message: message) }
}
@main private enum P1Tests {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sputnik-p1-\(UUID())")
        var active: NotebookModel?
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for isolated in [false, true] {
                let path = root.appendingPathComponent(isolated ? "worker.sputnikbook" : "local.sputnikbook")
                try FileManager.default.copyItem(at: URL(fileURLWithPath: "tools/notebook-macos/Samples/Workstation.sputnikbook"), to: path)
                let model = NotebookModel(workerExecutable: isolated ? option("--worker") : nil); active = model
                try await run(model, project: path, isolated: isolated)
                if !isolated { try await presetUITests(model); try await previews(model) }
                await shutdown(model); active = nil
            }
            try pureTests()
            print("notebook macOS P1 tests passed")
        } catch {
            if let active { await shutdown(active) }
            fputs("notebook macOS P1 tests failed: \(error)\n", stderr); exit(1)
        }
    }
    private static func option(_ key: String) -> String? { CommandLine.arguments.firstIndex(of: key).flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } }
    @MainActor private static func run(_ model: NotebookModel, project: URL, isolated: Bool) async throws {
        let original = try Data(contentsOf: project.appendingPathComponent("project.json"))
        let opened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
        try check(opened, model.error ?? "open sample")
        try check(model.snapshot?.tabs.first?.cells.first?.ok == false, "opening is inert")
        let ran = await perform(model, "run_all")
        try check(ran, model.error ?? "run sample")
        var board = model.snapshot!.boards!.first!
        let tab = model.controller(for: board)!
        try check(tab.cells[0].ok && tab.cells[0].result.hasPrefix("0.862"), "metric source evaluates")
        try check(tab.cells[0].output.map(\.text).joined().contains("Experiment finished"), "committed logs remain available")
        let artifacts = NotebookArtifact.capture(NotebookTableSnapshot.decode(tab.cells[1].result_format?.table_json ?? ""), project: project.path)
        try check(artifacts.count == 1 && artifacts[0].url.lastPathComponent == "report.txt" && artifacts[0].belongsToProject(project.path), "artifact records retain source files and classify paths across macOS symlink aliases")
        let preview = try NotebookFilePreview.read(artifacts[0].url)
        try check(preview.text.contains("Sputnik experiment report"), "artifact bounded text preview")
        try check(try Data(contentsOf: project.appendingPathComponent("project.json")) == original, "Run does not save a document")
        let presets = board.allComponents.first { $0.kind == "parameter_presets" }!
        let selected = presets.settings.presets![1]
        try check(NotebookPresetEditing.validate(selected, inputs: model.snapshot!.inputs!, selected: presets.settings.preset_inputs) == nil, "preset validates exact scalar types")
        let applied = await withCheckedContinuation { c in model.setProjectInputs(selected.values) { c.resume(returning: $0) } }
        try check(applied && model.snapshot?.inputs?.first(where: { $0.id == "large" })?.editingText == "9223372036854775807", "preset Apply preserves exact Int64")
        var renamed = presets; var settings = renamed.settings
        settings.presets![1].title = "Fast renamed"; renamed.p1 = settings
        let saved = await withCheckedContinuation { c in model.saveComponent(renamed, board: board) { c.resume(returning: $0) } }
        try check(saved, model.error ?? "save preset")
        board = model.snapshot!.boards!.first!
        let data = try Data(contentsOf: project.appendingPathComponent("project.json"))
        let before = try JSONSerialization.jsonObject(with: original) as! [String: Any], after = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try check(before["inputs"] as! NSArray == after["inputs"] as! NSArray, "preset save leaves saved defaults unchanged")
        let action = board.allComponents.first { $0.kind == "action" }!
        for expected in ["[25, 1]", "[25, 2]"] {
            let success = await perform(model, "action_run", board: board, component: action)
            try check(success, model.error ?? "action execution")
            let result = model.snapshot?.periodic_results?.first { $0.id == board.id + ":" + action.id }
            try check(!model.actionIsStale(board: board, component: action), "committed action retains its frozen argument provenance")
            try check(result?.ok == true && result?.result == expected, "action freezes accepted arguments and preserves its own runtime: \(result?.error ?? result?.result ?? "missing")")
        }
        try check(model.snapshot?.tabs.first?.cells[0].ok == true, "action runtime does not replace the sheet result")
        let changedArguments = await withCheckedContinuation { c in model.setProjectInputs(["gain": "3.0"]) { c.resume(returning: $0) } }
        try check(changedArguments && model.actionIsStale(board: board, component: action), "changing accepted action arguments marks its previous result stale")
        if isolated {
            var slow = action; slow.function = "slow"; var settings = slow.settings; settings.arguments = []; slow.p1 = settings
            let savedSlow = await withCheckedContinuation { c in model.saveComponent(slow, board: board) { c.resume(returning: $0) } }
            try check(savedSlow, "save slow action")
            var stopped: Bool?
            model.perform("action_run", tab: model.controller(for: board), text: board.id, commandCellID: slow.id) { stopped = $0 }
            let deadline = Date().addingTimeInterval(5)
            while !model.canStop && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            try check(model.canStop && model.executingTargetID == board.id + ":" + action.id, "execution controls address only the running action")
            model.stopExecution()
            while stopped == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            let result = model.snapshot?.periodic_results?.first { $0.id == board.id + ":" + action.id }
            try check(stopped != nil && result?.ok == false && result?.error.contains("Cancelled") == true, "action Stop completes and retains a cancellation diagnostic")
            let restored = await withCheckedContinuation { c in model.saveComponent(action, board: board) { c.resume(returning: $0) } }
            try check(restored, "restore action")
        }
        let reopened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
        try check(reopened && model.snapshot?.boards?.first?.allComponents.first(where: { $0.kind == "parameter_presets" })?.settings.presets?[1].title == "Fast renamed", "presets survive reopen")
        try check(model.snapshot?.inputs?.first(where: { $0.id == "gain" })?.editingText == "1.0", "reopen restores defaults")
        let rerun = await perform(model, "run_all"); try check(rerun, "rerun preview")
    }
    private static func pureTests() throws {
        try check(NotebookMetricValue.make("0.92", settings: .init(precision: 1, percentage: true)).text.contains("92"), "percentage metric")
        try check(NotebookMetricValue.make("9223372036854775807", settings: .init()).text == "9223372036854775807", "metric preserves an integer's exact spelling")
        try check(NotebookMetricValue.make("nan", settings: .init()).number == nil, "non-finite metric rejected")
        try check(NotebookFilePreview.csvShape("a,b\r\n\"x\ny\",\"q\"\"r\"\r\n").rows == 2, "CSV preview handles quotes, escaped quotes, embedded newline and CRLF")
        let logs = NotebookLogEntry.capture([NotebookOutput(stream: "stdout", text: "One"), NotebookOutput(stream: "stdout", text: "\n"), NotebookOutput(stream: "stderr", text: "Two")])
        try check(logs.count == 2 && logs[0].text == "One\n" && logs[1].stream == "stderr", "log fragments combine without reordering streams")
        let input = NotebookProjectInput(id: "i", title: "Integer", type: "integer", value_json: "1", minimum: 0, maximum: 2)
        try check(NotebookPresetEditing.validate(.init(id: "p", title: "P", values: ["i": "3"]), inputs: [input], selected: nil) != nil, "incompatible preset rejected before publication")
        let series = [NotebookChartSeriesSnapshot(settings: .init(id: "a", title: "A", stroke: "#86505f"), chart: .init(id: "a", points: [.init(x: 1, y: 2), .init(x: 2, y: 4)], total_points: 2, replace_chart: true)),
                      NotebookChartSeriesSnapshot(settings: .init(id: "b", title: "B", stroke: "#87512c"), chart: .init(id: "b", points: [.init(x: 1, y: 8)], total_points: 1, replace_chart: true))]
        let scene = NotebookMultiSeriesScene.make(series, style: .init(title: "Series", xLabel: "X", yLabel: "Y", stroke: "#86505f"), size: CGSize(width: 640, height: 340))
        try check(scene?.layers.count == 2 && scene?.bounds[3] == 8, "multi-series uses one domain and separate layers")
        let render = NotebookMultiSeriesRenderState()
        render.capture(series, style: .init(title: "Series", xLabel: "X", yLabel: "Y", stroke: "#86505f"), size: CGSize(width: 640, height: 340), scene: scene)
        guard let png = render.png(viewport: nil), let bitmap = NSBitmapImageRep(data: png) else { throw P1Failure(message: "multi-series PNG export failed") }
        try check(bitmap.pixelsWide == 1280 && bitmap.pixelsHigh > 680, "PNG export preserves canvas size and includes a series legend")
        if let output = option("--output") { try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("multi-series-export.png")) }
    }
    @MainActor private static func presetUITests(_ model: NotebookModel) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let host = NSHostingView(rootView: P1PresetHarness(model: model))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded()
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        guard let field = fields(host).first(where: { $0.placeholderString == "Preset name" }) else { throw P1Failure(message: "native preset name field missing") }
        field.selectText(nil)
        guard let editor = field.currentEditor() as? NSTextView else { throw P1Failure(message: "preset field editor missing") }
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count)); editor.insertText("UI trial", replacementRange: editor.selectedRange()); window.makeFirstResponder(nil)
        try await Task.sleep(nanoseconds: 30_000_000)
        let rect = field.convert(field.bounds, to: host)
        try click(host, window: window, x: host.bounds.width - 80, fromTop: host.isFlipped ? rect.midY : host.bounds.height - rect.midY)
        var deadline = Date().addingTimeInterval(5)
        while Date() < deadline && model.snapshot?.boards?.first?.allComponents.first(where: { $0.kind == "parameter_presets" })?.settings.presets?.contains(where: { $0.title == "UI trial" }) != true { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(model.snapshot?.boards?.first?.allComponents.first(where: { $0.kind == "parameter_presets" })?.settings.presets?.contains(where: { $0.title == "UI trial" }) == true, "native Capture current saves a named set")
        let changed = await withCheckedContinuation { c in model.setProjectInputs(["gain":"3.0"]) { c.resume(returning: $0) } }
        try check(changed, "change input after capture")
        try await Task.sleep(nanoseconds: 70_000_000); host.layoutSubtreeIfNeeded()
        guard let current = fields(host).first(where: { $0.placeholderString == "Preset name" }) else { throw P1Failure(message: "preset field disappeared") }
        let currentRect = current.convert(current.bounds, to: host)
        let top = host.isFlipped ? currentRect.minY : host.bounds.height - currentRect.maxY
        try snapshot(host, name: "preset-ui.png")
        try click(host, window: window, x: 70, fromTop: top - 21)
        deadline = Date().addingTimeInterval(5)
        while Date() < deadline && model.snapshot?.inputs?.first(where: { $0.id == "gain" })?.editingText != "1.0" { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(model.snapshot?.inputs?.first(where: { $0.id == "gain" })?.editingText == "1.0", "native Apply preset restores the captured parameter batch")
    }
    @MainActor private static func click(_ view: NSView, window: NSWindow, x: Double, fromTop: Double) throws {
        let point = view.convert(NSPoint(x: x, y: view.isFlipped ? fromTop : view.bounds.height - fromTop), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { throw P1Failure(message: "mouse event missing") }
            window.sendEvent(event)
        }
    }
    @MainActor private static func previews(_ model: NotebookModel) async throws {
        guard let board = model.snapshot?.boards?.first else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 900), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }; window.makeKeyAndOrderFront(nil)
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: NotebookBoardView(model: model, board: board, onDesign: {}).environment(\.colorScheme, scheme))
            window.contentView = host; try await Task.sleep(nanoseconds: 150_000_000); host.layoutSubtreeIfNeeded()
            try snapshot(host, name: scheme == .light ? "runtime-light.png" : "runtime-dark.png")
            window.setContentSize(NSSize(width: 1120, height: 740))
            let designer = NSHostingView(rootView: NotebookBoardEditor(model: model, board: board, document: model.documentIdentity).environment(\.colorScheme, scheme))
            window.contentView = designer; try await Task.sleep(nanoseconds: 150_000_000); designer.layoutSubtreeIfNeeded()
            try snapshot(designer, name: scheme == .light ? "designer-light.png" : "designer-dark.png")
            model.boardEditorOpen = false; window.setContentSize(NSSize(width: 1120, height: 900))
            var details = board; details.components = board.components.filter { ["files", "details"].contains($0.row ?? "") }; details.rows = board.rows?.filter { ["files", "details"].contains($0.id) }
            let lower = NSHostingView(rootView: NotebookBoardView(model: model, board: details, onDesign: {}).environment(\.colorScheme, scheme))
            window.contentView = lower; try await Task.sleep(nanoseconds: 100_000_000); lower.layoutSubtreeIfNeeded()
            try snapshot(lower, name: scheme == .light ? "files-logs-light.png" : "files-logs-dark.png")
        }
    }
    @MainActor private static func snapshot(_ view: NSView, name: String) throws {
        guard let output = option("--output"), let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let root = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(name))
    }
    @MainActor private static func perform(_ model: NotebookModel, _ action: String, board: NotebookBoard? = nil, component: NotebookBoardComponent? = nil) async -> Bool {
        await withCheckedContinuation { c in model.perform(action, tab: board.flatMap { model.controller(for: $0) }, text: board?.id ?? "", commandCellID: component?.id) { c.resume(returning: $0) } }
    }
    @MainActor private static func shutdown(_ model: NotebookModel) async { await withCheckedContinuation { c in model.shutdown { c.resume() } } }
}

private struct P1PresetHarness: View {
    @ObservedObject var model: NotebookModel
    var body: some View {
        if let board = model.snapshot?.boards?.first, let component = board.allComponents.first(where: { $0.kind == "parameter_presets" }) {
            NotebookPresetView(model: model, board: board, component: component).padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .foregroundStyle(NotebookPalette.ink).background(NotebookPalette.canvas).environment(\.colorScheme, .light)
        }
    }
}

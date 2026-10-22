import AppKit
import Foundation
import SwiftUI

private struct P0Failure: Error { let message: String }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw P0Failure(message: message) }
}

@main private enum P0Tests {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sputnik-p0-\(UUID())")
        var active: NotebookModel?
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let original = URL(fileURLWithPath: "tools/notebook-macos/Samples/Parameters and Tables.sputnikbook")
            for isolated in [false, true] {
                guard !isolated || option("--worker") != nil else { continue }
                let project = root.appendingPathComponent(isolated ? "worker.sputnikbook" : "local.sputnikbook")
                try FileManager.default.copyItem(at: original, to: project)
                let model = NotebookModel(workerExecutable: isolated ? option("--worker") : nil)
                active = model
                try await modelTests(model, project: project)
                if !isolated { try await previewTests(model) }
                try await formUITests(model)
                await shutdown(model); active = nil
            }
            try editingTests()
            print("notebook macOS P0 tests passed")
        } catch {
            if let active { await shutdown(active) }
            fputs("notebook macOS P0 tests failed: \(error)\n", stderr); exit(1)
        }
    }
    private static func option(_ name: String) -> String? {
        CommandLine.arguments.firstIndex(of: name).flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
    }
    @MainActor private static func modelTests(_ model: NotebookModel, project: URL) async throws {
        let manifest = project.appendingPathComponent("project.json")
        let original = try Data(contentsOf: manifest)
        let opened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
        try check(opened, model.error ?? "open P0 sample")
        try check(model.snapshot?.tabs.first?.cells.first(where: { $0.id == "2" })?.ok == false, "open remains inert")
        let beforeRun = await inputs(model, ["gain":"2.0", "offset":"3"])
        try check(beforeRun && model.snapshot?.tabs.first?.cells.first(where: { $0.id == "2" })?.ok == false, "changing inputs never initializes a sheet")
        let ran = await perform(model, "run_all")
        try check(ran, model.error ?? "run input project in both execution modes")
        let first = try cell(model, "2")
        try check(local(first, "score") == "23" && local(first, "evaluation_count") == "1", "run sees one immutable batch snapshot")
        guard let table = NotebookTableSnapshot.decode(first.result_format?.table_json ?? "") else { throw P0Failure(message: "typed table missing") }
        try check(table.rows.count == 3 && table.columns.map(\.title) == ["name", "score", "device", "count"], "runtime captures schema and records")
        try check(table.rows[0].values[3].text == "9223372036854775806", "typed table preserves Int64 beyond Double precision")
        let sorted = table.visibleRows(query: "", column: 1, ascending: true)
        try check(sorted.map(\.id) == ["1", "0", "2"], "numeric sorting keeps source row identities")
        let filtered = table.visibleRows(query: "quoted", column: nil, ascending: true)
        try check(filtered.count == 1 && table.csv(filtered).contains("\"Beta, \"\"quoted\"\"\""), "search and CSV escape quotes/commas without parsing preview")
        let applied = await inputs(model, ["gain":"4.0", "offset":"7", "large":"9223372036854775807"])
        try check(applied, model.error ?? "batch Apply")
        let second = try cell(model, "2")
        try check(local(second, "score") == "47" && local(second, "evaluation_count") == "2", "one batch runs Watch consumers exactly once")
        let manual = try cell(model, "4")
        try check(manual.dirty && local(manual, "manual") == "200", "Manual consumer remains stale with its previous named value until explicit Run")
        let rejected = await inputs(model, ["gain":"5.0", "offset":"not an integer"])
        try check(!rejected && local(try cell(model, "2"), "score") == "47" && model.snapshot?.inputs?.first(where: { $0.id == "gain" })?.editingText == "4.0", "invalid batch publishes no partial values and no evaluation")
        model.clearError()
        let equal = await inputs(model, ["gain":"4.0", "offset":"7"])
        try check(equal && local(try cell(model, "2"), "evaluation_count") == "2", "equal batch remains quiet")
        var board = model.snapshot!.boards!.first!
        board.components.firstIndex(where: { $0.kind == "parameter_form" }).map { board.components[$0].fields?.reverse() }
        let saved = await withCheckedContinuation { c in model.saveBoard(board) { c.resume(returning: $0) } }
        try check(saved && model.activeBoard?.components.first(where: { $0.kind == "parameter_form" })?.fields?.first?.input == "mode", "form controls and order roundtrip through backend")
        let after = try Data(contentsOf: manifest)
        let sourceBefore = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        let sourceAfter = try JSONSerialization.jsonObject(with: after) as! [String: Any]
        try check((sourceBefore["inputs"] as? NSArray) == (sourceAfter["inputs"] as? NSArray), "Save Board does not persist session input values as defaults")
        let reopened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
        try check(reopened && model.snapshot?.inputs?.first(where: { $0.id == "gain" })?.editingText == "1.0", "reopening restores saved defaults")
        try check(try cell(model, "2").result_format?.table_json?.isEmpty != false, "runtime table snapshots do not persist into the document")
        let finalRun = await perform(model, "run_all")
        try check(finalRun, model.error ?? "rerun sample for rendering")
    }
    @MainActor private static func previewTests(_ model: NotebookModel) async throws {
        guard let board = model.snapshot?.boards?.first else { throw P0Failure(message: "sample board missing") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 900), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.center(); window.makeKeyAndOrderFront(nil)
        for scheme in [ColorScheme.light, .dark] {
            let runtime = NSHostingView(rootView: NotebookBoardView(model: model, board: board, onDesign: {}).environment(\.colorScheme, scheme))
            window.contentView = runtime
            try await Task.sleep(nanoseconds: 150_000_000); runtime.layoutSubtreeIfNeeded()
            try snapshot(runtime, name: scheme == .light ? "runtime-light.png" : "runtime-dark.png")
            window.setContentSize(NSSize(width: 1120, height: 740))
            let designer = NSHostingView(rootView: NotebookBoardEditor(model: model, board: board, document: model.documentIdentity).environment(\.colorScheme, scheme))
            window.contentView = designer
            try await Task.sleep(nanoseconds: 150_000_000); designer.layoutSubtreeIfNeeded()
            try snapshot(designer, name: scheme == .light ? "designer-light.png" : "designer-dark.png")
            model.boardEditorOpen = false
            var overview = board
            overview.rows = [NotebookBoardRow(id: "categories", height: 170)]
            overview.components = [
                NotebookBoardComponent(id: "layout", kind: "tabs", title: "Layout · Tabs", row: "categories", span: 4,
                    panels: [NotebookBoardPanel.empty(title: "Panel")]),
                NotebookBoardComponent(id: "controls", kind: "input", title: "Controls · Gain", input: "gain", row: "categories", span: 4),
                NotebookBoardComponent(id: "display", kind: "table", title: "Display · Data Table", cell: "2", row: "categories", span: 4),
                NotebookBoardComponent(id: "service", kind: "periodic_work", title: "Services · Periodic Work", module_id: "audit", function: "tick")
            ]
            let categories = NSHostingView(rootView: NotebookBoardEditor(model: model, board: overview, document: model.documentIdentity).environment(\.colorScheme, scheme))
            window.contentView = categories
            try await Task.sleep(nanoseconds: 150_000_000); categories.layoutSubtreeIfNeeded()
            try snapshot(categories, name: scheme == .light ? "categories-light.png" : "categories-dark.png")
            model.boardEditorOpen = false
            window.setContentSize(NSSize(width: 1120, height: 900))
        }
    }
    @MainActor private static func formUITests(_ model: NotebookModel) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 250), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let fields = [NotebookFormField(input: "gain", control: NotebookInputControl()),
                      NotebookFormField(input: "offset", control: NotebookInputControl())]
        let host = NSHostingView(rootView: NotebookParameterFormView(model: model, fields: fields)
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 100_000_000); host.layoutSubtreeIfNeeded()
        func textFields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields)
        }
        func edit(_ title: String, _ value: String) throws {
            guard let field = textFields(host).first(where: { $0.placeholderString == title }) else {
                throw P0Failure(message: "native form field missing: \(title)")
            }
            field.selectText(nil)
            guard let editor = field.currentEditor() as? NSTextView else { throw P0Failure(message: "field editor missing") }
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            editor.insertText(value, replacementRange: editor.selectedRange())
            window.makeFirstResponder(nil)
        }
        let before = local(try cell(model, "2"), "evaluation_count")
        try edit("Gain", "20")
        try await Task.sleep(nanoseconds: 50_000_000)
        try check(local(try cell(model, "2"), "evaluation_count") == before, "invalid UI draft does not publish")
        try edit("Gain", "3.5"); try edit("Offset", "8")
        try await Task.sleep(nanoseconds: 50_000_000)
        try check(local(try cell(model, "2"), "evaluation_count") == before &&
            model.snapshot?.inputs?.first(where: { $0.id == "gain" })?.editingText == "1.0", "editing native form fields does not publish before Apply")
        host.layoutSubtreeIfNeeded()
        try snapshot(host, name: "form-ui-draft.png")
        guard let lastField = textFields(host).first(where: { $0.placeholderString == "Offset" }) else {
            throw P0Failure(message: "last form field missing")
        }
        let rect = lastField.convert(lastField.bounds, to: host)
        let bottom = host.isFlipped ? rect.maxY : host.bounds.height - rect.minY
        let point = host.convert(NSPoint(x: host.bounds.width - 45,
            y: host.isFlipped ? bottom + 23 : host.bounds.height - bottom - 23), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw P0Failure(message: "form mouse event missing")
            }
            window.sendEvent(event)
        }
        let deadline = Date().addingTimeInterval(10)
        while try Date() < deadline && local(cell(model, "2"), "score") != "43" {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try check(local(try cell(model, "2"), "score") == "43" &&
            local(try cell(model, "2"), "evaluation_count") == "2", "native form Apply publishes both fields and runs Watch once")
    }
    private static func editingTests() throws {
        let integer = NotebookProjectInput(id: "large", title: "Large", type: "integer", value_json: "9223372036854775806", minimum: nil, maximum: nil)
        let stepper = NotebookInputControl(style: "stepper", step: 1)
        try check(NotebookInputEditing.stepped(integer.editingText, by: 1, input: integer, control: stepper) == "9223372036854775807", "Stepper keeps large integers exact")
        try check(NotebookInputEditing.stepped("9223372036854775807", by: 1, input: integer, control: stepper) == nil, "Stepper cannot overflow Int64")
        let number = NotebookProjectInput(id: "gain", title: "Gain", type: "number", value_json: "1.0", minimum: 0, maximum: 10)
        try check(NotebookInputEditing.error("nan", input: number, control: NotebookInputControl()) != nil && NotebookInputEditing.error("11", input: number, control: NotebookInputControl()) != nil, "form errors catch non-finite/out-of-range drafts")
        let malformed = #"{"columns":[{"id":"a","title":"A","type":"integer"}],"rows":[{"id":"1","values":[]}],"total_rows":1,"truncated":false}"#
        try check(NotebookTableSnapshot.decode(malformed) == nil, "malformed row width cannot reach the table renderer")
    }
    @MainActor private static func snapshot(_ view: NSView, name: String) throws {
        guard let output = option("--output") else { return }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw P0Failure(message: "snapshot bitmap missing") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw P0Failure(message: "snapshot PNG missing") }
        let root = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try png.write(to: root.appendingPathComponent(name))
    }
    @MainActor private static func cell(_ model: NotebookModel, _ id: String) throws -> NotebookCell {
        guard let cell = model.snapshot?.tabs.first?.cells.first(where: { $0.id == id }) else { throw P0Failure(message: "cell missing") }
        return cell
    }
    private static func local(_ cell: NotebookCell, _ name: String) -> String? { cell.locals.first { $0.name == name }?.value }
    @MainActor private static func perform(_ model: NotebookModel, _ action: String) async -> Bool {
        await withCheckedContinuation { c in model.perform(action) { c.resume(returning: $0) } }
    }
    @MainActor private static func inputs(_ model: NotebookModel, _ values: [String: String]) async -> Bool {
        await withCheckedContinuation { c in model.setProjectInputs(values) { c.resume(returning: $0) } }
    }
    @MainActor private static func shutdown(_ model: NotebookModel) async {
        await withCheckedContinuation { c in model.shutdown { c.resume() } }
    }
}

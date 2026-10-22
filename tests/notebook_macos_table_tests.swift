import AppKit
import SwiftUI

private struct TableFailure: Error { let message: String }
@main private enum TableTests {
    static func option(_ key: String) -> String? { CommandLine.arguments.firstIndex(of: key).flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } }
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw TableFailure(message: message) } }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = NotebookModel(workerExecutable: option("--worker"))
        do {
            let project = URL(fileURLWithPath: "tools/notebook-macos/Samples/Data Tables.sputnikbook")
            let original = try Data(contentsOf: project.appendingPathComponent("project.json"))
            let opened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
            try check(opened, model.error ?? "open")
            let ran = await withCheckedContinuation { c in model.perform("run_all") { c.resume(returning: $0) } }
            try check(ran && model.activeTab!.environment_error.isEmpty, model.error ?? model.activeTab!.environment_error)
            for cell in model.activeTab!.cells where cell.kind == "code" { try check(cell.ok, cell.error) }
            let cell = model.activeTab!.cells.first { $0.id == "2" }!
            try check(cell.result == "42" && cell.result_format?.table_json?.isEmpty != false, "explicit table is independent from return-value inspection")
            let panel = cell.displays!.first { $0.id == "orders" }!
            let table = NotebookTableSnapshot.decode(String(data: panel.data, encoding: .utf8)!)!
            try check(table.rows.count == 3 && table.rows[1].values[1].text == "9223372036854775806", "typed view keeps exact Int64")
            func local(_ name: String) -> String? { cell.locals.first { $0.name == name && $0.role == "module_cell" }?.text_value }
            try check(table.csv(table.rows) == local("csv"), "native CSV agrees with DataTableView.to_csv")
            try check(table.markdown(table.rows) == local("markdown"), "native Markdown agrees with DataTableView.to_markdown")
            let filtered = table.visibleRows(query: "Beta", column: 1, ascending: false)
            try check(filtered.count == 1 && table.markdown(filtered).contains("Beta \\| quoted") && !table.csv(filtered).contains("Alpha"), "menu exports obey filtering and preserve Markdown escapes")
            let empty = model.activeTab!.cells.first { $0.id == "3" }!.displays!.first!
            let emptyTable = NotebookTableSnapshot.decode(String(data: empty.data, encoding: .utf8)!)!
            try check(emptyTable.rows.isEmpty && emptyTable.columns.map(\.title) == ["Заказ", "Вес"], "empty view preserves its schema")
            let live = model.activeTab!.cells.first { $0.id == "4" }!.displays!
            try check(live.count == 1 && live[0].id == "live", "live channel retains one final table")
            try check(model.snapshot!.boards!.first!.allComponents.filter { $0.kind == "table" }.map(\.table_id) == ["orders", "empty", "live"], "board retains named channels")
            if let output = option("--output") { try await previews(model, directory: URL(fileURLWithPath: output)) }
            let saved = try Data(contentsOf: project.appendingPathComponent("project.json"))
            try check(saved == original, "running/exporting preserves the authored document")
            await withCheckedContinuation { c in model.shutdown { c.resume() } }
            print("DataTableView native tests passed: scalar result, CSV/Markdown parity, filtered exports, empty schema, channel bindings and light/dark rendering")
        } catch {
            await withCheckedContinuation { c in model.shutdown { c.resume() } }
            fputs("DataTableView native tests failed: \(error)\n", stderr); exit(1)
        }
    }
    @MainActor static func previews(_ model: NotebookModel, directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 1300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }; window.makeKeyAndOrderFront(nil)
        for scheme in [ColorScheme.light, .dark] {
            let board = NSHostingView(rootView: NotebookBoardView(model: model, board: model.snapshot!.boards!.first!, onDesign: {}).environment(\.colorScheme, scheme))
            window.contentView = board; try await Task.sleep(nanoseconds: 200_000_000); board.layoutSubtreeIfNeeded()
            try snapshot(board, to: directory.appendingPathComponent(scheme == .light ? "tables-board-light.png" : "tables-board-dark.png"))
            let sheet = NSHostingView(rootView: NotebookView(model: model).environment(\.colorScheme, scheme))
            window.contentView = sheet; try await Task.sleep(nanoseconds: 200_000_000); sheet.layoutSubtreeIfNeeded()
            try snapshot(sheet, to: directory.appendingPathComponent(scheme == .light ? "tables-sheet-light.png" : "tables-sheet-dark.png"))
        }
    }
    @MainActor static func snapshot(_ view: NSView, to path: URL) throws {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: path)
    }
}

import AppKit
import SwiftUI

private struct SQLiteTestFailure: Error { let message: String }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw SQLiteTestFailure(message: message) }
}

/// Integration check for a generated Строки notebook and its external, read-only DB.
@main private enum SQLiteTests {
    static func option(_ key: String) -> String? {
        CommandLine.arguments.firstIndex(of: key).flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = NotebookModel(workerExecutable: option("--worker"))
        do {
            let project = URL(fileURLWithPath: option("--project") ?? "build/SQLite-Rows.sputnikbook")
            let original = try Data(contentsOf: project.appendingPathComponent("project.json"))
            let opened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
            try require(opened, model.error ?? "open")
            try require(model.snapshot?.tabs.first?.cells.first(where: { $0.kind == "code" })?.ok == false, "opening must not execute SQL")
            let database = model.snapshot!.inputs!.first { $0.id == "database" }!.editingText
            try await run(model)
            try validate(model, database: database, table: "Строка 1", search: "", page: 1, size: 100)
            for (table, search, page, size) in [("Строка 2", "", 2, 25), ("Строка 3", "МК 89", 1, 50),
                                               ("Строка 1", "' OR 1=1 -- %_", 1, 25), ("Строка 1", "", 1000000, 500)] {
                let old = model.activeTab!.cells.first { $0.id == "2" }!.output.map(\.text).joined()
                let changed = await withCheckedContinuation { c in
                    model.setProjectInputs(["table": json(table), "search": json(search), "page": String(page), "page_size": String(size)]) { c.resume(returning: $0) }
                }
                try require(changed, model.error ?? "set SQL parameters")
                let stale = model.activeTab!.cells.first { $0.id == "2" }!
                try require(stale.dirty && stale.output.map(\.text).joined() == old, "Apply invalidates Manual queries without running SQL")
                try await run(model)
                try validate(model, database: database, table: table, search: search, page: page, size: size)
            }
            let restored = await withCheckedContinuation { c in
                model.setProjectInputs(["table": json("Строка 1"), "search": json(""), "page": "1", "page_size": "100"]) { c.resume(returning: $0) }
            }
            try require(restored, "restore initial query")
            try await run(model)
            if let output = option("--output") { try await preview(model, output: URL(fileURLWithPath: output)) }
            let saved = try Data(contentsOf: project.appendingPathComponent("project.json"))
            try require(original == saved, "Run and input edits must not rewrite the document")
            print("SQLite notebook passed: real native queries, three tables, pagination, literal search, empty results, read-only connection and native board")
            await shutdown(model)
        } catch {
            await shutdown(model)
            fputs("SQLite notebook failed: \(error)\n", stderr)
            exit(1)
        }
    }
    static func json(_ text: String) -> String {
        String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
    }
    @MainActor static func run(_ model: NotebookModel) async throws {
        let ran = await withCheckedContinuation { c in model.perform("run_all") { c.resume(returning: $0) } }
        try require(ran, model.error ?? "run all")
        try require(model.activeTab!.environment_error.isEmpty, model.activeTab!.environment_error)
        for cell in model.activeTab!.cells where cell.kind == "code" {
            try require(cell.ok && cell.error.isEmpty, "Cell \(cell.id): \(cell.error)")
        }
    }
    static func oracle(_ path: String, _ query: String) throws -> [[String: Any]] {
        let process = Process(), pipe = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        // Foundation treats argv strings as filesystem representations on macOS,
        // decomposing Cyrillic identifiers. SQL must retain the DB's exact UTF-8.
        process.arguments = ["-readonly", "-json", path]
        process.standardOutput = pipe
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data((query + ";\n").utf8))
        try input.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "SQLite CLI oracle")
        return data.isEmpty ? [] : try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    }
    @MainActor static func validate(_ model: NotebookModel, database: String, table: String, search: String, page: Int, size: Int) throws {
        // Independent SQLite CLI verifies server-side counts and page boundaries.
        let literal = "'" + search.replacingOccurrences(of: "'", with: "''") + "'"
        let predicate = search.isEmpty ? "" : " WHERE instr(COALESCE(\"Код наряда/заказ\", ''), \(literal)) > 0 OR instr(CAST(\"Полный номер наряда\" AS TEXT), \(literal)) > 0"
        let total = try oracle(database, "SELECT count(*) AS n FROM \"\(table)\"" + predicate)[0]["n"] as! Int
        let pages = max(1, (total + size - 1) / size), current = min(page, pages)
        let expected = try oracle(database, "SELECT \"Полный номер наряда\" AS n, trim(\"Код наряда/заказ\") AS label, \"ВесИтого\" AS weight FROM \"\(table)\"" + predicate + " ORDER BY rowid LIMIT \(size) OFFSET \((current - 1) * size)")
        let cell = model.activeTab!.cells.first { $0.id == "2" }!
        func local(_ name: String) -> String? { cell.locals.first { $0.name == name && $0.role == "module_cell" }?.value }
        try require(local("matching_rows") == String(total), "SQL total matches CLI: \(table)")
        try require(local("current_page") == String(current) && local("page_count") == String(pages), "SQL page count and clamping")
        try require(local("readonly") == "true", "database opened read-only")
        try require(cell.result == String(expected.count), "table publication is independent from the final scalar expression")
        let published = cell.displays?.first { $0.mime == "application/vnd.sputnik.table+json" && $0.id == "rows" }
        guard let published, let text = String(data: published.data, encoding: .utf8), let snapshot = NotebookTableSnapshot.decode(text) else {
            throw SQLiteTestFailure(message: "Missing Data Table snapshot (\(expected.count) expected rows)")
        }
        try require(snapshot.rows.count == expected.count && !snapshot.truncated, "bounded SQL page arrives without presentation truncation")
        if !expected.isEmpty {
            let index = snapshot.columns.firstIndex { $0.title == "Наряд" }!
            let label = snapshot.columns.firstIndex { $0.title == "Заказ" }!
            let weight = snapshot.columns.firstIndex { $0.title == "Вес" }!
            for (actual, expected) in zip(snapshot.rows, expected) {
                if let number = expected["n"] as? NSNumber {
                    try require(Decimal(string: actual.values[index].text) == number.decimalValue, "row identity/order matches SQL")
                } else {
                    try require(actual.values[index].text.isEmpty, "SQL NULL order number")
                }
                try require(actual.values[label].text == (expected["label"] as? String ?? ""), "Unicode text survives native/worker/table transport")
                if let number = expected["weight"] as? NSNumber {
                    let actual = Double(actual.values[weight].text) ?? .infinity
                    try require(abs(actual - number.doubleValue) < 1e-9, "SQLite numeric values survive transport")
                } else {
                    try require(actual.values[weight].text.isEmpty, "SQL NULL weight")
                }
            }
            let sorted = snapshot.visibleRows(query: "", column: index, ascending: false)
            try require(sorted.count == snapshot.rows.count, "local sort retains fetched page")
            try require(snapshot.csv(snapshot.rows).contains("Наряд"), "CSV preserves table headers")
            try require(snapshot.markdown(snapshot.rows).contains("| Наряд |"), "Markdown preserves table headers")
        }
        print("Verified \(table): \(expected.count) / \(total), page \(current) / \(pages)")
    }
    @MainActor static func preview(_ model: NotebookModel, output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let board = model.snapshot!.boards!.first!
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 1600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: NotebookBoardView(model: model, board: board, onDesign: {}).environment(\.colorScheme, scheme))
            window.contentView = host
            try await Task.sleep(nanoseconds: 300_000_000)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw SQLiteTestFailure(message: "preview bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(scheme == .light ? "sqlite-light.png" : "sqlite-dark.png"))
        }
    }
    @MainActor static func shutdown(_ model: NotebookModel) async {
        await withCheckedContinuation { c in model.shutdown { c.resume() } }
    }
}

import AppKit
import SwiftUI

struct NotebookTableSnapshot: Decodable {
    struct Column: Decodable, Identifiable { let id: String, title: String, type: String }
    struct Row: Decodable, Identifiable { let id: String, values: [NotebookTableValue] }
    let columns: [Column], rows: [Row]
    let total_rows: Int, truncated: Bool

    static func decode(_ json: String) -> Self? {
        guard json.utf8.count <= 1024 * 1024, let value = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)),
              !value.columns.isEmpty, value.columns.count <= 32, value.rows.count <= 4096,
              value.total_rows >= value.rows.count,
              value.truncated || value.total_rows == value.rows.count,
              Set(value.columns.map(\.id)).count == value.columns.count,
              Set(value.rows.map(\.id)).count == value.rows.count,
              value.columns.allSatisfy({ ["null", "text", "integer", "number", "boolean", "mixed"].contains($0.type) && $0.title.utf8.count <= 1024 }),
              value.rows.allSatisfy({ $0.values.count == value.columns.count && $0.values.allSatisfy { $0.text.utf8.count <= 24576 } }) else { return nil }
        return value
    }

    func visibleRows(query: String, column: Int?, ascending: Bool) -> [Row] {
        let filtered = query.isEmpty ? rows : rows.filter { $0.values.contains { $0.text.localizedCaseInsensitiveContains(query) } }
        guard let column, columns.indices.contains(column) else { return filtered }
        return filtered.enumerated().sorted { left, right in
            let comparison = left.element.values[column].compare(right.element.values[column])
            return comparison == .orderedSame ? left.offset < right.offset :
                ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }.map(\.element)
    }
    func csv(_ rows: [Row]) -> String {
        func field(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return ([columns.map { field($0.title) }.joined(separator: ",")] + rows.map { $0.values.map { field($0.text) }.joined(separator: ",") }).joined(separator: "\r\n") + "\r\n"
    }
    func markdown(_ rows: [Row]) -> String {
        func field(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n", with: "<br>")
        }
        func line(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }
        return ([line(columns.map { field($0.title) }), line(columns.map { _ in "---" })] +
                rows.map { line($0.values.map { field($0.text) }) }).joined(separator: "\n") + "\n"
    }
}

struct NotebookTableView: View {
    let table: NotebookTableSnapshot
    var stale = false
    var height: CGFloat? = nil
    var selectionBinding: NotebookTableSelectionBinding? = nil
    var sourceID = ""
    @State private var query = ""
    @State private var sortedColumn: Int?
    @State private var ascending = true
    @State private var selectedRow: String?
    private var rows: [NotebookTableSnapshot.Row] { table.visibleRows(query: query, column: sortedColumn, ascending: ascending) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Filter rows…", text: $query).textFieldStyle(.roundedBorder)
                NotebookObjectMenu(title: "Table actions") {
                    Button("Copy CSV") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(table.csv(rows), forType: .string) }
                    Button("Save CSV…") { save(markdown: false) }
                    Button("Copy Markdown") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(table.markdown(rows), forType: .string) }
                    Button("Save Markdown…") { save(markdown: true) }
                    if let row = rows.first(where: { $0.id == selectedRow }) {
                        Button("Copy selected row") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.values.map(\.text).joined(separator: "\t"), forType: .string) }
                    }
                    Button("Reset sorting") { sortedColumn = nil }
                }
            }
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(Array(table.columns.enumerated()), id: \.element.id) { index, column in
                            Button {
                                if sortedColumn == index { ascending.toggle() } else { sortedColumn = index; ascending = true }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack { Text(column.title).lineLimit(1); if sortedColumn == index { Image(systemName: ascending ? "chevron.up" : "chevron.down") } }
                                    Text(column.type).font(.caption2).foregroundStyle(NotebookPalette.muted)
                                }.frame(width: 150, alignment: .leading).padding(8)
                            }.buttonStyle(.plain).accessibilityLabel("Sort by \(column.title)")
                        }
                    }.background(NotebookPalette.canvas)
                    Divider()
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                HStack(spacing: 0) {
                                    ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                                        Text(value.text).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                                            .frame(minHeight: 24).frame(width: 150, alignment: .leading).padding(8)
                                    }
                                }
                                .background(selectedRow == row.id ? NotebookPalette.sputnik.opacity(0.12) : .clear)
                                .contentShape(Rectangle()).onTapGesture { selectedRow = row.id }
                                .accessibilityElement(children: .combine)
                                Divider()
                            }
                        }
                    }.frame(height: height.map { max(48, $0 - 90) } ?? 260)
                }
            }
            if let binding = selectionBinding {
                HStack {
                    Button("Apply selection") { if let selection = pendingSelection { binding.apply(selection) } }
                        .disabled(pendingSelection == nil || binding.disabled).accessibilityIdentifier("table-apply-selection")
                    Button("Clear selection") { selectedRow = nil; binding.apply(nil) }.disabled(binding.disabled || binding.accepted == nil)
                    Text(selectionMessage(binding)).font(.caption).foregroundStyle(NotebookPalette.muted)
                }
            }
            HStack {
                Text("\(rows.count) shown · \(table.total_rows) rows")
                if table.truncated { Text("Snapshot limited · export contains retained rows") }
                if stale { Label("Previous result · stale", systemImage: "clock") }
            }.font(.caption).foregroundStyle(stale ? NotebookPalette.sputnik : NotebookPalette.muted)
        }.onAppear { restoreSelection() }.onChange(of: sourceID) { selectedRow = nil; restoreSelection() }
    }
    private var keyIndex: Int? {
        guard let name = selectionBinding?.keyColumn, !name.isEmpty else { return nil }
        return table.columns.firstIndex { $0.id == name || $0.title == name }
    }
    private var validKeys: Bool {
        guard let keyIndex, Set(table.columns.map(\.title)).count == table.columns.count else { return false }
        let keys = table.rows.map { $0.values[keyIndex] }
        let encoded = keys.compactMap { try? JSONEncoder().encode($0) }
        return !keys.contains(.null) && encoded.count == keys.count && Set(encoded).count == keys.count
    }
    private var pendingSelection: NotebookSharedSelection? {
        guard validKeys, let keyIndex, let row = table.rows.first(where: { $0.id == selectedRow }) else { return nil }
        return .init(source: sourceID, key: row.values[keyIndex], row: table.columns.enumerated().reduce(into: [String: NotebookTableValue]()) { $0[$1.element.title] = row.values[$1.offset] })
    }
    private func restoreSelection() {
        guard let accepted = selectionBinding?.accepted, accepted.source == sourceID, let keyIndex else { return }
        selectedRow = table.rows.first { $0.values[keyIndex] == accepted.key }?.id
    }
    private func selectionMessage(_ binding: NotebookTableSelectionBinding) -> String {
        if !validKeys { return "Choose a unique, nonempty key column in the designer" }
        if let accepted = binding.accepted, accepted.source != sourceID { return "Table changed · select and Apply again" }
        return "Select a row, then Apply · no automatic Run"
    }
    private func save(markdown: Bool) {
        let text = markdown ? table.markdown(rows) : table.csv(rows)
        let panel = NSSavePanel(); panel.nameFieldStringValue = markdown ? "table.md" : "table.csv"
        if panel.runModal() == .OK, let url = panel.url {
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { let alert = NSAlert(error: error); alert.runModal() }
        }
    }
}

struct NotebookPublishedTableView: View {
    let panel: NotebookFigurePanel
    var stale = false
    var height: CGFloat? = nil
    var selectionBinding: NotebookTableSelectionBinding? = nil
    @State private var table: NotebookTableSnapshot?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !panel.caption.isEmpty { Text(panel.caption).font(.callout.bold()).textSelection(.enabled) }
            if let table { NotebookTableView(table: table, stale: stale, height: height, selectionBinding: selectionBinding, sourceID: notebookAssetID(panel.data)) }
            else { Label("Table snapshot unavailable", systemImage: "tablecells.badge.ellipsis").foregroundStyle(NotebookPalette.muted) }
        }.onAppear(perform: update).onChange(of: panel.data) { update() }
    }
    private func update() { table = NotebookTableSnapshot.decode(String(data: panel.data, encoding: .utf8) ?? "") }
}

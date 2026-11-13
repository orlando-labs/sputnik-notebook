import SwiftUI

struct NotebookCellExportsEditor: View {
    private struct Request: Encodable, Sendable {
        let source: String
        var exports: [NotebookCellExport]? = nil
    }
    private struct Analysis: Decodable, Sendable {
        let bindings: [String]
        let exports: [NotebookCellExport]
    }
    private struct UpdatedSource: Decodable, Sendable { let source: String }
    private struct Row {
        let binding: String
        let available: Bool
        var enabled: Bool
        var alias = ""
        var value: NotebookCellExport {
            let name = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            return NotebookCellExport(name: name.isEmpty ? binding : name, binding: binding)
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row]?
    @State private var error: String?
    @State private var applying = false
    let model: NotebookModel
    let tab: NotebookTab
    let cell: NotebookCell
    @State private var source: String

    init(model: NotebookModel, tab: NotebookTab, cell: NotebookCell) {
        self.model = model
        self.tab = tab
        self.cell = cell
        _source = State(initialValue: model.source(for: cell, in: tab))
    }

    private static func parse<Result: Decodable & Sendable>(_ request: Request, as type: Result.Type) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            var error: UnsafeMutablePointer<CChar>?
            let value = sputnik_notebook_cell_exports(json, &error)
            defer { sputnik_notebook_string_free(value); sputnik_notebook_string_free(error) }
            guard let value else {
                throw NSError(domain: "NotebookCellExports", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: error.map { String(cString: $0) } ?? "Could not analyze cell exports."
                ])
            }
            return try JSONDecoder().decode(type, from: Data(String(cString: value).utf8))
        }.value
    }

    private var selection: [Row] { rows?.filter(\.enabled) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exports · \(tab.cellLabel(for: cell.id))").font(.headline)
            if let rows {
                if rows.isEmpty {
                    Text("This cell has no bindings to export.").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(rows.indices, id: \.self) { index in
                                let row = rows[index]
                                HStack {
                                    Toggle(isOn: Binding(get: { self.rows?[index].enabled ?? false },
                                                         set: { self.rows?[index].enabled = $0 })) {
                                        Text(row.binding).font(.system(.body, design: .monospaced))
                                    }.toggleStyle(.checkbox)
                                    Spacer()
                                    if !row.available {
                                        Text("Binding missing").foregroundStyle(.secondary)
                                    } else if row.enabled {
                                        TextField("Export as \(row.binding)",
                                                  text: Binding(get: { self.rows?[index].alias ?? "" },
                                                                set: { self.rows?[index].alias = $0 }))
                                            .accessibilityLabel("Export name for \(row.binding)")
                                            .font(.system(.body, design: .monospaced)).frame(width: 190)
                                    }
                                }.frame(minHeight: 24)
                            }
                        }.padding(.vertical, 3).padding(.trailing, 12)
                    }.frame(height: min(CGFloat(rows.count) * 32 + 6, 284))
                        .disabled(applying)
                }
            } else if error == nil {
                ProgressView("Analyzing cell…").controlSize(.small)
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(applying)
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
                    .disabled(rows == nil || applying || !model.canEdit || selection.contains { !$0.available })
            }
        }.padding(20).frame(width: 480).task {
            do {
                let analysis = try await Self.parse(Request(source: source), as: Analysis.self)
                let available = Set(analysis.bindings)
                let declared = Dictionary(grouping: analysis.exports, by: \.binding)
                rows = (available.union(declared.keys)).sorted().flatMap { binding in
                    let present = available.contains(binding)
                    return declared[binding]?.map {
                        Row(binding: binding, available: present, enabled: true, alias: $0.name == binding ? "" : $0.name)
                    } ?? [Row(binding: binding, available: true, enabled: false)]
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func apply() {
        let request = Request(source: source, exports: selection.map(\.value))
        applying = true
        error = nil
        Task {
            do {
                let updated = try await Self.parse(request, as: UpdatedSource.self)
                guard let currentTab = model.snapshot?.tabs.first(where: { $0.id == tab.id }),
                      let currentCell = currentTab.cells.first(where: { $0.id == cell.id }),
                      model.source(for: currentCell, in: currentTab) == source else {
                    error = "The cell changed. Reopen Exports to refresh the list."
                    applying = false
                    return
                }
                if updated.source == source { dismiss(); return }
                model.perform("source", tab: tab, cell: cell, text: updated.source) { success in
                    applying = false
                    if success { dismiss() }
                    else { error = model.error ?? "Could not update cell exports." }
                }
            } catch {
                self.error = error.localizedDescription
                applying = false
            }
        }
    }
}

struct NotebookSheetImportsEditor: View {
    private struct Choice: Identifiable {
        let link: NotebookSheetImport
        let label: String
        var id: NotebookSheetImport { link }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var imports: [NotebookSheetImport]
    @State private var selected: NotebookSheetImport?
    let model: NotebookModel
    let tab: NotebookTab
    let tabs: [NotebookTab]

    init(model: NotebookModel, tab: NotebookTab, tabs: [NotebookTab]) {
        self.model = model
        self.tab = tab
        self.tabs = tabs
        _imports = State(initialValue: tab.imports ?? [])
    }

    private var choices: [Choice] {
        tabs.filter { $0.kind == "sheet" && $0.id != tab.id }.flatMap { source in
            source.cells.flatMap { cell in
                (cell.exports ?? []).map { value in
                    Choice(link: NotebookSheetImport(name: value.name, sheet: String(source.id.dropFirst(6)),
                                                     cell: cell.id, export: value.name),
                           label: "\(source.title) · \(source.cellLabel(for: cell.id)) · \(value.name)")
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Imports · \(tab.title)").font(.headline)
            ForEach(imports.indices, id: \.self) { index in
                HStack {
                    TextField("Local name", text: $imports[index].name).frame(width: 155)
                    let link = imports[index]
                    let title = tabs.first { $0.id == "sheet:" + link.sheet }?.title ?? link.sheet
                    Text("\(title) · \(link.export)").lineLimit(1)
                    Spacer()
                    Button(role: .destructive) { imports.remove(at: index) } label: {
                        Image(systemName: "minus.circle")
                    }.help("Remove import").accessibilityLabel("Remove import")
                }
            }
            HStack {
                Picker("Export", selection: $selected) {
                    Text("Choose an export").tag(nil as NotebookSheetImport?)
                    ForEach(choices) { choice in Text(choice.label).tag(Optional(choice.link)) }
                }
                Button("Add") {
                    guard var link = selected else { return }
                    let name = link.name
                    var suffix = 2
                    while imports.contains(where: { $0.name == link.name }) {
                        link.name = "\(name)_\(suffix)"
                        suffix += 1
                    }
                    imports.append(link)
                    selected = nil
                }.disabled(selected == nil)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let json = try? JSONEncoder().encode(imports) else { return }
                    model.perform("sheet_imports", tab: tab, text: String(decoding: json, as: UTF8.self)) {
                        if $0 { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction)
                    .disabled(imports.contains { $0.name.isEmpty } || Set(imports.map(\.name)).count != imports.count)
            }
        }.padding(20).frame(width: 550)
    }
}

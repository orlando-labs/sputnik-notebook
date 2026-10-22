import AppKit
import SwiftUI

struct NotebookMetricValue {
    let text: String
    let number: Double?
    static func make(_ source: String?, settings: NotebookP1Settings) -> Self {
        guard let source, let number = Double(source), number.isFinite else { return Self(text: "Unavailable", number: nil) }
        let scaled = settings.percentage == true ? number * 100 : number
        guard scaled.isFinite else { return Self(text: "Out of range", number: number) }
        let precision = max(0, min(12, settings.precision ?? 2))
        let text = settings.percentage != true && Int64(source) != nil && settings.precision == nil ? source : scaled.formatted(.number.precision(.fractionLength(precision)))
        return Self(text: text + (settings.percentage == true ? "%" : "") + (settings.unit.map { " \($0)" } ?? ""), number: number)
    }
}
struct NotebookMetricView: View {
    @ObservedObject var model: NotebookModel
    let component: NotebookBoardComponent, tab: NotebookTab, cell: NotebookCell
    private var value: NotebookMetricValue {
        let local = cell.locals.first { $0.name == component.binding && $0.role == "module_cell" && $0.initialized }
        return .make((component.binding ?? "").isEmpty ? (cell.ok ? cell.result : nil) : local.map { $0.text_value ?? $0.value }, settings: component.settings)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value.text).font(.system(size: 30, weight: .semibold, design: .rounded)).textSelection(.enabled)
            if let target = component.settings.target {
                Text("Target: \(NotebookMetricValue.make(String(target), settings: component.settings).text)").font(.caption)
            }
            if let number = value.number, let baseline = component.settings.baseline {
                let delta = number - baseline
                if delta.isFinite {
                    let better = component.settings.improvement == "lower" ? delta < 0 : delta > 0
                    Label("Δ \(delta >= 0 ? "+" : "")\(NotebookMetricValue.make(String(delta), settings: component.settings).text)", systemImage: delta >= 0 ? "arrow.up" : "arrow.down")
                        .font(.callout).foregroundStyle(component.settings.improvement == "neutral" ? NotebookPalette.muted : better ? NotebookPalette.success : NotebookPalette.error)
                }
            }
            if model.figureIsStale(for: cell, in: tab) { Label("Previous value · stale", systemImage: "clock").font(.caption).foregroundStyle(NotebookPalette.sputnik) }
            if let date = model.componentUpdatedAt[tab.id + ":" + cell.id] { Text("Updated \(date.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(NotebookPalette.muted) }
        }
    }
}

struct NotebookTargetStatus {
    var title: String, detail: String, symbol: String
    var failed = false
    var stale = false
}
struct NotebookStatusView: View {
    @ObservedObject var model: NotebookModel
    let board: NotebookBoard, component: NotebookBoardComponent, tab: NotebookTab
    var body: some View {
        let state = model.targetStatus(board: board, component: component, tab: tab)
        VStack(alignment: .leading, spacing: 8) {
            Label(state.title, systemImage: state.symbol).font(.headline)
                .foregroundStyle(state.failed ? NotebookPalette.error : state.stale ? NotebookPalette.sputnik : NotebookPalette.ink)
            if !state.detail.isEmpty { Text(state.detail).font(.callout).textSelection(.enabled) }
            if component.settings.target_kind != "runtime" { Button("Open source") {
                if ["service", "action"].contains(component.settings.target_kind ?? ""),
                   let source = board.allComponents.first(where: { $0.id == component.settings.target_component }),
                   let module = model.snapshot?.tabs.first(where: { $0.id == "module:" + (source.module_id ?? "") }) { model.selectTab(module) }
                else { model.selectTab(tab); if let id = component.cell { model.selectedCellID = id } }
            }.controlSize(.small).disabled(model.busy) }
        }
    }
}

struct NotebookLogEntry: Identifiable {
    let id: Int, stream: String
    var text: String
    let file: String?, line: Int?
    static func capture(_ output: [NotebookOutput]) -> [Self] {
        var result: [Self] = []
        for (index, event) in output.enumerated() {
            if let last = result.last, last.stream == event.stream && last.file == event.source_file && last.line == event.source_line && last.text.utf8.count + event.text.utf8.count <= 65536 {
                result[result.count - 1].text += event.text
            } else { result.append(.init(id: index, stream: event.stream, text: event.text, file: event.source_file, line: event.source_line)) }
        }
        return result
    }
}
struct NotebookLogView: View {
    let cell: NotebookCell
    var stale = false
    var height: CGFloat? = nil
    var sourceLabel = "Cell"
    var output: [NotebookOutput]? = nil
    var running = false
    @State private var query = ""
    @State private var stream = "all"
    private var events: [NotebookLogEntry] {
        NotebookLogEntry.capture(output ?? cell.output).filter { (stream == "all" || $0.stream == stream) && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)) }
    }
    private var exported: String { events.map { "[\($0.stream)] \($0.text)" }.joined() + (cell.error.isEmpty ? "" : "\n[diagnostic] " + cell.error) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Find in output…", text: $query).textFieldStyle(.roundedBorder)
                Picker("Stream", selection: $stream) { Text("All").tag("all"); Text("stdout").tag("stdout"); Text("stderr").tag("stderr") }.labelsHidden().frame(width: 100)
                NotebookObjectMenu(title: "Log actions") {
                    Button("Copy filtered output") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(exported, forType: .string) }
                    Button("Save output…") { let panel = NSSavePanel(); panel.nameFieldStringValue = "output.log"; if panel.runModal() == .OK, let url = panel.url { try? exported.write(to: url, atomically: true, encoding: .utf8) } }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(events.prefix(4096)) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(event.id + 1) · \(event.stream)" + (event.file.map { " · \($0.contains("isputnik-cell-") ? sourceLabel : $0):\(event.line ?? 0)" } ?? "")).font(.caption2).foregroundStyle(NotebookPalette.muted)
                            Text(String(event.text.prefix(65536))).font(.system(.caption, design: .monospaced)).foregroundStyle(event.stream == "stderr" ? NotebookPalette.error : NotebookPalette.ink).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !cell.error.isEmpty && (query.isEmpty || cell.error.localizedCaseInsensitiveContains(query)) { Text(cell.error).font(.system(.caption, design: .monospaced)).foregroundStyle(NotebookPalette.error).textSelection(.enabled) }
                    if events.isEmpty && cell.error.isEmpty { Text("No matching output").foregroundStyle(NotebookPalette.muted) }
                }
            }.frame(height: height ?? 200)
            Text((running ? "Live output · " : stale ? "Previous output · stale · " : "Committed output · ") + "\(events.count) events" + (events.count > 4096 ? " · display limited to 4,096" : ""))
                .font(.caption2).foregroundStyle(NotebookPalette.muted)
        }
    }
}

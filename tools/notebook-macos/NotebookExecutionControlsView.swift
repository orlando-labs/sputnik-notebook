import SwiftUI

struct NotebookExecutionControlsView: View {
    @ObservedObject var model: NotebookModel
    let board: NotebookBoard, component: NotebookBoardComponent, tab: NotebookTab
    @State private var force = false
    private var kind: String { component.settings.target_kind ?? "sheet" }
    private var target: NotebookBoardComponent? { board.allComponents.first { $0.id == component.settings.target_component } }
    private var active: Bool { model.executingTargetID == model.targetKey(board: board, component: component, tab: tab) || (model.remote.isSelected && ["sheet", "cell"].contains(kind) && model.executingCurrentWorker) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let state = model.targetStatus(board: board, component: component, tab: tab)
            Label(state.title, systemImage: state.symbol).font(.callout)
            HStack {
                Button("Run", systemImage: "play.fill", action: run).disabled(model.busy || !available)
                if kind == "service", let target {
                    Button("Pause", systemImage: "pause.fill") { model.pausePeriodic(board: board, component: target) }
                    Button("Start") { model.startPeriodic(board: board, component: target) }.disabled(model.busy)
                }
                Button("Stop", systemImage: "stop.fill") { model.stopExecution() }.disabled(!active || !model.canStop)
            }
            HStack {
                if model.isolatedExecution {
                    Button("Force Stop…", role: .destructive) { force = true }.disabled(!active || !model.canForceStop)
                    Button("Restart") {
                        if kind == "sheet" || kind == "cell" { model.perform("restart_worker", tab: tab) }
                        else { model.perform("periodic_dispose", tab: tab, text: board.id, commandCellID: target?.id) }
                    }.disabled(model.busy || !available)
                }
                if active, let start = model.executionStarted {
                    TimelineView(.periodic(from: start, by: 1)) { context in Text("\(max(0, context.date.timeIntervalSince(start)).formatted(.number.precision(.fractionLength(0)))) s").font(.caption).foregroundStyle(NotebookPalette.muted) }
                }
            }.controlSize(.small)
            if active && !model.isolatedExecution { Text("Stop is available in isolated execution mode.").font(.caption).foregroundStyle(NotebookPalette.muted) }
        }.confirmationDialog("Terminate this worker? Its current runtime will be discarded.", isPresented: $force) {
            Button("Force Stop", role: .destructive) { model.stopExecution(force: true) }
        }
    }
    private var available: Bool { kind == "sheet" || (kind == "cell" ? tab.cells.contains { $0.id == component.cell } : target != nil) }
    private func run() {
        if kind == "service", let target { model.runPeriodicOnce(board: board, component: target) }
        else if kind == "action", let target { model.runAction(board: board, component: target) }
        else if kind == "cell", let cell = tab.cells.first(where: { $0.id == component.cell }) { model.perform("run", tab: tab, cell: cell) }
        else { model.perform("run_all", tab: tab) }
    }
}

struct NotebookActionButtonView: View {
    @ObservedObject var model: NotebookModel
    let board: NotebookBoard, component: NotebookBoardComponent
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(component.title, systemImage: "bolt.fill") { model.runAction(board: board, component: component) }
                .buttonStyle(.borderedProminent).tint(NotebookPalette.sputnik).disabled(model.busy)
            if model.executingTargetID == board.id + ":" + component.id { Label(model.executionLabel, systemImage: "hourglass").font(.caption) }
            else if let result = model.invocationResult(board.id + ":" + component.id) {
                Label(result.ok ? "Success" : "Error", systemImage: result.ok ? "checkmark.circle" : "exclamationmark.circle").font(.caption)
                if model.actionIsStale(board: board, component: component) { Label("Arguments or module changed · previous run", systemImage: "clock").font(.caption).foregroundStyle(NotebookPalette.sputnik) }
                Text(result.ok ? result.result : result.error).font(.system(.caption, design: .monospaced)).foregroundStyle(result.ok ? NotebookPalette.ink : NotebookPalette.error).lineLimit(8).textSelection(.enabled)
            }
        }
    }
}

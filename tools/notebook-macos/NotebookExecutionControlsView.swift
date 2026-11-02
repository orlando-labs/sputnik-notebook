import SwiftUI

struct NotebookExecutionControlsView: View {
    @ObservedObject var model: NotebookModel
    let board: NotebookBoard, component: NotebookBoardComponent, tab: NotebookTab
    @State private var force = false
    @State private var forceRun: NotebookRemoteRun?
    private var kind: String { component.settings.target_kind ?? "sheet" }
    private var target: NotebookBoardComponent? { board.allComponents.first { $0.id == component.settings.target_component } }
    private var remoteRun: NotebookRemoteRun? { model.targetRun(board: board, component: component, tab: tab) }
    private var active: Bool { model.remote.isSelected ? remoteRun?.active == true : model.executingTargetID == model.targetKey(board: board, component: component, tab: tab) }
    private var canStop: Bool { model.remote.isSelected ? model.remote.connected && remoteRun?.state != "terminating" : model.canStop }
    private var canForceStop: Bool { model.remote.isSelected ? model.remote.connected : model.canForceStop }
    private var scheduleEnabled: Bool { kind == "service" && target.map { model.periodicState(board: board, component: $0).enabled } == true }
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
                Button("Stop", systemImage: "stop.fill") { model.stopTarget(board: board, component: component, tab: tab) }.disabled(!active || !canStop)
            }
            HStack {
                if model.isolatedExecution {
                    Button("Force Stop…", role: .destructive) { forceRun = remoteRun; force = true }.disabled(!active || !canForceStop)
                    Button("Restart") {
                        if kind == "sheet" || kind == "cell" { model.perform("restart_worker", tab: tab) }
                        else { model.perform("periodic_dispose", tab: tab, text: board.id, commandCellID: target?.id) }
                    }.disabled(model.busy || (model.remote.isSelected && (model.remote.busy || !model.remote.connected || active || scheduleEnabled)) || !available)
                }
                if active, let start = model.executionStarted {
                    TimelineView(.periodic(from: start, by: 1)) { context in Text("\(max(0, context.date.timeIntervalSince(start)).formatted(.number.precision(.fractionLength(0)))) s").font(.caption).foregroundStyle(NotebookPalette.muted) }
                }
            }.controlSize(.small)
            if active && !model.isolatedExecution { Text("Stop is available in isolated execution mode.").font(.caption).foregroundStyle(NotebookPalette.muted) }
        }.confirmationDialog("Terminate this worker? Its current runtime will be discarded.", isPresented: $force) {
            Button("Force Stop", role: .destructive) {
                if model.remote.isSelected { if let forceRun { model.remote.stop(run: forceRun, force: true) } }
                else { model.stopExecution(force: true) }
            }
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
    private var remoteRun: NotebookRemoteRun? { model.remote.runs.last { $0.board == board.id && $0.component == component.id && $0.active } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(component.title, systemImage: "bolt.fill") { model.runAction(board: board, component: component) }
                .buttonStyle(.borderedProminent).tint(NotebookPalette.sputnik).disabled(model.busy)
            if model.remote.isSelected, let remoteRun { Label(remoteRun.label, systemImage: "hourglass").font(.caption) }
            else if !model.remote.isSelected && model.executingTargetID == board.id + ":" + component.id { Label(model.executionLabel, systemImage: "hourglass").font(.caption) }
            else if let result = model.invocationResult(board.id + ":" + component.id) {
                Label(result.ok ? "Success" : "Error", systemImage: result.ok ? "checkmark.circle" : "exclamationmark.circle").font(.caption)
                if model.actionIsStale(board: board, component: component) { Label("Arguments or module changed · previous run", systemImage: "clock").font(.caption).foregroundStyle(NotebookPalette.sputnik) }
                Text(result.ok ? result.result : result.error).font(.system(.caption, design: .monospaced)).foregroundStyle(result.ok ? NotebookPalette.ink : NotebookPalette.error).lineLimit(8).textSelection(.enabled)
            }
        }
    }
}

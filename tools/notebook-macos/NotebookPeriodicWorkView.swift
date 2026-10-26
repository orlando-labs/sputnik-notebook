import SwiftUI

struct NotebookPeriodicWorkView: View {
    @ObservedObject var model: NotebookModel
    let board: NotebookBoard
    let component: NotebookBoardComponent
    private var state: NotebookPeriodicState { model.periodicState(board: board, component: component) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Label(component.title, systemImage: "timer").font(.headline)
                Text(state.status).font(.caption).foregroundStyle(state.failures > 0 ? NotebookPalette.sputnik : NotebookPalette.muted)
                Spacer()
                if state.running { ProgressView().controlSize(.small) }
                if state.enabled {
                    Button("Pause", systemImage: "pause.fill") { model.pausePeriodic(board: board, component: component) }
                } else {
                    Button("Start", systemImage: "play.fill") { model.startPeriodic(board: board, component: component) }.disabled(model.busy)
                }
                Button("Run Once") { model.runPeriodicOnce(board: board, component: component) }.disabled(model.busy)
            }
            if model.remote.isSelected { Text("Server schedule continues when this board or app is closed.").font(.caption).foregroundStyle(NotebookPalette.muted) }
            HStack(spacing: 16) {
                Text("\(component.module_id ?? "?").\(component.function ?? "?")()")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("Every \(state.settings.period.formatted()) s · \(state.settings.timing == "fixed_rate" ? "start to start" : "after completion")")
                Text("\(state.runs) runs · \(state.failures) errors · \(state.skipped) skipped")
            }.font(.caption).foregroundStyle(NotebookPalette.muted)
            if !state.history.isEmpty {
                DisclosureGroup("History · \(state.history.count) stored runs") {
                    HStack {
                        Spacer()
                        Button("Clear history") { model.clearPeriodicHistory(board: board, component: component) }.controlSize(.small)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(state.history.reversed()) { run in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Image(systemName: run.ok ? "checkmark.circle" : "exclamationmark.circle")
                                            .foregroundStyle(run.ok ? NotebookPalette.muted : NotebookPalette.error)
                                        Text("#\(run.id) · \(run.started.formatted(date: .omitted, time: .standard)) · \(run.duration.formatted(.number.precision(.fractionLength(3)))) s")
                                            .foregroundStyle(NotebookPalette.muted)
                                    }
                                    Text(run.value ?? run.error ?? "").textSelection(.enabled)
                                        .foregroundStyle(run.ok ? NotebookPalette.ink : NotebookPalette.error)
                                }.font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                            }
                        }
                    }.frame(maxHeight: 220)
                }
            }
        }.padding(16).background(NotebookPalette.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(NotebookPalette.rule))
            .accessibilityIdentifier("periodic-work-\(component.id)")
    }
}

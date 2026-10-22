import SwiftUI

enum NotebookDuration {
    static func text(_ milliseconds: UInt64) -> String {
        let seconds = milliseconds / 1000
        let fraction = (milliseconds % 1000) / 10
        if seconds >= 3600 { return String(format: "%llu:%02llu:%02llu.%02llu", seconds / 3600, seconds / 60 % 60, seconds % 60, fraction) }
        return String(format: "%02llu:%02llu.%02llu", seconds / 60, seconds % 60, fraction)
    }
}

struct NotebookCellTimer: View {
    @ObservedObject var model: NotebookModel
    let cell: NotebookCell, tab: NotebookTab
    var body: some View {
        if model.cellTiming(cell, in: tab)?.running == true {
            TimelineView(.periodic(from: .now, by: 0.05)) { _ in timer }
        } else { timer }
    }
    @ViewBuilder private var timer: some View {
        if let timing = model.cellTiming(cell, in: tab) {
            Label(NotebookDuration.text(timing.milliseconds), systemImage: timing.running ? "stopwatch" : "clock")
                .font(.system(size: 11, design: .monospaced)).monospacedDigit()
                .foregroundStyle(timing.running ? NotebookPalette.sputnik : NotebookPalette.muted)
                .help(timing.running ? "Cell execution time · running" : "Last cell execution time")
                .accessibilityLabel("Cell execution time: \(NotebookDuration.text(timing.milliseconds))")
        }
    }
}

struct NotebookStopwatchView: View {
    @ObservedObject var model: NotebookModel
    let tab: NotebookTab
    var channel = "default"
    var body: some View {
        Group {
            if model.stopwatches(in: tab, channel: channel).running {
                TimelineView(.periodic(from: .now, by: 0.05)) { _ in display }
            } else { display }
        }.accessibilityIdentifier("notebook-stopwatch-\(channel)")
    }
    private var display: some View {
        let state = model.stopwatches(in: tab, channel: channel)
        return Group {
            if state.items.isEmpty {
                Label("Waiting for Stopwatch.measure(\"\(channel)\")", systemImage: "stopwatch")
                    .font(.callout).foregroundStyle(NotebookPalette.muted)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(state.items) { timer in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(timer.id, systemImage: "stopwatch").font(.caption).foregroundStyle(NotebookPalette.muted)
                            Text(NotebookDuration.text(timer.elapsed_ms))
                                .font(.system(size: 32, weight: .medium, design: .monospaced)).monospacedDigit()
                                .foregroundStyle(NotebookPalette.ink).textSelection(.enabled)
                            Text(timer.done ? "Finished" : state.running ? "Running" : "Stopped")
                                .font(.caption).foregroundStyle(state.running && !timer.done ? NotebookPalette.sputnik : NotebookPalette.muted)
                        }
                    }
                    if state.stale { Label("Previous measurement · stale", systemImage: "clock").font(.caption).foregroundStyle(NotebookPalette.sputnik) }
                }
            }
        }
    }
}

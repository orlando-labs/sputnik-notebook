import Foundation

struct NotebookPeriodicSettings: Equatable {
    var module: String, function: String
    var period: Double, timing: String, retention: String
    var tailLimit: Int
    var storeValues: Bool, storeErrors: Bool, runImmediately: Bool, stopOnError: Bool, pauseWhenHidden: Bool

    var validationError: String? {
        let identifier = #"^[A-Za-z_][A-Za-z0-9_]*$"#
        if module.range(of: identifier, options: .regularExpression) == nil ||
            function.range(of: identifier, options: .regularExpression) == nil {
            return "Choose a module and an exported function name."
        }
        if !period.isFinite || !(0.01...31536000).contains(period) { return "Period must be 0.01…31536000 seconds." }
        if !["fixed_rate", "fixed_delay"].contains(timing) { return "Choose a scheduling mode." }
        if !["none", "all", "tail"].contains(retention) { return "Choose a history mode." }
        if !(1...1000000).contains(tailLimit) { return "Tail must be 1…1000000 runs." }
        return nil
    }
}

struct NotebookPeriodicResult: Decodable, Identifiable {
    let id: String
    let ok: Bool
    let result: String, error: String
}

struct NotebookPeriodicRun: Identifiable {
    let id: Int, started: Date, duration: Double, ok: Bool
    let value: String?, error: String?
}

// Monotonic uptime controls scheduling; dates are display metadata only.
// Each service holds one invocation, with no queue of missed ticks.
struct NotebookPeriodicState {
    var settings: NotebookPeriodicSettings
    var enabled = false, running = false, needsExplicitRun = true
    var nextDeadline: Double?
    var runs = 0, failures = 0, skipped = 0
    var status = "Stopped"
    var history: [NotebookPeriodicRun] = []

    mutating func start(at now: Double) {
        enabled = true; needsExplicitRun = true
        nextDeadline = now + (settings.runImmediately ? 0 : settings.period)
        status = "Waiting"
    }
    mutating func pause() {
        enabled = false; nextDeadline = nil
        status = running ? "Pausing after this run" : "Paused"
    }
    mutating func skipBusyTicks(at now: Double) {
        guard settings.timing == "fixed_rate", let deadline = nextDeadline, deadline <= now else { return }
        let count = Int(floor((now - deadline) / settings.period)) + 1
        skipped += count; nextDeadline = deadline + Double(count) * settings.period
    }
    mutating func complete(start: Double, end: Double, date: Date, ok: Bool, value: String, error: String) {
        running = false; runs += 1
        if !ok { failures += 1 }
        if settings.retention != "none" && (ok ? settings.storeValues : settings.storeErrors) {
            history.append(NotebookPeriodicRun(id: runs, started: date, duration: max(0, end - start), ok: ok,
                value: ok && settings.storeValues ? value : nil,
                error: !ok && settings.storeErrors ? error : nil))
            if settings.retention == "tail" && history.count > settings.tailLimit {
                history.removeFirst(history.count - settings.tailLimit)
            }
        }
        if !ok && settings.stopOnError { enabled = false }
        if enabled {
            if settings.timing == "fixed_delay" { nextDeadline = end + settings.period }
            else {
                let missed = max(0, Int(ceil((end - start) / settings.period)) - 1)
                skipped += missed
                nextDeadline = start + Double(missed + 1) * settings.period
            }
        } else { nextDeadline = nil }
        status = enabled ? (ok ? "Waiting" : "Last run failed") : (ok ? "Paused" : "Stopped after error")
    }
}

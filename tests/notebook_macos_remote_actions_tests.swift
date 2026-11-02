import AppKit
import Foundation
import SwiftUI

@main private enum RemoteActionsTests {
    struct Failure: Error { let message: String }
    static func option(_ key: String) -> String { CommandLine.arguments[CommandLine.arguments.firstIndex(of: key)! + 1] }
    static func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    static func externalGuard(_ book: URL) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard let handle = sputnik_notebook_open(book.path, 0, "", &error) else { throw Failure(message: "native fixture open") }
        defer { sputnik_notebook_destroy(handle); sputnik_notebook_string_free(error) }
        try check(sputnik_notebook_external(handle, 1, &error) != 0, "native external mode")
        let success = sputnik_notebook_command(handle, "periodic_dispose", "sheet:main", "counter", "board", &error)
        try check(success == 0 && error.map { String(cString: $0).contains("remote backend") } == true, "external C API cannot accept a local invocation-reset no-op")
    }
    @MainActor static func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<1400 { if condition() { return }; try await Task.sleep(nanoseconds: 25_000_000) }
        throw Failure(message: "timeout: " + message)
    }
    @MainActor static func perform(_ model: NotebookModel, _ action: String, cell: String? = nil, text: String = "") async throws {
        let success = await withCheckedContinuation { c in model.perform(action, text: text, commandCellID: cell) { c.resume(returning: $0) } }
        try check(success, model.error ?? ("failed: " + action))
    }
    @MainActor static func idle(_ model: NotebookModel) async throws {
        try await wait("idle " + (model.error ?? "")) { !model.remote.busy && !model.busy && !model.remote.active }
    }
    @MainActor static func open(_ model: NotebookModel, _ book: URL) async throws {
        let success = await withCheckedContinuation { c in model.open(url: book) { c.resume(returning: $0) } }
        try check(success, model.error ?? "open")
    }
    @MainActor static func close(_ model: NotebookModel) async { await withCheckedContinuation { c in model.shutdown { c.resume() } } }
    @MainActor static func connected(_ model: NotebookModel) async throws {
        try await wait("connected " + (model.error ?? "")) { model.remote.connected && !model.remote.busy && !model.remote.hasPending }
    }
    @MainActor static func invoke(_ model: NotebookModel, _ id: String) async throws -> NotebookRemoteRun {
        try await perform(model, "action_run", cell: id, text: "board")
        return model.remote.runs.last { $0.component == id }!
    }
    @MainActor static func history(_ model: NotebookModel, all: Bool = false) async throws {
        let loaded = await withCheckedContinuation { c in model.remote.loadHistory { c.resume(returning: $0) } }
        try check(loaded, model.remote.historyError ?? "history page")
        if all {
            while model.remote.historyHasMore {
                let more = await withCheckedContinuation { c in model.remote.loadHistory(older: true) { c.resume(returning: $0) } }
                try check(more, model.remote.historyError ?? "older history")
            }
        }
    }
    @MainActor static func change(_ model: NotebookModel, _ record: NotebookRunRecord, title: String? = nil, pinned: Bool? = nil, remove: Bool = false) async -> Bool {
        await withCheckedContinuation { c in model.remote.changeHistory(record, title: title, pinned: pinned, remove: remove) { c.resume(returning: $0) } }
    }
    @MainActor static func inputs(_ model: NotebookModel, _ values: [String: String]) async throws {
        let success = await withCheckedContinuation { c in model.setProjectInputs(values) { c.resume(returning: $0) } }
        try check(success, model.error ?? "project inputs"); try await idle(model)
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: option("--root")), book = URL(fileURLWithPath: option("--book"))
        let storage = root.appendingPathComponent("desktop-settings"), core = option("--core"), worker = option("--worker")
        let token = URL(fileURLWithPath: option("--token")), marker = root.appendingPathComponent("drop-reply")
        let endpoint = option("--url"), wrapper = option("--fault-core")
        var model = NotebookModel(workerExecutable: worker, remoteExecutable: wrapper, remoteStorage: storage)
        var second: NotebookModel?
        do {
            try await open(model, book)
            try externalGuard(book)
            var server = NotebookServer(); server.ssh = false; server.url = endpoint; server.name = "Desktop regression"
            try model.remote.addServer(server, token: String(contentsOf: token).trimmingCharacters(in: .whitespacesAndNewlines))
            model.remote.choose(server.id)
            let initialDate = model.snapshot!.inputs!.first { $0.id == "day" }!
            try check(!NotebookDateInputView(model: model, input: initialDate, mode: "date", zone: "Europe/Moscow").canApply, "Date Apply disabled during connect")
            try await connected(model)
            try check(model.remote.supportsTargetedRestart && model.remote.supportsHistory, "desktop capabilities")

            let first = try await invoke(model, "counter")
            try await wait("counter 1") { !model.remote.active && model.invocationResult("board:counter")?.result == "1" }
            try Data("restart_invocation".utf8).write(to: marker)
            let lostReset = await withCheckedContinuation { c in model.perform("periodic_dispose", text: "board", commandCellID: "counter") { c.resume(returning: $0) } }
            try check(!lostReset && model.remote.hasPending, "restart acknowledgement loss is journaled")
            model.clearError(); model.remote.reconnect(); try await connected(model)
            let reset = try await invoke(model, "counter")
            try await wait("reset counter") { !model.remote.active && model.invocationResult("board:counter")?.result == "1" }
            try check(reset.epoch != first.epoch, "Restart creates a new invocation epoch")
            _ = try await invoke(model, "counter")
            try await wait("counter 2") { !model.remote.active && model.invocationResult("board:counter")?.result == "2" }
            print("PASS remote action Restart: new heap/epoch, lost acknowledgement, no duplicate reset")

            let board = model.snapshot!.boards!.first!, tab = model.activeTab!
            let aControl = board.allComponents.first { $0.id == "control_a" }!, bControl = board.allComponents.first { $0.id == "control_b" }!
            let a = try await invoke(model, "a"), b = try await invoke(model, "b")
            try await perform(model, "run", cell: "2")
            try await wait("three independent runs") { model.remote.runs.filter(\.active).count == 3 }
            try check(model.targetRun(board: board, component: aControl, tab: tab)?.id == a.id && model.targetRun(board: board, component: bControl, tab: tab)?.id == b.id, "controls resolve distinct targets")
            try check(model.targetStatus(board: board, component: aControl, tab: tab).symbol == "hourglass" && model.targetStatus(board: board, component: bControl, tab: tab).symbol == "hourglass", "both action controls show running")
            model.stopTarget(board: board, component: aControl, tab: tab)
            try await wait("only A cancelled") { model.remote.runs.contains { $0.id == a.id && $0.state == "cancelled" } }
            try check(model.remote.runs.contains { $0.id == b.id && $0.active } && model.executingCurrentWorker, "A Stop preserves B and sheet")
            model.stopExecution(force: true)
            try await wait("sheet force stopped") { !model.executingCurrentWorker }
            try check(model.remote.runs.contains { $0.id == b.id && $0.active }, "sheet Force Stop preserves B")
            model.stopTarget(board: board, component: bControl, tab: tab, force: true)
            try await wait("B force stopped") { model.remote.runs.contains { $0.id == b.id && $0.state == "force-stopped" } }
            try await perform(model, "periodic_dispose", cell: "b", text: "board")
            let newB = try await invoke(model, "b")
            try check(newB.epoch != b.epoch, "invocation restarts after Force Stop")
            model.remote.stop(run: newB, force: false); try await idle(model)
            try await perform(model, "restart_worker")
            print("PASS remote targeted Stop/Force Stop: parallel actions and sheet, status, recovery")

            let timer = board.services.first!, control = board.allComponents.first { $0.id == "control_timer" }!
            model.runPeriodicOnce(board: board, component: timer)
            try await wait("service first") { !model.remote.active && model.invocationResult("board:timer")?.result == "1" }
            let serviceEpoch = model.remote.runs.last { $0.component == "timer" }!.epoch
            model.startPeriodic(board: board, component: timer)
            try await wait("service enabled") { !model.remote.busy && model.periodicState(board: board, component: timer).enabled }
            let blocked = await withCheckedContinuation { c in model.perform("periodic_dispose", text: "board", commandCellID: "timer") { c.resume(returning: $0) } }
            try check(!blocked && model.remote.connected && !model.remote.hasPending, "enabled service rejects Restart")
            model.clearError(); model.pausePeriodic(board: board, component: timer)
            try await wait("service paused") { !model.remote.busy && !model.periodicState(board: board, component: timer).enabled }
            try check(model.targetRun(board: board, component: control, tab: tab)?.epoch == serviceEpoch, "service target resolves its own epoch")
            try await perform(model, "periodic_dispose", cell: "timer", text: "board")
            model.runPeriodicOnce(board: board, component: timer)
            try await wait("service reset") { !model.remote.busy && !model.remote.active && model.invocationResult("board:timer")?.result == "1" }
            try check(model.remote.runs.last { $0.component == "timer" }!.epoch != serviceEpoch, "service reset starts new heap")
            print("PASS remote service Restart: pause requirement and new invocation epoch")

            try await perform(model, "image_select", cell: "gallery", text: "1")
            try await perform(model, "run", cell: "1")
            try await wait("selected image") { !model.remote.active && model.activeTab!.cells[0].result.contains("Second") }
            let baselineRun = model.remote.runs.last { $0.board == nil }!.id
            try check(model.imageSelection("gallery", in: model.activeTab!) == 1, "desktop and worker use selected image")
            await close(model)
            model = NotebookModel(workerExecutable: worker, remoteExecutable: wrapper, remoteStorage: storage)
            try await open(model, book); try await connected(model)
            try check(model.imageSelection("gallery", in: model.activeTab!) == 1, "carousel selection survives document reopen")
            try await perform(model, "run", cell: "1")
            try await wait("selected image after reconnect") { !model.remote.active && model.activeTab!.cells[0].result.contains("Second") }
            print("PASS remote Carousel: selected frame -> worker -> close/reopen/reconnect")

            let dateInput = model.snapshot!.inputs!.first { $0.id == "day" }!
            try check(NotebookDateInputView(model: model, input: dateInput, mode: "date", zone: "Europe/Moscow").canApply, "remote Date Apply enabled")
            try check(!NotebookDateInputView(model: model, input: dateInput, mode: "date", zone: "invalid-zone").canApply, "invalid zone rejected")
            let instant = ISO8601DateFormatter().date(from: "2026-10-31T23:30:00Z")!
            let day = try NotebookDateInputView.encodedValue(instant, mode: "date", zone: "Europe/Moscow")
            try check(day == "\"2026-11-01\"", "calendar date follows configured timezone")
            try await inputs(model, ["day": day])
            let timestamp = try NotebookDateInputView.encodedValue(instant, mode: "date_time", zone: "Europe/Moscow")
            try check(timestamp == "\"2026-10-31T23:30:00Z\"", "timestamp serialized in UTC")
            try await inputs(model, ["when": timestamp])
            model.remote.reconnect(); try await connected(model)
            try check(model.snapshot!.inputs!.first { $0.id == "when" }!.value_json == timestamp, "accepted date survives reconnect")
            try await perform(model, "run", cell: "1")
            try await wait("date consumed") { !model.remote.active && model.activeTab!.cells[0].result.contains("2026-10-31T23:30:00Z") }
            print("PASS remote Date/Time Apply: availability, timezone, UTC, accepted state, worker result")

            // More than one server page; these ordinary commands reuse the
            // existing revision and worker instead of editing notebook sources.
            let observer = NotebookRemoteClient(executable: core, token: token); observer.endpoint = endpoint
            let project = model.remote.projectID!
            let head = try await observer.call(["--command", "project", "--project", project])["head"] as! String
            for index in 0..<52 {
                let run = try await observer.call(["--command", "run", "--project", project, "--revision", head, "--sheet", "main", "--cell", "1", "--command-id", "history-page-\(index)"])
                _ = try await observer.call(["--command", "wait", "--run-id", run["run_id"] as! String])
            }
            try await idle(model); try await history(model)
            try check(model.remote.historyRuns.count == 50 && model.remote.historyHasMore, "history first page is bounded")
            try await history(model, all: true)
            try check(model.remote.historyRuns.count > 50 && model.remote.historyRuns.contains { $0.id == baselineRun }, "older history available")
            let sourceBefore = model.activeTab!.cells[0].source, resultBefore = model.activeTab!.cells[0].result
            var record = try await model.remote.historyRecord(baselineRun)
            try check(record.cellInputs["1"]?["exact"] == "9223372036854775806", "history preserves exact Int64")
            let interrupted = try await NotebookRemoteHistorySnapshot.decode(sheet: "main", document: record.remoteDocument!, data: Data())
            try check(interrupted.cells.allSatisfy(\.dirty) && interrupted.cell_inputs["1"]?["exact"] == "9223372036854775806", "history retains frozen inputs without claiming fresh output when no terminal artifact exists")
            try check(model.activeTab!.cells[0].source == sourceBefore && model.activeTab!.cells[0].result == resultBefore, "history inspection is inert")
            try Data("change_run".utf8).write(to: marker)
            let lostPin = await change(model, record, title: "Shared baseline", pinned: true)
            try check(!lostPin && model.remote.hasPending, "history command acknowledgement loss is journaled")
            model.clearError(); model.remote.reconnect(); try await connected(model); try await history(model, all: true)
            record = try await model.remote.historyRecord(baselineRun)
            try check(record.pinned && record.title == "Shared baseline", "server metadata survives reconnect")

            let copy = root.appendingPathComponent("Second.sputnikbook")
            let downloaded = await withCheckedContinuation { c in model.remote.download(project: project, revision: head, to: copy) { c.resume(returning: $0) } }
            try check(downloaded, model.error ?? "download")
            let peer = NotebookModel(workerExecutable: worker, remoteExecutable: core, remoteStorage: root.appendingPathComponent("peer-settings")); second = peer
            try peer.remote.addServer(server, token: String(contentsOf: token).trimmingCharacters(in: .whitespacesAndNewlines))
            try await open(peer, copy); try await connected(peer); try await history(peer, all: true)
            let stale = try await peer.remote.historyRecord(baselineRun)
            try check(stale.title == "Shared baseline" && stale.pinned, "second client sees shared metadata and full history")
            let renamed = await change(model, record, title: "New title")
            try check(renamed, model.error ?? "rename")
            let conflict = await change(peer, stale, title: "Stale overwrite")
            try check(!conflict, "stale metadata cannot overwrite another client")
            peer.clearError(); try await history(peer, all: true)
            record = try await peer.remote.historyRecord(baselineRun)
            try check(record.title == "New title", "metadata CAS preserves newer title")
            let pinnedDelete = await change(peer, record, remove: true)
            try check(!pinnedDelete, "pinned run remains protected")
            peer.clearError()
            let unpinned = await change(peer, record, pinned: false)
            try check(unpinned, peer.error ?? "unpin")
            record = try await peer.remote.historyRecord(baselineRun)

            try await inputs(model, ["when": "\"2027-01-02T00:00:00Z\"", "dataset": "\"inputs/other.txt\""])
            let accepted = await withCheckedContinuation { c in model.setCellInputs(["exact": "5"], cell: model.activeTab!.cells[0], tab: model.activeTab!) { c.resume(returning: $0) } }
            try check(accepted, model.error ?? "change cell input"); try await idle(model)
            let reviewVersion = model.remote.acceptedInputVersion
            let projectRestore = await withCheckedContinuation { c in model.restoreRunParameters(record, expectedVersion: reviewVersion) { c.resume(returning: $0) } }
            try check(projectRestore, model.error ?? "project restore"); try await idle(model)
            try check(model.snapshot!.inputs!.first { $0.id == "when" }!.editingText.isEmpty && model.snapshot!.inputs!.first { $0.id == "dataset" }!.editingText == "inputs/other.txt", "scalar restore preserves managed asset selection")
            try check(model.activeTab!.cells[0].cell_inputs!.first!.value_json == "5", "project restore does not change cell scope")
            try await inputs(model, ["when": "\"2027-01-02T00:00:00Z\""])
            let cellRestore = await withCheckedContinuation { c in model.restoreRunParameters(record, scope: "1", expectedVersion: model.remote.acceptedInputVersion) { c.resume(returning: $0) } }
            try check(cellRestore, model.error ?? "cell restore"); try await idle(model)
            try check(model.activeTab!.cells[0].cell_inputs!.first!.value_json == "9223372036854775806" && model.snapshot!.inputs!.first { $0.id == "when" }!.editingText == "2027-01-02T00:00:00Z", "cell restore is exact and preserves project scope")
            let staleRestore = await withCheckedContinuation { c in model.restoreRunParameters(record, expectedVersion: reviewVersion) { c.resume(returning: $0) } }
            try check(!staleRestore, "restore rejects a stale accepted-state review"); model.clearError()

            try await history(model, all: true)
            let latest = model.remote.historyRuns.first { $0.board == nil }!
            let latestRecord = try await model.remote.historyRecord(latest.id)
            let protected = await change(model, latestRecord, remove: true)
            try check(!protected, "current presentation cannot be deleted"); model.clearError()
            try Data("change_run".utf8).write(to: marker)
            let lostDelete = await change(model, record, remove: true)
            try check(!lostDelete && model.remote.hasPending, "delete reply loss is recoverable")
            model.clearError(); model.remote.reconnect(); try await connected(model); try await history(model, all: true)
            try check(!model.remote.historyRuns.contains { $0.id == baselineRun }, "deleted server run never resurrects on reconnect")
            try await history(peer, all: true)
            try check(!peer.remote.historyRuns.contains { $0.id == baselineRun }, "second client sees deletion")
            print("PASS remote server history: paging, second client, Pin/Rename/Delete, CAS, lost replies, scoped exact restore")
            await close(peer); second = nil; await close(model)
            print("PASS all five remote action regressions")
        } catch {
            print("FAIL remote actions: \(error) · \(model.error ?? "") · \(model.remote.historyError ?? "")")
            print(model.remote.runs.map { "\($0.component ?? $0.sheet):\($0.state)" })
            if let second { await close(second) }; await close(model); exit(1)
        }
    }
}

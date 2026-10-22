import AppKit
import Foundation

private struct ModelTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
private struct NotebookModelRegressionTests {
    @MainActor
    static func main() async {
        // Model.open records recent documents through AppKit. Keep this test
        // process hidden; it exercises the real async worker without a window.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sputnik-notebook-model-\(UUID().uuidString)",
                                   isDirectory: true)
        let first = root.appendingPathComponent("first.sputnikbook", isDirectory: true)
        let second = root.appendingPathComponent("second.sputnikbook", isDirectory: true)
        let model = NotebookModel()
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: root,
                                                   withIntermediateDirectories: false)
            try writeProject(first, title: "Model Test", cellIDs: ["101", "102"])
            try writeProject(second, title: "Second Project", cellIDs: ["901"])

            try testTextVariables()
            try testProgressSourceSelection()
            try testFigurePanels()
            try testNumericChartSampling()
            try await testNumberedStructures(model, url: root.appendingPathComponent("numbered.sputnikbook"))
            try await testBoards(model, url: root.appendingPathComponent("board.sputnikbook"))
            try await testDraftsTabsAndStructures(model, first: first)
            try await testTextFormattingDrafts(model)
            try await testDeleteDoesNotLeaveAnOrphanDraft(model, first: first)
            try await testNulAndFailedOpenKeepTheCurrentDocument(model, first: first)
            try await testRepeatedReplacementAndExternalConflict(model,
                                                                 first: first,
                                                                 second: second)
            try await testIsolatedWorker(url: root.appendingPathComponent("isolated.sputnikbook"))
            try await testExecutionNavigation(url: root.appendingPathComponent("navigation.sputnikbook"))
            try await testRetainedResults(root: root)
            try await testStopwatch(root: root)
            try await testDefaultModuleAndWatch(url: root.appendingPathComponent("unified.sputnikbook"))
            try await testWorkerGrants(root: root)
            try await testCellIDs(root: root)

            await shutdown(model)
            // Completion must mean the old borrowed-fd source has been
            // cancelled and its host destroyed. Reopening proves the worker
            // remains usable after that cancellation barrier.
            let reopenedAfterShutdown = await open(model, url: second)
            try require(reopenedAfterShutdown,
                        "model should reopen after orderly shutdown")
            await shutdown(model)
            print("notebook macOS model tests passed")
        } catch {
            await shutdown(model)
            fputs("notebook macOS model tests failed: \(error)\n", stderr)
            exit(1)
        }

    }

    @MainActor
    private static func testNumberedStructures(_ model: NotebookModel, url: URL) async throws {
        let opened = await open(model, url: url, create: true)
        try require(opened && model.activeTab?.title == "Sheet 1" && model.nextSheetTitle == "Sheet 2", "new notebook sheet names")
        var board = NotebookBoard.empty(sheet: "main", existing: model.snapshot?.boards ?? [])
        try require(board.title == "Board 1", "first default board name")
        var saved = await withCheckedContinuation { c in model.saveBoard(board) { c.resume(returning: $0) } }
        try require(saved, model.error ?? "save Board 1")
        board = NotebookBoard.empty(sheet: "main", existing: model.snapshot?.boards ?? [])
        try require(board.title == "Board 2", "board numbering spans the project")
        board.title = "Board 7"
        saved = await withCheckedContinuation { c in model.saveBoard(board) { c.resume(returning: $0) } }
        try require(saved, model.error ?? "save numbered board")
        let created = await perform(model, "new_sheet", text: model.nextSheetIdentifier)
        try require(created && model.activeTab?.title == "Sheet 2" && model.activeTab?.id == "sheet:sheet_2", "suggested sheet identifier and numbered title")
        let reopened = await open(model, url: url)
        try require(reopened && model.nextSheetTitle == "Sheet 3" && model.nextSheetIdentifier == "sheet_3", "sheet numbering survives reopening")
        try require(NotebookBoard.empty(sheet: "sheet_2", existing: model.snapshot?.boards ?? []).title == "Board 8", "board numbering spans controller sheets and skips existing numbered titles")
    }

    @MainActor
    private static func testCellIDs(root: URL) async throws {
        let model = NotebookModel()
        let url = root.appendingPathComponent("cell-ids.sputnikbook")
        try writeProject(url, title: "Cell IDs", cellIDs: ["8101", "8102"])
        do {
            let opened = await open(model, url: url)
            try require(opened, "open cell ID fixture")
            let tab = model.activeTab!, cell = tab.cells[1]
            model.selectedCellID = cell.id
            for invalid in ["", "0", "-1", "+1", "1.5", "18446744073709551615", "18446744073709551616", "8101"] {
                try require(model.cellIDValidationError(invalid, cell: cell) != nil, "invalid or duplicate Hard ID accepted: \(invalid)")
            }
            try require(model.cellIDValidationError("9007199254740993", cell: cell) == nil, "64-bit Hard ID rejected")
            model.editSource("answer = 42\nanswer\n", cell: cell, tab: tab)
            let renamed = await withCheckedContinuation { c in
                model.setCellID(" 009102 ", cell: cell, tab: tab) { c.resume(returning: $0) }
            }
            try require(renamed && model.selectedCellID == "9102", model.error ?? "renaming lost cell selection")
            var current = model.activeTab!, updated = model.activeTab!.cells[1]
            try require(updated.id == "9102" && current.cellNumber(for: updated.id) == "02" &&
                        model.source(for: updated, in: current) == "answer = 42\nanswer\n" && model.hasUnsavedChanges,
                        "renaming lost a source draft or changed the visible number")
            let moved = await perform(model, "move_up", tab: current, cell: updated)
            current = model.activeTab!; updated = current.cells[0]
            try require(moved && updated.id == "9102" && current.cellNumber(for: updated.id) == "01" && model.selectedCellID == updated.id,
                        "moving changed Hard ID or selection")
            let saved = await perform(model, "save_all")
            try require(saved && !model.hasUnsavedChanges, model.error ?? "renaming left an orphan draft")
            let reopened = await open(model, url: url)
            try require(reopened && model.activeTab?.cells.first?.id == "9102" && model.activeTab?.cells.first?.source == "answer = 42\nanswer\n",
                        "save/reopen lost the new ID or source")
            await shutdown(model)
        } catch { await shutdown(model); throw error }
    }

    @MainActor
    private static func testStopwatch(root: URL) async throws {
        let model = NotebookModel()
        let url = root.appendingPathComponent("stopwatch.sputnikbook")
        try writeProject(url, title: "Stopwatch", cellIDs: ["661", "662"])
        do {
            let opened = await open(model, url: url)
            try require(opened, "open stopwatch fixture")
            let tab = model.activeTab!
            model.editSource("import task\ntask.sleep(250)\n1\n", cell: tab.cells[0], tab: tab)
            model.editSource("from notebook.ui import Stopwatch\nimport task\nStopwatch.measure(\"outer\"):\n  Stopwatch.measure:\n    task.sleep(800)\n    42\n", cell: tab.cells[1], tab: tab)
            var completion: Bool?
            model.perform("run_all") { completion = $0 }
            for _ in 0..<500 where model.stopwatches(in: tab, channel: "default").items.isEmpty && completion == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            let first = model.stopwatches(in: tab, channel: "default")
            try require(first.running && first.items.first?.done == false, "default Stopwatch.measure publishes a running channel without dependencies: \(model.error ?? model.activeTab!.cells.map(\.error).joined(separator: "; "))")
            let cellStart = model.cellTiming(tab.cells[1], in: tab)
            try await Task.sleep(nanoseconds: 160_000_000)
            try require(model.stopwatches(in: tab, channel: "default").items.first!.elapsed_ms > first.items.first!.elapsed_ms,
                        "block stopwatch time advances while a sleeping block produces no output")
            try require(model.cellTiming(tab.cells[1], in: tab)!.milliseconds > cellStart!.milliseconds, "cell elapsed time advances independently")
            for _ in 0..<500 where completion == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            let completed = model.activeTab!
            try require(completion == true && completed.cells[1].ok && completed.cells[1].result == "42", "measure preserves block return values: \(completed.cells[1].error)")
            try require((completed.cells[0].elapsed_ms ?? 0) >= 200 && (completed.cells[0].elapsed_ms ?? 9999) < 650,
                        "Run All records separate durations for earlier cells")
            try require((completed.cells[1].elapsed_ms ?? 0) >= 750 && model.cellTiming(completed.cells[1], in: completed)?.running == false,
                        "final cell time is committed after evaluation")
            let timers = model.stopwatches(in: completed, channel: "")
            try require(Set(timers.items.map(\.id)) == ["outer", "default"] && timers.items.allSatisfy { $0.done && $0.elapsed_ms >= 750 },
                        "nested channels keep independent completed times")
            let frozen = timers.items.first!.elapsed_ms
            try await Task.sleep(nanoseconds: 150_000_000)
            try require(model.stopwatches(in: completed, channel: "").items.first!.elapsed_ms == frozen, "completed stopwatch does not drift")
            model.editSource("from notebook.ui import Stopwatch\nimport task\nStopwatch.measure:\n  task.sleep(350)\n  1\n", cell: completed.cells[0], tab: completed)
            completion = nil
            model.perform("run", tab: completed, cell: completed.cells[0]) { completion = $0 }
            for _ in 0..<500 where !model.stopwatches(in: completed, channel: "default").running && completion == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            try require(model.stopwatches(in: completed, channel: "default").running, "current channel takes precedence over a later cell's previous measurement")
            for _ in 0..<500 where completion == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            var board = NotebookBoard.empty(sheet: "main")
            board.components = [NotebookBoardComponent(id: "timer", kind: "stopwatch", title: "Stopwatch", stopwatch_id: "default")]
            let saved = await withCheckedContinuation { c in model.saveBoard(board) { c.resume(returning: $0) } }
            try require(saved && model.snapshot?.boards?.first?.components.first?.stopwatch_id == "default", "Stopwatch board component persists its channel")
            var current = model.activeTab!
            model.editSource("from notebook.ui import Stopwatch\nimport task\nStopwatch.measure(\"failure\"):\n  task.sleep(120)\n  1 / 0\n", cell: current.cells[1], tab: current)
            let failed = await perform(model, "run", tab: current, cell: current.cells[1])
            current = model.activeTab!
            try require(failed && !current.cells[1].ok && model.stopwatches(in: current, channel: "failure").items.first?.done == true,
                        "block exceptions stop the stopwatch and remain cell errors")
            for force in [false, true] {
                current = model.activeTab!
                model.editSource("from notebook.ui import Stopwatch\nStopwatch.measure(\"cancel\"):\n  while true:\n    x = 1\n", cell: current.cells[1], tab: current)
                completion = nil
                model.perform("run", tab: current, cell: current.cells[1]) { completion = $0 }
                for _ in 0..<500 where model.stopwatches(in: current, channel: "cancel").items.isEmpty && completion == nil { try await Task.sleep(nanoseconds: 10_000_000) }
                try require(model.stopwatches(in: current, channel: "cancel").items.isEmpty == false, "cancel stopwatch is live")
                model.stopExecution(force: force)
                for _ in 0..<500 where completion == nil { try await Task.sleep(nanoseconds: 10_000_000) }
                let stopped = model.activeTab!
                let value = model.stopwatches(in: stopped, channel: "cancel").items.first!.elapsed_ms
                try await Task.sleep(nanoseconds: 150_000_000)
                try require(!model.stopwatches(in: stopped, channel: "cancel").running && model.stopwatches(in: stopped, channel: "cancel").items.first!.elapsed_ms == value,
                            "Stop and Force Stop freeze stopwatch presentation")
                model.clearError()
            }
            await shutdown(model)
        } catch {
            model.stopExecution(force: true)
            for _ in 0..<500 where model.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
            await shutdown(model)
            throw error
        }
    }

    @MainActor
    private static func testRetainedResults(root: URL) async throws {
        let model = NotebookModel()
        let url = root.appendingPathComponent("retained.sputnikbook")
        let other = root.appendingPathComponent("retention-other.sputnikbook")
        try writeProject(url, title: "Retained", cellIDs: ["601"])
        try writeProject(other, title: "Other", cellIDs: ["602"])
        func current() -> (NotebookTab, NotebookCell) { let tab = model.activeTab!; return (tab, tab.cells[0]) }
        func result() -> NotebookCellResult? { let (tab, cell) = current(); return model.presentation(for: cell, in: tab).result }
        do {
            let opened = await open(model, url: url)
            try require(opened && model.retainCellResults, "retention is enabled by default")
            var (tab, cell) = current()
            let source = "[{:name: \"kept\", :value: 42}]\n"
            model.editSource(source, cell: cell, tab: tab)
            let ran = await perform(model, "run_all")
            try require(ran && result()?.previous == false && result()?.text.contains("kept") == true,
                        "a successful run exposes an ordinary result")
            let captured = result()!
            try require(captured.format?.is_container == true && captured.format?.pretty.contains("kept") == true && captured.format?.table_json?.isEmpty == false,
                        "capture retains Inspect, Pretty and the typed result table")
            (tab, cell) = current()
            model.editSource("import task\ntask.sleep(600)\n1 / 0\n", cell: cell, tab: tab)
            try require(result()?.previous == true && result()?.text == captured.text, "editing labels the previous run result")
            var completion: Bool?
            model.perform("run_all") { completion = $0 }
            try require(result()?.previous == true && result()?.format?.table_json == captured.format?.table_json,
                        "rerunning keeps the full result available for inspection")
            for _ in 0..<500 where completion == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            try require(completion == true && !current().1.ok && result()?.previous == true && result()?.text == captured.text && result()?.format?.pretty == captured.format?.pretty,
                        "a new error keeps a separately labelled previous successful result")
            for force in [false, true] {
                (tab, cell) = current()
                model.editSource("while true:\n  x = 1\n", cell: cell, tab: tab)
                completion = nil
                model.perform("run_all") { completion = $0 }
                for _ in 0..<500 where model.executingCells[tab.id] == nil && completion == nil { try await Task.sleep(nanoseconds: 10_000_000) }
                try require(model.executingCells[tab.id] != nil, "cancellation fixture must be executing")
                model.stopExecution(force: force)
                for _ in 0..<500 where completion == nil { try await Task.sleep(nanoseconds: 10_000_000) }
                try require(completion != nil && result()?.previous == true && result()?.text == captured.text,
                            "Stop and Force Stop retain the last successful result")
            }
            let disabled = await perform(model, "retain_cell_results", text: "off")
            try require(disabled && !model.retainCellResults && result() == nil && model.hasUnsavedChanges,
                        "disabling drops the retained result without saving source buffers")
            let manifest = try String(contentsOf: url.appendingPathComponent("project.json"))
            let savedDocument = try JSONSerialization.jsonObject(with: Data(manifest.utf8)) as! [String: Any]
            try require(savedDocument["retain_cell_results"] as? Bool == false && !manifest.contains("while true"), "the option is persisted in the book independently of source")
            await shutdown(model)
            let openedOther = await open(model, url: other)
            try require(openedOther && model.retainCellResults, "retention is scoped to one sputnikbook")
            await shutdown(model)
            let reopened = await open(model, url: url)
            try require(reopened && !model.retainCellResults && result() == nil, "the option survives reopening; in-memory results do not")
            (tab, cell) = current()
            model.editSource("12\n", cell: cell, tab: tab)
            let resetAfterForce = await perform(model, "restart_worker")
            try require(resetAfterForce, "fresh test worker after the deliberate Force Stop")
            let disabledRun = await perform(model, "run_all")
            try require(disabledRun && result()?.text == "12" && result()?.previous == false, "disabled retention still shows current results")
            (tab, cell) = current()
            model.editSource("1 / 0\n", cell: cell, tab: tab)
            try require(result() == nil, "disabled retention hides stale output after an edit")
            let disabledFailure = await perform(model, "run_all")
            try require(disabledFailure && result() == nil, "disabled retention does not restore a result after failure")
            let enabled = await perform(model, "retain_cell_results", text: "on")
            try require(enabled && result() == nil, "reenabling cannot revive a discarded failure fallback")
            (tab, cell) = current()
            model.editSource(source, cell: cell, tab: tab)
            let reran = await perform(model, "run_all")
            try require(reran && result()?.text == captured.text, "a new successful result replaces the retained snapshot")
            let restarted = await perform(model, "restart_worker")
            try require(restarted && result() == nil, "worker restart clears both current and retained result presentation")
            let saved = await perform(model, "save_all")
            try require(saved && result() == nil, "an inert host snapshot cannot resurrect results after restart")
            let fresh = await perform(model, "run_all")
            try require(fresh && result()?.previous == false, "only a new evaluation restores a result after restart")
            await shutdown(model)
        } catch {
            model.stopExecution(force: true)
            for _ in 0..<500 where model.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
            await shutdown(model)
            throw error
        }
    }

    @MainActor
    private static func testExecutionNavigation(url: URL) async throws {
        let model = NotebookModel()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let manifest = #"{"format":"sputnik-notebook","version":2,"title":"Navigation","active_sheet":"main","sheets":[{"id":"main","title":"Main","cells":[{"id":"101","kind":"code","mode":"manual","source":"import task\ntask.sleep(900)\n11\n"},{"id":"102","kind":"code","mode":"manual","source":"while true:\n  x = 1\n"}]},{"id":"other","title":"Other","cells":[{"id":"201","kind":"code","mode":"manual","source":"33\n"}]}],"modules":[],"auto_imports":[],"inputs":[],"boards":[{"id":"dashboard","title":"Dashboard","sheet":"main","columns":1,"components":[]}]}"#
        try manifest.write(to: url.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        do {
            let opened = await open(model, url: url)
            try require(opened, "open navigation fixture: \(model.error ?? "unknown error")")
            let main = model.activeTab!
            let other = model.snapshot!.tabs.first { $0.id == "sheet:other" }!
            let board = model.snapshot!.boards!.first!
            var completion: Bool?
            model.perform("run_all", tab: main) { completion = $0 }
            for _ in 0..<500 where model.executingCells[main.id] != "101" && completion == nil {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try require(model.executingCells[main.id] == "101" && model.canNavigate, "silent first cell is marked running")
            model.selectTab(other)
            try require(model.activeTab?.id == other.id && model.busy, "sheet selection is immediate while the worker runs")
            model.editSource("44\n", cell: other.cells[0], tab: other)
            model.selectBoard(board)
            try require(model.activeBoard?.id == board.id && model.busy, "board selection is immediate while the worker runs")
            model.showExecutingCell()
            try require(model.activeBoard == nil && model.activeTab?.id == main.id && model.selectedCellID == "101" && model.cellNavigation?.location.cell == "101",
                        "show current cell opens its sheet and requests scrolling")
            let request = model.cellNavigation
            model.showExecutingCell()
            try require(model.cellNavigation != request, "repeated navigation requests scroll even to the same cell")
            for _ in 0..<500 where model.executingCells[main.id] != "102" && completion == nil {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try require(model.executingCells[main.id] == "102" && model.selectedCellID == "101", "run-all marker advances independently of selection")
            model.showExecutingCell()
            try require(model.selectedCellID == "102" && model.cellNavigation?.location.cell == "102", "navigation follows the actual current cell")
            model.selectTab(other)
            model.selectBoard(board)
            model.stopExecution()
            for _ in 0..<500 where completion == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            try require(completion == true && !model.busy && model.executingCells.isEmpty, "Stop clears the running marker")
            try require(model.activeTab?.id == other.id && model.activeBoard?.id == board.id, "completion preserves sheet and board navigation")
            let latestOther = model.snapshot!.tabs.first { $0.id == other.id }!
            try require(model.source(for: latestOther.cells[0], in: latestOther) == "44\n", "background completion preserves drafts on another sheet")
            let latestMain = model.snapshot!.tabs.first { $0.id == main.id }!
            model.editSource("22\n", cell: latestMain.cells[1], tab: latestMain)
            completion = nil
            model.perform("run_all", tab: latestMain) { completion = $0 }
            for _ in 0..<500 where completion == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            try require(completion == true && model.executingCells.isEmpty && model.activeTab?.id == other.id && model.activeBoard?.id == board.id,
                        "successful background execution also preserves navigation and clears markers")
            try require(model.snapshot!.tabs.first { $0.id == main.id }!.cells[1].result == "22", "background result reaches the executing sheet")
            await shutdown(model)
        } catch {
            model.stopExecution(force: true)
            for _ in 0..<500 where model.busy { try? await Task.sleep(nanoseconds: 10_000_000) }
            await shutdown(model)
            throw error
        }
    }

    @MainActor
    private static func testWorkerGrants(root: URL) async throws {
        let url = root.appendingPathComponent("grants.sputnikbook")
        let storage = root.appendingPathComponent("grant-settings")
        let model = NotebookModel(remoteStorage: storage)
        try writeProject(url, title: "Grants", cellIDs: ["701"])
        let completed1 = await open(model, url: url)
        try require(completed1, "open grant fixture")
        var tab = model.activeTab!
        model.editSource("from system import cmd\ncmd\"/usr/bin/printf granted\".output\n", cell: tab.cells[0], tab: tab)
        let completed2 = await perform(model, "run_all")
        try require(completed2, "denied command returns a cell diagnostic")
        try require(model.activeTab!.cells[0].error.contains("CapabilityError"), "default denies process creation")
        tab = model.activeTab!
        let initial = try await model.workerSettings(for: tab)
        do {
            try await model.configureWorker(tab, text: "process.spawn=", settings: initial)
            throw ModelTestFailure(description: "empty grant target accepted")
        } catch is ModelTestFailure { throw ModelTestFailure(description: "empty grant target accepted") }
        catch {}
        try await model.configureWorker(tab, text: "process.spawn=/usr/bin/printf", settings: initial)
        try require(model.activeTab!.cells[0].error.contains("CapabilityError"), "applying policy does not replay cells")
        let completed3 = await perform(model, "run_all")
        try require(completed3, "run with explicit grant")
        try require(model.activeTab!.cells[0].ok && model.activeTab!.cells[0].result.contains("granted"), "scoped grant reaches the runtime")
        let completed4 = await perform(model, "save_all")
        try require(completed4, "save sources")
        await shutdown(model)
        let completed5 = await open(model, url: url)
        try require(completed5, "reopen with private policy")
        tab = model.activeTab!
        let stored = try await model.workerSettings(for: tab)
        try require(stored.grants == ["process.spawn=/usr/bin/printf"], "grants persist outside notebook sources")
        let completed6 = await perform(model, "run_all")
        try require(completed6, "run after reopen")
        try require(model.activeTab!.cells[0].ok, "reopened worker retains explicit host grants")
        try await model.configureWorker(model.activeTab!, text: "", settings: stored)
        let completed7 = await perform(model, "run_all")
        try require(completed7, "run after revocation")
        try require(model.activeTab!.cells[0].error.contains("CapabilityError"), "clearing grants revokes process creation")
        await shutdown(model)
    }


    @MainActor
    private static func testIsolatedWorker(url: URL) async throws {
        let model = NotebookModel()
        try writeProject(url, title: "Isolated", cellIDs: ["801"])
        do {
            let opened = await open(model, url: url)
            try require(opened, "open isolated host")
            guard let tab = model.activeTab, let cell = tab.cells.first else { throw ModelTestFailure(description: "missing isolated cell") }
            model.editSource("try:\n  while true:\n    x = 1\nensure:\n  print(\"STOPPED\")\n", cell: cell, tab: tab)
            var completion: Bool?
            model.perform("run_all", tab: tab) { completion = $0 }
            for _ in 0..<500 where !model.canStop && completion == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            try require(model.canStop && model.canEdit, "independent controls and editor remain available")
            // Reverting to the PRE-run snapshot must not be mistaken for no edit.
            model.editSource(cell.source, cell: cell, tab: tab)
            model.stopExecution()
            for _ in 0..<500 where completion == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            try require(completion == true && !model.busy, "Stop completes on main thread")
            guard let stoppedTab = model.activeTab, let stopped = stoppedTab.cells.first else { throw ModelTestFailure(description: "missing stopped cell") }
            try require(model.source(for: stopped, in: stoppedTab) == cell.source && stopped.source != cell.source && model.hasUnsavedChanges,
                        "late worker snapshot preserves a newer revert draft")
            let saved = await perform(model, "save_all")
            try require(saved && !model.hasUnsavedChanges, "host saves the newer draft, not executed source")
            guard let savedTab = model.activeTab, let savedCell = savedTab.cells.first else { throw ModelTestFailure(description: "missing saved cell") }
            model.editSource("while true:\n  x = 1\n", cell: savedCell, tab: savedTab)
            completion = nil
            model.perform("run_all") { completion = $0 }
            for _ in 0..<500 where !model.canForceStop && completion == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            try require(model.canForceStop, "force control available")
            model.editSource("123\n", cell: savedCell, tab: savedTab)
            model.stopExecution(force: true)
            for _ in 0..<500 where completion == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            try require(completion == false && !model.busy && model.error != nil, "forced worker is reaped, not reported successful")
            model.clearError()
            let restarted = await perform(model, "restart_worker")
            try require(restarted && model.activeTab?.cells.first?.source == "123\n", "restart keeps newer draft without replay")
            let reran = await perform(model, "run_all")
            try require(reran && model.activeTab?.cells.first?.result == "123", "explicit rerun creates fresh worker")
            guard let chartTab = model.activeTab, let chartCell = chartTab.cells.first else {
                throw ModelTestFailure(description: "missing chart cell")
            }
            model.editSource("import task\nchart = notebook.chart_begin(\"live\", throttle_ms: 0)\ni = 0\nwhile i < 1000:\n  notebook.chart_point(chart, i, i % 11)\n  i += 1\ntask.sleep(400)\nnotebook.chart_end(chart)\n123\n", cell: chartCell, tab: chartTab)
            completion = nil
            model.perform("run_all") { completion = $0 }
            for _ in 0..<500 where model.liveCells.isEmpty && completion == nil {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try require(!model.liveCells.isEmpty, "live scene is decoded while the producer is running")
            for _ in 0..<500 where completion == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            try await Task.sleep(nanoseconds: 300_000_000)
            try require(completion == true && model.liveCells.isEmpty,
                        "late live decode cannot replace completed presentation")
            guard let completedTab = model.activeTab, let completedCell = completedTab.cells.first else {
                throw ModelTestFailure(description: "missing completed chart cell")
            }
            try require(completedCell.displays?.count == 1 && !model.figureIsStale(for: completedCell, in: completedTab),
                        "completed chart is committed and not marked stale")
            model.editSource("""
            import task
            notebook.chart_point("loss", 0, 3)
            notebook.chart_point("retired", 0, 8)
            task.sleep(300)
            notebook.progress("training", 1, 2, "Training", false)
            task.sleep(300)
            notebook.chart_point("loss", 1, 2)
            task.sleep(300)
            notebook.chart_point("loss", 2, 1)
            task.sleep(300)
            notebook.progress("training", 2, 2, "Training", true)
            42

            """, cell: completedCell, tab: completedTab)
            completion = nil
            model.perform("run_all") { completion = $0 }
            var observedProgressWithChart = false
            var largestHistory = 0
            for _ in 0..<500 where completion == nil {
                try await Task.sleep(nanoseconds: 10_000_000)
                if model.executingWorker, let tab = model.activeTab,
                   let live = model.liveCells[completedCell.id] {
                    let chart = model.liveChart("loss", in: tab)
                    let count = chart?.points.count ?? 0
                    try require(count >= largestHistory, "progress-only polling preserves live chart history")
                    largestHistory = count
                    if live.progress.contains(where: { $0.id == "training" && $0.current == 1 }) {
                        observedProgressWithChart = true
                        try require(count > 0, "progress update must not hide a chart")
                    }
                }
            }
            try require(completion == true && observedProgressWithChart && largestHistory == 3,
                        "numeric chart samples accumulate through the real Swift polling path")
            guard let pointTab = model.activeTab, let pointCell = pointTab.cells.first else {
                throw ModelTestFailure(description: "missing point chart cell")
            }
            try require(pointCell.charts?.first(where: { $0.id == "loss" })?.points.count == 3,
                        "completed numeric chart retains all samples")
            model.editSource("import task\nnotebook.chart_point(\"loss\", 0, 7)\ntask.sleep(600)\n42\n",
                             cell: pointCell, tab: pointTab)
            completion = nil
            model.perform("run_all") { completion = $0 }
            var sawNewRun = false
            for _ in 0..<500 where completion == nil {
                try await Task.sleep(nanoseconds: 10_000_000)
                if model.executingWorker, let tab = model.activeTab,
                   let chart = model.liveChart("loss", in: tab), chart.points.first?.y == 7 {
                    sawNewRun = true
                    try require(chart.points.count == 1 && model.liveChart("retired", in: tab) == nil,
                                "rerun reset clears obsolete channels and previous points")
                }
            }
            try require(completion == true && sawNewRun && model.activeTab?.cells.first?.charts?.count == 1,
                        "rerun publishes its own channel set")
            await shutdown(model)
        } catch {
            if model.executingWorker { model.stopExecution(force: true) }
            await shutdown(model)
            throw error
        }
    }

    @MainActor
    private static func testDefaultModuleAndWatch(url: URL) async throws {
        let model = NotebookModel()
        try writeProject(url, title: "Unified execution", cellIDs: ["801", "802"])
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("project.json"))) as! [String: Any]
        document["version"] = 3
        document["inputs"] = []
        document["boards"] = []
        document["modules"] = [["id": "helpers", "path": "helpers.s"]]
        let package = Bundle.main.executableURL!.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("sputnik-lang/packages/progressbar").path
        document["dependencies"] = [["path": package, "auto_import": false]]
        try JSONSerialization.data(withJSONObject: document).write(to: url.appendingPathComponent("project.json"))
        let savedModule = "package helpers\nexport answer\ndef answer(): 42\n"
        try savedModule.write(to: url.appendingPathComponent("helpers.s"), atomically: true, encoding: .utf8)
        do {
            let opened = await open(model, url: url)
            try require(opened && model.isolatedExecution, "ordinary open selects worker without flags: \(model.error ?? package)")
            guard let module = model.snapshot?.tabs.first(where: { $0.kind == "module" }), let cell = module.cells.first else {
                throw ModelTestFailure(description: "missing module editor")
            }
            model.editSource("""
            package helpers
            from progressbar import ProgressBar
            import task
            bar = ProgressBar(total: 20, desc: "Module progress")
            20.times:
              task.sleep(0.03)
              bar.inc!()
            bar.end
            42

            """, cell: cell, tab: module)
            var completion: Bool?
            model.perform("run", tab: module, cell: cell) { completion = $0 }
            var live = false
            for _ in 0..<500 where completion == nil {
                try await Task.sleep(nanoseconds: 10_000_000)
                if model.liveCell(cell, in: module)?.progress.contains(where: { $0.current > 0 && $0.current < 20 }) == true {
                    live = true
                    try require(model.canStop && model.canForceStop, "module progress has both controls")
                }
            }
            let result = model.snapshot?.tabs.first(where: { $0.id == module.id })?.cells.first
            try require(completion == true && live && result?.ok == true && result?.progress?.first?.current == 20,
                        "module dependencies and progress execute live in the default worker: \(result?.error ?? model.error ?? "")")
            let diskModule = try String(contentsOf: url.appendingPathComponent("helpers.s"), encoding: .utf8)
            try require(diskModule == savedModule, "module Run preserves unsaved editor source")

            // A Watch registration wakes an inert readiness poll. Automatic
            // pumping must acknowledge it without executing edited buffers.
            guard let sheet = model.snapshot?.tabs.first(where: { $0.kind == "sheet" }) else {
                throw ModelTestFailure(description: "missing watch sheet")
            }
            model.editSource("x = 1\nKernel.watch(x)\nx\n", cell: sheet.cells[0], tab: sheet)
            model.editSource("x + 1\n", cell: sheet.cells[1], tab: sheet)
            let ran = await perform(model, "run_all", tab: sheet)
            try require(ran, "watch fixture executes")
            try await Task.sleep(nanoseconds: 400_000_000)
            try require(!model.busy && model.error == nil && model.snapshot?.tabs.first(where: { $0.id == sheet.id })?.cells[1].result == "2",
                        "default automatic watch pump settles and preserves results")
            guard let current = model.snapshot?.tabs.first(where: { $0.id == sheet.id }) else {
                throw ModelTestFailure(description: "missing current watch sheet")
            }
            model.editSource("""
            x = 1
            Kernel.watch(x)
            70000.times:
              x += 1
            notebook.progress("watch", 1, 2, "Automatic Watch", false)
            task.sleep(800)
            x

            """, cell: current.cells[0], tab: current)
            let hotRun = await perform(model, "run_all", tab: current)
            try require(hotRun, "hot source executes explicitly")
            for _ in 0..<500 where !model.executingWorker { try await Task.sleep(nanoseconds: 10_000_000) }
            var watchedLive = false
            for _ in 0..<500 where model.executingWorker && !watchedLive {
                try await Task.sleep(nanoseconds: 10_000_000)
                watchedLive = model.liveCell(current.cells[0], in: current)?.progress.contains(where: { $0.id == "watch" }) == true
            }
            try require(watchedLive && model.canStop && model.canForceStop && model.canEdit,
                        "automatic Watch uses live presentation, editing and both execution controls")
            model.stopExecution()
            for _ in 0..<500 where model.busy { try await Task.sleep(nanoseconds: 10_000_000) }
            try await Task.sleep(nanoseconds: 300_000_000)
            try require(!model.busy && model.error == nil, "cancelled automatic Watch is not replayed")
            await shutdown(model)
        } catch {
            if model.executingWorker { model.stopExecution(force: true) }
            await shutdown(model)
            throw error
        }
    }

    @MainActor
    private static func testBoards(_ model: NotebookModel, url: URL) async throws {
        var legacy = NotebookBoard(id: "legacy", title: "Legacy", sheet: "main", columns: 5,
                                   components: (0..<7).map { NotebookBoardComponent(id: "c\($0)", kind: "text", title: "Value", cell: "1") })
        let migrated = legacy.rowLayout
        try require(legacy.rows == nil && migrated.rows?.count == 2 &&
                    migrated.components.map(\.id) == legacy.components.map(\.id) &&
                    migrated.availableColumns(in: "row_1") == 0 &&
                    migrated.components.map(\.columnSpan) == [2, 2, 3, 2, 3, 2, 2],
                    "legacy grids migrate without losing order or overflowing twelve columns")
        legacy = migrated
        legacy.moveComponent("c5", to: "row_1")
        try require(legacy.components[5].row == "row_2", "moving into a full row is rejected")
        let addedRow = legacy.appendRow()
        legacy.moveComponent("c5", to: addedRow)
        try require(legacy.components.first { $0.id == "c5" }?.row == addedRow && legacy.availableColumns(in: addedRow) == 10,
                    "component moves preserve width and update row capacity")
        legacy.removeRow(addedRow)
        try require(!legacy.components.contains { $0.id == "c5" } && legacy.rows?.count == 2,
                    "removing a row removes only its owned components")
        let created = await withCheckedContinuation { continuation in
            model.open(url: url, create: true) { continuation.resume(returning: $0) }
        }
        try require(created, "create board project")
        let inputCreated = await perform(model, "new_input", text: #"{"id":"gain","title":"Gain","type":"number","default":2}"#)
        try require(inputCreated && model.snapshot?.inputs?.first?.editingText == "2.0", "typed input snapshot")
        var board = NotebookBoard.empty(sheet: "main")
        board.components = [NotebookBoardComponent(id: "gain", kind: "input", title: "Gain", input: "gain"),
                            NotebookBoardComponent(id: "loss", kind: "live_chart", title: "Loss",
                                                   chart_id: "loss", x_label: "Step", y_label: "Loss", stroke: "#d97706",
                                                   y_min: 0, y_max: 100)]
        board = board.rowLayout
        board.rows?[0].height = 320
        board.components[0].span = 4
        board.components[1].span = 8
        board.components[0].h_align = "trailing"; board.components[0].v_align = "center"
        board.components[1].v_align = "stretch"
        let saved = await withCheckedContinuation { continuation in
            model.saveBoard(board) { continuation.resume(returning: $0) }
        }
        try require(saved && model.activeBoard?.id == board.id, "designer board saves with valid generated ID")
        try require(model.activeBoard?.rows?.first?.height == 320 &&
                    model.activeBoard?.components[0].span == 4 &&
                    model.activeBoard?.components[0].h_align == "trailing" &&
                    model.activeBoard?.components[0].v_align == "center",
                    "row height, span and alignment survive native save and snapshot reload")
        board.components[1].x_label = "Optimizer step"
        let edited = await withCheckedContinuation { continuation in
            model.saveBoard(board) { continuation.resume(returning: $0) }
        }
        try require(edited && model.activeBoard?.components[1].x_label == "Optimizer step" &&
                    model.activeBoard?.components[1].cell == nil && model.activeBoard?.components[1].y_max == 100,
                    "chart settings survive Swift encoding, backend validation and model reload")
        board.components[1].y_min = nil; board.components[1].y_max = nil; board.rows?[0].height = nil
        let automatic = await withCheckedContinuation { continuation in
            model.saveBoard(board) { continuation.resume(returning: $0) }
        }
        try require(automatic && model.activeBoard?.components[1].y_max == nil && model.activeBoard?.rows?.first?.height == nil,
                    "clearing optional bounds and height restores automatic sizing")
        guard let tab = model.activeTab, let cell = tab.cells.first else { throw ModelTestFailure(description: "board controller missing") }
        model.editSource("notebook.input(\"gain\") * 21\n", cell: cell, tab: tab)
        let ran = await perform(model, "run_all", tab: tab)
        try require(ran && model.activeTab?.cells.first?.result == "42", "board controller reads default")
        let changed = await withCheckedContinuation { continuation in
            model.perform("set_input", text: "3", commandCellID: "gain") { continuation.resume(returning: $0) }
        }
        try require(changed && model.activeTab?.cells.first?.result == "63", "native model input event reruns controller")
        let rejected = await withCheckedContinuation { continuation in
            model.perform("set_input", text: "false", commandCellID: "gain") { continuation.resume(returning: $0) }
        }
        try require(!rejected && model.snapshot?.inputs?.first?.editingText == "3.0", "invalid input retains snapshot")
        let integerJSON = try NotebookProjectInput.valueJSON("9223372036854775807", type: "integer")
        let stringJSON = try NotebookProjectInput.valueJSON("a\"b", type: "string")
        try require(integerJSON == "9223372036854775807", "integer edits remain exact")
        try require(stringJSON == #""a\"b""#, "string editor escapes JSON")
    }

    private static func testNumericChartSampling() throws {
        var points = (0..<1000).map { NotebookChartPoint(x: Double($0), y: 1) }
        points[123] = NotebookChartPoint(x: 123, y: 100)
        points[456] = NotebookChartPoint(x: 456, y: -50)
        let chart = NotebookLiveChart(id: "loss", points: points, total_points: 1000, replace_chart: true)
        let sampled = chart.sampledPoints(maxCount: 120)
        try require(sampled.count <= 120 && sampled.first?.x == 0 && sampled.last?.x == 999 &&
                    sampled.contains(where: { $0.y == 100 }) && sampled.contains(where: { $0.y == -50 }),
                    "responsive chart sampling retains endpoints and narrow loss spikes")
    }

    private static func testFigurePanels() throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<2 { for x in 0..<2 {
            bitmap.setColor(NSColor(deviceRed: 1, green: 0.5, blue: 0, alpha: 1), atX: x, y: y)
        } }
        let png = bitmap.representation(using: .png, properties: [:])!
        let json = try JSONSerialization.data(withJSONObject: [
            "mime": "image/png", "caption": "Тест 🦊", "width": 2, "height": 2,
            "data": png.base64EncodedString()
        ])
        let decoded = try JSONDecoder().decode(NotebookFigurePanel.self, from: json)
        try require(decoded.data == png && decoded.caption == "Тест 🦊" && decoded.image() != nil,
                    "figure JSON must retain original PNG bytes and Unicode captions")
        try require(decoded.image(maxPixelSize: 1)?.size == NSSize(width: 1, height: 1),
                    "gallery previews must respect their decode size budget")
        try require(NotebookFigurePanel.label(0) == "a)" && NotebookFigurePanel.label(25) == "z)" &&
                    NotebookFigurePanel.label(26) == "aa)" && NotebookFigurePanel.label(63) == "bl)",
                    "scientific panel labels must continue beyond z")
        for invalid in [
            NotebookFigurePanel(mime: "image/svg+xml", caption: "", width: 2, height: 2, data: png),
            NotebookFigurePanel(mime: "image/png", caption: "", width: 3, height: 2, data: png),
            NotebookFigurePanel(mime: "image/png", caption: "", width: 9000, height: 2, data: png),
            NotebookFigurePanel(mime: "image/png", caption: "", width: 2, height: 2, data: Data("not PNG".utf8))
        ] {
            try require(invalid.image() == nil, "invalid or mismatched figure images must not decode")
        }
    }

    private static func testProgressSourceSelection() throws {
        let settings = NotebookCell(id: "3", kind: "code", source: "epochs = 5", formatting: "",
            watch: false, dirty: false, ok: true, result: "5", error: "", output: [], locals: [])
        var training = NotebookCell(id: "5", kind: "code", source: "metrics = train_mnist()", formatting: "",
            watch: false, dirty: false, ok: true, result: "", error: "", output: [], locals: [])
        let model = NotebookModel()
        var tab = makeTab(id: "sheet:main", cells: [settings, training])
        model.snapshot = makeSnapshot(tab: tab)
        try require(model.suggestedProgressCell(in: tab) == nil, "unpublished progress must not default to the settings cell")
        training.progress = [NotebookProgress(id: "mnist-training", description: "Training", current: 1, total: 32, elapsed_ms: 100, done: false)]
        tab = makeTab(id: tab.id, cells: [settings, training]); model.snapshot = makeSnapshot(tab: tab)
        try require(model.suggestedProgressCell(in: tab)?.id == "5", "preselect the unique publishing cell rather than the first code cell")
        try require(model.presentation(for: settings, in: tab).progress.isEmpty && model.presentation(for: training, in: tab).progress.first?.id == "mnist-training",
                    "progress is owned by the publishing cell, not the root or preceding settings cell")
        var another = settings
        another.progress = [NotebookProgress(id: "loading", description: "Loading", current: 1, total: 2, elapsed_ms: 10, done: false)]
        tab = makeTab(id: tab.id, cells: [another, training]); model.snapshot = makeSnapshot(tab: tab)
        try require(model.suggestedProgressCell(in: tab) == nil, "multiple providers require an explicit source selection")
    }

    private static func testTextVariables() throws {
        let first = NotebookCell(
            id: "code-1", kind: "code", source: "answer = 1\n", formatting: "",
            watch: false, dirty: false, ok: true, result: "", error: "",
            output: [], locals: [
                NotebookLocal(name: "answer", value: "debug-1", role: "module_cell",
                              binding_kind: "local", initialized: true, watched: false,
                              text_value: "one"),
                NotebookLocal(name: "from_import", value: "debug-import", role: "module_import",
                              binding_kind: "import", initialized: true, watched: false,
                              text_value: "should-not-appear")
            ])
        let shadow = NotebookCell(
            id: "code-2", kind: "code", source: "answer = 2\n", formatting: "",
            watch: false, dirty: false, ok: true, result: "", error: "",
            output: [], locals: [
                NotebookLocal(name: "answer", value: "debug-2", role: "module_cell",
                              binding_kind: "local", initialized: true, watched: false,
                              text_value: "two"),
                NotebookLocal(name: "pending", value: "", role: "module_cell",
                              binding_kind: "local", initialized: false, watched: false,
                              text_value: nil)
            ])
        let target = NotebookCell(
            id: "text-1", kind: "text", source: "{{answer}}", formatting: "",
            watch: false, dirty: false, ok: false, result: "", error: "",
            output: [], locals: [])
        let later = NotebookCell(
            id: "code-3", kind: "code", source: "answer = 3\n", formatting: "",
            watch: false, dirty: false, ok: true, result: "", error: "",
            output: [], locals: [
                NotebookLocal(name: "later", value: "debug-later", role: "module_cell",
                              binding_kind: "local", initialized: true, watched: false,
                              text_value: "later")
            ])
        let tab = makeTab(id: "sheet:variables", cells: [first, shadow, target, later])
        let model = NotebookModel()
        model.snapshot = makeSnapshot(tab: tab)

        let values = model.textVariables(before: target, in: tab)
        try require(values.map { $0.name } == ["answer", "pending"],
                    "variables should be deterministic and exclude later/import bindings")
        let answer = try requireVariable("answer", in: values)
        try require(answer.value == "two" && answer.cellID == shadow.id,
                    "nearest module-cell provider should shadow the older value and use text_value")
        try require(!answer.stale, "fresh providers should not be marked stale")
        let boardValues = model.textVariables(in: tab)
        try require(boardValues.map(\.name) == ["answer", "later", "pending"] &&
                    boardValues.first(where: { $0.name == "answer" })?.value == answer.value,
                    "board and sheet text share shadowing, roles and text-value resolution")
        try require(!model.figureIsStale(for: shadow, in: tab), "fresh figures should not be stale")
        let pending = try requireVariable("pending", in: values)
        try require(pending.value == "<unavailable>" && pending.stale,
                    "uninitialized providers should remain visible but unavailable and stale")

        var staleTab = makeTab(id: "sheet:stale", cells: [
            first,
            NotebookCell(
                id: "failed", kind: "code", source: "broken", formatting: "",
                watch: false, dirty: true, ok: false, result: "", error: "failed",
                output: [], locals: []),
            target
        ])
        staleTab = NotebookTab(id: staleTab.id, kind: staleTab.kind, title: staleTab.title,
                               modified: staleTab.modified, environment_stale: true,
                               auto_import: staleTab.auto_import, status: staleTab.status,
                               environment_error: staleTab.environment_error,
                               environment_output: staleTab.environment_output,
                               selected_cell: staleTab.selected_cell, cells: staleTab.cells)
        let staleTarget = staleTab.cells[2]
        let staleModel = NotebookModel()
        staleModel.snapshot = makeSnapshot(tab: staleTab)
        let staleAnswer = try requireVariable("answer",
                                              in: staleModel.textVariables(before: staleTarget,
                                                                           in: staleTab))
        try require(staleAnswer.stale,
                    "environment and dirty/failed predecessors should stale retained values")

        let draftModel = NotebookModel()
        draftModel.snapshot = makeSnapshot(tab: tab)
        draftModel.editSource("answer = draft\n", cell: first, tab: tab)
        let draftedAnswer = try requireVariable("answer",
                                                in: draftModel.textVariables(before: target,
                                                                             in: tab))
        try require(draftedAnswer.stale,
                    "a prior code draft should stale the nearest runtime provider")
        try require(draftModel.textVariables(in: tab).allSatisfy(\.stale),
                    "board references obey the same conservative draft staleness as sheet text")
        try require(draftModel.figureIsStale(for: shadow, in: tab),
                    "a prior code draft should also stale retained dependent figures")
    }

    private static func makeTab(id: String, cells: [NotebookCell]) -> NotebookTab {
        NotebookTab(id: id, kind: "sheet", title: id, modified: false,
                     environment_stale: false, auto_import: false, status: "ready",
                     environment_error: "", environment_output: [],
                     selected_cell: cells.first?.id ?? "", cells: cells)
    }

    private static func makeSnapshot(tab: NotebookTab) -> NotebookSnapshot {
        NotebookSnapshot(title: "Variables", path: "", selected_tab: tab.id,
                         modified_count: 0, environment_generation: 1, tabs: [tab])
    }

    private static func requireVariable(_ name: String,
                                        in values: [NotebookTextVariable]) throws -> NotebookTextVariable {
        guard let variable = values.first(where: { $0.name == name }) else {
            throw ModelTestFailure(description: "missing variable \(name)")
        }
        return variable
    }

    @MainActor
    private static func testDraftsTabsAndStructures(_ model: NotebookModel,
                                                    first: URL) async throws {
        let initiallyOpened = await open(model, url: first)
        try require(initiallyOpened, "initial project should open")
        let initial = try requireSnapshot(model)
        let main = try requireTab("sheet:main", in: initial)
        let firstCell = try requireCell("101", in: main)

        // Create a second sheet, then edit the first sheet while it is
        // inactive. Selecting a different tab must flush every cached draft
        // before changing the backend's active tab.
        let sheetCreated = await perform(model, "new_sheet", tab: main,
                                         text: "second")
        try require(sheetCreated, "new sheet should be created")
        let secondSheet = try requireTab("sheet:second", in: requireSnapshot(model))
        model.editSource("answer = 42\n", cell: firstCell, tab: main)
        let selectedMainTab = await perform(model, "select", tab: main)
        try require(selectedMainTab,
                    "cross-tab selection should not use the old tab's cell ID")
        try require(model.error == nil,
                    "cross-tab selection should not report a stale cell ID")
        let selectedMain = try requireTab("sheet:main", in: requireSnapshot(model))
        try require(selectedMain.cells.first(where: { $0.id == "101" })?.source ==
                        "answer = 42\n",
                    "selecting a tab should flush its pending source draft")

        // A module tab has a different cell ID. Editing its source and
        // selecting a sheet must still route the select with no stale cell.
        let selectedSecondSheet = await perform(model, "select", tab: secondSheet)
        try require(selectedSecondSheet, "second sheet should be selectable")
        let moduleCreated = await perform(model, "new_module", text: "scratch")
        try require(moduleCreated, "new module should be created")
        let module = try requireTab("module:scratch", in: requireSnapshot(model))
        let moduleCell = try requireCell(module.cells.first?.id ?? "", in: module)
        let moduleSource = "package scratch\nvalue = 7\n"
        model.editSource(moduleSource, cell: moduleCell, tab: module)
        let selectedFromModule = await perform(model, "select", tab: selectedMain)
        try require(selectedFromModule,
                    "module-to-sheet selection should succeed")
        try require(model.error == nil,
                    "module-to-sheet selection should not report a stale cell ID")
        let savedAll = await perform(model, "save_all")
        try require(savedAll,
                    "Save All should persist drafts across sheet and module tabs")
        try require(!model.hasUnsavedChanges,
                    "successful Save All should clear committed drafts")
        let saved = try requireSnapshot(model)
        let savedMain = try requireTab("sheet:main", in: saved)
        let savedModule = try requireTab("module:scratch", in: saved)
        try require(!savedMain.modified, "main sheet should be saved")
        try require(!savedModule.modified, "module source should be saved")
    }

    @MainActor
    private static func testTextFormattingDrafts(_ model: NotebookModel) async throws {
        let created = await perform(model, "add_text")
        try require(created, "text block creation should succeed")
        guard let tab = model.activeTab, let cell = model.selectedCell, cell.kind == "text" else {
            throw ModelTestFailure(description: "text block should be selected")
        }
        let source = "Заметка 🦊"
        let bold = "{\"version\":1,\"runs\":[{\"start\":0,\"length\":7,\"bold\":true}]}"
        model.editRichText(source, formatting: bold, cell: cell, tab: tab)
        try require(model.hasUnsavedChanges, "rich source draft is modified")
        let savedDraft = await perform(model, "save_all")
        try require(savedDraft, "rich draft should save")
        try require(!model.hasUnsavedChanges, "saved rich draft clears both source and formatting")
        guard let saved = model.selectedCell, let savedTab = model.activeTab else {
            throw ModelTestFailure(description: "saved text should exist")
        }
        let italic = "{\"version\":1,\"runs\":[{\"start\":0,\"length\":7,\"italic\":true}]}"
        model.editRichText(source, formatting: italic, cell: saved, tab: savedTab)
        try require(model.hasUnsavedChanges && model.source(for: saved, in: savedTab) == saved.source,
                    "style-only edits should count dirty with unchanged plain text")
        let savedStyle = await perform(model, "save_all")
        try require(savedStyle, "style-only draft should save")
        try require(!model.hasUnsavedChanges && model.selectedCell?.formatting.contains("italic") == true,
                    "style-only save must reach backend and clear draft")
        // A native buffer that cannot be encoded is still unsaved. Do not
        // silently save the previous source or unmount that editor on select.
        let document = model.documentIdentity
        model.reportEditorError("Unsupported attachment", cell: saved, tab: savedTab, document: document)
        try require(model.hasUnsavedChanges && model.isModified(savedTab), "unencodable buffer must protect close")
        let rejectedSave = await perform(model, "save_all")
        let rejectedSelect = await perform(model, "select", tab: savedTab)
        try require(!rejectedSave && !rejectedSelect, "unencodable editor must block save and tab replacement")
        model.reportEditorError(nil, cell: saved, tab: savedTab, document: UUID())
        try require(model.hasUnsavedChanges, "stale document callback must not clear current protection")
        model.reportEditorError(nil, cell: saved, tab: savedTab, document: document)
        let savedRecovery = await perform(model, "save_all")
        try require(savedRecovery && !model.hasUnsavedChanges, "undoing the unsupported edit recovers normal saving")
        if let latest = model.selectedCell, let latestTab = model.activeTab, let path = model.snapshot?.path {
            let structured = "Title\n1.\t{{answer}}\nA\nB\n"
            let version2 = #"{"version":2,"runs":[],"paragraphs":[{"start":0,"length":6,"style":"heading1"},{"start":6,"length":14,"list":"numbered"}],"tables":[{"start":20,"length":4,"columns":2,"cells":[{"start":20,"length":2},{"start":22,"length":2}]}]}"#
            model.editRichText(structured, formatting: version2, cell: latest, tab: latestTab)
            let savedStructure = await perform(model, "save_all")
            try require(savedStructure, "v2 heading/list/table template must pass the real worker and save")
            let reopened = NotebookModel()
            let opened = await open(reopened, url: URL(fileURLWithPath: path))
            let restored = reopened.snapshot?.tabs.first(where: { $0.id == latestTab.id })?.cells.first(where: { $0.id == latest.id })
            let preserved = restored?.source == structured && restored?.formatting.contains("\"tables\"") == true
            await shutdown(reopened)
            try require(opened && preserved, "v2 structure and interpolation templates must survive a fresh runtime reopen")
        }
        // Removal of a drafted text block must clear its whole structured draft.
        if let latest = model.selectedCell, let latestTab = model.activeTab {
            model.editRichText(source + "!", formatting: italic, cell: latest, tab: latestTab)
            let deleted = await perform(model, "delete_cell", tab: latestTab, cell: latest)
            try require(deleted, "drafted text deletes")
            let savedDelete = await perform(model, "save_all")
            try require(savedDelete, "deleting rich draft leaves project saveable")
        }
    }

    @MainActor
    private static func testDeleteDoesNotLeaveAnOrphanDraft(_ model: NotebookModel,
                                                             first: URL) async throws {
        _ = first
        let snapshot = try requireSnapshot(model)
        let main = try requireTab("sheet:main", in: snapshot)
        let cell = try requireCell("102", in: main)
        model.editSource("doomed = 9\n", cell: cell, tab: main)
        let deleted = await perform(model, "delete_cell", tab: main, cell: cell)
        try require(deleted, "deleting a drafted cell should succeed")
        let afterDelete = try requireSnapshot(model)
        let mainAfterDelete = try requireTab("sheet:main", in: afterDelete)
        try require(mainAfterDelete.cells.allSatisfy { $0.id != cell.id },
                    "deleted cell should disappear from the snapshot")
        let savedAfterDelete = await perform(model, "save_all")
        try require(savedAfterDelete,
                    "Save All must not retry a deleted cell's stale draft ID")
        try require(!model.hasUnsavedChanges,
                    "deleting then saving should leave no orphan draft")

        // The model keeps the selected cell stable while moving it in the
        // backend. Add one after the remaining cell, then move it both ways.
        let currentMain = try requireTab("sheet:main", in: requireSnapshot(model))
        guard let remaining = currentMain.cells.first else {
            throw ModelTestFailure(description: "sheet should retain one code cell")
        }
        let addedSuccessfully = await perform(model, "add_cell", tab: currentMain,
                                               cell: remaining)
        try require(addedSuccessfully, "adding a code cell should succeed")
        let added = model.activeTab?.selected_cell ?? ""
        try require(!added.isEmpty && model.selectedCellID == added,
                    "new cell should become the stable selected cell")
        let latestMain = try requireTab("sheet:main", in: requireSnapshot(model))
        let addedCell = try requireCell(added, in: latestMain)
        let movedUp = await perform(model, "move_up", tab: currentMain,
                                    cell: addedCell)
        try require(movedUp, "moving a cell up should succeed")
        try require(model.activeTab?.selected_cell == added,
                    "moving up should preserve the selected cell ID")
        let movedDown = await perform(model, "move_down", tab: model.activeTab,
                                      cell: addedCell)
        try require(movedDown, "moving a cell down should succeed")
        try require(model.activeTab?.selected_cell == added,
                    "moving down should preserve the selected cell ID")
        let savedStructure = await perform(model, "save_all")
        try require(savedStructure, "structural edits should remain saveable")
    }

    @MainActor
    private static func testNulAndFailedOpenKeepTheCurrentDocument(
        _ model: NotebookModel, first: URL) async throws {
        let snapshot = try requireSnapshot(model)
        let main = try requireTab("sheet:main", in: snapshot)
        guard let cell = main.cells.first else {
            throw ModelTestFailure(description: "main sheet should have a cell")
        }

        let nulSource = "prefix\0suffix\n"
        model.editSource(nulSource, cell: cell, tab: main)
        try require(!model.source(for: cell, in: main).isEmpty,
                    "NUL draft should remain visible before submission")
        let nulSaved = await perform(model, "save_all")
        try require(!nulSaved, "NUL source should be rejected instead of truncated")
        try require(model.error?.contains("NUL") == true,
                    "NUL rejection should explain why the source was not submitted")
        let afterNul = try requireSnapshot(model)
        let persistedCell = try requireCell(cell.id,
            in: try requireTab("sheet:main", in: afterNul))
        try require(persistedCell.source != "prefix",
                    "C string truncation must never persist a source prefix")
        try require(model.source(for: cell, in: main) == nulSource,
                    "rejected source must remain recoverable as a Swift draft")

        // A replacement project that cannot be created must leave the live
        // handle, pending editor buffer, and recent project untouched.
        let overwroteProject = await open(model, url: first, create: true)
        try require(!overwroteProject,
                    "creating over the existing project should fail")
        try require(model.snapshot?.path == snapshot.path &&
                    model.snapshot?.selected_tab == snapshot.selected_tab,
                    "failed open must keep the old host and snapshot: \(model.snapshot?.path ?? "nil") vs \(snapshot.path)")
        try require(model.source(for: cell, in: main) == nulSource,
                    "failed open must keep pending drafts")
        model.clearError()
        model.editSource(cell.source, cell: cell, tab: main)
        let savedAfterRevert = await perform(model, "save_all")
        try require(savedAfterRevert,
                    "reverting a rejected draft should restore a saveable project")
    }

    @MainActor
    private static func testRepeatedReplacementAndExternalConflict(
        _ model: NotebookModel, first: URL, second: URL) async throws {
        for project in [second, first, second, first] {
            let replacementOpened = await open(model, url: project)
            try require(replacementOpened, "replacing a project should succeed")
            let reported = model.snapshot.map {
                URL(fileURLWithPath: $0.path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            }
            try require(reported == project.resolvingSymlinksInPath().standardizedFileURL,
                        "replacement snapshot should refer to the latest project: \(reported?.path ?? "nil") vs \(project.path)")
        }

        let manifestURL = first.appendingPathComponent("project.json")
        let baseline = try String(contentsOf: manifestURL, encoding: .utf8)
        let changed = baseline.replacingOccurrences(of: "Model Test", with: "Outside Edit")
        try require(changed != baseline,
                    "fixture should contain the title field for conflict injection")
        try changed.write(to: manifestURL, atomically: true, encoding: .utf8)

        let main = try requireTab("sheet:main", in: requireSnapshot(model))
        guard let cell = main.cells.first else {
            throw ModelTestFailure(description: "main sheet should have a cell")
        }
        model.editSource("local = 5\n", cell: cell, tab: main)
        let conflictSaved = await perform(model, "save_all")
        try require(!conflictSaved,
                    "Save All should reject an externally changed manifest")
        try require(model.error?.localizedCaseInsensitiveContains("changed") == true,
                    "save conflict should explain that the project changed")
        try require(model.hasUnsavedChanges,
                    "conflicting Save All must retain dirty source state")
        try require(model.source(for: cell, in: main) == "local = 5\n" ||
                        model.snapshot?.tabs.first(where: { $0.id == main.id })?.cells
                            .first(where: { $0.id == cell.id })?.source == "local = 5\n",
                    "failed Save All must retain the source in the draft or backend")
    }

    @MainActor
    private static func open(_ model: NotebookModel, url: URL,
                             create: Bool = false) async -> Bool {
        await withCheckedContinuation { continuation in
            model.open(url: url, create: create) { opened in
                continuation.resume(returning: opened)
            }
        }
    }

    @MainActor
    private static func perform(_ model: NotebookModel, _ action: String,
                                tab: NotebookTab? = nil,
                                cell: NotebookCell? = nil,
                                text: String = "") async -> Bool {
        await withCheckedContinuation { continuation in
            model.perform(action, tab: tab, cell: cell, text: text) { succeeded in
                continuation.resume(returning: succeeded)
            }
        }
    }

    @MainActor
    private static func shutdown(_ model: NotebookModel) async {
        await withCheckedContinuation { continuation in
            model.shutdown { continuation.resume() }
        }
    }

    private static func writeProject(_ path: URL, title: String,
                                     cellIDs: [String]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: path, withIntermediateDirectories: false)
        let cells = cellIDs.enumerated().map { index, id in
            "{\"id\":\"\(id)\",\"kind\":\"code\",\"source\":\"value_\(index) = \(index)\\n\",\"mode\":\"watch\"}"
        }.joined(separator: ",")
        let json = "{\"format\":\"sputnik-notebook\",\"version\":1,\"title\":\"\(title)\",\"active_sheet\":\"main\",\"sheets\":[{\"id\":\"main\",\"title\":\"Main\",\"cells\":[\(cells)]}],\"modules\":[],\"auto_imports\":[]}"
        try json.write(to: path.appendingPathComponent("project.json"),
                       atomically: true, encoding: .utf8)
    }

    private static func requireSnapshot(_ model: NotebookModel) throws -> NotebookSnapshot {
        guard let snapshot = model.snapshot else {
            throw ModelTestFailure(description: "model should have an open snapshot")
        }
        return snapshot
    }

    private static func requireTab(_ id: String,
                                   in snapshot: NotebookSnapshot) throws -> NotebookTab {
        guard let tab = snapshot.tabs.first(where: { $0.id == id }) else {
            throw ModelTestFailure(description: "snapshot is missing tab \(id)")
        }
        return tab
    }

    private static func requireCell(_ id: String,
                                    in tab: NotebookTab) throws -> NotebookCell {
        guard let cell = tab.cells.first(where: { $0.id == id }) else {
            throw ModelTestFailure(description: "tab \(tab.id) is missing cell \(id)")
        }
        return cell
    }

    private static func require(_ condition: @autoclosure () -> Bool,
                                _ message: String) throws {
        guard condition() else { throw ModelTestFailure(description: message) }
    }
}

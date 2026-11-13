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
            let legacyImportError = notebookEnvironmentMessage("missing bundled module dependency: torch (searched /home/private/server/packages, /var/lib/sputnik-packages)")
            try require(legacyImportError.contains("torch") && legacyImportError.contains("Open Dependencies") && !legacyImportError.contains("/home/") && !legacyImportError.contains("/var/"), "legacy remote import diagnostics expose the module and recovery action without server paths")
            try testProgressSourceSelection()
            try testFigurePanels()
            try testNumericChartSampling()
            try await testNumberedStructures(model, url: root.appendingPathComponent("numbered.sputnikbook"))
            try await testBookFiles(model, root: root)
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
            try await testEnvironmentTiming(root: root)
            try await testImportDiagnostics(root: root)
            try await testCompileOnlyModuleCheck(root: root)
            try await testModuleErrorsFromBoards(root: root)
            try await testDefaultModuleAndWatch(url: root.appendingPathComponent("unified.sputnikbook"))
            try await testWorkerGrants(root: root)
            try await testCellIDs(root: root)
            try await testResourcePolicies(root: root)
            try await testRemoteCallbacksCannotEditAnotherDocument(root: root)
            try await testRemoteAmbiguousRepliesAndTerminalFailures(root: root)
            try await testExportDraft(model, url: root.appendingPathComponent("exports.sputnikbook"))

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
    private static func testExportDraft(_ model: NotebookModel, url: URL) async throws {
        try writeProject(url, title: "Exports", cellIDs: ["1"])
        let opened = await open(model, url: url)
        try require(opened, "open export fixture")
        let tab = model.activeTab!, cell = tab.cells[0]
        let draft = "dataset = [1, 2]\nlabels = [3, 4]\n"
        model.editSource(draft, cell: cell, tab: tab)
        let source = draft + "export dataset, labels as categories\n"
        let applied = await perform(model, "source", tab: tab, cell: cell, text: source)
        let current = model.activeTab!, updated = current.cells[0]
        try require(applied && model.source(for: updated, in: current) == source, "export edit replaces the unsaved editor buffer")
        try require(updated.exports?.map(\.name) == ["categories", "dataset"], "export choices are available to the imports editor")
        let saved = await perform(model, "save_all")
        let reloaded = await open(model, url: url)
        try require(saved && reloaded && model.activeTab?.cells[0].source == source, "saving keeps the updated declarations")
    }

    @MainActor
    private static func testResourcePolicies(root: URL) async throws {
        let first = root.appendingPathComponent("policy-first.sputnikbook")
        let second = root.appendingPathComponent("policy-second.sputnikbook")
        try writeProject(first, title: "Policy First", cellIDs: ["1"])
        try writeProject(second, title: "Policy Second", cellIDs: ["1"])
        let model = NotebookModel()
        var app = NotebookResourcePolicy.appDefaults
        app.run_count = 5
        model.setAppResourcePolicy(app)
        let opened = await open(model, url: first)
        try require(opened, "open policy book")
        var book = NotebookResourcePolicy()
        book.run_count = 2
        let saved = await withCheckedContinuation { continuation in model.setBookResourcePolicy(book) { continuation.resume(returning: $0) } }
        try require(saved && model.effectiveResourcePolicy.run_count == 2, "book override applies")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: first.appendingPathComponent("project.json"))) as! [String: Any]
        try require((raw["resource_policy"] as? [String: Int])?["run_count"] == 2, "book policy is in project document")
        let other = await open(model, url: second)
        try require(other && model.bookResourcePolicy.run_count == nil && model.effectiveResourcePolicy.run_count == 5, "another book inherits app without previous book overrides")
        let reopened = await open(model, url: first)
        try require(reopened && model.bookResourcePolicy.run_count == 2, "book policy survives reopen")
        for _ in 0..<4 {
            let start = NotebookRunStart(tab: model.activeTab!.id, cell: nil, action: "run", backend: "Local", sources: [], inputs: [:], cellInputs: [:], assets: [:], dependencies: [])
            model.runHistory.record(start, state: model.snapshot!)
        }
        try require(model.runHistory.runs.count == 2, "local history obeys book count")
        let pinned = model.runHistory.runs[0].id
        model.runHistory.pin(pinned)
        for _ in 0..<3 {
            let start = NotebookRunStart(tab: model.activeTab!.id, cell: nil, action: "run", backend: "Local", sources: [], inputs: [:], cellInputs: [:], assets: [:], dependencies: [])
            model.runHistory.record(start, state: model.snapshot!)
        }
        try require(model.runHistory.runs.count == 2 && model.runHistory.runs.contains { $0.id == pinned }, "retention protects pinned snapshots")
        book.run_count = 9
        book.minimum_free_bytes = 256 * 1024 * 1024
        try require(book.applying(to: app).run_count == 9 && book.applying(to: app).minimum_free_bytes == book.minimum_free_bytes, "local book replaces app defaults in either direction")
        try require(book.applying(to: app, restrictive: true).run_count == 5 && book.applying(to: app, restrictive: true).minimum_free_bytes == app.minimum_free_bytes, "remote without opt-in remains restrictive")
        book.run_seconds = 5
        let increased = await withCheckedContinuation { continuation in model.setBookResourcePolicy(book) { continuation.resume(returning: $0) } }
        try require(increased && model.effectiveResourcePolicy.run_count == 9 && model.appResourcePolicy.run_count == 5, "saved book can raise app default independently")
        var limited = app
        limited.run_seconds = 1
        model.setAppResourcePolicy(limited)
        let shortTab = model.activeTab!, shortCell = shortTab.cells[0]
        model.editSource("import task\ntask.sleep(1200)\n42\n", cell: shortCell, tab: shortTab)
        let extended = await perform(model, "run")
        try require(extended && model.activeTab!.cells[0].ok, "local book time budget can exceed app default")
        book.run_seconds = nil
        let inherited = await withCheckedContinuation { continuation in model.setBookResourcePolicy(book) { continuation.resume(returning: $0) } }
        try require(inherited && model.effectiveResourcePolicy.run_seconds == 1, "unchecked time budget inherits app")
        let tab = model.activeTab!, cell = tab.cells[0]
        model.editSource("import task\ntask.sleep(60000)\n42\n", cell: cell, tab: tab)
        let started = ProcessInfo.processInfo.systemUptime
        _ = await perform(model, "run")
        try require(ProcessInfo.processInfo.systemUptime - started < 5, "local run stops at configured time")
        try require(model.error?.contains("time limit") == true, "budget stop has an actionable reason")
        try require(model.resourceUsage.current >= 1, "local usage was charged")
        await shutdown(model)
        let again = await open(model, url: first)
        try require(again && model.resourceUsage.current >= 1 && model.effectiveResourcePolicy.run_count == 9, "usage and raised book policy survive reopen")
        await shutdown(model)
    }

    @MainActor
    private static func testRemoteCallbacksCannotEditAnotherDocument(root: URL) async throws {
        let model = NotebookModel(remoteStorage: root.appendingPathComponent("identity-settings"))
        let first = root.appendingPathComponent("identity-first.sputnikbook")
        let second = root.appendingPathComponent("identity-second.sputnikbook")
        try writeProject(first, title: "First", cellIDs: ["1"])
        try writeProject(second, title: "Second", cellIDs: ["1"])
        let firstOpened = await open(model, url: first)
        try require(firstOpened, "open identity fixture")
        model.editSource("999\n", cell: model.activeTab!.cells[0], tab: model.activeTab!)
        var opened: Bool?
        // Force the old remote callback to enqueue after replacement, before
        // open's main-thread completion has advanced the model identity.
        model.open(url: second) { opened = $0 }
        do { _ = try await model.remote.exportSnapshot!(); throw ModelTestFailure(description: "stale export accepted") }
        catch is ModelTestFailure { throw ModelTestFailure(description: "stale export accepted") }
        catch {}
        for _ in 0..<200 where opened == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(opened == true, "replacement opens")
        let expected = model.activeTab!.cells[0].source
        let saved = await perform(model, "save_all")
        try require(saved, "save replacement")
        let reopened = await open(model, url: second)
        try require(reopened, "reopen replacement")
        try require(model.activeTab!.cells[0].source == expected && expected != "999\n",
                    "a rejected remote callback must not mutate the new native document")

        // Failed open keeps the old owner usable, including its unsaved edits.
        model.editSource("777\n", cell: model.activeTab!.cells[0], tab: model.activeTab!)
        var failed: Bool?
        model.open(url: root.appendingPathComponent("does-not-exist.sputnikbook")) { failed = $0 }
        _ = try await model.remote.exportSnapshot!()
        try require(failed == false && model.activeTab!.cells[0].source == "777\n", "failed open preserves the old document owner")
        // Reopening the same pathname is still a new native handle/generation.
        model.editSource("888\n", cell: model.activeTab!.cells[0], tab: model.activeTab!)
        opened = nil; model.open(url: second) { opened = $0 }
        do { _ = try await model.remote.exportSnapshot!(); throw ModelTestFailure(description: "same-path stale export accepted") }
        catch is ModelTestFailure { throw ModelTestFailure(description: "same-path stale export accepted") }
        catch {}
        let samePathSaved = await perform(model, "save_all")
        try require(samePathSaved, "save same-path replacement")
        try require(model.activeTab!.cells[0].source == expected, "same-path replacement rejects old drafts")
        await shutdown(model)
    }

    @MainActor
    private static func testRemoteAmbiguousRepliesAndTerminalFailures(root: URL) async throws {
        let directory = root.appendingPathComponent("remote-recovery")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let book = directory.appendingPathComponent("Remote.sputnikbook")
        try writeProject(book, title: "Recovery", cellIDs: ["1"])
        let helper = directory.appendingPathComponent("fixture-cli")
        let registryFile = directory.appendingPathComponent("registry.json"), faultFile = directory.appendingPathComponent("fault")
        let commandsFile = directory.appendingPathComponent("commands.json")
        let program = #"""
        #!/usr/bin/python3
        import json,pathlib,sys
        root=pathlib.Path(__file__).parent;args=sys.argv;command=args[args.index('--command')+1]
        fault=root/'fault';armed=fault.read_text() if fault.exists() else ''
        commands=json.loads((root/'commands.json').read_text()) if (root/'commands.json').exists() else []
        if command=='health': result={'protocol':1,'capabilities':['gui_reconnect','compact_registry','board_actions','server_periodic','project_inputs','cell_inputs']}
        elif command=='registry': result=json.loads((root/'registry.json').read_text())
        elif command=='projects': result={'projects':[{'id':'p','head':'r','state':'active'}]}
        elif command=='status':
            run=next(x for x in json.loads((root/'registry.json').read_text())['runs'] if x['id']==args[args.index('--run-id')+1])
            result={'result':{'cells':[{'result':'42','error':''}]} if run['state']=='succeeded' else None,'error':run.get('error','')}
        elif command=='prepare': result={}
        elif command=='upload_prepared': result={'revision':'r'}
        elif command=='receipt': result={'response':{'run_id':'accepted'}}
        elif command in ['run','invoke','configure_service','set_inputs','set_cell_inputs']:
            identity=args[args.index('--command-id')+1] if command=='run' else json.loads(pathlib.Path(args[args.index('--request-file')+1]).read_text())['command_id']
            commands.append(identity);(root/'commands.json').write_text(json.dumps(commands));result={'run_id':'accepted'}
        else: raise RuntimeError(command)
        if armed.startswith(command+':'):
            fault.unlink();result={'remote_error':{'status':int(armed.split(':')[1]),'message':'injected ambiguous reply'}}
        print(json.dumps(result))
        """#
        try Data(program.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let remote = NotebookRemoteController(executable: helper.path, storage: directory.appendingPathComponent("settings"))
        var server = NotebookServer(); server.ssh = false; server.url = "http://127.0.0.1:1"
        try remote.addServer(server, token: "test-token")
        var binding = NotebookRemoteBinding(project: "p", revision: "r"); binding.exported = "snapshot"; binding.saved = "disk"
        try NotebookRemoteController.write(try JSONEncoder().encode(NotebookRemoteDocument(selected: server.id, bindings: [server.id: binding])), to: book.appendingPathComponent(".sputnik/remote.json"))
        remote.exportSnapshot = { NotebookRemoteExport(current: "snapshot", disk: "disk") }
        func registry(_ runs: [[String: Any]]) throws {
            try JSONSerialization.data(withJSONObject: ["project": ["id": "p", "head": "r", "state": "active"], "runs": runs, "runtimes": [], "reset_epochs": []]).write(to: registryFile, options: .atomic)
        }
        func count() throws -> Int { (try JSONSerialization.jsonObject(with: Data(contentsOf: commandsFile)) as! [String]).count }
        func waitFor(_ predicate: () -> Bool) async throws {
            for _ in 0..<400 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            throw ModelTestFailure(description: "remote recovery fixture timed out: \(remote.status)")
        }
        try registry([]); remote.open(book)
        try await waitFor { remote.connected && !remote.busy }
        for (command, status) in [("run", 503), ("invoke", 502), ("configure_service", 504), ("set_inputs", 503), ("set_cell_inputs", 502)] {
            try Data("\(command):\(status)".utf8).write(to: faultFile)
            let succeeded: Bool
            if command == "set_inputs" || command == "set_cell_inputs" {
                succeeded = await withCheckedContinuation { c in remote.setCellInputs(sheet: "main", cell: command == "set_inputs" ? "project" : "1", values: ["gain": "2"]) { c.resume(returning: $0) } }
            } else {
                succeeded = await withCheckedContinuation { c in remote.run(sheet: "main", cell: "1", all: false, action: command == "run" ? nil : command == "configure_service" ? "periodic_run" : "action_run", board: command == "run" ? nil : "board", component: command == "run" ? nil : "act", operation: command == "configure_service" ? "once" : nil) { c.resume(returning: $0) } }
            }
            try require(!succeeded && remote.hasPending && !remote.connected, "\(command) keeps its ticket after \(status)")
            let accepted = try count()
            let blocked = await withCheckedContinuation { c in remote.run(sheet: "main", cell: "1", all: false) { c.resume(returning: $0) } }
            let afterBlocked = try count()
            try require(!blocked && afterBlocked == accepted, "unresolved command blocks another Run")
            try Data("receipt:503".utf8).write(to: faultFile); remote.reconnect()
            try await waitFor { !remote.busy }
            try require(remote.hasPending && !remote.connected, "ambiguous receipt lookup retains the original ticket")
            remote.reconnect(); try await waitFor { remote.connected && !remote.busy }
            let afterRecovery = try count()
            try require(!remote.hasPending && afterRecovery == accepted, "receipt recovers \(command) without resubmission")
        }
        try Data("run:422".utf8).write(to: faultFile)
        let rejected = await withCheckedContinuation { c in remote.run(sheet: "main", cell: "1", all: false) { c.resume(returning: $0) } }
        try require(!rejected && !remote.hasPending && remote.connected, "definitive validation rejection clears its ticket without disconnecting")

        let success: [String: Any] = ["id": "success", "revision": "r", "sheet_id": "owner", "epoch": "e", "state": "succeeded", "board": "board", "component": "act", "controller": "main", "action": "action_run", "has_presentation": true]
        try registry([success]); try await waitFor { remote.invocationResults["board:act"]?.ok == true }
        for state in ["interrupted", "force-stopped", "failed"] {
            var failure = success; failure["id"] = state; failure["state"] = state; failure["has_presentation"] = false; failure["error"] = "failure: " + state
            try registry([success, failure]); try await waitFor { remote.invocationResults["board:act"]?.error == "failure: " + state }
            try require(remote.invocationResults["board:act"]?.ok == false && remote.invocationResults["board:act"]?.result == "", "latest terminal failure supersedes old success without an artifact")
        }
        remote.detach()
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
        let renamed = await perform(model, "rename_sheet", text: "Обучение")
        try require(renamed && model.activeTab?.title == "Обучение" && model.activeTab?.id == "sheet:sheet_2", "sheet rename changes its display name without changing identity")
        _ = await perform(model, "rename_sheet", text: "Sheet 2")
        let reopened = await open(model, url: url)
        try require(reopened && model.nextSheetTitle == "Sheet 3" && model.nextSheetIdentifier == "sheet_3", "sheet numbering survives reopening")
        try require(NotebookBoard.empty(sheet: "sheet_2", existing: model.snapshot?.boards ?? []).title == "Board 8", "board numbering spans controller sheets and skips existing numbered titles")
        let moduleCreated = await perform(model, "new_module", text: "training")
        try require(moduleCreated, model.error ?? "create rename fixture")
        let module = model.activeTab!, cell = module.cells[0]
        model.editSource("package training\n# unsaved source\n", cell: cell, tab: module)
        let moduleRenamed = await perform(model, "rename_module", tab: module, text: "digit-recognizer")
        try require(moduleRenamed && model.activeTab?.id == "module:digit_recognizer" &&
                    model.activeTab?.cells[0].id == cell.id && !model.hasUnsavedChanges,
                    model.error ?? "module rename keeps selection and consumes the submitted draft")
        let renamedSource = try String(contentsOf: url.appendingPathComponent("modules/digit_recognizer.s"), encoding: .utf8)
        try require(renamedSource == "package digit_recognizer\n# unsaved source\n" &&
                    !FileManager.default.fileExists(atPath: url.appendingPathComponent("modules/training.s").path),
                    "module rename saves the draft under its matching filename")
    }

    @MainActor
    private static func testBookFiles(_ model: NotebookModel, root: URL) async throws {
        let book = root.appendingPathComponent("files.sputnikbook")
        let opened = await open(model, url: book, create: true)
        try require(opened, "open book files fixture")
        model.createMarkdown("Описание")
        let path = "docs/Описание.md", source = "# Набор данных\n\nПервая версия.\n"
        try require(model.bookPage == .markdown(path) && model.markdownPaths == [path], "new Markdown is discoverable")
        model.editMarkdown(path, source: source)
        try require(model.hasUnsavedChanges, "Markdown participates in unsaved changes")
        let saved = await perform(model, "save")
        try require(saved && !model.hasUnsavedChanges, "Save Current Tab commits Markdown")
        let files = model.bookFiles!
        let contents = try files.readMarkdown(path)
        try require(contents == source, "Markdown round trips as UTF-8")

        let dataset = root.appendingPathComponent("Dataset")
        let nested = dataset.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let bytes = Data([0, 255, 41])
        try bytes.write(to: nested.appendingPathComponent("data.bin"))
        try files.importItem(dataset, into: "resources")
        try files.move("resources/Dataset", to: "resources/Measurements")
        let imported = try Data(contentsOf: files.url("resources/Measurements/nested/data.bin"))
        try require(imported == bytes && FileManager.default.fileExists(atPath: nested.path), "folder import copies nested binary files")
        let link = book.appendingPathComponent("resources/unsafe")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dataset)
        try require((try? files.url("resources/unsafe/nested/data.bin")) == nil, "attachment paths cannot cross symlinks")
        let reopened = await open(model, url: book)
        model.selectBookPage(.markdown(path))
        try require(reopened && model.markdownDrafts[path]?.source == source, "saved Markdown reopens with the book")
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
    private static func testEnvironmentTiming(root: URL) async throws {
        let model = NotebookModel()
        let url = root.appendingPathComponent("environment-timing.sputnikbook")
        try writeProject(url, title: "Environment timing", cellIDs: ["671"])
        let manifest = url.appendingPathComponent("project.json")
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        document["version"] = 3
        document["inputs"] = []
        document["dependencies"] = []
        document["boards"] = [["id": "history", "title": "History", "sheet": "main", "columns": 1,
                               "components": [["id": "history", "kind": "run_history", "title": "Runs"]]]]
        document["modules"] = [["id": "helpers", "path": "helpers.s"]]
        document["auto_imports"] = ["helpers"]
        try JSONSerialization.data(withJSONObject: document).write(to: manifest)
        try "package helpers\nexport answer\ndef answer(): 42\ntask.sleep(150)\n".write(to: url.appendingPathComponent("helpers.s"), atomically: true, encoding: .utf8)
        do {
            let opened = await open(model, url: url)
            try require(opened, "open environment timing fixture")
            var tab = model.snapshot!.tabs.first { $0.kind == "sheet" }!
            model.editSource("answer()\n", cell: tab.cells[0], tab: tab)
            let first = await perform(model, "run", tab: tab, cell: tab.cells[0])
            tab = model.snapshot!.tabs.first { $0.kind == "sheet" }!
            guard first, tab.cells[0].ok, let timing = model.cellTiming(tab.cells[0], in: tab) else {
                throw ModelTestFailure(description: "no environment timing: \(model.error ?? "") \(tab.environment_error) \(tab.cells[0].error)")
            }
            try require((timing.environmentRebuildMilliseconds ?? 0) >= 140 && timing.help.contains("Preparation:") && timing.help.contains("excluded"), "rebuilt run explains preparation separately from execution")
            guard let run = model.runHistory.runs.first else {
                throw ModelTestFailure(description: model.runHistory.error ?? "no retained environment timing run")
            }
            let saved = try model.runHistory.load(run.id)
            try require(saved.outputs.first?.environmentRebuildMilliseconds == timing.environmentRebuildMilliseconds, "run history retains rebuild context")
            let second = await perform(model, "run", tab: tab, cell: tab.cells[0])
            tab = model.snapshot!.tabs.first { $0.kind == "sheet" }!
            let warm = model.cellTiming(tab.cells[0], in: tab)
            try require(second && warm?.environmentRebuildMilliseconds == nil && warm?.help.contains("rebuilt") == false,
                        "warm run removes the previous rebuild badge")
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
        model.editSource("package scratch\nvalue = )\n", cell: moduleCell, tab: module)
        _ = await perform(model, "run", tab: module, cell: moduleCell)
        let failedModule = try requireTab("module:scratch", in: requireSnapshot(model))
        let failedCell = try requireCell(moduleCell.id, in: failedModule)
        try require(failedCell.error_ranges?.contains { $0.start_line == 1 && $0.start_column == 8 } == true,
                    "module diagnostics should publish source ranges in snapshots")
        guard let diagnostic = failedCell.diagnostics?.first(where: { $0.range != nil }) else {
            throw ModelTestFailure(description: "source diagnostic missing")
        }
        model.showSource(diagnostic.range!, cell: failedCell, tab: failedModule)
        try require(model.cellNavigation?.selection?.range == diagnostic.range,
                    "source errors should request navigation to their own range")
        let moduleSource = "package scratch\nvalue = 7\n"
        model.editSource(moduleSource, cell: moduleCell, tab: module)
        let previousNavigation = model.cellNavigation
        model.showSource(diagnostic.range!, cell: failedCell, tab: failedModule)
        try require(model.cellNavigation == previousNavigation, "stale diagnostic must not navigate into an edited source")
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
        let libraryBeforeFailedOpen = model.library.projects
        let overwroteProject = await open(model, url: first, create: true)
        try require(!overwroteProject,
                    "creating over the existing project should fail")
        try require(model.library.projects == libraryBeforeFailedOpen,
                    "a failed open must not change library membership or recency")
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
            try require(model.library.sortedProjects.first?.path == project.standardizedFileURL.resolvingSymlinksInPath().path &&
                        model.library.sortedProjects.first?.lastOpened != nil,
                        "successful opens must update library recency")
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
    private static func testCompileOnlyModuleCheck(root: URL) async throws {
        let url = root.appendingPathComponent("module-check.sputnikbook")
        try writeProject(url, title: "Compile only module check", cellIDs: ["741"])
        let package = url.appendingPathComponent("native")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try "schema: \"sputnik.build.v1\"\nname: native_check\nversion: \"1.0.0\"\nsource_root: \".\"\nroot: native_check\nfiles: [main.s]\nmodule_names: {main.s: native_check}\nprofiles: {required: [core.v1, ffi.v1]}\n"
            .write(to: package.appendingPathComponent("sputnik.build.yaml"), atomically: true, encoding: .utf8)
        try "package native_check\nexport answer\nnative def answer() -> Int from \"unregistered_native_thunk\"\nraise \"dependency must not execute\"\n"
            .write(to: package.appendingPathComponent("main.s"), atomically: true, encoding: .utf8)
        let manifest = url.appendingPathComponent("project.json")
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        document["version"] = 3; document["inputs"] = []; document["boards"] = []
        document["modules"] = [["id": "checked", "path": "checked.s"], ["id": "unfinished", "path": "unfinished.s"]]
        document["auto_imports"] = ["unfinished"]
        document["dependencies"] = [["path": "native", "auto_import": false, "native_library": "not-loaded.dylib", "native_sha256": String(repeating: "0", count: 64)]]
        try JSONSerialization.data(withJSONObject: document).write(to: manifest)
        try "package checked\n42\n".write(to: url.appendingPathComponent("checked.s"), atomically: true, encoding: .utf8)
        try "package unfinished\nvalue = )\n".write(to: url.appendingPathComponent("unfinished.s"), atomically: true, encoding: .utf8)
        let marker = url.appendingPathComponent("must-not-exist")
        let model = NotebookModel()
        do {
            let opened = await open(model, url: url)
            try require(opened && model.snapshot?.dependencies?.first?.native == true, "open native module check fixture: \(model.error ?? "")")
            let module = model.snapshot!.tabs.first { $0.id == "module:checked" }!
            let cell = module.cells[0]
            let historyCount = model.runHistory.runs.count
            let source = "package checked\nfrom native_check import answer\nimport fs\nfs.atomic_write_text(\"\(marker.path)\", \"executed\")\nanswer()\nraise \"module must not execute\"\n"
            model.editSource(source, cell: cell, tab: module)
            try require(model.canCheckModule(module), "checking does not depend on runtime grants")
            let completed = await perform(model, "check_module", tab: module, cell: cell)
            let checked = model.snapshot!.tabs.first { $0.id == module.id }!
            try require(completed && checked.cells[0].ok && checked.status == "module check passed; code not executed",
                        "native imports compile without loading libraries or running init: \(model.error ?? checked.cells[0].error)")
            try require(!model.hasNativeWorkerTrust && !model.executingWorker && model.runHistory.runs.count == historyCount,
                        "checking requests no native trust and creates no execution or run history")
            try require(!FileManager.default.fileExists(atPath: marker.path) && checked.cells[0].elapsed_ms == nil && checked.cells[0].output.isEmpty && checked.cells[0].result.isEmpty,
                        "checks publish no runtime side effects, output, timings or results")
            let savedSource = try String(contentsOf: url.appendingPathComponent("checked.s"), encoding: .utf8)
            try require(savedSource == "package checked\n42\n",
                        "checking an unsaved draft does not save it")
            model.editSource("package checked\nfrom native_check import missing\n", cell: checked.cells[0], tab: checked)
            _ = await perform(model, "check_module", tab: checked, cell: checked.cells[0])
            let failed = model.snapshot!.tabs.first { $0.id == module.id }!
            try require(!failed.cells[0].ok && failed.cells[0].error.contains("Cannot import 'missing'") && failed.cells[0].error_ranges?.first?.start_line == 1,
                        "checks validate native exports and retain source coordinates")
            await shutdown(model)
        } catch { await shutdown(model); throw error }
    }

    @MainActor
    private static func testImportDiagnostics(root: URL) async throws {
        let url = root.appendingPathComponent("import-diagnostics.sputnikbook")
        try writeProject(url, title: "Import diagnostics", cellIDs: ["721"])
        let manifest = url.appendingPathComponent("project.json")
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        document["modules"] = [["id": "training", "path": "training.s"]]
        document["auto_imports"] = ["training"]
        try JSONSerialization.data(withJSONObject: document).write(to: manifest)
        try "package training\n# Header\nfrom notebook.ui import unavailable_function\n"
            .write(to: url.appendingPathComponent("training.s"), atomically: true, encoding: .utf8)
        let model = NotebookModel()
        do {
            let opened = await open(model, url: url)
            try require(opened, "open import diagnostic fixture")
            _ = await perform(model, "run_all")
            let sheet = model.snapshot!.tabs.first { $0.kind == "sheet" }!
            try require(sheet.environment_error.contains("Cannot import 'unavailable_function' from 'notebook.ui'") &&
                        sheet.environment_error.contains("training.s:3:"), "import failure must identify its source line")
            guard let target = model.environmentErrorSource(in: sheet) else {
                throw ModelTestFailure(description: "import failure must link to the module's source")
            }
            try require(target.tab.id == "module:training" && target.range.start_line == 2,
                        "import failure selected the wrong module or line")
            model.showSource(target.range, cell: target.cell, tab: target.tab)
            let deadline = Date().addingTimeInterval(5)
            while model.cellNavigation?.location.tab != target.tab.id && Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try require(model.activeTab?.id == target.tab.id && model.cellNavigation?.selection?.range.start_line == 2,
                        "import error link must open the module and select line 3")
            model.editSource("package training\n42\n", cell: target.cell, tab: target.tab)
            try require(model.environmentErrorSource(in: sheet) == nil,
                        "an import error must not navigate into a modified module draft")
            await shutdown(model)
        } catch { await shutdown(model); throw error }
    }

    @MainActor
    private static func testModuleErrorsFromBoards(root: URL) async throws {
        let fixtures: [(String, String, String, Int)] = [
            ("syntax", "package training\n# Header\ndef answer(:\n", "42\n", 2),
            ("init", "package training\n# Header\nraise \"module init failed\"\n", "42\n", 2),
            ("call", "package training\nexport answer\ndef answer():\n  raise \"module call failed\"\n", "answer()\n", 3)
        ]
        for (name, source, sheetSource, line) in fixtures {
            let url = root.appendingPathComponent("board-module-error-\(name).sputnikbook")
            try writeProject(url, title: "Board module error", cellIDs: ["731"])
            let manifest = url.appendingPathComponent("project.json")
            var document = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
            document["version"] = 3
            document["inputs"] = []
            document["dependencies"] = []
            document["modules"] = [["id": "training", "path": "training.s"]]
            document["auto_imports"] = ["training"]
            document["boards"] = [["id": "dashboard", "title": "Dashboard", "sheet": "main", "columns": 1, "components": []]]
            try JSONSerialization.data(withJSONObject: document).write(to: manifest)
            try source.write(to: url.appendingPathComponent("training.s"), atomically: true, encoding: .utf8)
            let model = NotebookModel()
            do {
                let opened = await open(model, url: url)
                try require(opened && model.isolatedExecution, "open \(name) diagnostic fixture with a real worker: \(model.error ?? "no error")")
                let controller = model.activeTab!
                model.editSource(sheetSource, cell: controller.cells[0], tab: controller)
                model.selectBoard(model.snapshot!.boards![0])
                _ = await perform(model, "run_all", tab: controller)
                let sheet = model.snapshot!.tabs.first { $0.id == controller.id }!
                let module = model.snapshot!.tabs.first { $0.id == "module:training" }!
                let issues = model.executionIssues(in: sheet)
                try require(model.activeBoard != nil && !issues.isEmpty, "\(name): failed Run Sheet remains visible on the board")
                guard let issue = issues.first(where: { $0.location?.tab == module.id }),
                      let range = issue.range else {
                    throw ModelTestFailure(description: "\(name): failure has no module source target: \(sheet.environment_error), \(sheet.cells[0].error), \(sheet.module_errors?.map(\.message) ?? [])")
                }
                try require(range.start_line == line, "\(name): wrong module source line \(range.start_line)")
                let diagnostics = model.sourceDiagnostics(for: module.cells[0], in: module)
                try require(diagnostics.contains { $0.range?.start_line == line }, "\(name): module page shows the sheet's error and highlights its source")
                model.showExecutionIssue(issue)
                let deadline = Date().addingTimeInterval(5)
                while (model.activeBoard != nil || model.cellNavigation?.selection?.range != range) && Date() < deadline {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                try require(model.activeBoard == nil && model.activeTab?.id == module.id && model.cellNavigation?.selection?.range == range,
                            "\(name): board error opens the module and requests its source line")
                let corrected = "package training\nexport answer\ndef answer():\n  42\n"
                model.editSource(corrected, cell: module.cells[0], tab: module)
                try require(model.sourceDiagnostics(for: module.cells[0], in: module).isEmpty && model.environmentErrorSource(in: sheet) == nil,
                            "\(name): stale errors never decorate or navigate into a new module draft")
                let saved = await perform(model, "save_all")
                try require(saved, "save corrected module")
                _ = await perform(model, "apply", tab: sheet)
                let fixedSheet = model.snapshot!.tabs.first { $0.id == sheet.id }!
                let fixedModule = model.snapshot!.tabs.first { $0.id == module.id }!
                try require(model.executionIssues(in: fixedSheet).isEmpty && model.sourceDiagnostics(for: fixedModule.cells[0], in: fixedModule).isEmpty,
                            "\(name): successful Apply clears errors on both pages")
                await shutdown(model)
            } catch { await shutdown(model); throw error }
        }
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

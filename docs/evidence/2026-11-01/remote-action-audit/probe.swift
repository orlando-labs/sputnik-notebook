import AppKit
import Foundation

// Audit reproduction against the real desktop model and a disposable Core.
// No production code or normal test suite is changed by this probe.
@main private enum RemoteActionAudit {
    struct Failure: Error { let message: String }
    static func option(_ key: String) -> String {
        CommandLine.arguments[CommandLine.arguments.firstIndex(of: key)! + 1]
    }
    @MainActor static func wait(_ label: String, _ condition: () -> Bool) async throws {
        for _ in 0..<1200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw Failure(message: "timeout: " + label)
    }
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    @MainActor static func perform(_ model: NotebookModel, _ action: String, text: String = "", component: String? = nil) async throws {
        let success = await withCheckedContinuation { c in
            model.perform(action, text: text, commandCellID: component) { c.resume(returning: $0) }
        }
        try check(success, model.error ?? ("failed: " + action))
    }
    @MainActor static func idle(_ model: NotebookModel) async throws {
        try await wait("idle: " + (model.error ?? "")) { !model.busy && !model.remote.busy && !model.remote.active }
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: option("--root"))
        let project = root.appendingPathComponent("Audit.sputnikbook")
        let model = NotebookModel(workerExecutable: option("--worker"), remoteExecutable: option("--core"), remoteStorage: root.appendingPathComponent("settings"))
        var observations: [[String: Any]] = []
        do {
            try FileManager.default.createDirectory(at: project.appendingPathComponent("modules"), withIntermediateDirectories: true)
            let document = #"""
            {"format":"sputnik-notebook","version":4,"title":"Remote action audit","active_sheet":"main",
             "sheets":[{"id":"main","title":"Main","cells":[{"id":"1","kind":"code","mode":"manual","source":"notebook.read_image(\"gallery\")[:caption]\n"}]}],
             "modules":[{"id":"jobs","path":"modules/jobs.s"}],"auto_imports":[],"inputs":[],"dependencies":[],
             "boards":[{"id":"board","title":"Audit","sheet":"main","columns":1,"components":[
              {"id":"counter","kind":"action","title":"Counter","module_id":"jobs","function":"next"},
              {"id":"a","kind":"action","title":"A","module_id":"jobs","function":"slow"},
              {"id":"b","kind":"action","title":"B","module_id":"jobs","function":"slow"},
              {"id":"history","kind":"run_history","title":"History","cell":"1"},
              {"id":"gallery","kind":"image_carousel","title":"Gallery","image_id":"gallery","image_allow_load":true,"image_allow_read":true}]}]}
            """#
            try Data(document.utf8).write(to: project.appendingPathComponent("project.json"))
            try Data("package jobs\nimport task\nclass Counter:\n  def init(): @n = 0\n  def next():\n    @n += 1\n    @n\nState = Counter()\ndef next(): State.next()\ndef slow():\n  task.sleep(20000)\n  42\nexport next, slow\n".utf8).write(to: project.appendingPathComponent("modules/jobs.s"))
            let opened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
            try check(opened, model.error ?? "open")
            var server = NotebookServer(); server.name = "Disposable audit"; server.ssh = false; server.url = option("--url")
            let token = try String(contentsOfFile: option("--token")).trimmingCharacters(in: .whitespacesAndNewlines)
            try model.remote.addServer(server, token: token); model.remote.choose(server.id)
            try await wait("connect") { model.remote.connected && !model.remote.busy }

            try await perform(model, "action_run", text: "board", component: "counter")
            try await wait("first counter") { model.invocationResult("board:counter")?.result == "1" && !model.remote.active }
            let first = model.remote.runs.last { $0.component == "counter" }!
            try await perform(model, "periodic_dispose", text: "board", component: "counter")
            try await idle(model)
            try await perform(model, "action_run", text: "board", component: "counter")
            try await wait("second counter") { model.invocationResult("board:counter")?.result == "2" && !model.remote.active }
            let second = model.remote.runs.last { $0.component == "counter" }!
            observations.append(["case": "invocation_restart", "command_reported_success": true,
                "before": "1", "after": "2", "epoch_unchanged": first.epoch == second.epoch])
            print("REPRO invocation_restart: success, counter 1 -> 2, same epoch \(first.epoch == second.epoch)")

            // Explicit image editing is synchronized; plain carousel selection
            // only updates the desktop Session, not the uploaded document.
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
            let panels = ["First", "Second"].map { NotebookFigurePanel(mime: "image/png", caption: $0, width: 1, height: 1, data: png) }
            let board = model.snapshot!.boards!.first!, gallery = board.components.first { $0.id == "gallery" }!
            let edited = await withCheckedContinuation { c in
                model.editImages(panels, caption: "Audit", selected: 0, board: board, component: gallery) { c.resume(returning: $0) }
            }
            try check(edited, model.error ?? "image edit")
            try await idle(model)
            try await perform(model, "run_all")
            try await wait("initial image result") { !model.remote.active && model.activeTab?.cells.first?.result == "\"First\"" }
            try await perform(model, "image_select", text: "1", component: "gallery")
            let localSelection = model.imageSelection("gallery", in: model.activeTab!)
            try await idle(model)
            try await perform(model, "run_all")
            try await wait("selected image result") { !model.remote.active && model.remote.runs.last?.state == "succeeded" }
            let selectedResult = model.activeTab!.cells.first!.result
            observations.append(["case": "carousel_selection", "desktop_selected": localSelection, "server_result": selectedResult])
            print("REPRO carousel_selection: desktop index \(localSelection), server reads \(selectedResult)")

            try await wait("local history") { !model.runHistory.runs.isEmpty }
            let historyID = model.runHistory.runs.first!.id
            model.runHistory.remove(historyID)
            try check(!model.runHistory.runs.contains { $0.id == historyID }, "local history delete")
            model.remote.reconnect()
            try await wait("deleted history reappears") {
                model.remote.connected && !model.remote.busy && model.runHistory.runs.contains { $0.id == historyID }
            }
            observations.append(["case": "history_delete", "deleted_locally": true, "reappeared_after_reconnect": true])
            print("REPRO history_delete: deleted local record reappears after reconnect")

            try await perform(model, "action_run", text: "board", component: "a")
            try await wait("A running") { model.remote.runs.contains { $0.component == "a" && $0.active } }
            try await perform(model, "action_run", text: "board", component: "b")
            try await wait("A and B running") {
                model.remote.runs.filter { ["a", "b"].contains($0.component ?? "") && $0.active }.count == 2
            }
            // Both action controls call this same parameterless stop method.
            // No selected target is passed through to Remote.stop.
            model.stopExecution()
            try await wait("one action cancelled") { model.remote.runs.contains { $0.component == "b" && $0.state == "cancelled" } }
            let aActive = model.remote.runs.contains { $0.component == "a" && $0.active }
            observations.append(["case": "targeted_stop", "a_still_active": aActive, "b_state": "cancelled", "selected_target": model.executingTargetID ?? ""])
            print("REPRO targeted_stop: A active \(aActive), B cancelled, desktop target \(model.executingTargetID ?? "none")")
            model.stopExecution(force: true)
            try await idle(model)
            try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("observations.json"))
            await withCheckedContinuation { c in model.shutdown { c.resume() } }
            print("PASS audit reproductions completed")
        } catch {
            print("AUDIT PROBE FAILED: \(error)"); print("Model error: \(model.error ?? "none")"); print("History error: \(model.runHistory.error ?? "none")")
            print("Runs: \(model.remote.runs.map { "\($0.component ?? $0.sheet):\($0.state)" })")
            await withCheckedContinuation { c in model.shutdown { c.resume() } }
            exit(1)
        }
    }
}

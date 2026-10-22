import AppKit
import Foundation
import SwiftUI

private struct RemoteTestError: Error { let message: String }
private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw RemoteTestError(message: message) }
}
@main private enum RemoteUITests {
    private static func option(_ key: String) -> String {
        CommandLine.arguments[CommandLine.arguments.firstIndex(of: key)! + 1]
    }
    @MainActor private static func wait(_ message: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<800 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw RemoteTestError(message: "timeout: " + message)
    }
    @MainActor private static func open(_ model: NotebookModel, _ url: URL) async throws {
        let ok = await withCheckedContinuation { continuation in model.open(url: url) { continuation.resume(returning: $0) } }
        try check(ok, model.error ?? "open failed")
    }
    @MainActor private static func perform(_ model: NotebookModel, _ action: String, tab: NotebookTab? = nil) async throws {
        let ok = await withCheckedContinuation { continuation in model.perform(action, tab: tab) { continuation.resume(returning: $0) } }
        try check(ok, model.error ?? "perform failed: " + action)
    }
    @MainActor private static func close(_ model: NotebookModel) async {
        await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
    }
    @MainActor private static func edit(_ model: NotebookModel, _ source: String) throws {
        guard let tab = model.activeTab, let cell = tab.cells.first else { throw RemoteTestError(message: "missing cell") }
        model.editSource(source, cell: cell, tab: tab)
    }
    @MainActor private static func result(_ model: NotebookModel) -> String? { model.activeTab?.cells.first?.result }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: option("--root")), core = option("--core"), worker = option("--worker")
        let project = root.appendingPathComponent("Client.sputnikbook"), settings = root.appendingPathComponent("gui-settings")
        var active: NotebookModel?
        do {
            try FileManager.default.createDirectory(at: project.appendingPathComponent("modules"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project.appendingPathComponent("assets/deep"), withIntermediateDirectories: true)
            let manifest = #"{"format":"sputnik-notebook","version":2,"title":"Remote GUI","active_sheet":"main","sheets":[{"id":"main","title":"Main","cells":[{"id":"1","kind":"code","mode":"manual","source":"answer()\n"}]},{"id":"other","title":"Other","cells":[{"id":"2","kind":"code","mode":"manual","source":"0\n"}]}],"modules":[{"id":"helpers","path":"modules/helpers.s"}],"auto_imports":["helpers"],"inputs":[],"boards":[{"id":"dashboard","title":"Dashboard","sheet":"main","columns":1,"components":[{"id":"timer","kind":"stopwatch","title":"Remote Stopwatch","stopwatch_id":"remote"}]}],"future":{"integer":9007199254740995}}"#
            try Data(manifest.utf8).write(to: project.appendingPathComponent("project.json"))
            try Data("package helpers\ndef answer(): 42\nexport answer\n".utf8).write(to: project.appendingPathComponent("modules/helpers.s"))
            try Data([0, 1, 128, 255]).write(to: project.appendingPathComponent("assets/deep/data.bin"))
            let model = NotebookModel(workerExecutable: worker, remoteExecutable: core, remoteStorage: settings)
            active = model; try await open(model, project)
            try check(result(model) == "not evaluated", "opening is inert")
            let ssh = CommandLine.arguments.contains("--ssh-live")
            var server = NotebookServer(); server.name = ssh ? "Orlando GPU" : "Test GPU"; server.ssh = ssh
            if !ssh { server.url = option("--url") }
            let secret = ssh ? "" : try String(contentsOfFile: option("--token")).trimmingCharacters(in: .whitespacesAndNewlines)
            try model.remote.addServer(server, token: secret)
            model.remote.choose(server.id)
            try await wait("initial connection: \(model.error ?? "")") { model.remote.connected && !model.remote.busy && model.remote.projectID != nil }
            try check(!model.remote.conflict && model.error == nil, model.error ?? "unexpected conflict")
            try check(result(model) == "not evaluated", "connecting never evaluates cells")
            try await perform(model, "run")
            try await wait("first remote result: \(model.error ?? "")") { result(model) == "42" }
            try check(!model.busy && model.remote.runtimes.contains { $0["state"] as? String == "idle" }, "remote heap remains idle")
            let originalEpoch = model.remote.runs.last!.epoch
            let remoteProject = model.remote.projectID!
            print("PASS server selection, snapshot upload and native presentation")
            if ssh {
                try edit(model, "import task\nnotebook.progress(\"ssh\", 1, 2, \"GPU server\", false)\ntask.sleep(6000)\nanswer()\n")
                try await perform(model, "run")
                try await wait("SSH live output") { !model.liveCells.isEmpty }
                let id = model.remote.runs.last!.id
                await close(model); active = nil
                let reconnected = NotebookModel(workerExecutable: worker, remoteExecutable: core, remoteStorage: settings)
                active = reconnected; try await open(reconnected, project)
                try await wait("new SSH tunnel and original Run") { reconnected.remote.connected && !reconnected.remote.busy && reconnected.remote.runs.contains { $0.id == id } }
                try await wait("SSH result") { result(reconnected) == "42" }
                try check(reconnected.remote.runs.last?.id == id && reconnected.remote.runs.last?.epoch == originalEpoch, "real server preserved Run and epoch across SSH client closure")
                try await render(reconnected, to: root.appendingPathComponent("remote-ui.png"))
                let proof = ["project_id": remoteProject, "run_id": id, "runtime_epoch": originalEpoch, "result": "42", "server": server.host]
                let data = try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys, .prettyPrinted])
                try data.write(to: root.appendingPathComponent("ssh-result.json"))
                print(String(decoding: data, as: UTF8.self))
                await close(reconnected); active = nil
                print("PASS real SSH server selection, Run, client closure and state recovery")
                return
            }

            // The submitted draft differs from disk. Closing the client must
            // keep both the remote execution and the recoverable source buffer.
            try edit(model, "from notebook.ui import Stopwatch\nimport task\nnotebook.progress(\"load\", 1, 2, \"Working\", false)\nStopwatch.measure(\"remote\"):\n  task.sleep(4500)\n  answer() + 1\n")
            try await perform(model, "run")
            try await wait("running phase") { model.remote.active && model.canStop }
            try check(model.canEdit && !model.busy, "editing and closing remain available during remote execution")
            try await wait("remote live progress") { !model.liveCells.isEmpty }
            try await wait("remote live stopwatch") { model.stopwatches(in: model.activeTab!, channel: "remote").running }
            let timingTab = model.activeTab!
            let firstTick = model.stopwatches(in: timingTab, channel: "remote").items.first!.elapsed_ms
            let cellTick = model.cellTiming(timingTab.cells[0], in: timingTab)!.milliseconds
            try await Task.sleep(nanoseconds: 160_000_000)
            try check(model.stopwatches(in: timingTab, channel: "remote").items.first!.elapsed_ms > firstTick &&
                      model.cellTiming(timingTab.cells[0], in: timingTab)!.milliseconds > cellTick,
                      "remote cell and block timers tick during silent work")
            try await render(model, to: root.appendingPathComponent("stopwatch-sheet.png"))
            let runID = model.remote.runs.last!.id
            try await close(model); active = nil
            let observer = NotebookRemoteClient(executable: core, token: URL(fileURLWithPath: option("--token")))
            observer.endpoint = option("--url")
            let still = try await observer.call(["--command", "status", "--run-id", runID])
            try check(["preparing", "running", "draining"].contains(still["state"] as? String ?? ""), "closing the client did not cancel the Run")
            let resumed = NotebookModel(workerExecutable: worker, remoteExecutable: core, remoteStorage: settings)
            active = resumed; try await open(resumed, project)
            try await wait("reattach after close: \(resumed.error ?? "")") { resumed.remote.connected && !resumed.remote.busy && resumed.remote.runs.contains { $0.id == runID } }
            try check(resumed.activeTab?.cells.first?.source.contains("task.sleep(4500)") == true && resumed.hasUnsavedChanges,
                      "accepted unsaved source is restored without overwriting the saved file")
            resumed.selectBoard(resumed.snapshot!.boards!.first!)
            try await render(resumed, to: root.appendingPathComponent("stopwatch-board.png"))
            resumed.selectTab(resumed.snapshot!.tabs.first { $0.id == "sheet:main" }!)
            try await wait("reattached terminal presentation: \(resumed.error ?? "")") { result(resumed) == "43" }
            let timed = resumed.activeTab!
            let finishedTimer = resumed.stopwatches(in: timed, channel: "remote")
            try check(finishedTimer.items.first?.done == true && (finishedTimer.items.first?.elapsed_ms ?? 0) >= 4400 &&
                      (timed.cells[0].elapsed_ms ?? 0) >= 4400 && !finishedTimer.running,
                      "remote reconnect retains completed cell and block durations")
            try check(resumed.remote.runs.last?.id == runID && resumed.remote.runs.last?.epoch == originalEpoch,
                      "reconnect restores the same Run and heap, without replay")
            try check(try String(contentsOf: project.appendingPathComponent("project.json")) == manifest, "saved document stays unchanged")
            print("PASS close/reopen during Run, draft recovery, live progress, same runtime epoch")

            // A newer edit made during a Run must survive terminal publication.
            try edit(resumed, "import task\ntask.sleep(1500)\n44\n")
            try await perform(resumed, "run")
            try check(resumed.presentation(for: resumed.activeTab!.cells[0], in: resumed.activeTab!).result?.previous == true,
                      "remote rerun labels and retains its previous result")
            try edit(resumed, "99\n")
            try await wait("result for older source") { result(resumed) == "44" }
            let tab = resumed.activeTab!, cell = tab.cells.first!
            try check(resumed.source(for: cell, in: tab) == "99\n", "remote result cannot overwrite newer source")
            try check(resumed.figureIsStale(for: cell, in: tab), "older result is marked stale")
            try check(resumed.presentation(for: cell, in: tab).result?.text == "44" && resumed.presentation(for: cell, in: tab).result?.previous == true,
                      "a remote result for older source remains inspectable as a previous run")
            try await render(resumed, to: root.appendingPathComponent("retained-result.png"))
            print("PASS draft preservation across terminal publication")

            // Restore another client solely from the server-side document,
            // including modules, boards, resources and the latest presentation.
            let replica = root.appendingPathComponent("Downloaded.sputnikbook")
            let serverProject = try await observer.call(["--command", "project", "--project", remoteProject])
            let revision = serverProject["head"] as! String
            let downloaded = await withCheckedContinuation { continuation in
                resumed.remote.download(project: remoteProject, revision: revision, to: replica) { continuation.resume(returning: $0) }
            }
            try check(downloaded, resumed.error ?? "download failed")
            try check(try Data(contentsOf: replica.appendingPathComponent("assets/deep/data.bin")) == Data([0, 1, 128, 255]), "binary resources roundtrip")
            await close(resumed); active = nil
            let replicaModel = NotebookModel(workerExecutable: worker, remoteExecutable: core, remoteStorage: settings)
            active = replicaModel; try await open(replicaModel, replica)
            try await wait("downloaded project reattach: \(replicaModel.error ?? "")") { replicaModel.remote.connected && !replicaModel.remote.busy && result(replicaModel) == "44" }
            try check(replicaModel.snapshot?.boards?.first?.id == "dashboard" && replicaModel.snapshot?.tabs.contains { $0.id == "module:helpers" } == true,
                      "server copy restores modules and boards")
            print("PASS server-copy reconstruction and historical presentation")

            try edit(replicaModel, "from notebook.ui import Stopwatch\nStopwatch.measure(\"cancel\"):\n  while true:\n    x = 1\n")
            try await perform(replicaModel, "run")
            try await wait("force stop availability") { replicaModel.canForceStop && replicaModel.stopwatches(in: replicaModel.activeTab!, channel: "cancel").running }
            replicaModel.stopExecution(force: true)
            try await wait("force stop result") { replicaModel.remote.runs.last?.state == "force-stopped" }
            let stoppedTab = replicaModel.activeTab!
            let stoppedTimer = replicaModel.stopwatches(in: stoppedTab, channel: "cancel").items.first?.elapsed_ms
            try await Task.sleep(nanoseconds: 160_000_000)
            try check(stoppedTimer != nil && !replicaModel.stopwatches(in: stoppedTab, channel: "cancel").running &&
                      replicaModel.stopwatches(in: stoppedTab, channel: "cancel").items.first?.elapsed_ms == stoppedTimer,
                      "remote Force Stop freezes the last live stopwatch")
            replicaModel.remote.restart(sheet: "main")
            try await wait("explicit runtime restart") { !replicaModel.remote.busy }
            try check(replicaModel.presentation(for: replicaModel.activeTab!.cells[0], in: replicaModel.activeTab!).result == nil,
                      "remote restart clears retained results")
            replicaModel.remote.reconnect()
            try await wait("reconnect after runtime reset") { replicaModel.remote.connected && !replicaModel.remote.busy }
            try check(replicaModel.presentation(for: replicaModel.activeTab!.cells[0], in: replicaModel.activeTab!).result == nil,
                      "reconnect cannot restore a presentation from an explicitly reset epoch")
            try edit(replicaModel, "45\n")
            try await perform(replicaModel, "run")
            try await wait("new epoch result") { result(replicaModel) == "45" }
            try check(replicaModel.remote.runs.last?.epoch != originalEpoch, "explicit restart creates a new epoch")
            print("PASS Force Stop and explicit runtime restart")

            let other = replicaModel.snapshot!.tabs.first { $0.id == "sheet:other" }!
            replicaModel.selectTab(other)
            try await wait("select concurrent sheet") { replicaModel.activeTab?.id == other.id && !replicaModel.busy }
            try edit(replicaModel, "import task\nnotebook.progress(\"other\", 1, 2, \"Other sheet\", false)\ntask.sleep(5000)\n70\n")
            try await perform(replicaModel, "run")
            let otherRun = replicaModel.remote.runs.last!.id
            let main = replicaModel.snapshot!.tabs.first { $0.id == "sheet:main" }!
            replicaModel.selectTab(main)
            try await wait("select main sheet") { replicaModel.activeTab?.id == main.id && !replicaModel.busy }
            try edit(replicaModel, "import task\nnotebook.progress(\"main\", 1, 2, \"Main sheet\", false)\ntask.sleep(4000)\n71\n")
            try await perform(replicaModel, "run")
            try check(replicaModel.remote.runs.filter { $0.active }.count == 2, "two sheets execute independently")
            try await wait("focused live progress") { replicaModel.liveCells.values.contains { $0.progress.contains { $0.id == "main" } } }
            try await wait("execution markers on both sheets") {
                replicaModel.executingCells[main.id] == "1" && replicaModel.executingCells[other.id] == "2"
            }
            replicaModel.selectTab(other)
            try check(replicaModel.activeTab?.id == other.id, "remote sheet navigation is immediate")
            replicaModel.showExecutingCell()
            try check(replicaModel.activeTab?.id == other.id && replicaModel.cellNavigation?.location.cell == "2", "current remote cell follows the focused active sheet")
            let dashboard = replicaModel.snapshot!.boards!.first!
            replicaModel.selectBoard(dashboard)
            replicaModel.showExecutingCell()
            try check(replicaModel.activeBoard == nil && replicaModel.activeTab?.id == main.id && replicaModel.cellNavigation?.location.cell == "1", "remote board navigation reveals its controller's current cell")
            replicaModel.stopExecution()
            try await wait("focused Stop") { replicaModel.remote.runs.last?.state == "cancelled" }
            try check(!replicaModel.canStop && replicaModel.remote.runs.contains { $0.id == otherRun && $0.active }, "Stop affects only the focused sheet")
            try await wait("other sheet completion and presentation") {
                replicaModel.remote.runs.first { $0.id == otherRun }?.state == "succeeded" &&
                    replicaModel.snapshot?.tabs.first { $0.id == other.id }?.cells.first?.result == "70"
            }
            print("PASS concurrent sheets, focused progress and independent Stop")

            try await perform(replicaModel, "select", tab: other)
            try await perform(replicaModel, "run")
            try await wait("same-source remote rerun") { replicaModel.canForceStop }
            replicaModel.stopExecution(force: true)
            try await wait("same-source remote force stop") { replicaModel.remote.runs.last?.state == "force-stopped" }
            let previousOther = replicaModel.presentation(for: replicaModel.activeTab!.cells[0], in: replicaModel.activeTab!).result
            try check(previousOther?.text == "70" && previousOther?.previous == true,
                      "Force Stop preserves and labels a result even when source did not change")
            replicaModel.remote.reconnect()
            try await wait("reconnect after Force Stop") { replicaModel.remote.connected && !replicaModel.remote.busy }
            try check(replicaModel.presentation(for: replicaModel.activeTab!.cells[0], in: replicaModel.activeTab!).result?.previous == true,
                      "historical import cannot relabel a forced rerun's old result as current")
            replicaModel.remote.restart(sheet: "other")
            try await wait("reset forced other sheet") { !replicaModel.remote.busy }
            try await perform(replicaModel, "select", tab: main)
            print("PASS retained result after same-source Force Stop and reconnect")

            // Lose the first Run acknowledgement after the server accepted
            // it. Reconnect must recover its receipt, not create another Run.
            await close(replicaModel); active = nil
            let unreliable = NotebookModel(workerExecutable: worker, remoteExecutable: option("--fault-core"), remoteStorage: settings)
            active = unreliable; try await open(unreliable, replica)
            try await wait("unreliable client connected") { unreliable.remote.connected && !unreliable.remote.busy }
            let before = unreliable.remote.runs.count
            try edit(unreliable, "import task\ntask.sleep(3000)\n46\n")
            let acknowledged = await withCheckedContinuation { continuation in
                unreliable.perform("run") { continuation.resume(returning: $0) }
            }
            try check(!acknowledged && unreliable.remote.hasPending, "lost reply leaves a durable pending command")
            unreliable.clearError(); unreliable.remote.reconnect()
            try await wait("lost reply recovery") { unreliable.remote.connected && !unreliable.remote.busy && result(unreliable) == "46" }
            try check(unreliable.remote.runs.count == before + 1 && !unreliable.remote.hasPending, "receipt recovery does not duplicate execution")
            print("PASS lost Run acknowledgement and durable receipt recovery")

            // A forged sidecar can reference an existing revision, but it
            // cannot authorize a new Run without the private local ticket.
            let forged = root.appendingPathComponent("Forged.sputnikbook")
            try FileManager.default.copyItem(at: replica, to: forged)
            let sidecar = forged.appendingPathComponent(".sputnik/remote.json")
            var forgedState = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as! [String: Any]
            var bindings = forgedState["bindings"] as! [String: [String: Any]]
            var targetBinding = bindings[server.id]!
            targetBinding["pendingRun"] = ["command": UUID().uuidString.lowercased(), "revision": unreliable.remote.runs.last!.revision,
                                           "sheet": "main", "cell": "1", "all": false] as [String: Any]
            bindings[server.id] = targetBinding; forgedState["bindings"] = bindings
            try JSONSerialization.data(withJSONObject: forgedState).write(to: sidecar)
            let count = unreliable.remote.runs.count
            await close(unreliable); active = nil
            let untrusted = NotebookModel(workerExecutable: worker, remoteExecutable: core, remoteStorage: settings)
            active = untrusted; try await open(untrusted, forged)
            try await wait("untrusted pending command rejection") { untrusted.error?.contains("Untrusted pending Run") == true }
            let registry = try await observer.call(["--command", "runs", "--project", remoteProject])
            try check((registry["runs"] as? [Any])?.count == count, "opening a forged sidecar cannot run code")
            print("PASS inert notebook metadata and private command authorization")
            await close(untrusted); active = nil
            let missingProfile = NotebookModel(workerExecutable: worker, remoteExecutable: core, remoteStorage: root.appendingPathComponent("another-mac"))
            active = missingProfile; try await open(missingProfile, replica)
            try await wait("missing server profile") { missingProfile.remote.status == "Server profile unavailable" && !missingProfile.remote.busy }
            try check(missingProfile.remote.isSelected && !missingProfile.remote.connected && result(missingProfile) == "not evaluated",
                      "an unknown server binding never falls back to local execution")
            await close(missingProfile); active = nil
            let restored = NotebookModel(workerExecutable: worker, remoteExecutable: core, remoteStorage: settings)
            active = restored; try await open(restored, replica)
            try await wait("final reattach") { restored.remote.connected && !restored.remote.busy && result(restored) == "46" }
            try restored.remote.discardLocalCheckpoint()
            await close(restored); active = nil
            let discarded = NotebookModel(workerExecutable: worker, remoteExecutable: core, remoteStorage: settings)
            active = discarded; try await open(discarded, replica)
            try await wait("discarded checkpoint conflict") { discarded.remote.connected && !discarded.remote.busy && discarded.remote.conflict }
            try check(discarded.activeTab?.cells.first?.source == "99\n", "Discard preserves saved source on reopening")
            discarded.remote.sync(publish: true)
            try await wait("publish saved source") { !discarded.remote.busy && !discarded.remote.conflict }

            // A second writer advances the server head. Polling must preserve
            // this client's source until the user explicitly resolves it.
            let head = try await observer.call(["--command", "project", "--project", remoteProject])["head"] as! String
            let remoteDoc = try await observer.call(["--command", "document", "--project", remoteProject, "--revision", head])["document"] as! String
            var competing = try JSONSerialization.jsonObject(with: Data(remoteDoc.utf8)) as! [String: Any]
            competing["title"] = "Another writer"
            let competingFile = root.appendingPathComponent("competing.snapshot.json")
            let competingText = String(decoding: try JSONSerialization.data(withJSONObject: competing), as: UTF8.self)
            try JSONSerialization.data(withJSONObject: ["document": competingText, "modules": [:]] as [String: Any]).write(to: competingFile)
            let request = root.appendingPathComponent("competing.request.json")
            _ = try await observer.call(["--command", "prepare", "--project", remoteProject, "--directory", replica.path,
                                         "--base", head, "--snapshot-file", competingFile.path, "--request-file", request.path])
            let newer = try await observer.call(["--command", "upload_prepared", "--project", remoteProject, "--request-file", request.path])["revision"] as! String
            try await wait("competing server revision") { discarded.remote.conflict }
            try check(discarded.activeTab?.cells.first?.source == "99\n", "server conflict preserves local source")
            let observed = try await observer.call(["--command", "project", "--project", remoteProject])["head"] as! String
            try check(observed == newer, "polling never overwrites a competing revision")
            discarded.remote.sync(publish: true)
            try await wait("explicit conflict resolution") { !discarded.remote.busy && !discarded.remote.conflict }
            print("PASS Discard, competing writer and explicit conflict resolution")
            let grantTab = discarded.activeTab!
            let workerSettings = try await discarded.workerSettings(for: grantTab)
            try check(workerSettings.grants.isEmpty, "remote grants deny by default")
            try await discarded.configureWorker(grantTab, text: "process.spawn=/usr/bin/printf", settings: workerSettings)
            try edit(discarded, "from system import cmd\ncmd\"/usr/bin/printf granted\".output\n")
            try await perform(discarded, "run")
            try await wait("remote scoped process grant") { result(discarded)?.contains("granted") == true }
            let grantedSettings = try await discarded.workerSettings(for: discarded.activeTab!)
            try check(grantedSettings.grants == ["process.spawn=/usr/bin/printf"], "UI reads canonical server policy")
            discarded.remote.detach(); discarded.remote.reconnect()
            try await wait("grant settings reconnect") { discarded.remote.connected && !discarded.remote.busy }
            let reattachedSettings = try await discarded.workerSettings(for: discarded.activeTab!)
            try check(reattachedSettings.grants == grantedSettings.grants, "reconnect preserves server grants")
            try await discarded.configureWorker(discarded.activeTab!, text: "", settings: reattachedSettings)
            try await perform(discarded, "run")
            try await wait("remote grant revocation") { discarded.activeTab?.cells.first?.error.contains("CapabilityError") == true }
            print("PASS worker grant settings, scoped command, reconnect and revocation through the notebook model")
            if let journal = FileManager.default.enumerator(at: settings, includingPropertiesForKeys: nil) {
                for case let entry as URL in journal {
                    try check(![".request.json", ".snapshot.json", ".run.json", ".worker-settings.json", ".bin"].contains { entry.lastPathComponent.hasSuffix($0) },
                              "acknowledged command payloads and presentation downloads are cleaned up")
                }
            }
            try await render(discarded, to: root.appendingPathComponent("remote-ui.png"))
            let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
            let settingsView = NSHostingView(rootView: NotebookWorkerSettingsEditor(model: discarded, remote: discarded.remote,
                tab: discarded.activeTab!, document: discarded.documentIdentity, execution: discarded.remote.selected))
            settingsWindow.contentView = settingsView; settingsWindow.orderFront(nil)
            try await Task.sleep(nanoseconds: 500_000_000)
            settingsView.layoutSubtreeIfNeeded()
            if let bitmap = settingsView.bitmapImageRepForCachingDisplay(in: settingsView.bounds) {
                settingsView.cacheDisplay(in: settingsView.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("worker-settings.png"))
            }
            settingsWindow.orderOut(nil)
            let bookView = NSHostingView(rootView: NotebookBookSettingsView(model: discarded))
            settingsWindow.contentView = bookView; settingsWindow.orderFront(nil)
            try await Task.sleep(nanoseconds: 200_000_000)
            bookView.layoutSubtreeIfNeeded()
            if let bitmap = bookView.bitmapImageRepForCachingDisplay(in: bookView.bounds) {
                bookView.cacheDisplay(in: bookView.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("notebook-settings.png"))
            }
            settingsWindow.orderOut(nil)
            await close(discarded); active = nil
            print("notebook remote UI integration tests passed")
        } catch {
            if let active { await close(active) }
            fputs("remote UI tests failed: \(error); model=\(active?.error ?? "none"); status=\(active?.remote.status ?? "none")\n", stderr); exit(1)
        }
    }
    @MainActor private static func render(_ model: NotebookModel, to path: URL) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 840), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSHostingView(rootView: NotebookView(model: model))
        window.contentView = view; window.orderFront(nil); view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: path)
        }
        window.orderOut(nil)
    }
}

import AppKit
import Foundation
import SwiftUI

private struct RemoteWorkFailure: Error { let message: String }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw RemoteWorkFailure(message: message) }
}
@main private enum RemoteWorkTests {
    private static func option(_ key: String) -> String { CommandLine.arguments[CommandLine.arguments.firstIndex(of: key)! + 1] }
    @MainActor private static func wait(_ message: String, _ ready: () -> Bool) async throws {
        for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds: 25_000_000) }
        throw RemoteWorkFailure(message: "timeout: " + message)
    }
    @MainActor private static func cell(_ model: NotebookModel, _ id: String = "1") -> NotebookCell { model.snapshot!.tabs.first!.cells.first { $0.id == id }! }
    @MainActor private static func score(_ model: NotebookModel) -> String? { cell(model).locals.first { $0.name == "score" }?.value }
    @MainActor private static func apply(_ model: NotebookModel, _ values: [String: String], id: String = "1") async -> Bool {
        await withCheckedContinuation { c in model.setCellInputs(values, cell: cell(model, id), tab: model.activeTab!) { c.resume(returning: $0) } }
    }
    @MainActor private static func open(_ model: NotebookModel, _ project: URL) async throws {
        let opened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
        try check(opened, model.error ?? "open failed")
    }
    @MainActor private static func close(_ model: NotebookModel) async { await withCheckedContinuation { c in model.shutdown { c.resume() } } }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: option("--root")), project = root.appendingPathComponent("Work.sputnikbook")
        let storage = root.appendingPathComponent("work-settings"), core = option("--core"), worker = option("--worker")
        var active: NotebookModel?
        do {
            try FileManager.default.createDirectory(at: project.appendingPathComponent("modules"), withIntermediateDirectories: true)
            let document = #"""
            {"format":"sputnik-notebook","version":2,"title":"Remote work","active_sheet":"main",
             "sheets":[{"id":"main","title":"Main","cells":[{"id":"1","kind":"code","mode":"watch","source":"x = 1\nKernel.watch(x)\nnotebook.input(\"gain\") * 2\n"}]}],
             "modules":[{"id":"jobs","path":"modules/jobs.s"}],"auto_imports":[],
             "inputs":[{"id":"gain","title":"Gain","type":"integer","default":2}],
             "boards":[{"id":"dashboard","title":"Work","sheet":"main","columns":1,"components":[
             {"id":"act","kind":"action","title":"Compute","module_id":"jobs","function":"compute","p1":{"arguments":[{"id":"gain_arg","input":"gain"}]}},
             {"id":"timer","kind":"periodic_work","title":"Counter","module_id":"jobs","function":"tick","period_seconds":0.1,"retention":"tail","tail_limit":2}]}]}
            """#
            try Data(document.utf8).write(to: project.appendingPathComponent("project.json"))
            let module = "package jobs\nclass Counter:\n  def init(): @n = 0\n  def next():\n    @n += 1\n    @n\nState = Counter()\ndef compute(x): [State.next(), x]\ndef tick(): State.next()\nexport compute, tick\n"
            try Data(module.utf8).write(to: project.appendingPathComponent("modules/jobs.s"))
            let armed = root.appendingPathComponent("work-armed")
            let wrapper = root.appendingPathComponent("work-fault-client")
            func literal(_ value: String) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/") }
            let script = "#!/usr/bin/python3\nimport pathlib, subprocess, sys\na=sys.argv[1:]\nr=subprocess.run([\(try literal(core))]+a,stdout=subprocess.PIPE,stderr=subprocess.PIPE)\np=pathlib.Path(\(try literal(armed.path)))\nif '--command' in a and p.exists() and a[a.index('--command')+1]==p.read_text() and r.returncode==0:\n p.unlink()\n sys.exit(74)\nsys.stdout.buffer.write(r.stdout)\nsys.stderr.buffer.write(r.stderr)\nsys.exit(r.returncode)\n"
            try Data(script.utf8).write(to: wrapper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            let model = NotebookModel(workerExecutable: worker, remoteExecutable: wrapper.path, remoteStorage: storage)
            active = model; try await open(model, project)
            var server = NotebookServer(); server.name = "Work fixture"; server.ssh = false; server.url = option("--url")
            let token = try String(contentsOfFile: option("--token")).trimmingCharacters(in: .whitespacesAndNewlines)
            try model.remote.addServer(server, token: token); model.remote.choose(server.id)
            try await wait("connect: \(model.error ?? "")") { model.remote.connected && !model.remote.busy }
            try check(model.remote.supportsProjectInputs && model.remote.supportsBoardActions && model.remote.supportsServerPeriodic, "missing capabilities")
            let observer = NotebookRemoteClient(executable: core, token: URL(fileURLWithPath: option("--token"))); observer.endpoint = option("--url")
            let projectID = model.remote.projectID!
            let initialApply = await withCheckedContinuation { c in model.perform("set_inputs", text: #"{"gain":"4"}"#) { c.resume(returning: $0) } }
            try check(initialApply, model.error ?? "project Apply failed")
            try check(model.remote.runs.isEmpty, "input edit initialized a runtime")
            let ran = await withCheckedContinuation { c in model.perform("run_all") { c.resume(returning: $0) } }
            try check(ran, model.error ?? "Run failed")
            try await wait("first result and idle Watch") { !model.remote.active && cell(model).result == "8" && model.remote.runs.contains { $0.action == "watch" } }
            try Data("set_inputs".utf8).write(to: armed)
            let lost = await withCheckedContinuation { c in model.perform("set_inputs", text: #"{"gain":"7"}"#) { c.resume(returning: $0) } }
            try check(!lost && model.remote.hasPending, "lost project input reply was not journaled")
            model.clearError(); model.remote.reconnect()
            try await wait("recover project Apply") { model.remote.connected && !model.remote.busy && !model.remote.active && !model.remote.hasPending && cell(model).result == "14" }
            try check(model.snapshot?.inputs?.first?.value_json == "7", "accepted project value was not mirrored")
            try Data("invoke".utf8).write(to: armed)
            let invoked = await withCheckedContinuation { c in model.perform("action_run", text: "dashboard", commandCellID: "act") { c.resume(returning: $0) } }
            try check(!invoked && model.remote.hasPending, "lost action reply was not journaled")
            model.clearError(); model.remote.reconnect()
            try await wait("recover action exactly once") { model.remote.connected && !model.remote.busy && !model.remote.active && model.invocationResult("dashboard:act")?.result == "[1, 7]" }
            try check(cell(model).result == "14", "action replaced controller results")
            let board = model.snapshot!.boards!.first!, component = board.services.first!
            try Data("configure_service".utf8).write(to: armed)
            model.startPeriodic(board: board, component: component)
            try await wait("lost Start receipt") { model.remote.hasPending && !model.remote.busy }
            model.clearError(); model.remote.reconnect()
            try await wait("recover Start") { model.remote.connected && !model.remote.busy && !model.remote.hasPending }
            try await wait("server periodic history") { model.periodicState(board: board, component: component).runs >= 2 }
            await close(model); active = nil
            try await Task.sleep(nanoseconds: 500_000_000)
            let registry = try await observer.call(["--command", "registry", "--project", projectID])
            let state = (registry["services"] as! [[String: Any]]).first!
            try check(state["enabled"] as? Bool == true && (state["runs"] as? Int ?? 0) >= 3, "closing client stopped server work")
            let reconnected = NotebookModel(workerExecutable: worker, remoteExecutable: wrapper.path, remoteStorage: storage)
            active = reconnected; try await open(reconnected, project)
            try await wait("reattach service") { reconnected.remote.connected && !reconnected.remote.busy && reconnected.periodicState(board: board, component: component).enabled }
            reconnected.pausePeriodic(board: board, component: component)
            try await wait("durable server pause") { !reconnected.remote.busy && !reconnected.periodicState(board: board, component: component).enabled && !reconnected.periodicState(board: board, component: component).running }
            try check(reconnected.periodicState(board: board, component: component).history.count == 2, "server tail history missing")
            try check(reconnected.invocationResult("dashboard:act")?.result == "[1, 7]", "action result missing on reconnect")
            await close(reconnected); active = nil
            print("Remote work tests passed: project inputs, idle Watch, action receipt recovery, server periodic close/reconnect/pause and retained history")
        } catch {
            if let active { await close(active) }
            fputs("Remote work tests failed: \(error); model=\(active?.error ?? "none"); status=\(active?.remote.status ?? "none")\n", stderr); exit(1)
        }
    }
}

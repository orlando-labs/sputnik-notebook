import AppKit
import Foundation
import SwiftUI

private struct RemoteCellFailure: Error { let message: String }
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw RemoteCellFailure(message: message) }
}
@main private enum RemoteCellTests {
    private static func option(_ key: String) -> String { CommandLine.arguments[CommandLine.arguments.firstIndex(of: key)! + 1] }
    @MainActor private static func wait(_ message: String, _ ready: () -> Bool) async throws {
        for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds: 25_000_000) }
        throw RemoteCellFailure(message: "timeout: " + message)
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
        let root = URL(fileURLWithPath: option("--root")), project = root.appendingPathComponent("Cells.sputnikbook")
        let storage = root.appendingPathComponent("cell-settings"), core = option("--core"), worker = option("--worker")
        var active: NotebookModel?
        do {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let source = #"import task\ngain = notebook.cell_input(\"gain\")\noffset = notebook.cell_input(\"offset\")\n[0, 1, 2, 3, 4].each |step|:\n  notebook.chart_point(\"shared\", step, gain * step + offset)\n  notebook.progress(\"work\", step + 1, 5, \"Computing\", step == 4)\n  task.sleep(500)\nnotebook.images(\"preview\", [{data: [0, 64, 128, 255], width: 2, height: 2, format: :gray}])\nscore = gain * 10 + offset\n[{gain: gain, offset: offset, score: score}]\n"#
            let parameters = #"[{"id":"gain","title":"Gain","type":"number","default_json":"2","minimum":0,"maximum":10},{"id":"offset","title":"Offset","type":"number","default_json":"1"},{"id":"exact","title":"Exact","type":"integer","default_json":"9223372036854775806"}]"#
            let document = #"{"format":"sputnik-notebook","version":4,"title":"Remote cell components","active_sheet":"main","sheets":[{"id":"main","title":"Main","cells":[{"id":"1","kind":"code","mode":"watch","source":""# + source + #"","cell_ui":{"inputs":"# + parameters + #", "pre":[{"id":"form","kind":"parameter_form","title":"Remote parameters","fields":[{"input":"gain"},{"input":"offset"},{"input":"exact"}]}],"post":[{"id":"metric","kind":"metric","title":"Score","binding":"score"},{"id":"chart","kind":"live_chart","title":"Live response","chart_id":"shared"},{"id":"image","kind":"image","title":"Preview","image_id":"preview"},{"id":"table","kind":"table","title":"Data Table"}]}},{"id":"2","kind":"code","mode":"manual","source":"other = notebook.cell_input(\"gain\")\nnotebook.chart_point(\"shared\", 0, other)\nother\n","cell_ui":{"inputs":[{"id":"gain","title":"Independent","type":"number","default_json":"50"}],"pre":[{"id":"input","kind":"input","title":"Independent","input":"gain"}],"post":[{"id":"chart","kind":"live_chart","title":"Same channel, another cell","chart_id":"shared"}]}}]}],"modules":[],"auto_imports":[],"dependencies":[],"inputs":[],"boards":[],"future":12345678901234567890}"#
            try Data(document.utf8).write(to: project.appendingPathComponent("project.json"))
            // Drop one acknowledged input response after arming; reconnect must use its receipt.
            let armed = root.appendingPathComponent("inputs-armed"), dropped = root.appendingPathComponent("inputs-dropped")
            let wrapper = root.appendingPathComponent("input-fault-client")
            func literal(_ value: String) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self).replacingOccurrences(of: "\\/", with: "/") }
            let script = "#!/usr/bin/python3\nimport pathlib, subprocess, sys\nargs=sys.argv[1:]\nr=subprocess.run([\(try literal(core))]+args,stdout=subprocess.PIPE,stderr=subprocess.PIPE)\narmed=pathlib.Path(\(try literal(armed.path)))\ndropped=pathlib.Path(\(try literal(dropped.path)))\nif '--command' in args and args[args.index('--command')+1]=='set_cell_inputs' and r.returncode==0 and armed.exists() and not dropped.exists():\n dropped.touch()\n sys.exit(74)\nsys.stdout.buffer.write(r.stdout)\nsys.stderr.buffer.write(r.stderr)\nsys.exit(r.returncode)\n"
            try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            let model = NotebookModel(workerExecutable: worker, remoteExecutable: wrapper.path, remoteStorage: storage)
            active = model; try await open(model, project)
            var server = NotebookServer(); server.name = "Remote Cells"; server.ssh = false; server.url = option("--url")
            let token = try String(contentsOfFile: option("--token")).trimmingCharacters(in: .whitespacesAndNewlines)
            try model.remote.addServer(server, token: token); model.remote.choose(server.id)
            try await wait("connect: \(model.error ?? "")") { model.remote.connected && !model.remote.busy }
            try check(model.remote.supportsCellInputs, "cell input capability missing")
            let accepted = await apply(model, ["gain": "3", "offset": "4"])
            try check(accepted, model.error ?? "Apply before first run failed")
            try check(model.remote.runtimes.isEmpty && score(model) == nil, "input edit started an uninitialized remote or local worker")
            try check(cell(model).cell_inputs?.first?.editingText == "3.0", "accepted remote values not mirrored")
            let observer = NotebookRemoteClient(executable: core, token: URL(fileURLWithPath: option("--token"))); observer.endpoint = option("--url")
            let projectID = model.remote.projectID!
            let head = try await observer.call(["--command", "project", "--project", projectID])["head"] as! String
            var ui = cell(model).cell_ui!; ui.post[0].title = "Remote score"
            let saved = await withCheckedContinuation { c in model.saveCellUI(ui, cell: cell(model), tab: model.activeTab!) { c.resume(returning: $0) } }
            try check(saved, model.error ?? "Components save was blocked in remote mode")
            try await wait("component sync") { model.remote.status.hasPrefix("Synced") && !model.remote.busy }
            let configured = try await observer.call(["--command", "project", "--project", projectID])
            try check(configured["head"] as? String != head && (configured["document"] as? String)?.contains("Remote score") == true, "component settings did not reach server revision")
            try check(model.remote.runs.isEmpty, "saving components executed code")
            var finished: Bool? = nil; var live = false
            model.perform("run_all") { finished = $0 }
            try await wait("run accepted") { finished != nil }
            try check(finished == true, model.error ?? "remote Run failed")
            try await wait("remote result and live chart") {
                if let current = model.activeTab, model.remote.active,
                   model.cellChart("shared", cell: cell(model), tab: current)?.points.isEmpty == false { live = true }
                return !model.remote.active && score(model) == "34"
            }
            try check(live, "remote post-cell chart did not update during execution")
            let tab = model.activeTab!
            try check(model.cellChart("shared", cell: cell(model), tab: tab)?.points.last?.y == 16 && model.cellChart("shared", cell: cell(model, "2"), tab: tab)?.points.last?.y == 50, "remote channels crossed cell boundaries")
            try check(model.cellImages("preview", cell: cell(model), tab: tab)?.images.count == 1 && cell(model).result_format?.table_json?.contains("34") == true, "remote Image / Data Table missing")
            let count = model.remote.runs.count
            try Data().write(to: armed)
            let lost = await apply(model, ["gain": "4", "offset": "5", "exact": "9223372036854775807"])
            try check(!lost && model.remote.hasPending, "fault did not preserve pending input command")
            model.clearError(); model.remote.reconnect()
            try await wait("input receipt recovery") { model.remote.connected && !model.remote.busy && !model.remote.hasPending }
            try await wait("Watch from recovered Apply") { !model.remote.active && score(model) == "45" }
            try check(model.remote.runs.count == count + 1, "lost input response duplicated evaluation")
            try check(cell(model).cell_inputs?.first(where: { $0.id == "exact" })?.value_json == "9223372036854775807", "remote Int64 rounded")
            let quiet = await apply(model, ["gain": "4"])
            try check(quiet && model.remote.runs.count == count + 1, "equal Apply reran Watch")
            let invalid = await apply(model, ["gain": "9", "exact": "9223372036854775808"])
            try check(!invalid && cell(model).cell_inputs?.first?.editingText == "4.0", "invalid form partially committed")
            model.clearError()
            let manual = await apply(model, ["gain": "60"], id: "2")
            try check(manual, model.error ?? "Manual parameter Apply failed")
            try await wait("Manual invalidation") { !model.remote.active && cell(model, "2").dirty }
            try check(cell(model, "2").result != "60", "Manual cell executed on Apply")
            let ran = await withCheckedContinuation { c in model.perform("run", tab: model.activeTab!, cell: cell(model, "2")) { c.resume(returning: $0) } }
            try check(ran, model.error ?? "Manual Run rejected")
            try await wait("Manual result") { !model.remote.active && cell(model, "2").result == "60" }
            try check(try String(contentsOf: project.appendingPathComponent("project.json")).contains("12345678901234567890"), "component save rounded opaque metadata")
            await close(model); active = nil
            let reconnected = NotebookModel(workerExecutable: worker, remoteExecutable: wrapper.path, remoteStorage: storage)
            active = reconnected; try await open(reconnected, project)
            try await wait("reattach accepted inputs") { reconnected.remote.connected && !reconnected.remote.busy && cell(reconnected).cell_inputs?.first?.editingText == "4.0" }
            try check(cell(reconnected).cell_ui?.inputs.first?.default_json == "2" && cell(reconnected, "2").cell_inputs?.first?.editingText == "60.0", "reconnect lost values or rewrote defaults")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 950), styleMask: [.titled], backing: .buffered, defer: false)
            let view = NSHostingView(rootView: NotebookView(model: reconnected)); window.contentView = view; window.orderFront(nil)
            try await Task.sleep(nanoseconds: 200_000_000); view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("remote-cells.png"))
            }
            window.orderOut(nil)
            let beforeForgery = reconnected.remote.runs.count
            await close(reconnected); active = nil
            let sidecar = project.appendingPathComponent(".sputnik/remote.json")
            var metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as! [String: Any]
            var bindings = metadata["bindings"] as! [String: [String: Any]], binding = bindings[server.id]!
            binding["pendingInputs"] = ["command": UUID().uuidString.lowercased(), "revision": configured["head"]!, "version": "0", "cell": "1", "values": ["gain": "9"]]
            bindings[server.id] = binding; metadata["bindings"] = bindings
            try JSONSerialization.data(withJSONObject: metadata).write(to: sidecar)
            let forged = NotebookModel(workerExecutable: worker, remoteExecutable: wrapper.path, remoteStorage: storage)
            active = forged; try await open(forged, project)
            try await wait("untrusted input recovery rejected") { forged.error?.contains("Untrusted pending input edit") == true }
            let registry = try await observer.call(["--command", "registry", "--project", projectID])
            try check((registry["runs"] as? [Any])?.count == beforeForgery, "notebook metadata executed an input edit")
            await close(forged); active = nil
            print("Remote cell tests passed: Components, atomic inputs, own live channels, Image/Data Table, Watch/Manual, exact Int64, receipt recovery and reconnect")
        } catch {
            if let active { await close(active) }
            fputs("Remote cell tests failed: \(error); model=\(active?.error ?? "none"); status=\(active?.remote.status ?? "none")\n", stderr); exit(1)
        }
    }
}

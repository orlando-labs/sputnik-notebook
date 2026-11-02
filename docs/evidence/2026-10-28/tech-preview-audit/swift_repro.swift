import AppKit
import Foundation

@main enum PreviewAudit {
    @MainActor static func pause(_ seconds: Double = 0.05) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; await pause() }
        throw NSError(domain: "audit-timeout", code: 1)
    }
    static func emit(_ value: [String: Any]) { print(String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)) }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = CommandLine.arguments[2]
        let model = NotebookModel(workerExecutable: repo + "/build/sputnik-notebook-worker", remoteStorage: root.appendingPathComponent("model-settings"))
        let a = root.appendingPathComponent("A.sputnikbook"), b = root.appendingPathComponent("B.sputnikbook")
        func write(_ url: URL, _ source: String) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let doc: [String: Any] = ["format":"sputnik-notebook","version":1,"title":url.lastPathComponent,"active_sheet":"main","sheets":[["id":"main","title":"Main","cells":[["id":"1","kind":"code","mode":"manual","source":source]]]],"modules":[],"auto_imports":[]]
            try JSONSerialization.data(withJSONObject: doc).write(to: url.appendingPathComponent("project.json"))
        }
        try write(a,"1\n"); try write(b,"2\n")
        let openedA = await withCheckedContinuation { c in model.open(url:a) { c.resume(returning:$0) } }
        precondition(openedA)
        model.editSource("999\n",cell:model.activeTab!.cells[0],tab:model.activeTab!)
        // An old remote sync can reach exportSnapshot while worker.open is in flight.
        // Both calls go to the actual serial NotebookWorker queue.
        var openedB = false
        model.open(url:b) { openedB = $0 }
        var rejected = false
        do { _ = try await model.remote.exportSnapshot!() } catch { rejected = true }
        try await wait { openedB }
        let displayedBeforeSave = model.activeTab!.cells[0].source
        let saved = await withCheckedContinuation { c in model.perform("save_all") { c.resume(returning:$0) } }
        let disk = try JSONSerialization.jsonObject(with: Data(contentsOf:b.appendingPathComponent("project.json"))) as! [String:Any]
        let cells = (disk["sheets"] as! [[String:Any]])[0]["cells"] as! [[String:Any]]
        emit(["test":"old_remote_export_during_open","old_callback_rejected":rejected,"displayed_B_before_save":displayedBeforeSave,"save_succeeded":saved,"B_source_after_save":cells[0]["source"]!])
        await withCheckedContinuation { c in model.shutdown { c.resume() } }

        let storage = root.appendingPathComponent("remote-settings"), book = root.appendingPathComponent("Remote.sputnikbook")
        try write(book,"42\n")
        let helper = root.appendingPathComponent("fixture-cli")
        let registryFile = root.appendingPathComponent("registry.json")
        let program = """
        #!/usr/bin/python3
        import json,pathlib,sys
        args=sys.argv; command=args[args.index('--command')+1]
        if command=='health': result={'protocol':1,'capabilities':['gui_reconnect','compact_registry']}
        elif command=='registry': result=json.loads(pathlib.Path(__file__).with_name('registry.json').read_text())
        elif command=='projects': result={'projects':[{'id':'p','head':'r','state':'active'}]}
        elif command=='status': result={'result':{'cells':[{'result':'42','error':''}],'environment_error':''},'error':''}
        elif command=='prepare': result={}
        elif command=='upload_prepared': result={'revision':'r'}
        elif command=='run':
            path=pathlib.Path(__file__).with_name('accepted-commands.json')
            commands=json.loads(path.read_text()) if path.exists() else []
            commands.append(args[args.index('--command-id')+1]);path.write_text(json.dumps(commands))
            result={'remote_error':{'status':503,'message':'agent reply lost after accepting command'}} if len(commands)==1 else {'run_id':'accepted'}
        else: raise RuntimeError(command)
        print(json.dumps(result))
        """
        try Data(program.utf8).write(to:helper)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let remote = NotebookRemoteController(executable:helper.path,storage:storage)
        var server=NotebookServer();server.ssh=false;server.url="http://127.0.0.1:1"
        try remote.addServer(server,token:"test-token")
        var binding=NotebookRemoteBinding(project:"p",revision:"r");binding.exported="snapshot";binding.saved="disk"
        let metadata=NotebookRemoteDocument(selected:server.id,bindings:[server.id:binding])
        try NotebookRemoteController.write(try JSONEncoder().encode(metadata),to:book.appendingPathComponent(".sputnik/remote.json"))
        remote.exportSnapshot={ NotebookRemoteExport(current:"snapshot",disk:"disk") }
        remote.onError={ emit(["remote_error":$0]) }
        let first:[String:Any] = ["id":"run1","revision":"r","sheet_id":"service_owner","epoch":"e","state":"succeeded","board":"board","component":"act","controller":"main","action":"action_run","has_presentation":true]
        var second=first;second["id"]="run2";second["state"]="interrupted";second["has_presentation"]=false;second["error"]="worker crashed"
        func registry(_ runs:[[String:Any]]) throws {
            try JSONSerialization.data(withJSONObject:["project":["id":"p","head":"r","state":"active"],"runs":runs,"runtimes":[],"reset_epochs":[]]).write(to:registryFile,options:.atomic)
        }
        try registry([first]);remote.open(book)
        try await wait { remote.connected && !remote.busy && remote.invocationResults["board:act"] != nil }
        try registry([first,second])
        try await wait { remote.runs.last?.id == "run2" }
        await pause(0.3)
        let result=remote.invocationResults["board:act"]!
        emit(["test":"terminal_invocation_without_artifact","latest_run_state":remote.runs.last!.state,"displayed_ok":result.ok,"displayed_result":result.result,"displayed_error":result.error,"displayed_stale":remote.invocationStale["board:act"] ?? false])
        let firstRun = await withCheckedContinuation { c in remote.run(sheet:"main",cell:"1",all:false) { c.resume(returning:$0) } }
        let pendingAfter503 = remote.hasPending
        let secondRun = await withCheckedContinuation { c in remote.run(sheet:"main",cell:"1",all:false) { c.resume(returning:$0) } }
        let commands = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("accepted-commands.json"))) as! [String]
        emit(["test":"accepted_run_then_gateway_503","first_call_succeeded":firstRun,"pending_after_503":pendingAfter503,"second_call_succeeded":secondRun,"accepted_command_count":commands.count,"distinct_command_ids":Set(commands).count])
        remote.detach()
    }
}

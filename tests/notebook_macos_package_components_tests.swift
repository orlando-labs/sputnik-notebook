import Foundation

@main
@MainActor
struct NotebookPackageComponentsTests {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NotebookFailure(message: message) }
    }

    private static func eventually(_ message: String, check: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !check(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try require(check(), message)
    }

    private static func request(_ base: String, _ path: String, token: String?, json: String? = nil) async throws -> Int {
        var request = URLRequest(url: URL(string: base + path)!, timeoutInterval: 4)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(json.utf8)
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    static func main() async {
        let args = CommandLine.arguments
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sputnik-package-test-\(UUID())")
        let book = root.appendingPathComponent("Components.sputnikbook")
        let model = NotebookModel(workerExecutable: args[1], remoteExecutable: args[2], remoteStorage: root.appendingPathComponent("remote"))
        setenv("SPUTNIK_COMPILER", args[3], 1)
        var message: String?
        do {
            try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
            try Data("""
            {"format":"sputnik-notebook","version":2,"title":"Components","active_sheet":"main",
             "sheets":[{"id":"main","title":"Controller","cells":[{"id":"1","kind":"code","mode":"watch","source":"42"}]}],
             "modules":[{"id":"routes","path":"modules/routes.s"}],"auto_imports":[],
             "inputs":[],"boards":[{"id":"main_board","title":"Components","sheet":"main","columns":2,"rows":[{"id":"row"}],"components":[]}]}
            """.utf8).write(to: book.appendingPathComponent("project.json"))
            let modules = book.appendingPathComponent("modules", isDirectory: true)
            try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: false)
            try Data("""
            package routes
            import orbit
            export router

            def custom(request):
              orbit.render(text: "custom")

            def router():
              orbit.routes:
                get "/custom", to: &custom
            """.utf8).write(to: modules.appendingPathComponent("routes.s"))
            let opened = await withCheckedContinuation { continuation in model.open(url: book) { continuation.resume(returning: $0) } }
            try require(opened, model.error ?? "Could not open test book.")
            try require(model.componentPackages.isEmpty, "Provider must be local to the book.")

            let dependencies = NotebookDependencyController(model: model)
            await dependencies.load()
            dependencies.packageScope = "local"
            let packages = URL(fileURLWithPath: args[4]).standardizedFileURL.deletingLastPathComponent()
            let orbit = packages.deletingLastPathComponent()
            let session = root.appendingPathComponent("orbit-session", isDirectory: true)
            try FileManager.default.copyItem(at: packages.appendingPathComponent("orbit-session"), to: session)
            let manifest = session.appendingPathComponent("sputnik.build.yaml")
            let original = try String(contentsOf: manifest, encoding: .utf8)
            let exactOrbit = "  orbit: \"1.0.0-rc.1\""
            try require(original.contains(exactOrbit), "Update the fixture to match the source checkout's Orbit pin.")
            let pinnedPath = try JSONEncoder().encode(["path": orbit.path, "version": "1.0.0-rc.1"])
            try original.replacingOccurrences(of: exactOrbit, with: "  orbit: " + String(decoding: pinnedPath, as: UTF8.self))
                .write(to: manifest, atomically: true, encoding: .utf8)
            dependencies.packageSource = session.path
            await dependencies.installPackage()
            try require(dependencies.error == nil, dependencies.error ?? "Orbit Session installation failed.")
            try require(Set(dependencies.inventory.packages.map(\.name)) == ["orbit-session", "orbit"] && model.componentPackages.isEmpty,
                        "Installing Orbit Session must record its Orbit dependency and leave the companion optional.")
            try require(dependencies.notebookPackageSuggestions.map(\.id) == ["orbit-notebook"],
                        "Transitively installed Orbit must still offer the companion from its manifest.")
            dependencies.packageSource = args[4]
            await dependencies.installPackage()
            try require(dependencies.error == nil, dependencies.error ?? "Local installation failed.")
            try require(dependencies.notebookPackageSuggestions.isEmpty, "Hide the suggestion once its package is installed.")
            try require(model.componentPackages.map(\.name) == ["orbit-notebook"], "Installation did not update the palette catalog.")
            let package = model.componentPackages[0]
            try require(package.components.map(\.id) == ["http_server", "server_board"], "Package contributions are missing.")

            var board = model.snapshot!.boards![0]
            var service = NotebookBoardComponent(id: "server", kind: "package_service", title: "Custom server")
            service.package_component = NotebookPackageComponentReference(provider: package.id, type: "http_server")
            service.package_component?.properties["routes"] = "routes:router"
            var left = NotebookBoardComponent(id: "left", kind: "package_board", title: "Left", row: "row", span: 6)
            left.package_component = NotebookPackageComponentReference(provider: package.id, type: "server_board")
            var right = left
            right.id = "right"
            right.title = "Right"
            board.components = [service, left, right]
            let savedBoard = board
            let saved = await withCheckedContinuation { continuation in model.saveBoard(savedBoard) { continuation.resume(returning: $0) } }
            try require(saved, model.error ?? "Could not save package instances.")
            let savedComponents = model.snapshot?.boards?.first?.components
            try require(savedComponents?.first?.package_component == service.package_component, "Package configuration must round-trip through Core.")

            let runtime = model.packageRuntime
            guard let a = await runtime.prepareChild(model: model, board: board, component: left),
                  let b = await runtime.prepareChild(model: model, board: board, component: right),
                  let ab = a.board, let bb = b.board else {
                throw NotebookFailure(message: runtime.childErrors.description)
            }
            try require(a.directory != b.directory && a.model.documentIdentity != b.model.documentIdentity, "Subboards need independent state.")
            try require(a.model.snapshot?.inputs?.first?.id == "reading" && b.model.snapshot?.inputs?.first?.id == "reading", "Both subboards use local input names.")
            try require(runtime.sessions.isEmpty && a.model.packageRuntime.sessions.isEmpty, "Opening the book and its subboards must be passive.")
            runtime.start(model: model, board: board)
            let aService = ab.services[0], bService = bb.services[0]
            do {
                try await eventually("The three services did not report readiness.") {
                    runtime.state(board: board, component: service)?.url != nil &&
                        a.model.packageRuntime.state(board: ab, component: aService)?.url != nil &&
                        b.model.packageRuntime.state(board: bb, component: bService)?.url != nil
                }
            } catch {
                let status = [runtime, a.model.packageRuntime, b.model.packageRuntime].map { $0.serviceStates.mapValues(\.status) }
                throw NotebookFailure(message: "Service startup failed: \(status). \(model.error ?? "")")
            }
            let outer = runtime.state(board: board, component: service)!
            let first = a.model.packageRuntime.state(board: ab, component: aService)!
            let second = b.model.packageRuntime.state(board: bb, component: bService)!
            try require(first.url != second.url && first.token != second.token, "Each server needs a separate port and token.")
            let rejection = try await request(outer.url!, "/custom", token: nil)
            let accepted = try await request(outer.url!, "/custom", token: outer.token)
            try require(rejection == 401 && accepted == 200, "Saved routes and authentication should work.")
            let updated = try await request(first.url!, "/reading", token: first.token, json: "\"from HTTP\"")
            try require(updated == 200, "The HTTP endpoint should confirm writing the input.")
            try await eventually("The Watch result did not reflect the accepted input.") {
                a.model.controller(for: ab)?.cells.first?.result.contains("from HTTP") == true
            }
            try require(b.model.controller(for: bb)?.cells.first?.result.contains("from HTTP") == false, "An update must stay in its subboard.")
            runtime.stop(model: model, board: board)
            try require(runtime.sessions.isEmpty && a.model.packageRuntime.sessions.isEmpty && b.model.packageRuntime.sessions.isEmpty,
                        "Stop must stop the child sessions.")
            try await eventually("The HTTP server did not stop.") { runtime.state(board: board, component: service)?.status == "Stopped" }
            print("Verified installation, palette catalog, saved settings, isolated subboards, HTTP routes, Watch and Stop")
        } catch {
            message = error.localizedDescription
        }
        await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
        try? FileManager.default.removeItem(at: root)
        if let message {
            fputs("Notebook package components: \(message)\n", stderr)
            exit(1)
        }
    }
}

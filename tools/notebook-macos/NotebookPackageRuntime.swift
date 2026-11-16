import AppKit
import Combine
import Foundation

final class NotebookPackageRuntime: ObservableObject {
    struct ServiceState {
        var status = "Starting…"
        var url: String?
        var token: String?
        var requests = 0
    }

    struct EmbeddedBoard {
        let model: NotebookModel
        let directory: URL
        let boardID: String
        let packageDigest: String
        var board: NotebookBoard? { model.snapshot?.boards?.first { $0.id == boardID } }
    }

    @Published private(set) var sessions: [String: UUID] = [:]
    @Published private(set) var serviceStates: [String: ServiceState] = [:]
    @Published private(set) var childBoards: [String: EmbeddedBoard] = [:]
    @Published private(set) var childErrors: [String: String] = [:]
    private var processes: [String: NotebookPackageProcess] = [:]
    private var preparing: Set<String> = []
    private var generation = UUID()

    func key(_ board: NotebookBoard, _ component: NotebookBoardComponent) -> String {
        board.id + ":" + component.id
    }

    func state(board: NotebookBoard, component: NotebookBoardComponent) -> ServiceState? {
        serviceStates[key(board, component)]
    }

    func stop(_ boardID: String) {
        sessions.removeValue(forKey: boardID)
        let prefix = boardID + ":"
        for (id, process) in processes where id.hasPrefix(prefix) {
            process.stop()
            serviceStates[id] = ServiceState(status: "Stopping…")
        }
        for id in childBoards.keys.filter({ $0.hasPrefix(prefix) }) {
            retireChild(id)
        }
        childErrors = childErrors.filter { !$0.key.hasPrefix(prefix) }
    }

    func stopAll() {
        generation = UUID()
        for id in Array(sessions.keys) { stop(id) }
        for id in Array(childBoards.keys) { retireChild(id) }
        childErrors = [:]
    }

    private func retireChild(_ id: String) {
        guard let child = childBoards.removeValue(forKey: id) else { return }
        child.model.shutdown {
            try? FileManager.default.removeItem(at: child.directory)
        }
    }

    func reconcile(_ boards: [NotebookBoard]) {
        let ids = Set(boards.map(\.id))
        for removed in sessions.keys.filter({ !ids.contains($0) }) { stop(removed) }
        let active = Set(boards.flatMap { board in
            board.allComponents.compactMap { component -> String? in
                guard let reference = component.package_component, reference.enabled else { return nil }
                return key(board, component)
            }
        })
        for (id, process) in processes where !active.contains(id) {
            process.stop()
        }
        for id in childBoards.keys.filter({ !active.contains($0) }) { retireChild(id) }
        serviceStates = serviceStates.filter { active.contains($0.key) }
    }

    @MainActor
    func prepareChild(model: NotebookModel, board: NotebookBoard, component: NotebookBoardComponent) async -> EmbeddedBoard? {
        let id = key(board, component)
        if let cached = childBoards[id] { return cached }
        guard !model.remote.isSelected, component.package_component?.enabled == true else { return nil }
        if preparing.contains(id) {
            while preparing.contains(id) && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return childBoards[id]
        }
        guard model.packageBoardDepth < 8 else {
            childErrors[id] = "The board nesting limit has been reached."
            return nil
        }
        preparing.insert(id)
        defer { preparing.remove(id) }
        let requestedGeneration = generation
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sputnik-subboard-\(UUID()).sputnikbook", isDirectory: true)
        do {
            guard let (package, definition) = model.packageDefinition(for: component), let home = model.componentPackageHome else {
                throw NotebookFailure(message: "Install this component's package in Dependencies.")
            }
            let document = try package.boardDocument(for: definition)
            let manifest = try JSONSerialization.jsonObject(with: document) as? [String: Any]
            guard let boards = manifest?["boards"] as? [[String: Any]], boards.count == 1, let boardID = boards[0]["id"] as? String else {
                throw NotebookFailure(message: "An embedded board package must define one board.")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try document.write(to: directory.appendingPathComponent("project.json"), options: .atomic)
            try package.copyBoardAssets(for: definition, to: directory)
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("packages"), withDestinationURL: home)
            let child = NotebookModel(workerExecutable: model.workerExecutable, remoteExecutable: model.remote.executable)
            child.packageHomeOverride = home
            child.packageBoardDepth = model.packageBoardDepth + 1
            let opened = await withCheckedContinuation { continuation in
                child.open(url: directory) { continuation.resume(returning: $0) }
            }
            guard opened, requestedGeneration == generation,
                  model.snapshot?.boards?.first(where: { $0.id == board.id })?.allComponents.contains(where: { $0.id == component.id }) == true else {
                child.shutdown { try? FileManager.default.removeItem(at: directory) }
                if requestedGeneration == generation, !opened {
                    childErrors[id] = child.error ?? "Could not open the packaged board."
                }
                return nil
            }
            let embedded = EmbeddedBoard(model: child, directory: directory, boardID: boardID, packageDigest: package.digest)
            childBoards[id] = embedded
            childErrors.removeValue(forKey: id)
            return embedded
        } catch {
            try? FileManager.default.removeItem(at: directory)
            childErrors[id] = error.localizedDescription
            return nil
        }
    }

    func start(model: NotebookModel, board: NotebookBoard) {
        guard !model.remote.isSelected, !model.busy, !model.dependencyOperationActive, sessions[board.id] == nil,
              processes.keys.allSatisfy({ !$0.hasPrefix(board.id + ":") }) else { return }
        let session = UUID()
        sessions[board.id] = session
        Task { @MainActor in
            if let tab = model.controller(for: board), tab.cells.contains(where: { $0.kind == "code" }) {
                let ok = await withCheckedContinuation { continuation in
                    model.perform("run_all", tab: tab) { continuation.resume(returning: $0) }
                }
                guard sessions[board.id] == session else { return }
                if let failure = model.controller(for: board)?.cells.first(where: { $0.kind == "code" && !$0.error.isEmpty }) {
                    model.error = failure.error
                    stop(board.id)
                    return
                }
                guard ok else { stop(board.id); return }
            }
            guard sessions[board.id] == session else { return }
            for component in board.services {
                if component.kind == "periodic_work" {
                    model.startPeriodic(board: board, component: component)
                } else if component.package_component?.enabled == true {
                    startService(model: model, board: board, component: component)
                }
            }
            for component in board.allComponents where component.kind == "package_board" {
                guard sessions[board.id] == session else { break }
                if let child = await prepareChild(model: model, board: board, component: component),
                   sessions[board.id] == session, let nested = child.board {
                    child.model.packageRuntime.start(model: child.model, board: nested)
                }
            }
        }
    }

    func stop(model: NotebookModel, board: NotebookBoard) {
        for component in board.services where component.kind == "periodic_work" {
            model.pausePeriodic(board: board, component: component)
        }
        stop(board.id)
    }

    private func startService(model: NotebookModel, board: NotebookBoard, component: NotebookBoardComponent) {
        let id = key(board, component)
        do {
            guard let ref = component.package_component, let (_, definition) = model.packageDefinition(for: component),
                  let home = model.componentPackageHome else {
                throw NotebookFailure(message: "Install this component's package in Dependencies.")
            }
            let settings = try definition.settings(ref)
            let config = try NotebookPackageProcess.configuration(model: model, definition: definition, settings: settings)
            let token = UUID().uuidString + UUID().uuidString
            let service = try NotebookPackageProcess(compiler: model.packageCompiler, home: home, configuration: config, token: token)
            processes[id] = service
            serviceStates[id] = ServiceState(token: token)
            service.onEvent = { [weak self, weak service, weak model] event in
                guard let self, let service, let model, self.processes[id] === service else { return }
                switch event.kind {
                case "ready":
                    guard let port = event.port, (1...65535).contains(port), !service.stopping else { return }
                    self.serviceStates[id]?.status = "Running"
                    self.serviceStates[id]?.url = "http://127.0.0.1:\(port)"
                case "stats":
                    if let count = event.requests { self.serviceStates[id]?.requests = count }
                case "input":
                    guard let request = event.id, let input = event.input, let value = event.value else { return }
                    let allowed = definition.properties?.filter { $0.kind == .input }.contains { settings[$0.id] == input } ?? false
                    guard allowed, model.snapshot?.inputs?.contains(where: { $0.id == input }) == true else {
                        service.reply(request, status: 422); return
                    }
                    guard !service.stopping, !model.busy else { service.reply(request, status: 503); return }
                    model.setProjectInputs([input: value]) { success in service.reply(request, status: success ? 200 : 422) }
                default: break
                }
            }
            service.onExit = { [weak self, weak service] code, message in
                guard let self, let service, self.processes[id] === service else { return }
                self.processes.removeValue(forKey: id)
                let status = service.stopping ? "Stopped" : (message.isEmpty ? "Service exited (\(code))" : message)
                if self.serviceStates[id] != nil { self.serviceStates[id] = ServiceState(status: status) }
            }
            try service.start()
        } catch {
            processes.removeValue(forKey: id)
            serviceStates[id] = ServiceState(status: error.localizedDescription)
        }
    }
}

extension NotebookModel {
    var packageCompiler: String {
        ProcessInfo.processInfo.environment["SPUTNIK_COMPILER"] ??
            URL(fileURLWithPath: remote.executable).deletingLastPathComponent().appendingPathComponent("sputnik").path
    }
}

private final class NotebookPackageProcess {
    struct Configuration {
        let source: String
        let modules: [String: String]
        let settings: [String: String]
        let port: Int?
        let returnsInput: Bool
    }

    struct Event: Decodable {
        let event: String
        let port: Int?
        let requests: Int?
        let id: Int?
        let input: String?
        let value: String?
        var kind: String { event }
    }

    private let process = Process()
    private let pipe = Pipe()
    private let directory: URL
    private let control: URL
    private var output = Data()
    private var errorLines: [String] = []
    private var poll: Timer?
    private var publishedReady = false
    private var lastRequests: Int?
    private var lastInput = 0
    private let token: String
    private(set) var stopping = false
    var onEvent: ((Event) -> Void)?
    var onExit: ((Int32, String) -> Void)?

    static func configuration(model: NotebookModel, definition: NotebookPackageComponentDefinition,
                              settings: [String: String]) throws -> Configuration {
        guard let module = definition.module, let entry = definition.entry else {
            throw NotebookFailure(message: "The service entry point is missing.")
        }
        var imports = "from \(module) import \(entry) as notebook_service"
        var arguments = ""
        var moduleFiles: [String: String] = [:]
        let bindings = (definition.properties ?? []).filter { $0.kind == .module }
        for (index, property) in bindings.enumerated() {
            guard let selected = settings[property.id], !selected.isEmpty else { continue }
            let pair = selected.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let validModule = pair.first?.split(separator: ".", omittingEmptySubsequences: false)
                .allSatisfy { NotebookComponentPackage.identifier(String($0)) } ?? false
            guard let argument = property.argument, pair.count == 2, validModule, NotebookComponentPackage.identifier(pair[1]),
                  model.snapshot?.tabs.contains(where: { $0.id == "module:" + pair[0] }) == true else {
                throw NotebookFailure(message: "Choose a saved module and a valid export for \(property.title).")
            }
            imports += "\nfrom \(pair[0]) import \(pair[1]) as notebook_export_\(index)"
            arguments += ", \(argument): notebook_export_\(index)" + (property.invoke == true ? "()" : "")
        }
        if !arguments.isEmpty {
            for tab in model.snapshot?.tabs ?? [] where tab.kind == "module" {
                let name = String(tab.id.dropFirst("module:".count))
                let source = tab.cells.map(\.source).joined(separator: "\n")
                guard name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ NotebookComponentPackage.identifier(String($0)) }) else { continue }
                moduleFiles[name.replacingOccurrences(of: ".", with: "/") + ".s"] = source
            }
        }
        let source = """
        package notebook_service_entry
        \(imports)

        def main():
          parser = ArgParser()
          parser.arg("--config")
          parser.arg("--control")
          args = parser.parse_or_raise()
          notebook_service(args["config"], args["control"]\(arguments))
        """
        let port = definition.listen_port.flatMap { settings[$0] }.flatMap(Int.init)
        if let port, !(0...65535).contains(port) { throw NotebookFailure(message: "Choose a valid port.") }
        return Configuration(source: source, modules: moduleFiles, settings: settings, port: port,
                             returnsInput: (definition.properties ?? []).contains { $0.kind == .input })
    }

    init(compiler: String, home: URL, configuration: Configuration, token: String) throws {
        self.token = token
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("sputnik-package-service-\(UUID().uuidString)", isDirectory: true)
        control = directory.appendingPathComponent("control", isDirectory: true)
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try manager.createDirectory(at: control, withIntermediateDirectories: false)
            let source = directory.appendingPathComponent("notebook_service_entry.s")
            let config = directory.appendingPathComponent("config.json")
            try configuration.source.write(to: source, atomically: true, encoding: .utf8)
            try JSONSerialization.data(withJSONObject: ["token": token, "properties": configuration.settings]).write(to: config, options: .atomic)
            for (relative, module) in configuration.modules {
                let file = directory.appendingPathComponent(relative)
                guard file != source else { throw NotebookFailure(message: "The module name conflicts with the service entry.") }
                try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try module.write(to: file, atomically: true, encoding: .utf8)
            }
            process.executableURL = URL(fileURLWithPath: compiler)
            process.currentDirectoryURL = directory
            process.environment = ["SPUTNIK_PKG_HOME": home.path]
            var arguments = ["run", source.path, "--grant", "fs.read=\(config.path)", "--grant", "fs.metadata=\(control.path)",
                             "--grant", "fs.write=\(control.path)"]
            if configuration.returnsInput { arguments += ["--grant", "fs.read=\(control.path)"] }
            if let port = configuration.port { arguments += ["--grant", "net.listen=127.0.0.1:\(port)"] }
            process.arguments = arguments + ["--", "--config", config.path, "--control", control.path]
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func start() throws {
        let stream = pipe.fileHandleForReading
        stream.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            Task { @MainActor [weak self] in self?.consume(data) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.poll?.invalidate()
                self.pipe.fileHandleForReading.readabilityHandler = nil
                self.consume((try? self.pipe.fileHandleForReading.readToEnd()) ?? Data())
                try? FileManager.default.removeItem(at: self.directory)
                let message = self.diagnostic()
                self.onExit?(status, message)
            }
        }
        do {
            try process.run()
            try? pipe.fileHandleForWriting.close()
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.pollEvents() }
            poll = timer
            RunLoop.main.add(timer, forMode: .common)
        } catch {
            stream.readabilityHandler = nil
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func diagnostic() -> String {
        let text = errorLines.joined(separator: "\n")
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end,
           let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
           let items = object["diagnostics"] as? [[String: Any]], let message = items.first?["message"] as? String {
            return message
        }
        return errorLines.first ?? ""
    }

    private func pollEvents() {
        func read(_ name: String) -> Event? {
            let path = control.appendingPathComponent(name)
            guard let info = try? path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 16_384,
                  let handle = try? FileHandle(forReadingFrom: path) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 16_385), data.count <= 16_384 else { return nil }
            return try? JSONDecoder().decode(Event.self, from: data)
        }
        if !publishedReady, let event = read("ready.json"), event.kind == "ready" {
            publishedReady = true
            onEvent?(event)
        }
        if let event = read("stats.json"), event.kind == "stats", let requests = event.requests, requests != lastRequests {
            lastRequests = requests
            onEvent?(event)
        }
        if let event = read("input.json"), event.kind == "input", let id = event.id, id > lastInput {
            lastInput = id
            onEvent?(event)
        }
    }

    private func consume(_ data: Data) {
        output.append(data)
        while let newline = output.firstIndex(of: 10) {
            let line = output.prefix(upTo: newline)
            if !line.isEmpty {
                let safe = String(decoding: line.prefix(1024), as: UTF8.self).replacingOccurrences(of: token, with: "•••")
                errorLines.append(safe)
                if errorLines.count > 12 { errorLines.removeFirst() }
            }
            output.removeSubrange(...newline)
        }
        if output.count > 16_384 { output.removeAll() }
    }

    func reply(_ id: Int, status: Int) {
        guard id > 0 else { return }
        let path = control.appendingPathComponent("reply-\(id)")
        try? String(status).write(to: path, atomically: true, encoding: .utf8)
        Task {
            try? await Task.sleep(for: .seconds(5))
            try? FileManager.default.removeItem(at: path)
        }
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        try? Data().write(to: control.appendingPathComponent("stop"), options: .atomic)
        Task { @MainActor [self] in
            try? await Task.sleep(for: .seconds(4))
            if process.isRunning { process.terminate() }
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    deinit {
        poll?.invalidate()
        if process.isRunning { process.terminate() }
    }
}

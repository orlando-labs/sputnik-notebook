import AppKit
import Combine
import Darwin
import Foundation

struct NotebookServer: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    var name = "GPU server"
    var ssh = true
    var host = "lab.orlando-labs.com"
    var sshPort = 22176
    var remotePort = 18765
    var root = "/home/slowpilot/sputnik-remote-core/state"
    var url = "http://127.0.0.1:18765"
}
struct NotebookRemoteFailure: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}
struct NotebookRemotePendingRun: Codable, Equatable {
    let command: String, revision: String, sheet: String, cell: String
    let all: Bool
}
struct NotebookRemotePendingInputs: Codable, Equatable {
    let command: String, revision: String, version: String, cell: String
    let values: [String: String]
}
struct NotebookRemoteBinding: Codable {
    var project = UUID().uuidString.lowercased()
    var revision: String?
    var exported: String?
    var saved: String?
    var pendingUpload: String?
    var pendingExport: String?
    var pendingSaved: String?
    var pendingRun: NotebookRemotePendingRun?
    var pendingInputs: NotebookRemotePendingInputs?
}
struct NotebookRemoteExport { let current: String, disk: String }
struct NotebookRemoteDocument: Codable {
    var selected: String?
    var bindings: [String: NotebookRemoteBinding] = [:]
}
struct NotebookRemoteRun: Identifiable {
    let id: String, revision: String, sheet: String, epoch: String, state: String
    let inputVersion: String?
    let presentation: Bool, live: Bool
    let executingCell: String?
    var active: Bool { !["succeeded", "failed", "cancelled", "force-stopped", "interrupted"].contains(state) }
    init(_ value: [String: Any]) throws {
        func field(_ key: String) throws -> String {
            guard let text = value[key] as? String else { throw NotebookRemoteFailure(status: 0, message: "Invalid remote run: \(key)") }
            return text
        }
        inputVersion = value["input_version"] as? String
        id = try field("id"); revision = try field("revision"); sheet = try field("sheet_id")
        epoch = try field("epoch"); state = try field("state")
        presentation = value["presentation"] is String || value["has_presentation"] as? Bool == true
        live = value["live_presentation"] is String || value["has_live"] as? Bool == true
        executingCell = value["executing_cell"] as? String ?? (value["live"] as? [String: Any])?["executing_cell"] as? String
    }
}

// Each helper invocation is the native Sputnik client, including HTTP, CAS,
// immutable prepared uploads and command receipts. Swift never executes cells.
final class NotebookRemoteClient {
    let executable: String
    var endpoint = ""
    let token: URL
    init(executable: String, token: URL) { self.executable = executable; self.token = token }
    static func process(_ executable: String, _ arguments: [String], timeout: TimeInterval = 45) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process(), output = Pipe()
                    let errors = FileManager.default.temporaryDirectory.appendingPathComponent("sputnik-helper-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: errors, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                    defer { try? FileManager.default.removeItem(at: errors) }
                    let errorFile = errors.appendingPathComponent("stderr")
                    FileManager.default.createFile(atPath: errorFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    let errorHandle = try FileHandle(forWritingTo: errorFile)
                    defer { try? errorHandle.close() }
                    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = output; process.standardError = errorHandle
                    try process.run()
                    let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                    defer { deadline.cancel() }
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let text = String(decoding: (try? Data(contentsOf: errorFile)) ?? Data(), as: UTF8.self)
                        throw NotebookRemoteFailure(status: 0, message: text.isEmpty ? "Remote client exited (\(process.terminationStatus))." : text)
                    }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func call(_ arguments: [String]) async throws -> [String: Any] {
        let data = try await Self.process(executable, ["--mode", "cli", "--json-errors", "--url", endpoint,
                                                       "--token-file", token.path] + arguments)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotebookRemoteFailure(status: 0, message: "Invalid native remote client response.")
        }
        if let error = value["remote_error"] as? [String: Any] {
            let status = error["status"] as? Int ?? 0
            var message = error["message"] as? String ?? "Remote request failed."
            if status > 0, let start = message.range(of: ": "),
               let body = try? JSONSerialization.jsonObject(with: Data(message[start.upperBound...].utf8)) as? [String: Any],
               let detail = body["error"] as? String { message = detail }
            throw NotebookRemoteFailure(status: status, message: message)
        }
        return value
    }
}

struct NotebookWorkerSettings: Decodable {
    var environment_directory: String? = nil
    let grants: [String]
    let version: String
    let runtime_epoch: String?
}

final class NotebookRemoteController: ObservableObject {
    @Published private(set) var servers: [NotebookServer] = []
    @Published private(set) var selected: String?
    @Published private(set) var connected = false
    @Published private(set) var lastContact: Date? = nil
    @Published private(set) var busy = false
    @Published private(set) var status = "Local"
    @Published private(set) var conflict = false
    @Published private(set) var runs: [NotebookRemoteRun] = []
    @Published private(set) var runtimes: [[String: Any]] = []
    @Published private(set) var resetEpochs = Set<String>()
    @Published private(set) var projects: [[String: Any]] = []
    @Published private(set) var supportsWorkerGrants = false
    @Published private(set) var supportsCellInputs = false
    @Published private(set) var supportsRunDocument = false
    @Published private(set) var supportsDependencyManagement = false
    @Published private(set) var supportsPackageCatalog = false
    var dependencyOperationActive = false
    private(set) var frozenRunDocuments: Set<String> = []
    private var cellInputVersion = "0"
    var isSelected: Bool { selected != nil }
    var active: Bool { runs.contains { $0.active } }
    var serverName: String { servers.first { $0.id == selected }?.name ?? "Remote" }
    var projectID: String? { selected.flatMap { document.bindings[$0]?.project } }
    var hasPending: Bool { selected.flatMap { document.bindings[$0] }.map { $0.pendingUpload != nil || $0.pendingRun != nil || $0.pendingInputs != nil } ?? false }
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var onExternal: ((Bool) -> Void)?
    var onResultReset: ((String) -> Void)?
    var exportSnapshot: (() async throws -> NotebookRemoteExport)?
    var restoreSnapshot: ((String) async throws -> Void)?
    var importResult: ((String, String, String, Data, Bool) async throws -> Void)?
    var importLive: ((String, Data) async throws -> Void)?
    var importCellInputs: (([String: String]) async throws -> Void)?
    var focusedSheet: (() -> String?)?
    let storage: URL
    let executable: String
    private var local: URL?
    private var document = NotebookRemoteDocument()
    private var client: NotebookRemoteClient?
    private var tunnel: Process?
    private var generation = 0
    private var polling = false
    private var timer: Timer?
    private var syncTimer: Timer?
    private var dirty = 0
    private var pendingEdits = false
    private var completed = Set<String>()
    private var remoteHead: String?
    private var revisionDocuments: [String: String] = [:]
    private var recoveryConflict = false
    private var registryCommand = "runs"
    init(executable: String? = nil, storage: URL? = nil) {
        self.executable = executable ?? Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("sputnik-notebook-remote").path
        self.storage = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sputnik Notebook/Remote", isDirectory: true)
        if let data = try? Data(contentsOf: self.storage.appendingPathComponent("servers.json")),
           let saved = try? JSONDecoder().decode([NotebookServer].self, from: data) { servers = saved }
    }
    static func write(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        var created: [URL] = [], parent = url.deletingLastPathComponent()
        while !manager.fileExists(atPath: parent.path) { created.append(parent); parent.deleteLastPathComponent() }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        for path in [url, url.deletingLastPathComponent()] + created.map({ $0.deletingLastPathComponent() }) {
            let fd = Darwin.open(path.path, O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let result = fsync(fd), failure = errno
            Darwin.close(fd)
            if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
        }
    }
    private var bindingURL: URL? { local?.appendingPathComponent(".sputnik/remote.json") }
    private func save() throws {
        guard let url = bindingURL else { return }
        document.selected = selected
        try Self.write(try JSONEncoder().encode(document), to: url)
    }
    private func cache(_ suffix: String) throws -> URL {
        guard let selected, let projectID else { throw NotebookRemoteFailure(status: 0, message: "No remote project selected.") }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard [selected, projectID].allSatisfy({ !$0.isEmpty && $0.count <= 128 && $0.allSatisfy { allowed.contains($0) } }) else {
            throw NotebookRemoteFailure(status: 0, message: "Invalid remote binding identifier.")
        }
        guard !suffix.isEmpty, suffix.count <= 256, !suffix.hasPrefix("."), suffix.allSatisfy({ allowed.contains($0) || $0 == "." }) else {
            throw NotebookRemoteFailure(status: 0, message: "Invalid command journal entry.")
        }
        let directory = storage.appendingPathComponent(selected).appendingPathComponent(projectID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent(suffix)
    }
    private func cleanCommand(_ command: String) {
        for suffix in [".snapshot.json", ".request.json", ".run.json", ".inputs.json", ".input-request.json"] {
            if let path = try? cache(command + suffix) { try? FileManager.default.removeItem(at: path) }
        }
    }
    func discardLocalCheckpoint() throws {
        guard let selected else { return }
        document.bindings[selected]?.saved = nil
        document.bindings[selected]?.pendingSaved = nil
        try save()
    }
    @discardableResult func addServer(_ proposed: NotebookServer, token: String) throws -> String {
        var server = proposed
        guard !server.name.isEmpty, (1...65535).contains(server.sshPort), (1...65535).contains(server.remotePort),
              !server.ssh || (!server.host.isEmpty && !server.host.hasPrefix("-") && !server.host.contains(where: { $0.isWhitespace }) && server.root.hasPrefix("/")),
              server.ssh || (URL(string: server.url)?.scheme == "https" ||
                (URL(string: server.url)?.scheme == "http" && ["127.0.0.1", "localhost"].contains(URL(string: server.url)?.host ?? ""))) else {
            throw NotebookRemoteFailure(status: 0, message: "Enter a server name, valid address and ports. Direct connections require HTTPS or loopback HTTP.")
        }
        if let previous = servers.first(where: { $0.id == server.id }),
           previous.ssh != server.ssh || previous.host != server.host || previous.sshPort != server.sshPort ||
            previous.remotePort != server.remotePort || previous.root != server.root || previous.url != server.url {
            server.id = UUID().uuidString.lowercased() // Keep the old endpoint and its worker bindings reachable.
        }
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try Self.write(Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8),
                           to: storage.appendingPathComponent(server.id).appendingPathComponent("token"))
        }
        var next = servers; next.removeAll { $0.id == server.id }; next.append(server)
        try Self.write(try JSONEncoder().encode(next), to: storage.appendingPathComponent("servers.json"))
        servers = next
        return server.id
    }
    func open(_ url: URL) {
        detach(); local = url; selected = nil
        let metadata = url.appendingPathComponent(".sputnik/remote.json")
        if FileManager.default.fileExists(atPath: metadata.path) {
            do {
                document = try JSONDecoder().decode(NotebookRemoteDocument.self, from: Data(contentsOf: metadata))
                if let id = document.selected, document.bindings[id] == nil { throw NotebookRemoteFailure(status: 0, message: "Missing remote binding.") }
            } catch {
                document = NotebookRemoteDocument(); selected = "unavailable"
                status = "Remote binding unreadable"; onExternal?(true); onChange?()
                onError?("The remote binding could not be read. Choose a server to recover from its project list, or explicitly select This Mac.")
                return
            }
        } else { document = NotebookRemoteDocument() }
        selected = document.selected
        recoveryConflict = false
        onExternal?(isSelected); onChange?()
        if isSelected {
            let stamp = generation
            busy = true; status = "Restoring remote binding…"
            Task { @MainActor in
                do {
                    if let selected, let binding = document.bindings[selected], let checkpoint = binding.pendingExport ?? binding.exported,
                       let exportSnapshot {
                        let snapshot = try await exportSnapshot(); try check(stamp)
                        if snapshot.disk == (binding.pendingSaved ?? binding.saved) {
                            if checkpoint != snapshot.current { try await restoreSnapshot?(checkpoint); try check(stamp) }
                        } else if checkpoint != snapshot.current { recoveryConflict = true }
                    }
                    try check(stamp); busy = false; reconnect()
                } catch { fail(error, stamp) }
            }
        }
    }
    func choose(_ id: String?) {
        guard !busy, !dependencyOperationActive else { return }
        detach(); selected = id
        recoveryConflict = false
        if let id, document.bindings[id] == nil { document.bindings[id] = NotebookRemoteBinding() }
        do { try save() } catch { onError?(error.localizedDescription) }
        onExternal?(isSelected); onChange?()
        if isSelected { reconnect() }
    }
    func detach() {
        generation += 1; timer?.invalidate(); timer = nil; syncTimer?.invalidate(); syncTimer = nil
        if tunnel?.isRunning == true { tunnel?.terminate() }; tunnel = nil
        client = nil; connected = false; busy = false; polling = false; pendingEdits = false
        supportsWorkerGrants = false; supportsCellInputs = false; supportsRunDocument = false; supportsDependencyManagement = false; supportsPackageCatalog = false; frozenRunDocuments = []; cellInputVersion = "0"
        runs = []; runtimes = []; resetEpochs = []; projects = []; completed = []; revisionDocuments = [:]; remoteHead = nil; conflict = false
        status = isSelected ? "Disconnected · server work continues" : "Local"
        onChange?()
    }
    func discardPending() {
        guard !busy, let selected else { return }
        let commands = [document.bindings[selected]?.pendingRun?.command, document.bindings[selected]?.pendingUpload, document.bindings[selected]?.pendingInputs?.command].compactMap { $0 }
        document.bindings[selected]?.pendingRun = nil; document.bindings[selected]?.pendingUpload = nil
        document.bindings[selected]?.pendingExport = nil; document.bindings[selected]?.pendingSaved = nil
        document.bindings[selected]?.pendingInputs = nil
        do { try save(); commands.forEach { cleanCommand($0) }; reconnect() } catch { onError?(error.localizedDescription) }
    }
    private func check(_ stamp: Int) throws { if stamp != generation { throw CancellationError() } }
    private static func port() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }; defer { Darwin.close(fd) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw POSIXError(.EADDRINUSE) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }
    func reconnect() {
        guard !busy, isSelected else { return }
        guard let server = servers.first(where: { $0.id == selected }) else {
            status = "Server profile unavailable"
            onError?("This notebook refers to a server profile unavailable on this Mac. Configure the server in Servers, then recover the notebook from Projects, or explicitly choose This Mac.")
            onChange?(); return
        }
        detach(); let stamp = generation
        busy = true; status = "Connecting to \(server.name)…"; onChange?()
        Task { @MainActor in
            do {
                try check(stamp)
                let token = storage.appendingPathComponent(server.id).appendingPathComponent("token")
                let connection = NotebookRemoteClient(executable: executable, token: token)
                if server.ssh {
                    do {
                        let quoted = "'" + (server.root + "/token").replacingOccurrences(of: "'", with: "'\\''") + "'"
                        let value = try await NotebookRemoteClient.process("/usr/bin/ssh", ["-p", String(server.sshPort), "-o", "BatchMode=yes", server.host, "cat -- " + quoted], timeout: 15)
                        try check(stamp)
                        let secret = String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard secret.count == 64, secret.allSatisfy({ $0.isHexDigit }) else { throw NotebookRemoteFailure(status: 0, message: "Server returned an invalid credential.") }
                        try Self.write(Data(secret.utf8), to: token)
                    }
                    let port = try Self.port(), process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                    process.arguments = ["-N", "-p", String(server.sshPort), "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2", "-L", "127.0.0.1:\(port):127.0.0.1:\(server.remotePort)", server.host]
                    process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                    try process.run(); tunnel = process; connection.endpoint = "http://127.0.0.1:\(port)"
                } else { connection.endpoint = server.url.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
                var ready = false
                for _ in 0..<30 {
                    try check(stamp)
                    do {
                        let health = try await connection.call(["--command", "health"])
                        guard health["protocol"] as? Int == 1 else { throw NotebookRemoteFailure(status: 0, message: "Unsupported remote protocol.") }
                        guard (health["capabilities"] as? [String])?.contains("gui_reconnect") == true else {
                            throw NotebookRemoteFailure(status: 422, message: "Update the remote core to enable notebook interface connections.")
                        }
                        registryCommand = (health["capabilities"] as? [String])?.contains("compact_registry") == true ? "registry" : "runs"
                        supportsWorkerGrants = (health["capabilities"] as? [String])?.contains("worker_grants") == true
                        supportsCellInputs = (health["capabilities"] as? [String])?.contains("cell_inputs") == true
                        supportsRunDocument = (health["capabilities"] as? [String])?.contains("run_document") == true
                        supportsDependencyManagement = (health["capabilities"] as? [String])?.contains("dependency_management") == true
                        supportsPackageCatalog = (health["capabilities"] as? [String])?.contains("package_catalog") == true
                        ready = true; break
                    } catch {
                        if let error = error as? NotebookRemoteFailure, error.status != 0 { throw error }
                        if server.ssh && tunnel?.isRunning != true { throw NotebookRemoteFailure(status: 0, message: "SSH tunnel failed. Check host, port and SSH key access.") }
                        try await Task.sleep(nanoseconds: 150_000_000)
                    }
                }
                guard ready else { throw NotebookRemoteFailure(status: 0, message: "Remote server did not become ready.") }
                try check(stamp); client = connection; connected = true
                try await recover(stamp)
                try await refresh(stamp)
                try check(stamp)
                if document.bindings[server.id]?.revision == nil {
                    try await synchronize(stamp, force: true)
                    try await refresh(stamp)
                } else if !conflict, document.bindings[server.id]?.exported != nil {
                    try await synchronize(stamp, force: false)
                }
                try check(stamp); busy = false; status = conflict ? "Server revision changed" : "Connected to \(server.name)"
                startTimer(stamp); onChange?()
            } catch { fail(error, stamp) }
        }
    }
    private func fail(_ error: Error, _ stamp: Int) {
        guard stamp == generation, !(error is CancellationError) else { return }
        busy = false
        if let failure = error as? NotebookRemoteFailure, failure.status > 0 && failure.status != 401 {
            if failure.status == 409 && (failure.message.contains("revision") || failure.message.contains("project deleted")) { conflict = true }
            status = failure.message
        }
        else { connected = false; timer?.invalidate(); timer = nil; status = "Disconnected · server work continues" }
        onError?(error.localizedDescription); onChange?()
    }
    @MainActor private func recover(_ stamp: Int) async throws {
        try check(stamp)
        guard let client, let selected, var binding = document.bindings[selected] else { return }
        if let command = binding.pendingUpload {
            let response: [String: Any]
            do { response = try await client.call(["--command", "receipt", "--project", binding.project, "--command-id", command])["response"] as? [String: Any] ?? [:] }
            catch let error as NotebookRemoteFailure where error.status == 404 {
                response = try await client.call(["--command", "upload_prepared", "--project", binding.project, "--request-file", try cache(command + ".request.json").path])
            }
            try check(stamp)
            guard let revision = response["revision"] as? String else { throw NotebookRemoteFailure(status: 0, message: "Invalid upload receipt.") }
            binding.revision = revision; binding.exported = binding.pendingExport; binding.saved = binding.pendingSaved
            binding.pendingUpload = nil; binding.pendingExport = nil; binding.pendingSaved = nil
            document.bindings[selected] = binding; try save()
            cleanCommand(command)
        }
        if let pending = binding.pendingInputs {
            let ticket = try cache(pending.command + ".inputs.json")
            guard (try? JSONDecoder().decode(NotebookRemotePendingInputs.self, from: Data(contentsOf: ticket))) == pending else {
                throw NotebookRemoteFailure(status: 0, message: "Untrusted pending input edit in notebook metadata. Discard the pending command and apply inputs explicitly.")
            }
            do {
                do { _ = try await client.call(["--command", "receipt", "--project", binding.project, "--command-id", pending.command]) }
                catch let failure as NotebookRemoteFailure where failure.status == 404 { _ = try await submitInputs(pending, project: binding.project) }
            } catch {
                try check(stamp)
                if let failure = error as? NotebookRemoteFailure, failure.status > 0 {
                    binding.pendingInputs = nil; document.bindings[selected] = binding; try save(); cleanCommand(pending.command)
                }
                throw error
            }
            try check(stamp); binding.pendingInputs = nil; document.bindings[selected] = binding; try save(); cleanCommand(pending.command)
        }
        if let pending = binding.pendingRun {
            // A notebook sidecar is inert input, not permission to run code.
            // Only an exact command ticket in this app's private journal may
            // recover a Run whose acceptance response was lost.
            let ticket = try cache(pending.command + ".run.json")
            guard (try? JSONDecoder().decode(NotebookRemotePendingRun.self, from: Data(contentsOf: ticket))) == pending else {
                throw NotebookRemoteFailure(status: 0, message: "Untrusted pending Run in notebook metadata. Reconnect without that pending command and run explicitly.")
            }
            do {
                do { _ = try await client.call(["--command", "receipt", "--project", binding.project, "--command-id", pending.command]) }
                catch let error as NotebookRemoteFailure where error.status == 404 { _ = try await submit(pending, project: binding.project) }
            } catch {
                try check(stamp)
                if let failure = error as? NotebookRemoteFailure, failure.status > 0 {
                    binding.pendingRun = nil; document.bindings[selected] = binding; try save()
                    cleanCommand(pending.command)
                }
                throw error
            }
            try check(stamp); binding.pendingRun = nil; document.bindings[selected] = binding; try save()
            cleanCommand(pending.command)
        }
    }
    @MainActor private func submit(_ pending: NotebookRemotePendingRun, project: String) async throws -> [String: Any] {
        guard let client else { throw NotebookRemoteFailure(status: 0, message: "Not connected.") }
        return try await client.call(["--command", "run", "--project", project, "--command-id", pending.command,
                                      "--revision", pending.revision, "--sheet", pending.sheet, "--cell", pending.cell] + (pending.all ? ["--all"] : []))
    }
    @MainActor private func submitInputs(_ pending: NotebookRemotePendingInputs, project: String) async throws -> [String: Any] {
        guard let client else { throw NotebookRemoteFailure(status: 0, message: "Not connected.") }
        let body: [String: Any] = ["command_id": pending.command, "revision": pending.revision,
            "base_version": pending.version, "cell_id": pending.cell, "values": pending.values]
        let request = try cache(pending.command + ".input-request.json")
        try Self.write(try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), to: request)
        return try await client.call(["--command", "set_cell_inputs", "--project", project, "--request-file", request.path])
    }
    func setCellInputs(sheet: String, cell: String, values: [String: String], completion: @escaping (Bool) -> Void) {
        guard connected, !busy, !conflict, supportsCellInputs else {
            onError?(!supportsCellInputs && connected ? "Update the remote core and worker to apply cell parameters." : "Reconnect and finish synchronization before applying cell parameters.")
            completion(false); return
        }
        let stamp = generation; busy = true; onChange?()
        Task { @MainActor in
            do {
                try await synchronize(stamp, force: false)
                try await refresh(stamp); try check(stamp)
                guard let selected, let binding = document.bindings[selected], let revision = binding.revision else { throw CancellationError() }
                let pending = NotebookRemotePendingInputs(command: UUID().uuidString.lowercased(), revision: revision,
                    version: cellInputVersion, cell: cell, values: values)
                try Self.write(try JSONEncoder().encode(pending), to: cache(pending.command + ".inputs.json"))
                document.bindings[selected]?.pendingInputs = pending; try save()
                _ = try await submitInputs(pending, project: binding.project); try check(stamp)
                document.bindings[selected]?.pendingInputs = nil; try save(); cleanCommand(pending.command)
                try await refresh(stamp); try check(stamp)
                busy = false; status = "Parameters applied on \(serverName)"; onChange?(); completion(true)
            } catch {
                if stamp == generation, let failure = error as? NotebookRemoteFailure, failure.status > 0, let selected {
                    let command = document.bindings[selected]?.pendingInputs?.command
                    document.bindings[selected]?.pendingInputs = nil; try? save()
                    if let command { cleanCommand(command) }
                }
                fail(error, stamp); completion(false)
            }
        }
    }
    @MainActor private func synchronize(_ stamp: Int, force: Bool, publish: Bool = false) async throws {
        try check(stamp)
        while polling { try await Task.sleep(nanoseconds: 20_000_000); try check(stamp) }
        guard let client, let selected, var binding = document.bindings[selected], let local, let exportSnapshot else { return }
        try await recover(stamp)
        try check(stamp)
        guard let current = document.bindings[selected] else { throw CancellationError() }
        binding = current
        let editVersion = dirty
        let snapshotValue = try await exportSnapshot(); try check(stamp)
        let exported = snapshotValue.current
        if !force && binding.exported == exported {
            pendingEdits = dirty != editVersion
            return
        }
        if conflict && !publish { throw NotebookRemoteFailure(status: 409, message: "The server has a newer revision. Download it or explicitly publish your local version.") }
        let command = UUID().uuidString.lowercased(), snapshot = try cache(command + ".snapshot.json"), request = try cache(command + ".request.json")
        try Self.write(Data(exported.utf8), to: snapshot)
        var arguments = ["--command", "prepare", "--project", binding.project, "--command-id", command,
                         "--directory", local.path, "--snapshot-file", snapshot.path, "--request-file", request.path]
        if let base = publish ? remoteHead : binding.revision { arguments += ["--base", base] }
        _ = try await client.call(arguments); try check(stamp)
        binding.pendingUpload = command; binding.pendingExport = exported; binding.pendingSaved = snapshotValue.disk
        document.bindings[selected] = binding; try save()
        let response = try await client.call(["--command", "upload_prepared", "--project", binding.project, "--request-file", request.path])
        try check(stamp)
        guard let revision = response["revision"] as? String else { throw NotebookRemoteFailure(status: 0, message: "Invalid revision response.") }
        binding.revision = revision; binding.exported = exported; binding.saved = snapshotValue.disk
        binding.pendingUpload = nil; binding.pendingExport = nil; binding.pendingSaved = nil
        document.bindings[selected] = binding; remoteHead = revision; conflict = false; recoveryConflict = false; try save()
        cleanCommand(command)
        pendingEdits = dirty != editVersion
    }
    func sync(publish: Bool = false) {
        guard connected, !busy else { return }
        let stamp = generation, version = dirty; busy = true; onChange?()
        Task { @MainActor in
            do {
                try check(stamp)
                if publish, let selected {
                    let commands = [document.bindings[selected]?.pendingUpload, document.bindings[selected]?.pendingRun?.command, document.bindings[selected]?.pendingInputs?.command].compactMap { $0 }
                    document.bindings[selected]?.pendingUpload = nil; document.bindings[selected]?.pendingRun = nil
                    document.bindings[selected]?.pendingInputs = nil; try save()
                    commands.forEach { cleanCommand($0) }
                }
                try await synchronize(stamp, force: true, publish: publish)
                try await refresh(stamp); try check(stamp); busy = false; status = "Synced to \(serverName)"; onChange?()
                if dirty != version { edited() }
            } catch { fail(error, stamp) }
        }
    }
    func edited() {
        dirty += 1; pendingEdits = true; syncTimer?.invalidate()
        guard connected, !conflict else { return }
        status = "Local changes waiting to sync"; onChange?()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.busy { self.edited() } else { self.syncChanged() }
        }
    }
    private func syncChanged() {
        guard connected, !busy, !conflict else { return }
        let stamp = generation, version = dirty; busy = true
        Task { @MainActor in
            do { try await synchronize(stamp, force: false); try check(stamp); busy = false; status = "Synced to \(serverName)"; onChange?(); if dirty != version { edited() } }
            catch { fail(error, stamp) }
        }
    }
    func run(sheet: String, cell: String, all: Bool, completion: @escaping (Bool) -> Void) {
        guard connected, !busy else { onError?(connected ? "Wait for synchronization to finish before running." : "Reconnect to the selected server before running."); completion(false); return }
        let stamp = generation; busy = true; onChange?()
        Task { @MainActor in
            do {
                try await synchronize(stamp, force: true)
                guard let selected, var binding = document.bindings[selected], let revision = binding.revision else { throw CancellationError() }
                let pending = NotebookRemotePendingRun(command: UUID().uuidString.lowercased(), revision: revision, sheet: sheet, cell: cell, all: all)
                try Self.write(try JSONEncoder().encode(pending), to: try cache(pending.command + ".run.json"))
                binding.pendingRun = pending; document.bindings[selected] = binding; try save()
                _ = try await submit(pending, project: binding.project); try check(stamp)
                document.bindings[selected]?.pendingRun = nil; try save()
                cleanCommand(pending.command)
                try await refresh(stamp); try check(stamp); busy = false; status = "Connected to \(serverName)"; onChange?(); completion(true)
            } catch {
                if stamp == generation, let failure = error as? NotebookRemoteFailure, failure.status > 0, let selected {
                    let command = document.bindings[selected]?.pendingRun?.command
                    document.bindings[selected]?.pendingRun = nil; try? save()
                    if let command { cleanCommand(command) }
                }
                fail(error, stamp); completion(false)
            }
        }
    }
    func stop(sheet: String, force: Bool) {
        guard connected, let client, let run = runs.last(where: { $0.sheet == sheet && $0.active }) else { return }
        let stamp = generation
        Task { @MainActor in
            do {
                _ = try await client.call(["--command", "stop", "--run-id", run.id, "--epoch", run.epoch] + (force ? ["--force"] : []))
                try check(stamp)
                if !busy && !polling { try await refresh(stamp) }
            }
            catch { fail(error, stamp) }
        }
    }
    func restart(sheet: String) {
        guard connected, !busy, let client, let projectID else { return }
        let stamp = generation; busy = true
        Task { @MainActor in
            do {
                while polling { try await Task.sleep(nanoseconds: 20_000_000); try check(stamp) }
                try check(stamp)
                _ = try await client.call(["--command", "restart", "--project", projectID, "--sheet", sheet])
                try check(stamp); onResultReset?(sheet)
                try await refresh(stamp); try check(stamp); busy = false; status = "Connected to \(serverName)"; onChange?()
            }
            catch { fail(error, stamp) }
        }
    }
    @MainActor func workerSettings(sheet: String) async throws -> NotebookWorkerSettings {
        guard connected, !busy, let client, let projectID else {
            throw NotebookRemoteFailure(status: 409, message: "Reconnect and wait for synchronization before editing worker settings.")
        }
        guard supportsWorkerGrants else {
            throw NotebookRemoteFailure(status: 422, message: "Update the remote core and worker to enable grant settings.")
        }
        let stamp = generation
        let result = try await client.call(["--command", "worker_settings", "--project", projectID, "--sheet", sheet])
        try check(stamp)
        return try JSONDecoder().decode(NotebookWorkerSettings.self, from: JSONSerialization.data(withJSONObject: result))
    }
    @MainActor func dependencyRequest(_ command: String, body: [String: Any]? = nil, operation: String? = nil, synchronizeFiles: Bool = false) async throws -> [String: Any] {
        guard connected, !busy, supportsDependencyManagement, let client, let projectID else {
            throw NotebookFailure(message: "Connect to a core with dependency management support.")
        }
        if command == "package_catalog" && !supportsPackageCatalog {
            throw NotebookFailure(message: "Update the remote core to browse package versions and builds.")
        }
        let stamp = generation; busy = true; onChange?()
        defer { if stamp == generation { busy = false; onChange?() } }
        if synchronizeFiles { try await synchronize(stamp, force: true); try check(stamp) }
        var arguments = ["--command", command, "--project", projectID]
        if let operation { arguments += ["--run-id", operation] }
        if let body {
            let file = try cache((body["command_id"] as? String ?? UUID().uuidString) + ".dependency.json")
            // Keep the request beside CLI receipts, so a lost reply can be inspected.
            try Self.write(try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), to: file)
            arguments += ["--request-file", file.path]
        }
        let result = try await client.call(arguments); try check(stamp)
        if command == "change_dependency" {
            for runtime in runtimes { if let sheet = runtime["sheet_id"] as? String { onResultReset?(sheet) } }
        }
        return result
    }
    @MainActor func dependencyEnvironment(_ id: String) async throws -> [String: Any] {
        try await dependencyRequest("environment", operation: id)
    }
    @MainActor func configureWorker(sheet: String, grants: [String], environmentDirectory: String, settings: NotebookWorkerSettings) async throws {
        guard connected, !busy, supportsWorkerGrants, let client, let projectID else {
            throw NotebookRemoteFailure(status: 409, message: "Reconnect and wait for synchronization before applying worker settings.")
        }
        guard environmentDirectory.isEmpty || settings.environment_directory != nil else {
            throw NotebookRemoteFailure(status: 422, message: "Update the remote core to configure worker environments.")
        }
        let stamp = generation; busy = true; onChange?()
        defer { if stamp == generation { busy = false; onChange?() } }
        let request = try cache(UUID().uuidString.lowercased() + ".worker-settings.json")
        defer { try? FileManager.default.removeItem(at: request) }
        let body: [String: Any] = ["command_id": UUID().uuidString.lowercased(), "base_version": settings.version,
            "runtime_epoch": settings.runtime_epoch.map { $0 as Any } ?? NSNull(), "grants": grants,
            "environment_directory": environmentDirectory]
        try Self.write(try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), to: request)
        _ = try await client.call(["--command", "configure_worker", "--project", projectID, "--sheet", sheet, "--request-file", request.path])
        try check(stamp)
        onResultReset?(sheet)
        try await refresh(stamp); try check(stamp)
        status = "Worker settings updated · Run starts a fresh runtime"
    }
    private func startTimer(_ stamp: Int) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self, !self.busy, !self.polling, self.connected else { return }
            Task { @MainActor in
                do { try await self.refresh(stamp) } catch { self.fail(error, stamp) }
            }
        }
    }
    @MainActor private func refresh(_ stamp: Int) async throws {
        try check(stamp)
        while polling { try await Task.sleep(nanoseconds: 20_000_000); try check(stamp) }
        polling = true
        defer { if stamp == generation { polling = false } }
        guard let client, let selected, let binding = document.bindings[selected] else { return }
        do {
            let registry = try await client.call(["--command", registryCommand, "--project", binding.project]); try check(stamp)
            lastContact = Date()
            remoteHead = (registry["project"] as? [String: Any])?["head"] as? String
            conflict = recoveryConflict || remoteHead != binding.revision
            if conflict { status = "Server revision changed · choose which version to keep" }
            if let inputs = registry["cell_inputs"] as? [String: Any], let version = inputs["version"] as? String,
               let values = inputs["values"] as? [String: String] {
                cellInputVersion = version
                if !conflict && !pendingEdits { try await importCellInputs?(values); try check(stamp) }
            }
            let values = registry["runs"] as? [[String: Any]] ?? []
            runs = try values.map(NotebookRemoteRun.init); runtimes = registry["runtimes"] as? [[String: Any]] ?? []
            resetEpochs = Set(registry["reset_epochs"] as? [String] ?? [])
            var artifacts: [String: NotebookRemoteRun] = [:]
            for run in runs where !run.active && run.presentation && !resetEpochs.contains(run.epoch) { artifacts[run.sheet] = run }
            onChange?()
            let restore = artifacts.values.sorted(by: { $0.sheet < $1.sheet }) + runs.filter { $0.active }
            for run in restore {
                try check(stamp)
                if run.active && run.live && (focusedSheet == nil || focusedSheet?() == run.sheet) {
                    let output = try cache(run.id + "." + UUID().uuidString.lowercased() + ".live.bin")
                    defer { try? FileManager.default.removeItem(at: output) }
                    _ = try await client.call(["--command", "live", "--run-id", run.id, "--output", output.path]); try check(stamp)
                    let data = try Data(contentsOf: output)
                    try await importLive?(run.sheet, data)
                } else if !run.active && run.presentation && !completed.contains(run.id) {
                    let output = try cache(run.id + "." + UUID().uuidString.lowercased() + ".bin")
                    defer { try? FileManager.default.removeItem(at: output) }
                    _ = try await client.call(["--command", "presentation", "--run-id", run.id, "--output", output.path]); try check(stamp)
                    var source = revisionDocuments[run.revision]
                    if source == nil {
                        let record = try await client.call(["--command", "document", "--project", binding.project, "--revision", run.revision]); try check(stamp)
                        source = record["document"] as? String
                    }
                    if supportsRunDocument {
                        let execution = try await client.call(["--command", "status", "--run-id", run.id]); try check(stamp)
                        if let frozen = execution["execution_document"] as? String { source = frozen; frozenRunDocuments.insert(run.id) }
                    }
                    guard let source else { throw NotebookRemoteFailure(status: 0, message: "Execution revision is missing.") }
                    if !frozenRunDocuments.contains(run.id) { revisionDocuments[run.revision] = source }
                    try await importResult?(run.sheet, run.id, source, Data(contentsOf: output), run.revision != binding.revision || ((run.inputVersion ?? "0") != cellInputVersion))
                    try check(stamp); completed.insert(run.id)
                }
            }
        } catch let error as NotebookRemoteFailure where error.status == 404 && binding.revision == nil {
            remoteHead = nil; runs = []; runtimes = []; resetEpochs = []
        }
        if projects.isEmpty {
            projects = try await client.call(["--command", "projects"])["projects"] as? [[String: Any]] ?? []; try check(stamp)
        }
        onChange?()
    }
    func download(project: String, revision: String, to destination: URL, completion: @escaping (Bool) -> Void) {
        guard connected, !busy, let client, let selected else { completion(false); return }
        let stamp = generation; busy = true
        Task { @MainActor in
            do {
                _ = try await client.call(["--command", "checkout", "--project", project, "--revision", revision, "--directory", destination.path]); try check(stamp)
                var state = NotebookRemoteDocument(); state.selected = selected
                state.bindings[selected] = NotebookRemoteBinding(project: project, revision: revision)
                try Self.write(try JSONEncoder().encode(state), to: destination.appendingPathComponent(".sputnik/remote.json"))
                busy = false; onChange?(); completion(true)
            } catch { fail(error, stamp); completion(false) }
        }
    }
    func reloadProjects() {
        guard connected, let client else { return }
        let stamp = generation
        Task { @MainActor in
            do { let response = try await client.call(["--command", "projects"]); try check(stamp); projects = response["projects"] as? [[String: Any]] ?? [] }
            catch { fail(error, stamp) }
        }
    }
}

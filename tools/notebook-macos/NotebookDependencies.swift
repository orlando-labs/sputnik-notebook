import AppKit
import Combine
import Foundation

struct NotebookInstalledPackage: Decodable, Identifiable {
    let name: String, version: String
    let variant: String?
    let digest: String?
    var id: String { name + "@" + version + (variant.map { "/" + $0 } ?? "") }
}
struct NotebookDependencyEnvironment: Decodable, Identifiable {
    let id: String, state: String, directory: String
    let error: String?
}
struct NotebookDependencyJob: Decodable, Identifiable {
    let id: String, action: String, state: String
    let error: String?
    var active: Bool { ["queued", "running"].contains(state) }
}
struct NotebookDependencyInventory: Decodable {
    struct Ready: Decodable { let directory: String; let python_packages: String; let ruby_packages: String }
    var packages: [NotebookInstalledPackage] = []
    var environments: [NotebookDependencyEnvironment] = []
    var jobs: [NotebookDependencyJob] = []
    var ready: Ready?
}

struct NotebookPackageRelease: Decodable, Identifiable {
    let version: String
    let yanked: Bool
    var id: String { version }
    var stable: Bool { !version.contains("-") }
}
struct NotebookPackageVersions: Decodable {
    let package_ref: String
    let versions: [NotebookPackageRelease]
    var available: [NotebookPackageRelease] { versions.filter { !$0.yanked } }
    var latest: String? { available.first(where: \.stable)?.version ?? available.first?.version }
}
struct NotebookPackageVariant: Decodable, Identifiable {
    struct Selection: Decodable {
        let compatible: Bool, reason: String, backend: String, bundle: String
        let allow_native: Bool, build_from_source: Bool
    }
    struct Target: Decodable { let os: String?, arch: String?, min_os: String?, compute_backend: String? }
    let variant: String
    let target: Target?
    let native_mode: String?
    let size: UInt64?
    let host_selection: Selection
    var id: String { variant }
    var detail: String {
        var parts = [target?.os, target?.arch].compactMap { $0 }.filter { $0 != "any" }
        if let minimum = target?.min_os, !minimum.isEmpty { parts.append("OS ≥ " + minimum) }
        if host_selection.backend != "cpu" || target?.compute_backend == "cpu" { parts.append(host_selection.backend.uppercased()) }
        if native_mode == "prebuilt" { parts.append("Prebuilt") }
        if host_selection.build_from_source { parts.append("Build from source") }
        if host_selection.bundle != "none" { parts.append(host_selection.bundle.capitalized + " bundle") }
        if let size { parts.append(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)) }
        return parts.isEmpty ? "Portable Sputnik package" : parts.joined(separator: " · ")
    }
}
struct NotebookPackageVariants: Decodable {
    struct Host: Decodable { let os: String, arch: String }
    let package_ref: String, version: String
    let yanked: Bool
    let artifacts: [NotebookPackageVariant]
    let recommended_variant: String?
    let host: Host
}

// Only these authored inputs can be changed by the editor. Byte comparisons
// prevent overwriting a lockfile changed by an external package manager.
struct NotebookDependencyFiles {
    static let names = ["requirements.txt", "requirements.lock", "Gemfile", "Gemfile.lock"]
    let directory: URL
    private(set) var baseline: [String: Data] = [:]
    init(directory: URL) throws {
        self.directory = directory
        for name in Self.names { if let data = try read(name) { baseline[name] = data } }
    }
    func read(_ name: String) throws -> Data? {
        guard Self.names.contains(name) else { throw NotebookFailure(message: "Unsupported dependency file.") }
        let file = directory.appendingPathComponent(name)
        let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        if values?.isSymbolicLink == true { throw NotebookFailure(message: "Dependency files must be regular files: \(name)") }
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard (values?.fileSize ?? Int.max) <= 1_048_576 else { throw NotebookFailure(message: "Dependency file exceeds 1 MiB: \(name)") }
        return try Data(contentsOf: file)
    }
    func text(_ name: String) -> String { String(decoding: baseline[name] ?? Data(), as: UTF8.self) }
    mutating func save(_ changes: [String: String]) throws {
        // Validate the entire batch before writing any file.
        for (name, text) in changes {
            guard Data(text.utf8).count <= 1_048_576 else { throw NotebookFailure(message: "Dependency file exceeds 1 MiB.") }
            guard try read(name) == baseline[name] else { throw NotebookFailure(message: "\(name) changed on disk. Reload before saving.") }
        }
        for (name, text) in changes {
            let data = Data(text.utf8)
            if baseline[name] != data {
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                baseline[name] = data
            }
        }
    }
}

@MainActor
final class NotebookDependencyController: ObservableObject {
    @Published var inventory = NotebookDependencyInventory()
    @Published var requirementFile = "requirements.txt"
    @Published var requirements = ""
    @Published var gemfile = ""
    @Published var packageName = "" {
        didSet { if packageName.trimmingCharacters(in: .whitespacesAndNewlines) != oldValue.trimmingCharacters(in: .whitespacesAndNewlines) { clearPackageCatalog() } }
    }
    @Published private(set) var packageCatalog: NotebookPackageVersions?
    @Published private(set) var packageBuilds: NotebookPackageVariants?
    @Published private(set) var catalogBusy = false
    @Published private(set) var catalogError: String?
    @Published var packageSource = ""
    @Published var packageVersion = "" {
        didSet { if packageVersion != oldValue { packageBuilds = nil; registryVariant = "" } }
    }
    @Published var registryVariant = ""
    @Published var packageVariant = ""
    @Published var packageBackend = "cpu"
    @Published var packageBundle = "none"
    @Published var packageAllowNative = false
    @Published var packageBuildFromSource = false
    @Published var packageAllowNativeLarge = false
    @Published var python = "python3"
    @Published var ruby = "ruby"
    @Published var busy = false
    @Published var message = ""
    @Published var error: String?
    @Published var log = ""
    private let model: NotebookModel
    private let document: UUID
    private let execution: String?
    private var files: NotebookDependencyFiles?
    private var logTask: Task<Void, Never>?
    private var catalogGeneration = UUID()
    private var catalogName = ""
    var isRemote: Bool { execution != nil }
    var current: Bool { model.documentIdentity == document && model.remote.selected == execution }
    var canChange: Bool { current && !busy && !catalogBusy && !model.busy && !model.executingWorker && !model.remote.busy && !model.remote.active && !inventory.jobs.contains(where: \.active) }
    var manifestChanged: Bool { requirements != files?.text(requirementFile) || gemfile != files?.text("Gemfile") }
    var lockedPython: Bool { requirementFile == "requirements.lock" }

    init(model: NotebookModel) {
        self.model = model; document = model.documentIdentity; execution = model.remote.selected
        // A GUI launch does not inherit shell activation. Explicit executable
        // paths are available in this editor and passed only to preparation.
        python = ProcessInfo.processInfo.environment["SPUTNIK_PYTHON_EXECUTABLE"].flatMap { $0.isEmpty ? nil : $0 } ?? "python3"
    }
    func load(reloadFiles: Bool = false) async {
        guard current, !busy, !catalogBusy, let path = model.snapshot?.path else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            if files == nil || reloadFiles {
                files = try NotebookDependencyFiles(directory: URL(fileURLWithPath: path))
                requirementFile = files!.baseline["requirements.lock"] != nil ? "requirements.lock" : "requirements.txt"
                requirements = files!.text(requirementFile); gemfile = files!.text("Gemfile")
            }
            let value = try await status()
            guard current else { return }
            inventory = try decode(value)
            message = inventory.jobs.contains(where: \.active) ? "Installation continues on the server. Refresh to update." : "Ready"
        } catch { self.error = error.localizedDescription }
    }
    func save() async {
        await perform("Saving dependency files…") { try self.saveInputs() }
    }
    private func saveInputs() throws {
        guard var files else { throw NotebookFailure(message: "Reload dependency files first.") }
        var changes: [String: String] = [:]
        if requirements != files.text(requirementFile) { changes[requirementFile] = requirements }
        if gemfile != files.text("Gemfile") { changes["Gemfile"] = gemfile }
        try files.save(changes); self.files = files
    }
    func installPackage() async {
        var options: [String: Any] = ["local_source": true,
            "allow_native": packageAllowNative, "build_from_source": packageBuildFromSource,
            "allow_native_large": packageAllowNativeLarge]
        if packageBackend != "cpu" { options["backend"] = packageBackend }
        if packageBundle != "none" { options["bundle"] = packageBundle }
        let variant = packageVariant.trimmingCharacters(in: .whitespacesAndNewlines)
        if !variant.isEmpty { options["variant"] = variant }
        await change(action: "install_sputnik", source: packageSource.trimmingCharacters(in: .whitespacesAndNewlines), version: "", options: options)
    }
    var selectedPackageVariant: NotebookPackageVariant? { packageBuilds?.artifacts.first { $0.variant == registryVariant } }
    var canInstallRegistryPackage: Bool {
        canChange && catalogName == packageName.trimmingCharacters(in: .whitespacesAndNewlines) &&
        packageBuilds?.version == packageVersion && packageBuilds?.yanked == false &&
        selectedPackageVariant?.host_selection.compatible == true
    }
    private func clearPackageCatalog() {
        catalogGeneration = UUID(); catalogName = ""; packageCatalog = nil; packageBuilds = nil
        packageVersion = ""; registryVariant = ""; catalogError = nil
    }
    func findPackageVersions() async {
        guard current, !busy, !catalogBusy else { return }
        let name = packageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        clearPackageCatalog(); error = nil
        let generation = catalogGeneration
        catalogBusy = true
        defer { catalogBusy = false }
        do {
            let catalog: NotebookPackageVersions = try decode(await catalog(query: "versions", source: name))
            guard current, generation == catalogGeneration else { return }
            packageCatalog = catalog; catalogName = name
            packageVersion = catalog.latest ?? ""
            if packageVersion.isEmpty { catalogError = "No available releases in this registry."; return }
            try await fetchPackageVariants(generation: generation)
        } catch { if current && generation == catalogGeneration { catalogError = error.localizedDescription } }
    }
    func findPackageVariants() async {
        guard current, !busy, !catalogBusy, let catalog = packageCatalog,
              catalog.available.contains(where: { $0.version == packageVersion }) else { return }
        catalogGeneration = UUID()
        let generation = catalogGeneration
        packageBuilds = nil; registryVariant = ""; catalogError = nil; catalogBusy = true
        defer { catalogBusy = false }
        do { try await fetchPackageVariants(generation: generation) }
        catch { if current && generation == catalogGeneration { catalogError = error.localizedDescription } }
    }
    private func fetchPackageVariants(generation: UUID) async throws {
        guard let packageCatalog else { return }
        let version = packageVersion
        let builds: NotebookPackageVariants = try decode(await catalog(query: "variants", source: packageCatalog.package_ref + "@" + version))
        guard current, generation == catalogGeneration, packageVersion == version else { return }
        guard builds.package_ref == packageCatalog.package_ref, builds.version == version else { throw NotebookFailure(message: "Registry returned a different package release.") }
        packageBuilds = builds
        registryVariant = builds.artifacts.first { $0.variant == builds.recommended_variant && $0.host_selection.compatible }?.variant ?? ""
        if builds.yanked { catalogError = "This release has been withdrawn. Choose another version." }
    }
    private func catalog(query: String, source: String) async throws -> [String: Any] {
        let body: [String: Any] = ["query": query, "source": source, "command_id": UUID().uuidString.lowercased()]
        return isRemote ? try await model.remote.dependencyRequest("package_catalog", body: body) : try await local("catalog", body: body)
    }
    func installRegistryPackage() async {
        guard canInstallRegistryPackage, let build = selectedPackageVariant, let catalog = packageCatalog else { return }
        let selection = build.host_selection
        guard !selection.allow_native || packageAllowNative else { error = "Allow native code to install this build."; return }
        guard !selection.build_from_source || packageBuildFromSource else { error = "Allow building native code from source to install this build."; return }
        guard (build.size ?? 0) <= 67_108_864 || packageAllowNativeLarge else { error = "Allow packages up to 2 GiB to install this build."; return }
        await change(action: "install_sputnik", source: catalog.package_ref, version: packageVersion,
            options: ["variant": build.variant, "backend": selection.backend, "bundle": selection.bundle,
                "allow_native": packageAllowNative, "build_from_source": selection.build_from_source && packageBuildFromSource,
                "allow_native_large": packageAllowNativeLarge])
    }
    func chooseLocalPackage(_ path: String) {
        packageSource = path; packageVariant = ""; packageBackend = "cpu"; packageBundle = "none"
    }
    func removePackage(_ package: NotebookInstalledPackage) async {
        await change(action: "remove_sputnik", source: package.name, version: package.version,
            options: package.variant.map { ["variant": $0] } ?? [:])
    }
    func resolveRuby() async {
        await perform("Resolving Gemfile.lock…") {
            try self.saveInputs()
            let result = try await self.changeRequest(action: "lock_ruby", source: "", version: "")
            let resolved = try JSONSerialization.jsonObject(with: Data((result["result"] as? String ?? "{}").utf8)) as? [String: Any]
            guard let lock = resolved?["gemfile_lock"] as? String, var files = self.files else { throw NotebookFailure(message: "Bundler did not return a lockfile.") }
            // A changed Gemfile must not receive a lock from an older resolution.
            guard try files.read("Gemfile") == files.baseline["Gemfile"] else { throw NotebookFailure(message: "Gemfile changed while resolving. Reload and resolve again.") }
            try files.save(["Gemfile.lock": lock]); self.files = files
            self.message = "Gemfile.lock saved. Prepare the environment to install it."
        }
    }
    func prepare() async {
        await perform("Preparing Python / Ruby environment…") {
            try self.saveInputs()
            guard let files = self.files else { return }
            guard files.baseline[self.requirementFile] != nil || files.baseline["Gemfile"] != nil else { throw NotebookFailure(message: "Add Python requirements or a Gemfile before preparing an environment.") }
            let result: [String: Any]
            if self.isRemote {
                let accepted = try await self.model.remote.dependencyRequest("prepare_environment", body: ["command_id": UUID().uuidString.lowercased(), "retry": true], synchronizeFiles: true)
                guard let id = accepted["id"] as? String else { throw NotebookFailure(message: "No dependency manifest was found on the server.") }
                result = try await self.waitEnvironment(id)
            } else {
                // The operation is explicit; reset idle workers before a local
                // package change, without evaluating any cells.
                try await self.resetLocalWorkers()
                result = try await self.local("prepare")
                self.log = self.logs(result)
                guard result["state"] as? String == "ready" else { throw NotebookFailure(message: result["error"] as? String ?? "Environment preparation failed.") }
            }
            guard self.current else { throw CancellationError() }
            let directory = self.isRemote ? "" : (result["directory"] as? String ?? "")
            for tab in self.model.snapshot?.tabs ?? [] where !self.isRemote || tab.kind == "sheet" {
                let settings = try await self.model.workerSettings(for: tab)
                try await self.model.configureWorker(tab, text: settings.grants.joined(separator: "\n"), environmentDirectory: directory, settings: settings)
            }
            self.message = "Environment ready. Workers restarted; run cells when ready."
        }
    }
    private func resetLocalWorkers() async throws {
        for tab in model.snapshot?.tabs ?? [] {
            // Reapply the existing policy to retire the sheet and all of its
            // action/Periodic Work invocation worlds before changing libraries.
            let settings = try await model.workerSettings(for: tab)
            let success = await withCheckedContinuation { c in
                model.perform("worker_grants", tab: tab, text: settings.grants.joined(separator: "\n")) { c.resume(returning: $0) }
            }
            guard success else { throw NotebookFailure(message: model.error ?? "Could not restart worker.") }
        }
    }
    private func change(action: String, source: String, version: String, options: [String: Any] = [:]) async {
        await perform(action == "remove_sputnik" ? "Removing package…" : "Installing package…") {
            _ = try await self.changeRequest(action: action, source: source, version: version, options: options)
            self.message = "Package \(action == "remove_sputnik" ? "removed" : "installed"). Workers restarted; run cells when ready."
        }
    }
    private func changeRequest(action: String, source: String, version: String, options: [String: Any] = [:]) async throws -> [String: Any] {
        var body: [String: Any] = ["command_id": UUID().uuidString.lowercased(), "action": action, "source": source, "version": version]
        body.merge(options) { _, new in new }
        let result: [String: Any]
        if isRemote {
            let accepted = try await model.remote.dependencyRequest("change_dependency", body: body, synchronizeFiles: action == "lock_ruby")
            guard let id = accepted["id"] as? String else { throw NotebookFailure(message: "Invalid dependency operation.") }
            while true {
                let value = try await model.remote.dependencyRequest("dependency", operation: id)
                log = logs(value)
                if !["queued", "running"].contains(value["state"] as? String ?? "") { result = value; break }
                try await Task.sleep(nanoseconds: 750_000_000)
            }
        } else {
            try await resetLocalWorkers()
            result = try await local("change", body: body); log = logs(result)
        }
        guard result["state"] as? String == "succeeded" else { throw NotebookFailure(message: result["error"] as? String ?? "Dependency operation failed.") }
        return result
    }
    private func waitEnvironment(_ id: String) async throws -> [String: Any] {
        while true {
            let value = try await model.remote.dependencyEnvironment(id)
            log = logs(value)
            let state = value["state"] as? String ?? ""
            if state == "ready" { return value }
            if ["failed", "interrupted"].contains(state) { throw NotebookFailure(message: value["error"] as? String ?? "Installation failed.") }
            try await Task.sleep(nanoseconds: 750_000_000)
        }
    }
    func inspectJob(_ id: String) async {
        await perform("Loading installation log…", mutation: false) {
            let value = try await self.model.remote.dependencyRequest("dependency", operation: id)
            self.log = self.logs(value)
        }
    }
    private func perform(_ title: String, mutation: Bool = true, _ operation: () async throws -> Void) async {
        guard current, !busy, !catalogBusy, !model.busy, !model.remote.busy else { return }
        guard !mutation || canChange else { error = "Stop active runs and wait for dependency operations to finish."; return }
        busy = true; error = nil; message = title
        if mutation { model.pauseForDependencyChanges() }
        model.dependencyOperationActive = true; model.remote.dependencyOperationActive = true
        defer { busy = false; model.dependencyOperationActive = false; model.remote.dependencyOperationActive = false }
        do {
            try await operation()
            inventory = try decode(await status())
            if message == title { message = "Saved" }
        } catch { self.error = error.localizedDescription }
    }
    private func status() async throws -> [String: Any] {
        isRemote ? try await model.remote.dependencyRequest("dependencies") : try await local("status")
    }
    private func decode<T: Decodable>(_ value: [String: Any]) throws -> T { try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value)) }
    private func logs(_ value: [String: Any]) -> String { [value["stdout"] as? String, value["stderr"] as? String].compactMap { $0 }.joined(separator: "\n") }
    private func local(_ command: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard current, let path = model.snapshot?.path else { throw CancellationError() }
        let helper = model.remote.executable
        let compiler = ProcessInfo.processInfo.environment["SPUTNIK_COMPILER"] ?? URL(fileURLWithPath: helper).deletingLastPathComponent().appendingPathComponent("sputnik").path
        var arguments = ["--mode", "dependencies", "--directory", path, "--command", command, "--python", python, "--ruby", ruby, "--sputnik", compiler]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sputnik-dependency-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        if let body { try JSONSerialization.data(withJSONObject: body).write(to: file); arguments += ["--request-file", file.path] }
        if command != "status" && command != "catalog" {
            log = ""
            logTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 750_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.log = Self.localLog(directory: URL(fileURLWithPath: path))
                }
            }
        }
        defer { logTask?.cancel(); logTask = nil }
        let data = try await NotebookRemoteClient.process(helper, arguments, timeout: 3600)
        guard current, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NotebookFailure(message: "Invalid dependency helper response.") }
        return value
    }
    private static func localLog(directory: URL) -> String {
        let root = directory.appendingPathComponent(".sputnik/dependencies/projects/local")
        let manager = FileManager.default
        func children(_ url: URL) -> [URL] { (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
        let attempts = children(root.appendingPathComponent("operations")) + children(root.appendingPathComponent("environments")).flatMap(children)
        let logs = attempts.flatMap { [$0.appendingPathComponent("stdout.log"), $0.appendingPathComponent("stderr.log")] }
        guard let newest = logs.filter({ manager.fileExists(atPath: $0.path) }).max(by: {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }) else { return "" }
        return ["stdout.log", "stderr.log"].compactMap { name -> String? in
            guard let handle = try? FileHandle(forReadingFrom: newest.deletingLastPathComponent().appendingPathComponent(name)) else { return nil }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 65536 ? size - 65536 : 0)
            return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        }.joined(separator: "\n")
    }
}

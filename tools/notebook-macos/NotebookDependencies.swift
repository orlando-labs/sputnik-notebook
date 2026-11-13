import AppKit
import Combine
import Foundation

struct NotebookInstalledPackage: Decodable, Identifiable {
    let name: String, version: String
    var display_name: String? = nil
    let variant: String?
    let digest: String?
    let scope: String?
    private let missing: Bool?
    var id: String { name + "@" + version + (variant.map { "/" + $0 } ?? "") }
    var displayName: String { display_name ?? name.split(separator: "/").last.map(String.init) ?? name }
    var isMissing: Bool { missing == true }
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
    var package_scopes: [String]?
    var environments: [NotebookDependencyEnvironment] = []
    var jobs: [NotebookDependencyJob] = []
    var ready: Ready?
}

struct NotebookDependencyProgress {
    let detail: String
    let fraction: Double?

    init(log: String, fallback: String) {
        let line = log.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.last { !$0.isEmpty }
        detail = line ?? fallback
        // Only the current download has a measurable total. Subsequent stages
        // return to an indeterminate bar, including verification and builds.
        let pattern = #"^Downloading .+\s+(\d{1,3})% \([^\n]+\)$"#
        if let line, let match = line.range(of: pattern, options: .regularExpression),
           let percent = line[match].split(separator: "%").first?.split(separator: " ").last.flatMap({ Double($0) }),
           (0...100).contains(percent) {
            fraction = percent / 100
        } else { fraction = nil }
    }
}

struct NotebookPackageRelease: Decodable, Identifiable {
    let version: String
    let yanked: Bool
    let shared_installed: Bool?
    var id: String { version }
    var stable: Bool { !version.contains("-") }
}
struct NotebookPackageVersions: Decodable {
    let package_ref: String
    var displayName: String { package_ref.split(separator: "/").last.map(String.init) ?? package_ref }
    let versions: [NotebookPackageRelease]
    var available: [NotebookPackageRelease] { versions.filter { !$0.yanked } }
    var latest: String? { available.first(where: \.stable)?.version ?? available.first?.version }
}
struct NotebookPackageInstallOption: Decodable, Identifiable {
    let name: String, type: String, description: String, env: String
    let choices: [String]?
    var id: String { name }
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
    let shared_installed: Bool?
    let host_selection: Selection
    let runtime_grants: [String]?
    var install_options: [NotebookPackageInstallOption]? = nil
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
    enum GrantScope: String, CaseIterable {
        case selectedSheet, currentSheets, entireBook
        var title: String {
            switch self {
            case .selectedSheet: return "Selected sheet"
            case .currentSheets: return "Current sheets in this notebook"
            case .entireBook: return "Entire notebook, always"
            }
        }
    }
    struct GrantApproval {
        let scope: GrantScope
        let tabs: [NotebookTab]
        let missing: [String]
        var selectionID: String { scope.rawValue + ":" + tabs.map(\.id).sorted().joined(separator: ",") }
        var targetDescription: String {
            switch scope {
            case .selectedSheet: return tabs.first?.title ?? "selected sheet"
            case .currentSheets: return "all \(tabs.count) current sheets"
            case .entireBook: return "the entire notebook, including future sheets"
            }
        }
        init(scope: GrantScope, tabs: [NotebookTab], missing: [String]) { self.scope = scope; self.tabs = tabs; self.missing = missing }
        init(tab: NotebookTab, missing: [String]) { self.init(scope: .selectedSheet, tabs: [tab], missing: missing) }
    }
    private struct GrantUpdate {
        let tab: NotebookTab?
        let settings: NotebookWorkerSettings
        let missing: [String]
    }
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
    @Published var packageSource = "" {
        didSet {
            if packageSource != oldValue {
                localPackageGrants = nil; localGrantError = nil
                localInstallOptions = []; localInstallValues = [:]
            }
        }
    }
    @Published private(set) var workerGrantsError: String?
    @Published private var workerGrantSnapshot: (selectionID: String, grants: [[String]])?
    @Published var grantScope: GrantScope = .selectedSheet {
        didSet { if grantScope != oldValue { workerGrantSnapshot = nil; workerGrantsError = nil } }
    }
    @Published var workerSheetID = "" {
        didSet {
            if workerSheetID != oldValue { workerGrantSnapshot = nil; workerGrantsError = nil }
        }
    }
    @Published private(set) var localPackageGrants: [String]?
    @Published private(set) var localInstallOptions: [NotebookPackageInstallOption] = []
    @Published var registryInstallValues: [String: String] = [:]
    @Published var localInstallValues: [String: String] = [:]
    @Published private(set) var localGrantError: String?
    @Published var packageScope = "shared"
    @Published var packageVersion = "" {
        didSet { if packageVersion != oldValue { packageBuilds = nil; registryVariant = "" } }
    }
    @Published var registryVariant = "" {
        didSet {
            if registryVariant != oldValue {
                packageAllowNative = false; packageAllowNativeLarge = false; packageBuildFromSource = false
                registryInstallValues = [:]
            }
        }
    }
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
    @Published private(set) var operationStartedAt: Date?
    var progress: NotebookDependencyProgress { .init(log: log, fallback: message) }
    private let model: NotebookModel
    private let document: UUID
    private let execution: String?
    private var files: NotebookDependencyFiles?
    private var catalogGeneration = UUID()
    private var catalogName = ""
    var isRemote: Bool { execution != nil }
    var supportsLocalPackageScope: Bool { inventory.package_scopes?.contains("local") == true }
    var workerSheets: [NotebookTab] { model.snapshot?.tabs.filter { $0.kind == "sheet" } ?? [] }
    var executionTab: NotebookTab? { workerSheets.first { $0.id == workerSheetID } }
    private var grantTabs: [NotebookTab] {
        switch grantScope {
        case .selectedSheet: return executionTab.map { [$0] } ?? []
        case .currentSheets: return workerSheets
        case .entireBook: return []
        }
    }
    var grantSelectionID: String { GrantApproval(scope: grantScope, tabs: grantTabs, missing: []).selectionID }
    var grantTargetDescription: String { GrantApproval(scope: grantScope, tabs: grantTabs, missing: []).targetDescription }
    var grantScopeDetail: String {
        switch grantScope {
        case .selectedSheet: return "Add missing permissions only to the selected sheet."
        case .currentSheets: return "Add missing permissions to all \(workerSheets.count) existing sheets. New sheets will keep their own permissions."
        case .entireBook: return "Save permissions for this notebook on \(isRemote ? "the server" : "this Mac"). They apply to all current and future sheets, including after reopening the notebook."
        }
    }
    var current: Bool { model.documentIdentity == document && model.remote.selected == execution }
    var canChange: Bool { current && !busy && !catalogBusy && !model.busy && !model.executingWorker && !model.remote.busy && !model.remote.active && !inventory.jobs.contains(where: \.active) }
    var manifestChanged: Bool { requirements != files?.text(requirementFile) || gemfile != files?.text("Gemfile") }
    var lockedPython: Bool { requirementFile == "requirements.lock" }

    init(model: NotebookModel) {
        self.model = model; document = model.documentIdentity; execution = model.remote.selected
        let focused = model.activeBoard.flatMap { model.controller(for: $0) } ?? model.activeTab
        let sheets = model.snapshot?.tabs.filter { $0.kind == "sheet" } ?? []
        if let focused, focused.kind == "sheet" { workerSheetID = focused.id }
        else if sheets.count == 1 { workerSheetID = sheets[0].id }
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
            await refreshWorkerGrants()
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
    func installPackage(approval: GrantApproval? = nil) async {
        var options: [String: Any] = ["local_source": true, "scope": packageScope,
            "allow_native": packageAllowNative, "build_from_source": packageBuildFromSource,
            "allow_native_large": packageAllowNativeLarge]
        if packageBackend != "cpu" { options["backend"] = packageBackend }
        if packageBundle != "none" { options["bundle"] = packageBundle }
        let variant = packageVariant.trimmingCharacters(in: .whitespacesAndNewlines)
        if !variant.isEmpty { options["variant"] = variant }
        options["install_options"] = localInstallValues.filter { !$0.value.isEmpty }
        await change(action: "install_sputnik", source: packageSource.trimmingCharacters(in: .whitespacesAndNewlines),
                     version: "", options: options, required: localPackageGrants ?? [], approval: approval)
    }
    var selectedPackageVariant: NotebookPackageVariant? { packageBuilds?.artifacts.first { $0.variant == registryVariant } }
    static let nativeWorkerGrants = ["ffi.call=*", "ffi.load=*"]
    var registryPackageGrants: [String] {
        guard let build = selectedPackageVariant else { return [] }
        return build.runtime_grants ?? (build.host_selection.allow_native ? Self.nativeWorkerGrants : [])
    }
    private func effectiveGrants(_ grants: [String]) throws -> [String] {
        let native = Self.nativeWorkerGrants
        let missingNative = try missingWorkerGrants(native, from: grants)
        if model.hasNativeWorkerTrust || missingNative.isEmpty {
            return grants + native + ["fs.read=*"]
        }
        return grants
    }
    func refreshWorkerGrants() async {
        workerGrantSnapshot = nil; workerGrantsError = nil
        guard current, grantScope == .entireBook || !grantTabs.isEmpty else { return }
        let selection = grantSelectionID
        do {
            var grants: [[String]] = []
            if grantScope == .entireBook { grants = [try await model.bookWorkerSettings().grants] }
            else {
                for tab in grantTabs { grants.append(try await model.workerSettings(for: tab).grants) }
            }
            guard current, !Task.isCancelled, grantSelectionID == selection else { return }
            workerGrantSnapshot = (selection, grants)
        } catch {
            if current, !Task.isCancelled, grantSelectionID == selection { workerGrantsError = error.localizedDescription }
        }
    }
    func missingPackageGrants(_ required: [String]) -> [String]? {
        if required.isEmpty { return [] }
        guard let snapshot = workerGrantSnapshot, snapshot.selectionID == grantSelectionID else { return nil }
        do {
            var missing = Set<String>()
            for grants in snapshot.grants {
                let existing = grantScope == .entireBook ? grants : try effectiveGrants(grants)
                missing.formUnion(try missingWorkerGrants(required, from: existing))
            }
            return missing.sorted()
        }
        catch { return nil }
    }
    func grantApproval(_ required: [String]) -> GrantApproval? {
        guard let missing = missingPackageGrants(required), !missing.isEmpty else { return nil }
        return GrantApproval(scope: grantScope, tabs: grantTabs, missing: missing)
    }
    var reusesSharedPackage: Bool {
        packageScope == "shared" && selectedPackageVariant?.shared_installed == true &&
            registryInstallValues.values.allSatisfy(\.isEmpty)
    }
    var canInstallRegistryPackage: Bool {
        canChange && catalogName == packageName.trimmingCharacters(in: .whitespacesAndNewlines) &&
        packageBuilds?.version == packageVersion && packageBuilds?.yanked == false &&
        selectedPackageVariant?.host_selection.compatible == true
    }
    func packageGrantIssue(_ required: [String]) -> String? {
        guard !required.isEmpty else { return nil }
        if grantScope != .entireBook && grantTabs.isEmpty {
            return workerSheets.isEmpty
                ? "Create a sheet in this notebook to install packages that require runtime permissions."
                : "Choose a sheet for package permissions above to continue."
        }
        if let error = workerGrantsError { return "Could not check permissions for \(grantTargetDescription). " + error }
        return missingPackageGrants(required) == nil ? "Checking permissions for \(grantTargetDescription)…" : nil
    }
    var registryInstallIssue: String? {
        if !canChange {
            if model.executingWorker || model.remote.active { return "Stop active runs before installing packages." }
            return "Wait for the current operation to finish before installing packages."
        }
        guard canInstallRegistryPackage else {
            if packageBuilds?.yanked == true { return "This release has been withdrawn. Choose another version." }
            return "Choose a compatible package version and build to continue."
        }
        if let issue = packageGrantIssue(registryPackageGrants) { return issue }
        guard let build = selectedPackageVariant else { return nil }
        if build.host_selection.allow_native && !packageAllowNative { return "Enable Allow native code above to continue." }
        if !reusesSharedPackage && build.host_selection.build_from_source && !packageBuildFromSource {
            return "Enable Build native code from source above to continue."
        }
        if !reusesSharedPackage && (build.size ?? 0) > 67_108_864 && !packageAllowNativeLarge {
            return "Enable Allow packages up to 2 GiB above to continue."
        }
        return nil
    }
    private func clearPackageCatalog() {
        catalogGeneration = UUID(); catalogName = ""; packageCatalog = nil; packageBuilds = nil
        packageVersion = ""; registryVariant = ""; catalogError = nil
        packageAllowNative = false; packageAllowNativeLarge = false; packageBuildFromSource = false
        registryInstallValues = [:]
    }
    func findPackageVersions(for package: NotebookInstalledPackage? = nil) async {
        guard current, !busy, !catalogBusy else { return }
        if let package { packageName = package.name }
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
            packageVersion = catalog.available.first { $0.version == package?.version }?.version ?? catalog.latest ?? ""
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
        let shared = packageScope == "shared" ? builds.artifacts.first { $0.shared_installed == true && $0.host_selection.compatible } : nil
        registryVariant = shared?.variant ?? builds.artifacts.first { $0.variant == builds.recommended_variant && $0.host_selection.compatible }?.variant ?? ""
        if builds.yanked { catalogError = "This release has been withdrawn. Choose another version." }
    }
    private func catalog(query: String, source: String) async throws -> [String: Any] {
        let body: [String: Any] = ["query": query, "source": source, "command_id": UUID().uuidString.lowercased()]
        return isRemote ? try await model.remote.dependencyRequest("package_catalog", body: body) : try await local("catalog", body: body)
    }
    func installRegistryPackage(approval: GrantApproval? = nil) async {
        guard canInstallRegistryPackage, let build = selectedPackageVariant else { return }
        let selection = build.host_selection
        guard !selection.allow_native || packageAllowNative else { error = "Allow native code to install this build."; return }
        guard reusesSharedPackage || !selection.build_from_source || packageBuildFromSource else { error = "Allow building native code from source to install this build."; return }
        guard reusesSharedPackage || (build.size ?? 0) <= 67_108_864 || packageAllowNativeLarge else { error = "Allow packages up to 2 GiB to install this build."; return }
        await change(action: "install_sputnik", source: catalogName, version: packageVersion,
            options: ["scope": packageScope, "variant": build.variant, "backend": selection.backend, "bundle": selection.bundle,
                "install_options": registryInstallValues.filter { !$0.value.isEmpty },
                "allow_native": packageAllowNative, "build_from_source": selection.build_from_source && packageBuildFromSource,
                "allow_native_large": packageAllowNativeLarge], required: registryPackageGrants, approval: approval)
    }
    func addPackageGrants(_ required: [String], to tab: NotebookTab) async {
        guard tab.kind == "sheet", canChange, !required.isEmpty else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let settings = try await model.workerSettings(for: tab)
            guard current else { return }
            let missing = try missingWorkerGrants(required, from: effectiveGrants(settings.grants))
            guard !missing.isEmpty else { message = "This worker already has the package grants."; return }
            try await model.configureWorker(tab, text: ((settings.own_grants ?? settings.grants) + missing).joined(separator: "\n"), settings: settings)
            message = "Package grants added to \(tab.title). Run cells when ready."
        } catch { if current { self.error = error.localizedDescription } }
        await refreshWorkerGrants()
    }
    func addPackageGrants(approval: GrantApproval) async {
        await perform("Adding package permissions…") {
            let updates = try await self.checkedPackageGrants(approval.missing, approval: approval)
            try await self.applyPackageGrants(updates)
            self.message = "Package permissions added to \(approval.targetDescription). Run cells when ready."
        }
        await refreshWorkerGrants()
    }
    func chooseLocalPackage(_ path: String) {
        packageSource = path; packageVariant = ""; packageBackend = "cpu"; packageBundle = "none"
        localInstallOptions = []; localInstallValues = [:]
    }
    func inspectLocalPackageGrants() async {
        let path = packageSource.trimmingCharacters(in: .whitespacesAndNewlines)
        localPackageGrants = nil; localGrantError = nil
        guard path.hasPrefix("/") else { return }
        do {
            try await Task.sleep(nanoseconds: 350_000_000)
            let value = try await catalog(query: "inspect", source: path)
            guard !Task.isCancelled, current, packageSource.trimmingCharacters(in: .whitespacesAndNewlines) == path else { return }
            localPackageGrants = value["runtime_grants"] as? [String] ?? []
            if let definitions = value["install_options"] {
                localInstallOptions = try JSONDecoder().decode([NotebookPackageInstallOption].self,
                    from: JSONSerialization.data(withJSONObject: definitions))
            }
        } catch {
            if !Task.isCancelled, current, packageSource.trimmingCharacters(in: .whitespacesAndNewlines) == path {
                localGrantError = error.localizedDescription
            }
        }
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
                try await self.model.configureWorker(tab, text: (settings.own_grants ?? settings.grants).joined(separator: "\n"), environmentDirectory: directory, settings: settings)
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
                model.perform("worker_grants", tab: tab, text: (settings.own_grants ?? settings.grants).joined(separator: "\n")) { c.resume(returning: $0) }
            }
            guard success else { throw NotebookFailure(message: model.error ?? "Could not restart worker.") }
        }
    }
    private func change(action: String, source: String, version: String, options: [String: Any] = [:],
                        required: [String] = [], approval: GrantApproval? = nil) async {
        await perform(action == "remove_sputnik" ? "Removing package…" : "Installing package…") {
            if !required.isEmpty {
                _ = try await self.checkedPackageGrants(required, approval: approval)
            }
            _ = try await self.changeRequest(action: action, source: source, version: version, options: options)
            if !required.isEmpty {
                do {
                    let updates = try await self.checkedPackageGrants(required, approval: approval)
                    if updates.contains(where: { !$0.missing.isEmpty }) {
                        try await self.applyPackageGrants(updates)
                        self.message = "Package ready for \(self.grantTargetDescription). Run cells when ready."
                        return
                    }
                } catch {
                    self.inventory = (try? self.decode(await self.status())) ?? self.inventory
                    throw NotebookFailure(message: "Package installed, but worker grants could not be applied. " + error.localizedDescription)
                }
            }
            self.message = "Package \(action == "remove_sputnik" ? "removed" : "installed"). Workers restarted; run cells when ready."
        }
        await refreshWorkerGrants()
    }
    private func checkedPackageGrants(_ required: [String], approval: GrantApproval?) async throws -> [GrantUpdate] {
        guard current, grantScope == .entireBook || !grantTabs.isEmpty else {
            throw NotebookFailure(message: "Choose which sheets will receive package permissions.")
        }
        let selection = grantSelectionID
        if let approval, approval.selectionID != selection {
            throw NotebookFailure(message: "The permission scope changed. Review and confirm it again.")
        }
        var targets: [(NotebookTab?, NotebookWorkerSettings)] = []
        if grantScope == .entireBook { targets.append((nil, try await model.bookWorkerSettings())) }
        else {
            for tab in grantTabs { targets.append((tab, try await model.workerSettings(for: tab))) }
        }
        guard current, grantSelectionID == selection else { throw CancellationError() }
        return try targets.map { tab, settings in
            let existing = tab == nil ? settings.grants : try effectiveGrants(settings.grants)
            let missing = try missingWorkerGrants(required, from: existing)
            guard Set(missing).isSubset(of: Set(approval?.missing ?? [])) else {
                throw NotebookFailure(message: "Worker grants changed. Review and confirm the missing grants.")
            }
            return GrantUpdate(tab: tab, settings: settings, missing: missing)
        }
    }
    private func applyPackageGrants(_ updates: [GrantUpdate]) async throws {
        for update in updates where !update.missing.isEmpty {
            let grants = (update.settings.own_grants ?? update.settings.grants) + update.missing
            if let tab = update.tab {
                try await model.configureWorker(tab, text: grants.joined(separator: "\n"), settings: update.settings)
            } else {
                try await model.configureBookWorkerGrants(grants, settings: update.settings)
            }
        }
    }
    private func changeRequest(action: String, source: String, version: String, options: [String: Any] = [:]) async throws -> [String: Any] {
        if options["scope"] as? String == "local" && !supportsLocalPackageScope {
            throw NotebookFailure(message: "This Core does not support notebook-only package storage.")
        }
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
        if mutation { log = ""; operationStartedAt = Date() }
        if mutation { model.pauseForDependencyChanges() }
        model.dependencyOperationActive = true; model.remote.dependencyOperationActive = true
        defer { busy = false; operationStartedAt = nil; model.dependencyOperationActive = false; model.remote.dependencyOperationActive = false }
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
    private func logs(_ value: [String: Any]) -> String {
        [value["stdout"] as? String, value["stderr"] as? String].compactMap { $0 }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
    }
    private func local(_ command: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard current, let path = model.snapshot?.path else { throw CancellationError() }
        let helper = model.remote.executable
        let compiler = ProcessInfo.processInfo.environment["SPUTNIK_COMPILER"] ?? URL(fileURLWithPath: helper).deletingLastPathComponent().appendingPathComponent("sputnik").path
        var arguments = ["--mode", "dependencies", "--json-errors", "--directory", path, "--command", command, "--python", python, "--ruby", ruby, "--sputnik", compiler]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sputnik-dependency-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        if let body { try JSONSerialization.data(withJSONObject: body).write(to: file); arguments += ["--request-file", file.path] }
        let directory = URL(fileURLWithPath: path)
        let previousAttempts = Set(Self.localLogAttempts(directory: directory))
        let streamsLogs = command != "status" && command != "catalog"
        var logTask: Task<Void, Never>?
        if streamsLogs {
            log = ""
            logTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled, let self, self.current else { return }
                    self.log = Self.localLog(directory: directory, excluding: previousAttempts)
                }
            }
        }
        defer {
            logTask?.cancel()
            if streamsLogs, current { log = Self.localLog(directory: directory, excluding: previousAttempts) }
        }
        let data = try await NotebookRemoteClient.process(helper, arguments, timeout: 3600)
        guard current else { throw CancellationError() }
        return try NotebookRemoteClient.response(data, invalidMessage: "Invalid dependency helper response.")
    }
    private static func localLogAttempts(directory: URL) -> [URL] {
        let root = directory.appendingPathComponent(".sputnik/dependencies/projects/local")
        let manager = FileManager.default
        func children(_ url: URL) -> [URL] { (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
        return children(root.appendingPathComponent("operations")) + children(root.appendingPathComponent("environments")).flatMap(children)
    }
    private static func localLog(directory: URL, excluding previousAttempts: Set<URL>) -> String {
        let manager = FileManager.default
        // Never show an earlier installation's success/error while a new job
        // is still starting or has not produced output yet.
        let attempts = localLogAttempts(directory: directory).filter { !previousAttempts.contains($0) }
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
        }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
    }
}

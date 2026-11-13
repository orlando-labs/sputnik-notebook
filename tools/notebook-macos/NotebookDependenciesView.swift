import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct NotebookDependenciesView: View {
    @ObservedObject var model: NotebookModel
    @ObservedObject var remote: NotebookRemoteController
    @StateObject private var controller: NotebookDependencyController
    @Environment(\.dismiss) private var dismiss
    @State private var ecosystem = "Sputnik"
    @State private var declaration = ""
    @State private var removing: NotebookInstalledPackage?
    @State private var showLog = false
    @State private var workerSettingsTarget: NotebookTab?
    @State private var showBookPermissions = false
    @State private var showNativeOptions = false
    private enum GrantAction { case registry, local, grantsOnly }
    private struct GrantChange {
        let approval: NotebookDependencyController.GrantApproval
        let action: GrantAction
        let title: String
    }
    @State private var grantChange: GrantChange?

    init(model: NotebookModel, initialEcosystem: String = "Sputnik", controller: NotebookDependencyController? = nil) {
        self.model = model; remote = model.remote
        _controller = StateObject(wrappedValue: controller ?? NotebookDependencyController(model: model))
        _ecosystem = State(initialValue: initialEcosystem)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Dependencies").font(.title2)
                    Text("\(model.snapshot?.title ?? "Notebook") · \(controller.isRemote ? remote.serverName : "This Mac")")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { Task { await controller.load() } }.disabled(controller.busy || controller.catalogBusy)
            }
            Picker("Packages", selection: $ecosystem) {
                Text("Sputnik").tag("Sputnik"); Text("Python / venv").tag("Python"); Text("Ruby / Bundler").tag("Ruby")
            }.pickerStyle(.segmented).accessibilityIdentifier("dependency-ecosystem")
            Group {
                if ecosystem == "Sputnik" { sputnik }
                else { foreign }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                if controller.busy || controller.catalogBusy { ProgressView().controlSize(.small) }
                Text(controller.catalogBusy ? "Loading package versions and builds…" : controller.message).font(.callout)
                Spacer()
                if let started = controller.operationStartedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        let elapsed = max(0, Int(context.date.timeIntervalSince(started)))
                        Text(String(format: "%d:%02d", elapsed / 60, elapsed % 60))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .accessibilityLabel("Elapsed time")
                    }
                }
                Button(showLog ? "Hide Log" : "Show Log") { showLog.toggle() }
            }
            if controller.operationStartedAt != nil {
                let progress = controller.progress
                VStack(alignment: .leading, spacing: 6) {
                    Text(progress.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    ProgressView(value: progress.fraction).progressViewStyle(.linear)
                        .accessibilityLabel("Dependency installation progress")
                }
            }
            if let error = controller.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if showLog {
                ScrollView { Text(controller.log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No installer output yet." : controller.log)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 125).padding(8).background(NotebookPalette.card, in: RoundedRectangle(cornerRadius: 6))
            }
            Text("Installing or removing dependencies restarts idle workers. Stop active runs first; run cells again when ready.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Reload Files") { Task { await controller.load(reloadFiles: true) } }.disabled(controller.busy || controller.catalogBusy)
                Spacer()
                if controller.manifestChanged { Button("Save Files") { Task { await controller.save() } }.disabled(!controller.canChange) }
                if controller.manifestChanged { Button("Discard and Close") { dismiss() }.disabled(controller.busy || controller.catalogBusy) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(controller.busy || controller.manifestChanged)
            }
        }.padding(24).frame(width: 780, height: showLog ? 830 : 690)
            .foregroundStyle(NotebookPalette.ink).background(NotebookPalette.canvas)
            .interactiveDismissDisabled(controller.busy || controller.manifestChanged)
            .task { await controller.load() }
            .onChange(of: controller.operationStartedAt, initial: true) { _, started in
                if started != nil { showLog = true }
            }
            .task(id: controller.grantSelectionID) {
                grantChange = nil
                await controller.refreshWorkerGrants()
            }
            .sheet(item: $workerSettingsTarget, onDismiss: { Task { await controller.refreshWorkerGrants() } }) { tab in
                NotebookWorkerSettingsEditor(model: model, remote: remote, tab: tab,
                    document: model.documentIdentity, execution: remote.selected)
            }
            .sheet(isPresented: $showBookPermissions, onDismiss: { Task { await controller.refreshWorkerGrants() } }) {
                NotebookWorkerSettingsEditor(model: model, remote: remote, tab: nil,
                    document: model.documentIdentity, execution: remote.selected)
            }
            .confirmationDialog("Remove \(removing?.id ?? "package") from this notebook?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                if let package = removing {
                    Button("Remove Package", role: .destructive) { removing = nil; Task { await controller.removePackage(package) } }
                }
                Button("Cancel", role: .cancel) { removing = nil }
            }
            .confirmationDialog("Add grants to \(grantChange?.approval.targetDescription ?? "the selected sheets")?", isPresented: Binding(get: { grantChange != nil }, set: { if !$0 { grantChange = nil } }), titleVisibility: .visible) {
                if let change = grantChange {
                    Button(change.title) {
                        grantChange = nil
                        Task {
                            switch change.action {
                            case .registry: await controller.installRegistryPackage(approval: change.approval)
                            case .local: await controller.installPackage(approval: change.approval)
                            case .grantsOnly: await controller.addPackageGrants(approval: change.approval)
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) { grantChange = nil }
            } message: {
                Text((grantChange?.approval.missing ?? []).joined(separator: "\n") + "\n\n" +
                    (grantChange?.approval.scope == .entireBook
                        ? "These permissions will also apply to future sheets and remain after reopening this notebook. Current workers will restart."
                        : "Applying changes restarts the affected workers. New sheets keep their own permissions."))
            }
    }
    private var sputnik: some View {
        ScrollViewReader { scroll in
            ScrollView { sputnikContent(scroll) }
        }
    }
    private func sputnikContent(_ scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notebook packages").font(.headline)
            List {
                if controller.inventory.packages.isEmpty { Text("No Sputnik packages installed here.").foregroundStyle(.secondary) }
                ForEach(controller.inventory.packages) { package in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(package.displayName, systemImage: "shippingbox").help(package.name)
                            if let variant = package.variant {
                                Text(variant).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .help(package.digest ?? variant).textSelection(.enabled)
                            }
                        }
                        if !package.version.isEmpty { Text(package.version).foregroundStyle(.secondary) }
                        if let scope = package.scope { Text(scope == "shared" ? "Shared" : "This notebook").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if package.isMissing {
                            Label("Missing", systemImage: "exclamationmark.triangle").foregroundStyle(NotebookPalette.sputnik)
                            Button("Find in Registry…") {
                                scroll.scrollTo("registry-installer", anchor: .top)
                                Task { await controller.findPackageVersions(for: package) }
                            }.disabled(controller.busy || controller.catalogBusy)
                            .accessibilityIdentifier("dependency-find-missing-" + package.name)
                        } else {
                            Button("Remove", role: .destructive) { removing = package }.disabled(!controller.canChange)
                        }
                    }
                }
            }.frame(height: controller.inventory.packages.isEmpty ? 48 : 125)
            Divider()
            Picker("Package storage", selection: $controller.packageScope) {
                Text(controller.isRemote ? "Shared on server" : "Shared on this Mac").tag("shared")
                if controller.supportsLocalPackageScope { Text("This notebook only").tag("local") }
            }.disabled(!controller.canChange).accessibilityIdentifier("dependency-package-scope")
            VStack(alignment: .leading, spacing: 5) {
                Picker("Package permissions", selection: $controller.grantScope) {
                    ForEach(NotebookDependencyController.GrantScope.allCases, id: \.self) { scope in Text(scope.title).tag(scope) }
                }.disabled(!controller.canChange).accessibilityIdentifier("dependency-grant-scope")
                if controller.grantScope == .selectedSheet {
                    Picker("Sheet for package permissions", selection: $controller.workerSheetID) {
                        Text(controller.workerSheets.isEmpty ? "No sheets in this notebook" : "Choose a sheet…").tag("")
                        ForEach(controller.workerSheets) { tab in Text(tab.title).tag(tab.id) }
                    }.disabled(!controller.canChange || controller.workerSheets.isEmpty)
                        .accessibilityIdentifier("dependency-worker-sheet")
                }
                Text(controller.grantScopeDetail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            registryInstaller.id("registry-installer")
            Divider()
            localInstaller
            Text(controller.isRemote
                ? "Names use the server's configured Sputnik registry. Paths refer to the server. Shared server packages remain available to imports."
                : "Names use the configured Sputnik registry. Packages installed here take priority over the shared package store.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Native packages require native trust or ffi.call and ffi.load worker grants.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Grant Native Execution…") { requestGrants(NotebookDependencyController.nativeWorkerGrants, action: .grantsOnly) }
                    .disabled(!controller.canChange || controller.missingPackageGrants(NotebookDependencyController.nativeWorkerGrants) == nil)
                if controller.grantScope != .currentSheets {
                    Button(controller.grantScope == .entireBook ? "Notebook Permissions…" : "Worker Settings…") {
                        if controller.grantScope == .entireBook { showBookPermissions = true }
                        else { workerSettingsTarget = controller.executionTab }
                    }.disabled(!controller.canChange || (controller.grantScope == .selectedSheet && controller.executionTab == nil))
                }
            }
            if !(model.snapshot?.dependencies ?? []).isEmpty {
                Text("Linked source directories").font(.headline)
                ForEach(model.snapshot?.dependencies ?? []) { item in
                    HStack {
                        Label(item.path, systemImage: "link").lineLimit(1).help(item.path)
                        Spacer()
                        Button("Unlink") { model.perform("remove_dependency", text: item.path) }.disabled(!controller.canChange || controller.isRemote)
                    }.font(.caption)
                }
            }
            if controller.isRemote, !controller.inventory.jobs.isEmpty {
                HStack {
                    Text("Last operation: \(controller.inventory.jobs.first!.state)").font(.caption)
                    Spacer()
                    Button("View Log") { showLog = true; Task { await controller.inspectJob(controller.inventory.jobs.first!.id) } }.disabled(controller.busy || controller.catalogBusy)
                }
            }
        }
    }
    private var registryInstaller: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Install from registry").font(.headline)
            HStack {
                TextField("Package name, e.g. sqlite3 or publisher/package", text: $controller.packageName)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("dependency-package-source")
                    .onSubmit { Task { await controller.findPackageVersions() } }
                Button("Find Versions") { Task { await controller.findPackageVersions() } }
                    .disabled(controller.busy || controller.catalogBusy || controller.packageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("dependency-find-versions")
            }
            if let catalog = controller.packageCatalog, !catalog.available.isEmpty {
                HStack {
                    Picker("Version", selection: Binding(get: { controller.packageVersion }, set: { version in
                        controller.packageVersion = version
                        Task { await controller.findPackageVariants() }
                    })) {
                        ForEach(catalog.available) { release in
                            Text(release.version + (release.version == catalog.latest ? " (Latest)" : "") +
                                (release.shared_installed == true ? " · Installed in shared store" : "")).tag(release.version)
                        }
                    }.frame(width: 260).accessibilityIdentifier("dependency-package-version")
                    Text(catalog.displayName).font(.caption).foregroundStyle(.secondary).help(catalog.package_ref).textSelection(.enabled)
                    Spacer()
                }.disabled(controller.busy || controller.catalogBusy)
            }
            if let builds = controller.packageBuilds {
                Picker("Build", selection: $controller.registryVariant) {
                    if controller.registryVariant.isEmpty { Text("No compatible build").tag("") }
                    ForEach(builds.artifacts) { build in
                        Text(build.variant + (build.variant == builds.recommended_variant ? " (Recommended)" : "") +
                            (build.shared_installed == true ? " · Installed in shared store" : "") +
                            (build.host_selection.compatible ? "" : " — " + build.host_selection.reason))
                            .tag(build.variant).disabled(!build.host_selection.compatible)
                    }
                }.disabled(!controller.canChange).accessibilityIdentifier("dependency-package-variant")
                if let build = controller.selectedPackageVariant {
                    Text(build.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    packageOptions(build.install_options ?? [], values: $controller.registryInstallValues)
                    packageGrants(controller.registryPackageGrants)
                    if controller.reusesSharedPackage {
                        Text("This build is already installed in the shared store. No download is needed.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if build.host_selection.allow_native {
                        Text("Allow native code permits installation. Missing runtime permissions will be added to the chosen scope after confirmation.")
                            .font(.callout).foregroundStyle(NotebookPalette.sputnik)
                    }
                    if build.host_selection.allow_native {
                        Toggle("Allow native code", isOn: $controller.packageAllowNative)
                    }
                    if !controller.reusesSharedPackage && build.host_selection.build_from_source {
                        Toggle("Build native code from source", isOn: $controller.packageBuildFromSource)
                    }
                    if !controller.reusesSharedPackage && (build.size ?? 0) > 67_108_864 {
                        Toggle("Allow packages up to 2 GiB", isOn: $controller.packageAllowNativeLarge)
                    }
                } else {
                    Text("No build of this version is compatible with the execution machine. Choose another version.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Checked for \(builds.host.os) / \(builds.host.arch) on \(controller.isRemote ? "the server" : "this Mac").")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    let required = controller.registryPackageGrants
                    Button(packageActionTitle(controller.reusesSharedPackage ? "Use Installed Package" : "Install Package", required)) {
                        requestGrants(required, action: .registry)
                    }
                        .disabled(controller.registryInstallIssue != nil)
                        .accessibilityIdentifier("dependency-install-sputnik")
                }
                if let issue = controller.registryInstallIssue {
                    Text(issue).font(.callout).foregroundStyle(NotebookPalette.sputnik)
                        .accessibilityIdentifier("dependency-install-reason")
                }
            }
            if let error = controller.catalogError { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
    private var localInstaller: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(controller.isRemote ? "Or install from a server path" : "Or install from a local package").font(.headline)
                Spacer()
                if !controller.isRemote {
                    Button("Choose Folder or .sputnikpkg…") {
                        let panel = NSOpenPanel()
                        panel.title = "Install a local Sputnik package"
                        panel.prompt = "Choose Package"
                        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
                        panel.allowedContentTypes = [UTType(filenameExtension: "sputnikpkg") ?? .data]
                        if panel.runModal() == .OK, let url = panel.url { controller.chooseLocalPackage(url.path) }
                    }.disabled(!controller.canChange).accessibilityIdentifier("dependency-choose-local")
                }
            }
            if controller.isRemote {
                TextField("Source directory or .sputnikpkg path on the server", text: $controller.packageSource)
                    .textFieldStyle(.roundedBorder).disabled(!controller.canChange)
            }
            if !controller.packageSource.isEmpty {
                packageOptions(controller.localInstallOptions, values: $controller.localInstallValues)
                if let grants = controller.localPackageGrants { packageGrants(grants) }
                else if let error = controller.localGrantError {
                    Text("Could not read package grants. " + error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                } else if controller.packageSource.hasPrefix("/") {
                    Text("Reading package grants…").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if !controller.isRemote {
                        Label(URL(fileURLWithPath: controller.packageSource).lastPathComponent, systemImage: "shippingbox")
                            .lineLimit(1).help(controller.packageSource)
                    }
                    Spacer()
                    let required = controller.localPackageGrants ?? []
                    Button(packageActionTitle("Install Local Package", required)) { requestGrants(required, action: .local) }
                        .disabled(!controller.canChange || controller.packageSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            controller.missingPackageGrants(required) == nil ||
                            (controller.packageSource.hasPrefix("/") && controller.localPackageGrants == nil && controller.localGrantError == nil))
                        .accessibilityIdentifier("dependency-install-local")
                }
                if let issue = controller.packageGrantIssue(controller.localPackageGrants ?? []) {
                    Text(issue).font(.callout).foregroundStyle(NotebookPalette.sputnik)
                }
                DisclosureGroup("Local installation options", isExpanded: $showNativeOptions) {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Allow native code", isOn: $controller.packageAllowNative)
                        Toggle("Build native code from source", isOn: $controller.packageBuildFromSource)
                        Toggle("Allow packages up to 2 GiB", isOn: $controller.packageAllowNativeLarge)
                    }.padding(.top, 4)
                }.disabled(!controller.canChange)
            }
        }.task(id: controller.packageSource) { await controller.inspectLocalPackageGrants() }
    }
    @ViewBuilder
    private func packageOptions(_ definitions: [NotebookPackageInstallOption], values: Binding<[String: String]>) -> some View {
        if !definitions.isEmpty {
            DisclosureGroup("Package parameters") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(controller.isRemote ? "Paths refer to the execution server. Empty fields use its environment and standard locations." :
                        "Empty fields use environment variables and standard locations on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(definitions) { option in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("--" + option.name).font(.callout.monospaced())
                            let value = Binding(get: { values.wrappedValue[option.name] ?? "" },
                                set: { values.wrappedValue[option.name] = $0 })
                            if option.type == "bool" || !(option.choices ?? []).isEmpty {
                                Picker(option.env, selection: value) {
                                    Text("Automatic").tag("")
                                    ForEach(option.type == "bool" ? ["true", "false"] : option.choices ?? [], id: \.self) {
                                        Text($0).tag($0)
                                    }
                                }.labelsHidden()
                            } else {
                                TextField(option.env, text: value).textFieldStyle(.roundedBorder)
                                    .accessibilityIdentifier("dependency-option-" + option.name)
                            }
                            Text(option.description + " · " + option.env).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.top, 6)
            }.disabled(!controller.canChange)
        }
    }
    private func packageActionTitle(_ defaultTitle: String, _ grants: [String]) -> String {
        controller.missingPackageGrants(grants)?.isEmpty == false ? defaultTitle + " and Add Grants…" : defaultTitle
    }
    private func requestGrants(_ grants: [String], action: GrantAction) {
        if action != .grantsOnly && controller.missingPackageGrants(grants)?.isEmpty == true {
            Task {
                if action == .registry { await controller.installRegistryPackage() }
                else { await controller.installPackage() }
            }
            return
        }
        guard let approval = controller.grantApproval(grants) else { return }
        let title: String
        switch action {
        case .registry: title = (controller.reusesSharedPackage ? "Use Installed Package" : "Install Package") + " and Add Grants"
        case .local: title = "Install Local Package and Add Grants"
        case .grantsOnly: title = "Add Grants and Restart Workers"
        }
        grantChange = GrantChange(approval: approval, action: action, title: title)
    }
    private func packageGrants(_ grants: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Required worker grants").font(.subheadline.bold())
            if grants.isEmpty {
                Text("No runtime grants declared.").font(.caption).foregroundStyle(.secondary)
            } else {
                let missing = controller.missingPackageGrants(grants)
                ForEach(grants, id: \.self) { grant in
                    let granted = missing?.contains(grant) == false
                    HStack(spacing: 6) {
                        Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(granted ? Color.green : Color.secondary)
                            .accessibilityLabel(granted ? "Granted" : (missing == nil ? "Unchecked" : "Missing"))
                        Text(grant).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if controller.workerGrantsError != nil {
                    Button("Retry Permission Check") { Task { await controller.refreshWorkerGrants() } }
                        .disabled(!controller.canChange)
                }
            }
        }
    }
    private var foreign: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(ecosystem == "Python" ? controller.requirementFile : "Gemfile").font(.headline)
                Spacer()
                if !controller.isRemote {
                    Text(ecosystem == "Python" ? "Python executable" : "Ruby executable").font(.caption).foregroundStyle(.secondary)
                    TextField(ecosystem == "Python" ? "python3" : "ruby", text: ecosystem == "Python" ? $controller.python : $controller.ruby)
                        .textFieldStyle(.roundedBorder).frame(width: 260)
                }
            }
            TextEditor(text: ecosystem == "Python" ? $controller.requirements : $controller.gemfile)
                .font(.system(.body, design: .monospaced)).padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(NotebookPalette.rule))
                .accessibilityIdentifier("dependency-manifest-editor").disabled(controller.busy || controller.catalogBusy)
            HStack {
                TextField(ecosystem == "Python" ? "numpy==2.3.0" : "gem \"json\", \"~> 2.0\"", text: $declaration).textFieldStyle(.roundedBorder)
                Button("Add Line") {
                    let line = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
                    if ecosystem == "Python" { controller.requirements += (controller.requirements.isEmpty || controller.requirements.hasSuffix("\n") ? "" : "\n") + line + "\n" }
                    else { controller.gemfile += (controller.gemfile.isEmpty || controller.gemfile.hasSuffix("\n") ? "" : "\n") + line + "\n" }
                    declaration = ""
                }.disabled(controller.busy || declaration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (ecosystem == "Python" && controller.lockedPython))
            }
            Text(ecosystem == "Python"
                ? (controller.lockedPython ? "This notebook uses a hash-locked requirements.lock. Edit the lock entries and hashes together, then prepare a fresh venv." : "Add or remove requirements, then prepare a fresh venv. An empty requirements file creates an empty venv.")
                : "Add or remove gem declarations, resolve Gemfile.lock, then prepare a fresh bundle. Ruby gems and Python packages share one environment generation.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if ecosystem == "Ruby" {
                    Button("Resolve Gemfile.lock") { Task { await controller.resolveRuby() } }.disabled(!controller.canChange || controller.gemfile.isEmpty)
                } else {
                    Button("Create Empty venv") { controller.requirements = "\n"; Task { await controller.prepare() } }.disabled(!controller.canChange || !controller.requirements.isEmpty || controller.lockedPython)
                }
                Spacer()
                Button("Save and Prepare Environment") { showLog = true; Task { await controller.prepare() } }
                    .disabled(!controller.canChange).accessibilityIdentifier("dependency-prepare-environment")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if let ready = controller.inventory.ready {
                        let packages = ecosystem == "Python" ? ready.python_packages : ready.ruby_packages
                        if !packages.isEmpty { Text(packages).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }
                    ForEach(controller.inventory.environments.reversed()) { environment in
                        HStack(alignment: .top) {
                            Text(environment.state).font(.caption.weight(.medium))
                            Text(environment.directory).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if controller.inventory.environments.isEmpty { Text("No managed environment prepared yet. Existing .venv / venv and Gemfile are discovered by workers automatically.").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 70)
        }
    }
}

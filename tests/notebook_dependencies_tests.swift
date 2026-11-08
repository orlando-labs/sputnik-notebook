import AppKit
import Foundation
import SwiftUI

@main
struct NotebookDependencyTests {
    struct Failure: Error { let message: String }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    @MainActor static func capture(_ model: NotebookModel, _ controller: NotebookDependencyController, _ build: URL, ecosystem: String = "Sputnik", name: String) async throws {
        let view = NSHostingView(rootView: NotebookDependenciesView(model: model, initialEcosystem: ecosystem, controller: controller))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 690), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        try await Task.sleep(nanoseconds: 600_000_000)
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: build.appendingPathComponent(name + ".png"))
        }
    }
    @MainActor static func testWorkerSheetSelection(_ model: NotebookModel) async throws {
        let original = model.snapshot!
        defer { model.snapshot = original; model.selectedBoardID = nil }
        let main = original.tabs.first { $0.id == "sheet:main" }!
        let module = original.tabs.first { $0.kind == "module" }!
        let required = NotebookDependencyController.nativeWorkerGrants
        try require(NotebookDependencyController(model: model).executionTab?.id == main.id, "default to the active sheet")
        model.selectedBoardID = "dashboard"
        try require(NotebookDependencyController(model: model).executionTab?.id == "sheet:other", "default to the active board's controller sheet")
        model.selectedBoardID = nil
        func focusModule(in tabs: [NotebookTab]) {
            model.snapshot = NotebookSnapshot(title: original.title, path: original.path, selected_tab: module.id,
                modified_count: original.modified_count, environment_generation: original.environment_generation, tabs: tabs)
        }
        focusModule(in: [main, module])
        let single = NotebookDependencyController(model: model)
        try require(single.executionTab?.id == main.id, "opening from a module selects the notebook's only sheet")
        await single.refreshWorkerGrants()
        try require(single.missingPackageGrants(required) != nil, "check the only sheet's permissions without closing Dependencies")
        focusModule(in: original.tabs)
        let multiple = NotebookDependencyController(model: model)
        try require(multiple.executionTab == nil && multiple.packageGrantIssue(required)?.contains("Choose a sheet") == true,
            "opening from a module with multiple sheets explains the required choice")
        multiple.workerSheetID = main.id
        await multiple.refreshWorkerGrants()
        try require(multiple.packageGrantIssue(required) == nil, "choosing a sheet checks its permissions")
        multiple.workerSheetID = "sheet:other"
        try require(multiple.missingPackageGrants(required) == nil, "changing the sheet immediately invalidates its permission snapshot")
        await multiple.refreshWorkerGrants()
        try require(multiple.executionTab?.id == "sheet:other" && multiple.packageGrantIssue(required) == nil,
            "check the chosen sheet independently of the active editor")
        multiple.workerSheetID = module.id
        try require(multiple.executionTab == nil, "a module cannot be used as the permission target")
        focusModule(in: [module])
        let empty = NotebookDependencyController(model: model)
        try require(empty.packageGrantIssue(required)?.contains("Create a sheet") == true, "explain how to continue when the notebook has no sheets")
        try require(empty.packageGrantIssue([]) == nil && empty.missingPackageGrants([]) == [], "packages without runtime permissions do not require a sheet")
    }
    @MainActor static func testGrantScopes(book: URL, build: URL, root: URL) async throws {
        let copy = root.appendingPathComponent("permission-scopes.sputnikbook")
        try FileManager.default.copyItem(at: book, to: copy)
        let storage = root.appendingPathComponent("scope-settings")
        let model = NotebookModel(workerExecutable: build.appendingPathComponent("sputnik-notebook-worker").path,
            remoteExecutable: build.appendingPathComponent("notebook-macos/sputnik-notebook-remote").path, remoteStorage: storage)
        func action(_ name: String, tab: NotebookTab? = nil, text: String = "") async -> Bool {
            await withCheckedContinuation { c in model.perform(name, tab: tab, text: text) { c.resume(returning: $0) } }
        }
        do {
            let opened = await withCheckedContinuation { c in model.open(url: copy) { c.resume(returning: $0) } }
            try require(opened, model.error ?? "open permission scopes fixture")
            let controller = NotebookDependencyController(model: model)
            await controller.load()
            let main = model.activeTab!
            let initial = try await model.workerSettings(for: main)
            try await model.configureWorker(main, text: "time.now=*", settings: initial)
            let required = ["process.spawn=/usr/bin/printf"]
            controller.grantScope = .currentSheets
            await controller.refreshWorkerGrants()
            let currentApproval = controller.grantApproval(required)!
            controller.grantScope = .entireBook
            await controller.addPackageGrants(approval: currentApproval)
            try require(controller.error != nil, "a current-sheets confirmation cannot authorize persistent notebook grants")
            controller.grantScope = .currentSheets
            await controller.refreshWorkerGrants()
            await controller.addPackageGrants(approval: controller.grantApproval(required)!)
            try require(controller.error == nil, controller.error ?? "grant current sheets")
            for tab in controller.workerSheets {
                let settings = try await model.workerSettings(for: tab)
                try require(settings.grants.contains(required[0]), "grant every existing sheet")
            }
            let noDefaults = try await model.bookWorkerSettings()
            try require(noDefaults.grants.isEmpty, "current-sheets scope does not save future defaults")
            try await capture(model, controller, build, name: "dependency-editor-current-sheets")
            let created = await action("new_sheet", text: "future")
            try require(created, model.error ?? "create a future sheet")
            let future = model.activeTab!
            let futureSettings = try await model.workerSettings(for: future)
            try require(futureSettings.grants.isEmpty, "current-sheets scope does not grant a later sheet")
            let source = "from system import cmd\ncmd\"/usr/bin/printf book-permission\".output\n"
            model.editSource(source, cell: future.cells[0], tab: future)
            _ = await action("run_all", tab: future)
            try require(model.activeTab?.cells[0].ok == false, "future sheet cannot spawn under current-sheets scope")
            controller.grantScope = .entireBook
            await controller.refreshWorkerGrants()
            await controller.addPackageGrants(approval: controller.grantApproval(required)!)
            try require(controller.error == nil, controller.error ?? "save persistent notebook grants")
            let persistent = try await model.bookWorkerSettings()
            try require(persistent.grants == required, "save book defaults independently of individual grants")
            let nextCreated = await action("new_sheet", text: "future_always")
            try require(nextCreated, model.error ?? "create a sheet after saving book permissions")
            let next = model.activeTab!
            model.editSource(source, cell: next.cells[0], tab: next)
            let ran = await action("run_all", tab: next)
            try require(ran && model.activeTab?.cells[0].ok == true && model.activeTab?.cells[0].result.contains("book-permission") == true,
                "new workers actually execute with inherited notebook permissions")
            let saved = await action("save_all")
            try require(saved, model.error ?? "save future sheets")
            try await capture(model, controller, build, name: "dependency-editor-entire-book")
            let reopened = await withCheckedContinuation { c in model.open(url: copy) { c.resume(returning: $0) } }
            try require(reopened, model.error ?? "reopen notebook permission fixture")
            let inherited = try await model.workerSettings(for: model.snapshot!.tabs.first { $0.id == next.id }!)
            try require(inherited.inherited_grants == required && inherited.own_grants == [], "book grants survive reopening and remain inherited")
            let defaults = try await model.bookWorkerSettings()
            try await model.configureBookWorkerGrants([], settings: defaults)
            let revoked = try await model.workerSettings(for: model.snapshot!.tabs.first { $0.id == next.id }!)
            try require(revoked.grants.isEmpty, "revoking book defaults removes inherited access")
            let preserved = try await model.workerSettings(for: main)
            try require(Set(preserved.grants) == ["time.now=*", required[0]], "book defaults preserve grants added to the original current sheets")
            await withCheckedContinuation { c in model.shutdown { c.resume() } }
        } catch {
            await withCheckedContinuation { c in model.shutdown { c.resume() } }
            throw error
        }
    }
    @MainActor static func testCatalog(_ controller: NotebookDependencyController, model: NotebookModel, build: URL) async throws {
        controller.packageName = "editor-probe"
        await controller.findPackageVersions()
        try require(controller.catalogError == nil, controller.catalogError ?? "find versions")
        try require(controller.packageCatalog?.latest == "1.1.0" && controller.packageVersion == "1.1.0", "select latest stable, excluding yanked releases")
        try require(controller.registryVariant == "source" && controller.canInstallRegistryPackage, "recommend a compatible portable build")
        try require(controller.selectedPackageVariant?.host_selection.allow_native == false, "portable packages do not need native consent")
        try require(controller.selectedPackageVariant?.install_options?.first?.name == "fixture-directory",
            "package manifest describes the parameter form")
        try require(controller.registryPackageGrants == ["fs.read=/package-fixture"], "show the declared package grant")
        let active = model.activeTab!
        let activeSettings = try await model.workerSettings(for: active)
        controller.workerSheetID = ""
        try require(controller.registryInstallIssue?.contains("Choose a sheet") == true, "explain why install is unavailable without a permission target")
        try await capture(model, controller, build, name: "dependency-editor-choose-sheet")
        let tab = model.snapshot!.tabs.first { $0.id == "sheet:other" }!
        controller.workerSheetID = tab.id
        await controller.refreshWorkerGrants()
        try require(controller.registryInstallIssue == nil && model.activeTab?.id == active.id,
            "choose the permission target inside Dependencies without changing the editor tab")
        await controller.installRegistryPackage(approval: .init(tab: active, missing: controller.registryPackageGrants))
        try require(controller.error != nil && controller.inventory.packages.isEmpty, "a confirmation for another sheet cannot authorize installation")
        let previous = try await model.workerSettings(for: tab)
        try await model.configureWorker(tab, text: "time.now=*", settings: previous)
        await controller.addPackageGrants(controller.registryPackageGrants, to: tab)
        let updated = try await model.workerSettings(for: tab)
        try require(Set(updated.grants) == ["time.now=*", "fs.read=/package-fixture"], "add package grants without replacing existing grants")
        let missing = try missingWorkerGrants(["fs.read=/data/models", "ffi.load=*"], from: ["fs.read=/data"])
        try require(missing == ["ffi.load=*"] && workerGrantCatalog().contains("workflow.persist"), "respect grant scopes and load the canonical catalogue")
        try require(controller.inventory.packages.isEmpty && !model.dependencyOperationActive, "discovery never installs or takes worker ownership")
        try await capture(model, controller, build, name: "dependency-editor-registry")
        controller.packageVersion = "0.9.0"
        try require(!controller.canInstallRegistryPackage && controller.packageBuilds == nil, "changing version invalidates stale variants immediately")
        await controller.findPackageVariants()
        try require(controller.catalogError == nil && controller.registryVariant.isEmpty && !controller.canInstallRegistryPackage, "disable installation when no build is compatible")
        controller.packageVersion = "1.0.0"
        await controller.findPackageVariants()
        try require(controller.catalogError == nil && controller.registryVariant == "source", "reload builds for an older exact version")
        controller.registryVariant = "foreign"
        try require(!controller.canInstallRegistryPackage, "incompatible build cannot be installed")
        controller.registryVariant = "source"
        controller.registryInstallValues["fixture-directory"] = build.path
        // Local-install settings must not override the selected registry build.
        controller.packageBackend = "cuda"; controller.packageBundle = "sdk"; controller.packageVariant = "wrong-local-variant"
        try await model.configureWorker(tab, text: "time.now=*", settings: updated)
        await controller.refreshWorkerGrants()
        try require(controller.missingPackageGrants(controller.registryPackageGrants) == ["fs.read=/package-fixture"], "show the missing scoped grant")
        try await capture(model, controller, build, name: "dependency-editor-add-grants")
        await controller.installRegistryPackage()
        try require(controller.error != nil && controller.inventory.packages.isEmpty, "do not install with unconfirmed missing grants")
        let installing = Task { await controller.installRegistryPackage(approval: .init(tab: tab, missing: ["fs.read=/package-fixture"])) }
        for _ in 0..<80 {
            if controller.progress.fraction == 0 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try require(controller.busy && model.dependencyOperationActive && controller.operationStartedAt != nil,
                    "installation keeps UI ownership and exposes elapsed time while downloading")
        try require(controller.progress.fraction == 0 && controller.log.contains("Downloading test/editor-probe@1.0.0"),
                    "piped SDK progress reaches the dependency editor before installation completes")
        try await capture(model, controller, build, name: "dependency-editor-installing")
        await installing.value
        try require(controller.error == nil, controller.error ?? "install selected registry build")
        try require(controller.log.contains("100%") && controller.log.contains("Dependency operation completed."), "retain final download and installation output")
        try require(!controller.busy && controller.operationStartedAt == nil, "completed install clears progress ownership")
        try require(controller.missingPackageGrants(controller.registryPackageGrants) == [], "combined install adds the grant and refreshes the status")
        let combined = try await model.workerSettings(for: tab)
        try require(Set(combined.grants) == ["time.now=*", "fs.read=/package-fixture"], "combined install preserves the worker's other grants")
        let unchanged = try await model.workerSettings(for: active)
        try require(unchanged.grants == activeSettings.grants, "combined install only adds grants to the selected sheet")
        try require(controller.inventory.packages.first?.name == "test/editor-probe" && controller.inventory.packages.first?.version == "1.0.0" && controller.inventory.packages.first?.variant == "source", "install exact selected version and variant")
        await controller.findPackageVariants()
        try require(controller.reusesSharedPackage, "catalog offers the already installed shared build")
        await controller.installRegistryPackage()
        try require(controller.error == nil, controller.error ?? "reuse the shared registry build")
        await controller.removePackage(controller.inventory.packages.first!)
        try require(controller.error == nil && controller.inventory.packages.isEmpty,
            controller.error ?? "remove registry installation; remaining packages: \(controller.inventory.packages.map(\.id))")
        controller.chooseLocalPackage("")
        controller.packageName = "missing"
        try require(controller.packageCatalog == nil && controller.packageBuilds == nil && !controller.canInstallRegistryPackage, "changing name invalidates catalog")
        await controller.findPackageVersions()
        try require(controller.catalogError == "Package 'missing' was not found in the registry." && controller.packageCatalog == nil,
            "display the missing package message instead of an internal APIError: \(controller.catalogError ?? "no error")")
        try require(controller.packageBuilds == nil && controller.packageVersion.isEmpty && !controller.catalogBusy && !controller.canInstallRegistryPackage,
            "failed lookup leaves no installable selection and releases the search button")
        controller.packageName = "unavailable"
        await controller.findPackageVersions()
        try require(controller.catalogError?.contains("HTTP 503 UNAVAILABLE") == true,
            "preserve registry service failures instead of reporting a missing package: \(controller.catalogError ?? "no error")")
        controller.packageName = "empty"
        await controller.findPackageVersions()
        try require(controller.catalogError != nil && controller.packageVersion.isEmpty, "handle an empty release index")
        controller.packageName = "slow"
        let pending = Task { await controller.findPackageVersions() }
        try await Task.sleep(nanoseconds: 80_000_000)
        controller.packageName = "editor-probe"
        await pending.value
        try require(controller.packageCatalog == nil && controller.packageBuilds == nil && !controller.catalogBusy, "ignore replies for a package name changed during lookup")
    }
    @MainActor static func main() async {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-dependencies-\(UUID().uuidString)")
        let book = root.appendingPathComponent("test.sputnikbook")
        let build = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
        let model = NotebookModel(workerExecutable: build.appendingPathComponent("sputnik-notebook-worker").path,
            remoteExecutable: build.appendingPathComponent("notebook-macos/sputnik-notebook-remote").path, remoteStorage: root.appendingPathComponent("settings"))
        do {
            try require(NotebookDependencyProgress(log: "\n", fallback: "Starting…").detail == "Starting…", "blank log has a visible starting state")
            let progress = NotebookDependencyProgress(log: "old output\nDownloading test/pkg@1.0.0   42% (16 MiB)\n", fallback: "")
            try require(progress.fraction == 0.42, "parse the current download percentage")
            try require(NotebookDependencyProgress(log: "Downloading test/pkg@1.0.0  100% (16 MiB)\nPreparing test/pkg@1.0.0…\n", fallback: "").fraction == nil,
                        "verification and builds do not keep a completed download bar")
            try require(NotebookDependencyProgress(log: "Downloading test/pkg@1.0.0  101% (16 MiB)", fallback: "").fraction == nil,
                        "reject invalid download percentages")
            try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
            let document: [String: Any] = ["format": "sputnik-notebook", "version": 2, "title": "Dependency Editor", "active_sheet": "main",
                "modules": [["id": "helpers", "path": "helpers.s"]], "auto_imports": [], "inputs": [],
                "sheets": [["id": "main", "title": "Main", "cells": [["id": "1", "kind": "code", "source": "42\n", "mode": "manual"]]],
                           ["id": "other", "title": "Other", "cells": [["id": "2", "kind": "code", "source": "21 * 2\n", "mode": "manual"]]]],
                "boards": [["id": "dashboard", "title": "Dashboard", "sheet": "other", "columns": 1, "components": []]]]
            try JSONSerialization.data(withJSONObject: document).write(to: book.appendingPathComponent("project.json"))
            try Data("42\n".utf8).write(to: book.appendingPathComponent("helpers.s"))
            var files = try NotebookDependencyFiles(directory: book)
            try files.save(["requirements.txt": "numpy==2.3.0\n"])
            try require(files.text("requirements.txt") == "numpy==2.3.0\n", "save dependency declaration")
            try Data("external change\n".utf8).write(to: book.appendingPathComponent("requirements.txt"))
            var conflict = false
            do { try files.save(["requirements.txt": "overwrite\n"]) } catch { conflict = true }
            try require(conflict, "external changes must reject a stale editor")
            let outside = root.appendingPathComponent("outside")
            try Data("keep".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: book.appendingPathComponent("Gemfile"), withDestinationURL: outside)
            var rejected = false
            do { _ = try NotebookDependencyFiles(directory: book) } catch { rejected = true }
            try require(rejected, "dependency editor must reject symlinked inputs")
            try FileManager.default.removeItem(at: book.appendingPathComponent("Gemfile"))
            try FileManager.default.removeItem(at: book.appendingPathComponent("requirements.txt"))
            let opened = await withCheckedContinuation { c in model.open(url: book) { c.resume(returning: $0) } }
            try require(opened, model.error ?? "open fixture")
            try await testWorkerSheetSelection(model)
            try await testGrantScopes(book: book, build: build, root: root)
            let controller = NotebookDependencyController(model: model)
            try require(controller.packageScope == "shared", "shared package storage is the default")
            await controller.load()
            try require(controller.error == nil, controller.error ?? "load dependency editor")
            if ProcessInfo.processInfo.environment["SPUTNIK_TEST_PACKAGE_CATALOG"] == "1" {
                try await testCatalog(controller, model: model, build: build)
                await withCheckedContinuation { c in model.shutdown { c.resume() } }
                try FileManager.default.removeItem(at: root)
                print("notebook package catalog tests passed")
                return
            }
            controller.python = ProcessInfo.processInfo.environment["SPUTNIK_TEST_PYTHON"] ?? "/opt/homebrew/bin/python3.14"
            controller.requirements = "\n"
            await controller.prepare()
            try require(controller.error == nil, controller.error ?? "prepare local venv")
            try require(controller.inventory.environments.last?.state == "ready", "environment must become ready")
            let settings = try await model.workerSettings(for: model.activeTab!)
            try require(settings.environment_directory?.contains("/environments/") == true, "all local workers select the prepared environment")
            try require(!model.dependencyOperationActive && !controller.busy, "dependency operation releases UI ownership")
            let source = root.appendingPathComponent("package-source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data("name: editor-probe\nversion: \"1.0.0\"\nfiles: [probe.s]\nmodule_names: {probe.s: editor_probe}\n".utf8).write(to: source.appendingPathComponent("sputnik.build.yaml"))
            try Data("package editor_probe\nexport answer\ndef answer(): 42\n".utf8).write(to: source.appendingPathComponent("probe.s"))
            controller.packageSource = source.path
            await controller.installPackage()
            try require(controller.error == nil, controller.error ?? "install local package through editor")
            try require(controller.inventory.packages.first?.name == "editor-probe", "show installed notebook package")
            try require(controller.inventory.packages.first?.scope == "shared", "show a shared package reference")
            controller.packageScope = "local"
            await controller.installPackage()
            try require(controller.error == nil && controller.inventory.packages.first?.scope == "local", controller.error ?? "replace the shared reference with a notebook-only package")
            controller.packageScope = "shared"
            for ecosystem in ["Sputnik", "Python", "Ruby"] {
                try await capture(model, controller, build, ecosystem: ecosystem, name: "dependency-editor-" + ecosystem.lowercased())
            }
            await controller.removePackage(controller.inventory.packages.first!)
            try require(controller.error == nil && controller.inventory.packages.isEmpty, controller.error ?? "remove local package through editor")
            // Exercise native opt-in, explicit variants and removal through
            // the real editor -> dependency helper -> SDK installer path.
            let workspace = build.deletingLastPathComponent().deletingLastPathComponent()
            let sdk = workspace.appendingPathComponent("sputnik-lang/build/sputnik")
            func command(_ executable: URL, _ arguments: [String]) throws {
                let process = Process(); let output = Pipe()
                process.executableURL = executable; process.arguments = arguments
                process.standardOutput = output; process.standardError = output
                try process.run()
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                try require(process.terminationStatus == 0, text)
            }
            let native = root.appendingPathComponent("native-source")
            try FileManager.default.createDirectory(at: native, withIntermediateDirectories: false)
            try Data("#include \"runtime/sputnik_ext.h\"\nextern \"C\" const char *sputnik_language_version(){return SPUTNIK_VERSION;}\nextern \"C\" SputnikStatus editor_answer(SputnikCtx*c,const SputnikValue*,size_t,SputnikValue*out){*out=sputnik_make_int(c,42);return SPUTNIK_OK;}\n".utf8).write(to: native.appendingPathComponent("answer.cpp"))
            try Data("package editor_native\nexport answer\nnative def answer() -> Int from \"editor_answer\"\n".utf8).write(to: native.appendingPathComponent("main.s"))
            try command(URL(fileURLWithPath: "/usr/bin/clang++"), ["-std=c++17", "-O2", "-mmacosx-version-min=14.0", "-dynamiclib", "-Wl,-undefined,dynamic_lookup", "-I" + workspace.appendingPathComponent("sputnik-lang").path, native.appendingPathComponent("answer.cpp").path, "-o", native.appendingPathComponent("answer.dylib").path])
            #if arch(arm64)
            let arch = "aarch64"
            #else
            let arch = "x86_64"
            #endif
            for variant in ["cpu-a", "cpu-b"] {
                let bundle = variant == "cpu-b" ? "runtime" : "none"
                let manifest = "name: editor-native\nversion: \"1.0.0\"\nfiles: [main.s, answer.dylib]\nmodule_names: {main.s: editor_native}\nprofiles: {required: [core.v1, ffi.v1]}\nartifact: {variant: \"\(variant)\", bundle: \"\(bundle)\"}\ntarget: {os: macos, arch: \"\(arch)\", min_os: \"14.0\", compute_backend: cpu}\nnative_extensions: [{name: answer, kind: prebuilt, library: answer.dylib, sputnik_version: \"1.0.0\"}]\n"
                try Data(manifest.utf8).write(to: native.appendingPathComponent("sputnik.build.yaml"))
                try command(sdk, ["pkg", "build", native.path, "--out", root.appendingPathComponent(variant + ".sputnikpkg").path])
            }
            controller.packageSource = root.appendingPathComponent("cpu-a.sputnikpkg").path
            await controller.installPackage()
            try require(controller.error != nil && controller.inventory.packages.isEmpty, "native archive needs explicit opt-in")
            controller.packageAllowNative = true
            controller.packageVariant = "wrong-variant"
            await controller.installPackage()
            try require(controller.error != nil && controller.inventory.packages.isEmpty, "explicit variant must reach the installer")
            for variant in ["cpu-a", "cpu-b"] {
                controller.chooseLocalPackage(root.appendingPathComponent(variant + ".sputnikpkg").path)
                await controller.installPackage()
                try require(controller.error == nil, controller.error ?? "install native variant through editor")
            }
            try require(Set(controller.inventory.packages.map(\.id)).count == 2, "variants of one release need separate rows")
            try require(Set(controller.inventory.packages.compactMap(\.variant)) == ["cpu-a", "cpu-b"], "inventory retains exact variant")
            try require(controller.inventory.packages.allSatisfy { $0.digest?.hasPrefix("sha256:") == true }, "inventory retains archive hashes")
            await controller.removePackage(controller.inventory.packages.first { $0.variant == "cpu-a" }!)
            try require(controller.error == nil && controller.inventory.packages.count == 1 && controller.inventory.packages.first?.variant == "cpu-b", "removal keeps the other installed variant")
            await controller.removePackage(controller.inventory.packages.first!)
            try require(controller.error == nil && controller.inventory.packages.isEmpty, "remove remaining native variant")
            controller.packageVariant = ""
            controller.ruby = ProcessInfo.processInfo.environment["SPUTNIK_TEST_RUBY"] ?? "ruby"
            controller.gemfile = "source \"https://rubygems.org\"\n"
            await controller.resolveRuby()
            try require(controller.error == nil, controller.error ?? "resolve Ruby lock through editor")
            try require(FileManager.default.fileExists(atPath: book.appendingPathComponent("Gemfile.lock").path), "save resolved lock in notebook")
            await controller.prepare()
            try require(controller.error == nil, controller.error ?? "prepare both Python and Ruby through editor")
            let pycall = build.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("pycall")
            if FileManager.default.fileExists(atPath: pycall.appendingPathComponent("sputnik.build.yaml").path) {
                controller.packageSource = pycall.path
                await controller.installPackage()
                try require(controller.error == nil, controller.error ?? "install native bridge through editor")
                let tab = model.activeTab!
                let settings = try await model.workerSettings(for: tab)
                try await model.configureWorker(tab, text: "ffi.call\nffi.load", settings: settings)
                model.editSource("import pycall.sys as sys\nsys.prefix\n", cell: tab.cells[0], tab: tab)
                let ran = await withCheckedContinuation { c in model.perform("run", tab: tab, cell: tab.cells[0]) { c.resume(returning: $0) } }
                try require(ran && model.activeTab!.cells[0].ok && model.activeTab!.cells[0].result.contains("/.venv"),
                    "native notebook import uses the selected venv and explicit worker grants: \(model.error ?? model.activeTab!.cells[0].error)")
                await controller.removePackage(controller.inventory.packages.first!)
                try require(controller.error == nil && controller.inventory.packages.isEmpty, controller.error ?? "remove loaded native bridge")
            }
            await withCheckedContinuation { c in model.shutdown { c.resume() } }
            try FileManager.default.removeItem(at: root)
            print("notebook dependency editor tests passed")
        } catch {
            await withCheckedContinuation { c in model.shutdown { c.resume() } }
            fputs("dependency editor tests failed: \(error)\nFixture: \(root.path)\n", stderr); exit(1)
        }
    }
}

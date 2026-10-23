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
    @MainActor static func testCatalog(_ controller: NotebookDependencyController, model: NotebookModel, build: URL) async throws {
        controller.packageName = "editor-probe"
        await controller.findPackageVersions()
        try require(controller.catalogError == nil, controller.catalogError ?? "find versions")
        try require(controller.packageCatalog?.latest == "1.1.0" && controller.packageVersion == "1.1.0", "select latest stable, excluding yanked releases")
        try require(controller.registryVariant == "source" && controller.canInstallRegistryPackage, "recommend a compatible portable build")
        try require(controller.selectedPackageVariant?.host_selection.allow_native == false, "portable packages do not need native consent")
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
        // Local-install settings must not override the selected registry build.
        controller.packageBackend = "cuda"; controller.packageBundle = "sdk"; controller.packageVariant = "wrong-local-variant"
        await controller.installRegistryPackage()
        try require(controller.error == nil, controller.error ?? "install selected registry build")
        try require(controller.inventory.packages.first?.name == "test/editor-probe" && controller.inventory.packages.first?.version == "1.0.0" && controller.inventory.packages.first?.variant == "source", "install exact selected version and variant")
        await controller.removePackage(controller.inventory.packages.first!)
        try require(controller.error == nil && controller.inventory.packages.isEmpty, "remove registry installation")
        controller.chooseLocalPackage("")
        controller.packageName = "missing"
        try require(controller.packageCatalog == nil && controller.packageBuilds == nil && !controller.canInstallRegistryPackage, "changing name invalidates catalog")
        await controller.findPackageVersions()
        try require(controller.catalogError != nil && controller.packageCatalog == nil, "display registry lookup errors")
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
            try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
            let document: [String: Any] = ["format": "sputnik-notebook", "version": 1, "title": "Dependency Editor", "active_sheet": "main", "modules": [], "auto_imports": [],
                "sheets": [["id": "main", "title": "Main", "cells": [["id": "1", "kind": "code", "source": "42\n", "mode": "manual"]]]]]
            try JSONSerialization.data(withJSONObject: document).write(to: book.appendingPathComponent("project.json"))
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
            let controller = NotebookDependencyController(model: model)
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
            try Data("[package]\nname = \"editor-probe\"\nversion = \"1.0.0\"\nroot = \"editor_probe\"\n[[modules]]\nname = \"editor_probe\"\npath = \"probe.s\"\n".utf8).write(to: source.appendingPathComponent("sputnik.toml"))
            try Data("package editor_probe\nexport answer\ndef answer(): 42\n".utf8).write(to: source.appendingPathComponent("probe.s"))
            controller.packageSource = source.path
            await controller.installPackage()
            try require(controller.error == nil, controller.error ?? "install local package through editor")
            try require(controller.inventory.packages.first?.name == "editor-probe", "show installed notebook package")
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
            try Data("#include \"runtime/sputnik_ext.h\"\nextern \"C\" uint32_t sputnik_ext_abi_version(){return SPUTNIK_EXT_ABI_VERSION;}\nextern \"C\" SputnikStatus editor_answer(SputnikCtx*c,const SputnikValue*,size_t,SputnikValue*out){*out=sputnik_make_int(c,42);return SPUTNIK_OK;}\n".utf8).write(to: native.appendingPathComponent("answer.cpp"))
            try Data("package editor_native\nexport answer\nnative def answer() -> Int from \"editor_answer\"\n".utf8).write(to: native.appendingPathComponent("main.s"))
            try command(URL(fileURLWithPath: "/usr/bin/clang++"), ["-std=c++17", "-O2", "-mmacosx-version-min=14.0", "-dynamiclib", "-Wl,-undefined,dynamic_lookup", "-I" + workspace.appendingPathComponent("sputnik-lang").path, native.appendingPathComponent("answer.cpp").path, "-o", native.appendingPathComponent("answer.dylib").path])
            #if arch(arm64)
            let arch = "aarch64"
            #else
            let arch = "x86_64"
            #endif
            for variant in ["cpu-a", "cpu-b"] {
                let bundle = variant == "cpu-b" ? "runtime" : "none"
                let manifest = "schema=\"sputnik.package-manifest.v1\"\n[package]\nname=\"editor-native\"\nversion=\"1.0.0\"\nroot=\"editor_native\"\n[artifact]\nvariant=\"\(variant)\"\nbundle=\"\(bundle)\"\n[target]\nos=\"macos\"\narch=\"\(arch)\"\nmin_os=\"14.0\"\ncompute_backend=\"cpu\"\n[[modules]]\nname=\"editor_native\"\nsource=\"main.s\"\n[[native]]\nname=\"answer\"\nkind=\"prebuilt\"\nlibrary=\"answer.dylib\"\nsputnik_ext_abi=1\n"
                try Data(manifest.utf8).write(to: native.appendingPathComponent("sputnik.toml"))
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
            if FileManager.default.fileExists(atPath: pycall.appendingPathComponent("sputnik.toml").path) {
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

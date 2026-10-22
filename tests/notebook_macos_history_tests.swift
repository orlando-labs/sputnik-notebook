import AppKit
import SwiftUI

private struct HistoryFailure: Error { let message: String }
@main private enum HistoryTests {
    static func option(_ key: String) -> String? { CommandLine.arguments.firstIndex(of: key).flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } }
    static func check(_ condition: @autoclosure () -> Bool, _ text: String) throws { if !condition() { throw HistoryFailure(message: text) } }
    @MainActor static func action(_ model: NotebookModel, _ action: String, text: String = "") async -> Bool {
        await withCheckedContinuation { c in model.perform(action, text: text) { c.resume(returning: $0) } }
    }
    @MainActor static func p2(_ model: NotebookModel, root: URL) async throws {
        let source = URL(fileURLWithPath: "tools/notebook-macos/Samples/Components P2.sputnikbook")
        let project = root.appendingPathComponent("P2.sputnikbook")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: project)
        let manifest = project.appendingPathComponent("project.json")
        var doc = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        doc["dependencies"] = [["path": URL(fileURLWithPath: "../sputnik-lang/packages/notebook_ui").standardizedFileURL.path, "auto_import": false]]
        try JSONSerialization.data(withJSONObject: doc).write(to: manifest)
        let opened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
        try check(opened, model.error ?? "P2 open")
        let ran = await action(model, "run_all")
        try check(ran && model.activeTab!.cells[0].ok && model.activeTab!.cells[0].result == "6", "P2 result: " + model.activeTab!.cells[0].result + " / " + model.activeTab!.cells[0].error + " / " + model.activeTab!.environment_error)
        let applied = await withCheckedContinuation { c in model.setProjectInputs(["gain": "8", "some_range": #"{"start":2,"finish":8,"inclusive_end":true,"step":2}"#, "when": #""2024-02-29T12:00:00Z""#]) { c.resume(returning: $0) } }
        try check(applied, model.error ?? "P2 parameter apply")
        let reran = await action(model, "run_all")
        try check(reran && model.activeTab!.cells[0].result == "16", "P2 second result: " + model.activeTab!.cells[0].result + " / " + model.activeTab!.cells[0].error + " / " + model.activeTab!.environment_error)
        let tab = model.activeTab!
        try check(model.telemetry(in: tab)?.total ?? 0 > 0 && model.runHistory.runs.count == 2, "P2 task telemetry and history")
        var board = model.snapshot!.boards![0]
        var split = board.components.first { $0.kind == "split" }!; split.split_fraction = 0.65
        try check(split.panels?.count == 2, "split owns two grids")
        _ = board.replaceComponent(split)
        let saved = await withCheckedContinuation { c in model.saveBoard(board) { c.resume(returning: $0) } }
        try check(saved && model.snapshot!.boards![0].components.first { $0.kind == "split" }?.split_fraction == 0.65, "split default ratio persists without changing child grids")
        if let output = option("--output") {
            let directory = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 1250), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil); defer { window.close() }
            for scheme in [ColorScheme.light, .dark] {
                let view = NSHostingView(rootView: NotebookBoardView(model: model, board: model.snapshot!.boards![0], onDesign: {}).environment(\.colorScheme, scheme))
                window.contentView = view; try await Task.sleep(nanoseconds: 300_000_000); view.layoutSubtreeIfNeeded()
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!; view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(scheme == .light ? "p2-light.png" : "p2-dark.png"))
            }
        }
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-tests-" + UUID().uuidString)
        let project = root.appendingPathComponent("History.sputnikbook")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = NotebookModel(workerExecutable: option("--worker"), remoteStorage: root.appendingPathComponent("settings"))
        do {
            if CommandLine.arguments.contains("--p2-only") {
                try await p2(model, root: root)
                await withCheckedContinuation { c in model.shutdown { c.resume() } }
                print("P2 passed: Range/Date inputs, live tasks/logs, worker resources, history/compare, Split View persistence and native themes"); return
            }
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let manifest: [String: Any] = ["format": "sputnik-notebook", "version": 3, "title": "Run History", "active_sheet": "main", "modules": [], "auto_imports": [], "dependencies": [],
                "inputs": [["id": "gain", "title": "Gain", "type": "integer", "default": 3]],
                "sheets": [["id": "main", "title": "Experiment", "cells": [["id": "1", "kind": "code", "mode": "manual", "source": "gain = notebook.input(\"gain\")\nscore = gain * 2\nscore\n"]]]],
                "boards": [["id": "history", "title": "История экспериментов", "sheet": "main", "columns": 1, "components": [
                    ["id": "history", "kind": "run_history", "title": "Запуски"],
                    ["id": "compare", "kind": "experiment_compare", "title": "Сравнение"],
                    ["id": "runtime", "kind": "status", "title": "Runtime", "p1": ["target_kind": "runtime"]]]]]]
            let manifestURL = project.appendingPathComponent("project.json")
            let original = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]); try original.write(to: manifestURL)
            let opened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
            try check(opened, model.error ?? "open")
            let firstRun = await action(model, "run_all"); try check(firstRun, model.error ?? "run")
            try check(model.runHistory.runs.count == 1, model.runHistory.error ?? "first run saved")
            let first = try model.runHistory.load(model.runHistory.runs[0].id)
            try check(first.inputs["gain"] == "3" && first.outputs[0].result == "6" && first.status == "success", "frozen inputs and output")
            let changed = await action(model, "set_inputs", text: "{\"gain\":\"8\"}")
            try check(changed, model.error ?? "change input")
            let secondRun = await action(model, "run_all"); try check(secondRun, model.error ?? "second run")
            try check(model.runHistory.runs.count == 2, "second run saved")
            let latest = try model.runHistory.load(model.runHistory.runs[0].id)
            try check(latest.inputs["gain"] == "8" && latest.outputs[0].result == "16", "new result")
            let reloaded = try model.runHistory.load(first.id)
            try check(reloaded.outputs[0].result == "6" && reloaded.inputs["gain"] == "3", "new Run cannot mutate an old snapshot")
            model.runHistory.pin(first.id); model.runHistory.rename(first.id, title: "Baseline")
            let pinned = try model.runHistory.load(first.id); try check(pinned.pinned, "pinned snapshot")
            model.restoreRunParameters(first)
            while model.busy { try await Task.sleep(nanoseconds: 10_000_000) }
            try check(model.snapshot!.inputs!.first!.value_json == "3" && model.activeTab!.cells[0].result == "16", "restore is inert and leaves outputs in place")
            let bytes = try Data(contentsOf: manifestURL); try check(bytes == original, "accepted parameters do not rewrite authored defaults")
            if let output = option("--output") {
                let directory = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil); defer { window.close() }
                let view = NSHostingView(rootView: NotebookBoardView(model: model, board: model.snapshot!.boards![0], onDesign: {}))
                window.contentView = view; try await Task.sleep(nanoseconds: 300_000_000); view.layoutSubtreeIfNeeded()
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!; view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("history.png"))
            }
            let tab = model.activeTab!, cell = tab.cells[0]
            model.editSource("raise ValueError(\"expected history failure\")\n", cell: cell, tab: tab)
            _ = await action(model, "run_all")
            try check(model.runHistory.runs.first?.status == "failed", "failed run is recorded")
            model.editSource("import task\nchild = task.async:\n  print(\"child-start\")\n  task.sleep(1400)\n  7\nprint(\"root-running\")\ntask.sleep(800)\nchild.wait()\n42\n", cell: model.activeTab!.cells[0], tab: model.activeTab!)
            let liveRun = Task { @MainActor in await action(model, "run_all") }
            var observedLive = false
            for _ in 0..<500 {
                try await Task.sleep(nanoseconds: 10_000_000)
                if let tab = model.activeTab, let telemetry = model.telemetry(in: tab), telemetry.active > 0,
                   model.output(for: tab.cells[0], in: tab).contains(where: { $0.text.contains("root-running") }) {
                    observedLive = model.executingWorker && !telemetry.tasks.isEmpty && (telemetry.resident_bytes ?? 0) > 0; break
                }
                if !model.busy { break }
            }
            try check(observedLive, "live logs, real task membership and worker RAM arrive before Run ends")
            _ = await liveRun.value
            try check(model.activeTab!.cells[0].ok && model.telemetry(in: model.activeTab!)?.active == 0, "terminal task snapshot has no active memberships")
            model.editSource("import task\ntask.sleep(20000)\n42\n", cell: model.activeTab!.cells[0], tab: model.activeTab!)
            let run = Task { @MainActor in await action(model, "run_all") }
            for _ in 0..<300 { if model.executionPhase == 2 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            model.stopExecution(); _ = await run.value
            try check(model.runHistory.runs.first?.status == "cancelled", "Stop is distinct from success and error")
            let saved = try model.runHistory.load(first.id)
            for _ in 0..<25 {
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
                object["id"] = UUID().uuidString.lowercased(); object["pinned"] = false; object["started"] = Date().timeIntervalSinceReferenceDate
                let next = try JSONDecoder().decode(NotebookRunRecord.self, from: JSONSerialization.data(withJSONObject: object))
                try model.runHistory.save(next)
            }
            try check(model.runHistory.runs.filter { !$0.pinned }.count <= 20 && model.runHistory.runs.contains { $0.id == first.id && $0.pinned }, "retention preserves pinned snapshots")
            let count = model.runHistory.runs.count
            let reopened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
            try check(reopened && model.runHistory.runs.count == count, "history survives document reopen")
            await withCheckedContinuation { c in model.shutdown { c.resume() } }
            print("History passed: worker snapshots, parameters, immutable outputs, pin/rename, inert restore, failed/Stop status, retention, reopen and native board")
        } catch {
            await withCheckedContinuation { c in model.shutdown { c.resume() } }
            fputs("History failed: \(error) · \(model.error ?? "") · \(model.runHistory.error ?? "")\n", stderr); exit(1)
        }
    }
}

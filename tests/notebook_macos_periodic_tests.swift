import AppKit
import Foundation
import SwiftUI

private struct PeriodicFailure: Error { let message: String }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PeriodicFailure(message: message) }
}

@main private struct PeriodicTests {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sputnik-periodic-\(UUID())")
        let model = NotebookModel()
        var isolated: NotebookModel?
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try schedulerTests()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let project = root.appendingPathComponent("Jobs.sputnikbook")
            try writeFixture(project)
            try await modelTests(model, project: project)
            try await previewTests(model)
            await shutdown(model)
            if let index = CommandLine.arguments.firstIndex(of: "--worker") {
                let workerModel = NotebookModel(workerExecutable: CommandLine.arguments[index + 1])
                isolated = workerModel
                try await modelTests(workerModel, project: project)
                await shutdown(workerModel)
            }
            print("notebook macOS periodic tests passed")
        } catch {
            await shutdown(model)
            if let isolated { await shutdown(isolated) }
            fputs("notebook macOS periodic tests failed: \(error)\n", stderr); exit(1)
        }
    }
    private static func schedulerTests() throws {
        let component = NotebookBoardComponent(id: "timer", kind: "periodic_work", title: "Work",
            module_id: "jobs", function: "tick", period_seconds: 1, timing: "fixed_rate", tail_limit: 2)
        var state = NotebookPeriodicState(settings: component.periodicSettings)
        try check(!state.enabled && state.nextDeadline == nil, "opening is inert")
        state.start(at: 10)
        try check(state.nextDeadline == 10, "first run may start immediately")
        state.complete(start: 10, end: 13.25, date: Date(), ok: true, value: "1", error: "")
        try check(state.nextDeadline == 14 && state.skipped == 3, "overlaps are skipped without catching up")
        state.complete(start: 14, end: 15, date: Date(), ok: true, value: "2", error: "")
        try check(state.nextDeadline == 15 && state.skipped == 3, "exact completion boundary does not count as overlap")
        state.skipBusyTicks(at: 17.4)
        try check(state.nextDeadline == 18 && state.skipped == 6, "busy host throttles fixed-rate ticks")
        state.complete(start: 18, end: 18.2, date: Date(), ok: false, value: "", error: "boom")
        try check(state.history.map(\.id) == [2, 3] && state.history.last?.error == "boom" && state.failures == 1,
                  "tail bounds results and errors together")
        state.settings.timing = "fixed_delay"
        state.complete(start: 19, end: 22.2, date: Date(), ok: true, value: "4", error: "")
        try check(state.nextDeadline == 23.2, "fixed delay begins after actual completion")
        state.settings.retention = "none"; state.history = []
        state.complete(start: 24, end: 24.2, date: Date(), ok: true, value: "secret", error: "")
        try check(state.history.isEmpty, "no history policy stores no return values")
        state.settings.retention = "all"; state.settings.storeValues = false
        state.complete(start: 25, end: 25.2, date: Date(), ok: true, value: "hidden", error: "")
        state.complete(start: 26, end: 26.2, date: Date(), ok: false, value: "", error: "saved")
        try check(state.history.count == 1 && state.history[0].error == "saved", "error-only retention is independent")
        state.settings.storeErrors = false
        state.complete(start: 27, end: 27.2, date: Date(), ok: false, value: "", error: "hidden")
        try check(state.history.count == 1, "disabled error retention does not append a run")
        state.settings.stopOnError = true
        state.complete(start: 28, end: 28.2, date: Date(), ok: false, value: "", error: "stop")
        try check(!state.enabled && state.nextDeadline == nil, "stop-on-error cancels scheduling")
        state.settings.runImmediately = false; state.start(at: 30)
        try check(state.nextDeadline == 31, "initial delay is configurable")
        state.running = true; state.pause()
        state.complete(start: 31, end: 32, date: Date(), ok: true, value: "done", error: "")
        try check(!state.enabled && state.nextDeadline == nil, "pause during a run never reschedules")
        var legacy = NotebookBoard(id: "board", title: "Board", sheet: "main", columns: 2, components: [component,
            NotebookBoardComponent(id: "value", kind: "text", title: "Value", cell: "1")]).rowLayout
        try check(legacy.components[0].row == nil && legacy.availableColumns(in: "row_1") == 6 &&
                  !legacy.moveComponent("timer", to: "row_1"), "nonvisual components do not occupy legacy or row layouts")
        let encoded = try JSONEncoder().encode(legacy)
        let roundtrip = try JSONDecoder().decode(NotebookBoard.self, from: encoded)
        try check(roundtrip.services[0].periodicSettings == component.periodicSettings, "settings survive Codable")
    }
    @MainActor private static func modelTests(_ model: NotebookModel, project: URL) async throws {
        let opened = await withCheckedContinuation { continuation in model.open(url: project) { continuation.resume(returning: $0) } }
        try check(opened, model.error ?? "open fixture")
        guard let board = model.snapshot?.boards?.first, let component = board.services.first else { throw PeriodicFailure(message: "service missing") }
        let before = try Data(contentsOf: project.appendingPathComponent("project.json"))
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(model.periodicStates.isEmpty && model.snapshot?.periodic_results?.isEmpty == true, "open never starts work")
        model.periodicBoardVisible = board.id
        model.startPeriodic(board: board, component: component)
        try await until { model.periodicState(board: board, component: component).runs >= 3 }
        model.pausePeriodic(board: board, component: component)
        try await until { !model.busy }
        let state = model.periodicState(board: board, component: component)
        try check(state.history.count == 2 && state.history.last?.value == String(state.runs),
                  "timer invokes persistent module function and retains tail: \(state.history.map { $0.value ?? "error" }) / \(model.error ?? "")")
        let pausedRuns = state.runs
        try await Task.sleep(nanoseconds: 130_000_000)
        try check(model.periodicState(board: board, component: component).runs == pausedRuns, "pause prevents further invocations")
        model.startPeriodic(board: board, component: component)
        try await until { model.periodicState(board: board, component: component).runs > pausedRuns }
        model.periodicBoardVisible = nil
        try await until { !model.busy && model.periodicState(board: board, component: component).status == "Waiting for board" }
        let hiddenRuns = model.periodicState(board: board, component: component).runs
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(model.periodicState(board: board, component: component).runs == hiddenRuns, "hidden board pauses by default")
        model.pausePeriodic(board: board, component: component)
        model.runPeriodicOnce(board: board, component: component)
        try await until { !model.busy }
        try check(model.periodicState(board: board, component: component).runs == hiddenRuns + 1 &&
                  !model.periodicState(board: board, component: component).enabled, "Run Once does not enable a stopped timer")
        let after = try Data(contentsOf: project.appendingPathComponent("project.json"))
        try check(after == before,
                  "runtime history and calls never persist synthetic cells")
        try check(model.snapshot?.tabs.first(where: { $0.kind == "sheet" })?.cells.first?.result == "not evaluated", "service never runs controller cells")
        var failingBoard = board
        failingBoard.components[0].function = "fail"
        failingBoard.components[0].stop_on_error = true
        failingBoard.components[0].retention = "all"
        let savedFailure = await withCheckedContinuation { continuation in
            model.saveBoard(failingBoard) { continuation.resume(returning: $0) }
        }
        try check(savedFailure, model.error ?? "save failing service")
        model.periodicBoardVisible = board.id
        model.startPeriodic(board: failingBoard, component: failingBoard.services[0])
        try await until { model.periodicState(board: failingBoard, component: failingBoard.services[0]).failures > 0 && !model.busy }
        let failed = model.periodicState(board: failingBoard, component: failingBoard.services[0])
        try check(!failed.enabled && failed.history.last?.error?.contains("periodic test failure") == true,
                  "runtime error is retained and stop-on-error prevents another tick")
        let restored = await withCheckedContinuation { continuation in
            model.saveBoard(board) { continuation.resume(returning: $0) }
        }
        try check(restored && !model.periodicState(board: board, component: component).enabled,
                  "saving settings keeps service stopped")
        // Closing stops the timers; no callback can revive the closed handle.
        model.startPeriodic(board: board, component: component)
        await shutdown(model)
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(!model.periodicState(board: board, component: component).enabled, "project close cancels periodic scheduling")
        let reopened = await withCheckedContinuation { continuation in model.open(url: project) { continuation.resume(returning: $0) } }
        try check(reopened && model.periodicStates.isEmpty, "reopen starts without runtime history or enabled timers")
    }
    @MainActor private static func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw PeriodicFailure(message: "timed out waiting for periodic execution")
    }
    @MainActor private static func shutdown(_ model: NotebookModel) async {
        await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
    }
    private static func writeFixture(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let manifest = #"{"format":"sputnik-notebook","version":2,"title":"Periodic Jobs","active_sheet":"main","sheets":[{"id":"main","title":"Main","cells":[{"id":"1","kind":"code","source":"raise \"controller stays inert\"\n","mode":"watch"}]}],"modules":[{"id":"jobs","path":"jobs.s"}],"auto_imports":[],"inputs":[],"boards":[{"id":"dashboard","title":"Background Jobs","sheet":"main","columns":2,"rows":[],"components":[{"id":"timer","kind":"periodic_work","title":"Poll a module","module_id":"jobs","function":"tick","period_seconds":0.04,"timing":"fixed_delay","retention":"tail","tail_limit":2}]}]}"#
        try manifest.write(to: url.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        try "package jobs\nclass Counter:\n  def init(): @value = 0\n  def next():\n    @value += 1\n    @value\nState = Counter()\ndef tick(): State.next()\ndef fail(): raise \"periodic test failure\"\nexport tick, fail\n".write(to: url.appendingPathComponent("jobs.s"), atomically: true, encoding: .utf8)
    }
    @MainActor private static func previewTests(_ model: NotebookModel) async throws {
        guard let board = model.snapshot?.boards?.first else { throw PeriodicFailure(message: "preview board missing") }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NSHostingView(rootView: NotebookBoardEditor(model: model, board: board, document: model.documentIdentity))
        window.contentView = editor; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 150_000_000)
        if let index = CommandLine.arguments.firstIndex(of: "--output") {
            try snapshot(editor, to: URL(fileURLWithPath: CommandLine.arguments[index + 1]).appendingPathComponent("periodic-initial.png"))
        }
        try click(editor, window: window, x: 297, fromTop: 139)
        try await Task.sleep(nanoseconds: 100_000_000)
        try click(editor, window: window, x: 220, fromTop: 375)
        try await Task.sleep(nanoseconds: 100_000_000)
        if let index = CommandLine.arguments.firstIndex(of: "--output") {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            try snapshot(editor, to: output.appendingPathComponent("periodic-designer.png"))
            // A nonvisual component can be added even with no rows selected.
            try click(editor, window: window, x: 110, fromTop: 195)
            try await Task.sleep(nanoseconds: 100_000_000)
            try click(editor, window: window, x: 1038, fromTop: 712)
            try await until { !model.busy }
            try check(model.activeBoard?.services.count == 2 && model.activeBoard?.rows?.isEmpty == true,
                      "categorized service insertion saves without taking any row columns")
            window.contentView = NSHostingView(rootView: NotebookBoardView(model: model, board: board, onDesign: {}))
            try await Task.sleep(nanoseconds: 150_000_000)
            try snapshot(window.contentView!, to: output.appendingPathComponent("periodic-runtime.png"))
        }
        model.boardEditorOpen = false
    }
    @MainActor private static func click(_ view: NSView, window: NSWindow, x: Double, fromTop: Double) throws {
        let point = view.convert(NSPoint(x: x, y: view.isFlipped ? fromTop : view.bounds.height - fromTop), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw PeriodicFailure(message: "mouse event missing")
            }
            window.sendEvent(event)
        }
    }
    @MainActor private static func snapshot(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw PeriodicFailure(message: "bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PeriodicFailure(message: "PNG") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }
}

import AppKit
import Foundation
import SwiftUI

private struct ConfigFailure: Error { let message: String }
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw ConfigFailure(message: message) }
}

@main private enum ConfigTests {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sputnik-config-\(UUID())")
        var active: NotebookModel?
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try codecTests(root)
            for isolated in [false, true] {
                guard !isolated || option("--worker") != nil else { continue }
                let project = root.appendingPathComponent(isolated ? "worker.sputnikbook" : "local.sputnikbook")
                try FileManager.default.copyItem(at: URL(fileURLWithPath: "tools/notebook-macos/Samples/Config Editor.sputnikbook"), to: project)
                let model = NotebookModel(workerExecutable: isolated ? option("--worker") : nil); active = model
                try await exercise(model, project: project, native: !isolated)
                await shutdown(model); active = nil
            }
            print("Config Editor tests passed: validation, exact JSON, files, native draft/Apply/Reset, board/cell/forms, Watch/Manual and workers")
        } catch {
            if let active { await shutdown(active) }
            fputs("Config Editor tests failed: \(error)\n", stderr); exit(1)
        }
    }

    private static func codecTests(_ root: URL) throws {
        let source = #" {"seed":9223372036854775807,"small":-9223372036854775808,"rate":1.2300e-4,"name":"\u03b1","nested":[null,true,{"α":"😀"}]} "#
        try check(try NotebookConfigJSON.process(source) == source, "validation rewrote source")
        let pretty = try NotebookConfigJSON.process(source, pretty: true)
        try check(pretty.contains("9223372036854775807") && pretty.contains("-9223372036854775808") && pretty.contains("1.2300e-4") && pretty.contains(#""\u03b1""#), "Format rounded or rewrote scalar lexemes")
        try check(try NotebookConfigJSON.process(pretty, pretty: true) == pretty, "Format is not stable")
        try check(NotebookConfigJSON.error("\"" + String(repeating: "a", count: 65_534) + "\"") == nil, "64 KiB boundary rejected")
        for valid in ["null", "true", "42", "0.5", #""text""#, "[]", "{}"] {
            try check(NotebookConfigJSON.error(valid) == nil, "valid JSON rejected: \(valid)")
        }
        for invalid in ["", "{", "[1,]", "true false", #"{"x":1,"\u0078":2}"#, #"{"a":{"x":1,"x":2}}"#,
                        "9223372036854775808", "-9223372036854775809", "1e999", "{\"a\":NaN}", "\u{0}",
                        String(repeating: "[", count: 66) + "0" + String(repeating: "]", count: 66), String(repeating: " ", count: 65_537)] {
            try check(NotebookConfigJSON.error(invalid) != nil, "invalid JSON accepted: \(invalid.prefix(80))")
        }
        try check(NotebookConfigJSON.error("{\n  \"a\":\n}")?.contains("3:1") == true, "missing line/column diagnostic")
        let file = root.appendingPathComponent("config.json")
        try NotebookConfigJSON.write(source, to: file)
        try check(try NotebookConfigJSON.read(file) == source && Data(contentsOf: file) == Data(source.utf8), "file roundtrip rewrote source")
        try Data(repeating: 32, count: 65_537).write(to: file)
        do { _ = try NotebookConfigJSON.read(file); throw ConfigFailure(message: "oversized import accepted") } catch is ConfigFailure { throw ConfigFailure(message: "oversized import accepted") } catch {}
        try Data([0xff]).write(to: file)
        do { _ = try NotebookConfigJSON.read(file); throw ConfigFailure(message: "invalid UTF-8 accepted") } catch is ConfigFailure { throw ConfigFailure(message: "invalid UTF-8 accepted") } catch {}
        let tool = NotebookComponentTool.tool("config_editor")
        try check(tool.componentKind == "input" && tool.category == .controls && NotebookCellUI.paletteKinds.contains("config_editor"), "palette integration missing")
        let input = NotebookProjectInput(id: "config", title: "Config", type: "string", value_json: "\"{}\"", minimum: nil, maximum: nil)
        try check(NotebookInputEditing.error("{", input: input, control: .init(style: "json")) != nil, "form accepts invalid JSON")
        let yaml = "# Keep this comment\nmessage: |\n  first\n  second\nseed: 9223372036854775807\nitems: [one, two]\n"
        let toml = "# Keep this comment\nseed = 9223372036854775807\nmessage = '''first\nsecond'''\n[optimizer]\nrate = 0.25\n"
        for (format, source) in [(NotebookConfigFormat.yaml, yaml), (.toml, toml)] {
            try check(try NotebookConfigJSON.process(source, format: format) == source, "\(format.title) validation rewrote source")
            let file = root.appendingPathComponent("config." + format.rawValue)
            try NotebookConfigJSON.write(source, to: file, format: format)
            try check(try NotebookConfigJSON.read(file, format: format) == source, "\(format.title) import/export lost comments")
            let settings = NotebookInputControl(style: "json", config_format: format.rawValue)
            let decoded = try JSONDecoder().decode(NotebookInputControl.self, from: JSONEncoder().encode(settings))
            try check(decoded.configFormat == format, "format setting lost in Codable")
        }
        for source in ["a: [1, 2", "a: 1\na: 2", "---\na: 1\n---\nb: 2", "x: .inf", "x: !custom data", "? [a, b]\n: value"] {
            try check(NotebookConfigJSON.error(source, format: .yaml) != nil, "invalid/unsupported YAML accepted: \(source)")
        }
        for source in ["a = [1,", "a = 1\na = 2", "x = 9223372036854775808", "x = inf", "[unclosed"] {
            try check(NotebookConfigJSON.error(source, format: .toml) != nil, "invalid TOML accepted: \(source)")
        }
    }

    @MainActor private static func exercise(_ model: NotebookModel, project: URL, native: Bool) async throws {
        let opened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
        try check(opened, model.error ?? "open failed")
        try check(!cell(model, "2").ok, "opening executed code")
        let initial = model.snapshot!.inputs!.first!.editingText
        let board = model.snapshot!.boards!.first!
        try check(board.components.first?.control?.style == "json", "board style lost")
        let savedBoard = await withCheckedContinuation { c in model.saveBoard(board) { c.resume(returning: $0) } }
        try check(savedBoard, model.error ?? "board roundtrip failed")
        try check(await perform(model, "run_all"), model.error ?? "run failed")
        try check(cell(model, "2").result == "10" && Double(cell(model, "3").result) == 1.5 && cell(model, "4").result == "10", "sample values incorrect")
        try check(cell(model, "5").result.contains("9223372036854775807"), "runtime rounded seed")
        try check(Double(cell(model, "6").result) == 1.75 && Double(cell(model, "7").result) == 4 && cell(model, "8").result == "11",
                  "YAML/TOML runtime read/serialize failed: \(cell(model, "6").error), \(cell(model, "7").error), \(cell(model, "8").error)")
        try check(!(await inputs(model, ["yaml": quote("x: ["), "toml": quote("epochs = 99")])), "invalid YAML batch accepted")
        model.clearError()
        try check(model.snapshot!.inputs!.first(where: { $0.id == "toml" })!.editingText.contains("epochs = 8"), "invalid YAML batch partially published TOML")
        let nextYAML = "# New source\nepochs: 12\noptimizer: {rate: 0.5}\n"
        let nextTOML = "epochs = 14\n[optimizer]\nrate = 0.5\n"
        try check(await inputs(model, ["yaml": quote(nextYAML), "toml": quote(nextTOML)]), model.error ?? "YAML/TOML Apply failed")
        try check(Double(cell(model, "6").result) == 6 && Double(cell(model, "7").result) == 7, "YAML/TOML Watch readers not updated")
        if native { try await nativeEditor(model) }
        let updated = #"{"epochs":20,"optimizer":{"rate":0.01},"seed":9223372036854775807}"#
        try check(await inputs(model, ["training": quote(updated)]), model.error ?? "project Apply failed")
        let manual = model.presentation(for: cell(model, "4"), in: model.snapshot!.tabs.first!)
        try check(cell(model, "2").result == "20" && manual.result?.text == "10" && manual.stale,
                  "Watch/Manual semantics failed: watch=\(cell(model, "2").result), manual=\(String(describing: manual.result?.text)), stale=\(manual.stale)")
        try check(Double(cell(model, "3").result) == 1.5, "project config leaked into cell scope")
        try check(!(await inputs(model, ["training": quote(#"{"epochs":99,"epochs":100}"#)])), "duplicate input accepted")
        model.clearError()
        try check(model.snapshot!.inputs!.first!.editingText == updated && cell(model, "2").result == "20", "failed Apply changed accepted config")
        let tab = model.snapshot!.tabs.first!, local = cell(model, "3")
        var ui = local.cell_ui!
        // One form transaction updates a JSON config and an integer together.
        ui.inputs.append(.init(id: "other", title: "Other", type: "integer", default_json: "1"))
        ui.pre = [.init(id: "form", kind: "parameter_form", title: "Config form", fields: [
            .init(input: "training", control: .init(style: "json")), .init(input: "other", control: .init())])]
        let saved = await withCheckedContinuation { c in model.saveCellUI(ui, cell: local, tab: tab) { c.resume(returning: $0) } }
        try check(saved, model.error ?? "local form save failed")
        let rejected = await withCheckedContinuation { c in model.setCellInputs(["training": quote("{"), "other": "2"], cell: cell(model, "3"), tab: model.snapshot!.tabs.first!) { c.resume(returning: $0) } }
        try check(!rejected, "invalid JSON form accepted")
        model.clearError()
        try check(cell(model, "3").cell_inputs!.first(where: { $0.id == "other" })!.editingText == "1", "invalid form partially published")
        let localText = #"{"epochs":8,"optimizer":{"rate":0.5}}"#
        let applied = await withCheckedContinuation { c in model.setCellInputs(["training": quote(localText), "other": "2"], cell: cell(model, "3"), tab: model.snapshot!.tabs.first!) { c.resume(returning: $0) } }
        try check(applied && Double(cell(model, "3").result) == 4 && cell(model, "2").result == "20", "local form Apply or isolation failed")
        ui = cell(model, "3").cell_ui!
        ui.inputs[0].default_json = quote(localText)
        let savedDefault = await withCheckedContinuation { c in model.saveCellUI(ui, cell: cell(model, "3"), tab: model.snapshot!.tabs.first!) { c.resume(returning: $0) } }
        try check(savedDefault, "save local default failed")
        let reopened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
        try check(reopened && model.snapshot!.inputs!.first!.editingText == initial, "session value overwrote saved project default")
        try check(cell(model, "3").cell_inputs!.first!.editingText == localText && cell(model, "3").cell_ui!.pre.first!.fields!.first!.control.style == "json", "local default or control did not survive reopen")
    }

    @MainActor private static func nativeEditor(_ model: NotebookModel) async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let host = NSHostingView(rootView: ConfigHost(model: model).padding(20).background(NotebookPalette.canvas).foregroundStyle(NotebookPalette.ink))
        window.contentView = host
        try await Task.sleep(nanoseconds: 150_000_000); host.layoutSubtreeIfNeeded()
        func textViews(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
        try check(textViews(host).isEmpty, "compact component contains an inline editor")
        try capture(host, name: "compact.png")
        let accepted = model.snapshot!.inputs!.first!.editingText
        func click(_ view: NSView, window: NSWindow, x: CGFloat, top: CGFloat) throws {
            view.layoutSubtreeIfNeeded()
            let point = view.convert(NSPoint(x: x, y: view.isFlipped ? top : view.bounds.height - top), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                    throw ConfigFailure(message: "native mouse event missing")
                }
                window.sendEvent(event)
            }
        }
        func open() async throws -> (NSWindow, NSView, NSTextView) {
            try click(host, window: window, x: host.bounds.width - 50, top: host.bounds.height / 2)
            try await Task.sleep(nanoseconds: 180_000_000)
            guard let sheet = NSApplication.shared.windows.first(where: { $0.sheetParent != nil && $0.contentView.map { !textViews($0).isEmpty } == true }), let content = sheet.contentView,
                  let editor = textViews(content).first else {
                let detail = NSApplication.shared.windows.map { "\($0.title): sheet=\($0.sheetParent != nil), textViews=\($0.contentView.map { textViews($0).count } ?? -1)" }.joined(separator: "; ")
                throw ConfigFailure(message: "JSON editor modal missing: \(detail)")
            }
            content.layoutSubtreeIfNeeded()
            return (sheet, content, editor)
        }
        var (modal, content, editor) = try await open()
        try capture(content, name: "modal.png")
        func edit(_ text: String) {
            modal.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
        func press(_ identifier: String) throws {
            let x: CGFloat = identifier == "config-reset" ? 50 : identifier == "config-cancel" ? content.bounds.width - 143 : content.bounds.width - 55
            let top: CGFloat = identifier == "config-format" ? 70 : content.bounds.height - 36
            try click(content, window: modal, x: x, top: top)
        }
        edit("{\n  \"epochs\":\n}")
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(model.snapshot!.inputs!.first!.editingText == accepted && cell(model, "2").result == "10", "typing published invalid draft")
        try capture(content, name: "invalid.png")
        edit("{")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try check(editor.string == "{\n  ", "JSON newline did not preserve indentation")
        try press("config-reset")
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(editor.string == accepted, "Reset did not restore accepted source")
        edit(#"{"epochs":99}"#)
        try await Task.sleep(nanoseconds: 80_000_000)
        try press("config-cancel")
        try await Task.sleep(nanoseconds: 180_000_000)
        try check(!modal.isVisible && model.snapshot!.inputs!.first!.editingText == accepted, "Cancel published a modal draft")
        (modal, content, editor) = try await open()
        try check(editor.string == accepted, "cancelled draft survived reopening")
        let compact = #"{"epochs":12,"alpha":"alpha","seed":9223372036854775807}"#
        edit(compact)
        try await Task.sleep(nanoseconds: 80_000_000)
        try press("config-format")
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(editor.string.contains("9223372036854775807") && editor.string.contains("alpha") && !editor.string.contains("α") && editor.string.contains("\n"), "native Format changed scalar values")
        (editor as? FocusTrackingTextView)?.undo(nil)
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(editor.string == compact, "Format was not undoable")
        try press("config-format")
        try await Task.sleep(nanoseconds: 80_000_000)
        try check(cell(model, "2").result == "10", "Format published draft")
        try capture(content, name: "light.png")
        try press("config-apply")
        let deadline = Date().addingTimeInterval(10)
        while (cell(model, "2").result != "12" || modal.isVisible) && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(cell(model, "2").result == "12" && !modal.isVisible, "modal Apply did not publish and close")
        try check(textViews(host).isEmpty, "applied config expanded into an inline editor")
        let dark = NSHostingView(rootView: ConfigHost(model: model).padding(20).background(NotebookPalette.canvas).foregroundStyle(NotebookPalette.ink).environment(\.colorScheme, .dark))
        window.contentView = dark
        try await Task.sleep(nanoseconds: 100_000_000); dark.layoutSubtreeIfNeeded()
        try capture(dark, name: "dark.png")

        // A form's modal edits only its draft. The form's Apply publishes later.
        let form = NSHostingView(rootView: NotebookParameterFormView(model: model, fields: [.init(input: "training", control: .init(style: "json"))]).padding(20)
            .frame(width: 780, height: 180, alignment: .topLeading)
            .background(NotebookPalette.canvas).foregroundStyle(NotebookPalette.ink).environment(\.colorScheme, .light))
        window.contentView = form
        window.setContentSize(NSSize(width: 780, height: 180))
        try await Task.sleep(nanoseconds: 100_000_000); form.layoutSubtreeIfNeeded()
        try capture(form, name: "form-compact.png")
        // The compact row sits between the field title and the form footer.
        try click(form, window: window, x: form.bounds.width - 50, top: 57)
        try await Task.sleep(nanoseconds: 180_000_000)
        guard let formModal = NSApplication.shared.windows.first(where: { $0.sheetParent != nil && $0.contentView.map { !textViews($0).isEmpty } == true }), let formContent = formModal.contentView,
              let formEditor = textViews(formContent).first else {
            throw ConfigFailure(message: "form config modal missing")
        }
        formModal.makeFirstResponder(formEditor)
        formEditor.setSelectedRange(NSRange(location: 0, length: formEditor.string.utf16.count))
        formEditor.insertText(#"{"epochs":13}"#, replacementRange: formEditor.selectedRange())
        try await Task.sleep(nanoseconds: 80_000_000)
        try click(formContent, window: formModal, x: formContent.bounds.width - 65, top: formContent.bounds.height - 36)
        try await Task.sleep(nanoseconds: 180_000_000)
        try check(!formModal.isVisible && cell(model, "2").result == "12", "form modal bypassed atomic Apply")
        try capture(form, name: "form-staged.png")
        try click(form, window: window, x: form.bounds.width - 50, top: 89)
        let formDeadline = Date().addingTimeInterval(10)
        while cell(model, "2").result != "13" && Date() < formDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(cell(model, "2").result == "13", "form Apply did not publish staged modal config")

        for format in [NotebookConfigFormat.yaml, .toml] {
            let config = NSHostingView(rootView: ConfigHost(model: model, inputID: format.rawValue, format: format).padding(20)
                .background(NotebookPalette.canvas).foregroundStyle(NotebookPalette.ink).environment(\.colorScheme, .light))
            window.contentView = config
            try await Task.sleep(nanoseconds: 100_000_000); config.layoutSubtreeIfNeeded()
            try check(textViews(config).isEmpty, "YAML/TOML expanded inline")
            try click(config, window: window, x: config.bounds.width - 50, top: config.bounds.height / 2)
            try await Task.sleep(nanoseconds: 180_000_000)
            guard let sheet = NSApplication.shared.windows.first(where: { $0.sheetParent != nil && $0.contentView.map { !textViews($0).isEmpty } == true }),
                  let view = sheet.contentView, let source = textViews(view).first else { throw ConfigFailure(message: "\(format.title) modal missing") }
            let text = format == .yaml ? "# Native edit\nepochs: 22\noptimizer: {rate: 0.5}\n" : "# Native edit\nepochs = 24\n[optimizer]\nrate = 0.5\n"
            sheet.makeFirstResponder(source)
            source.setSelectedRange(NSRange(location: 0, length: source.string.utf16.count))
            source.insertText(text, replacementRange: source.selectedRange())
            try await Task.sleep(nanoseconds: 80_000_000)
            try capture(view, name: format.rawValue + "-modal.png")
            try click(view, window: sheet, x: view.bounds.width - 55, top: view.bounds.height - 36)
            let end = Date().addingTimeInterval(10)
            while sheet.isVisible && Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
            try check(!sheet.isVisible && model.snapshot!.inputs!.first(where: { $0.id == format.rawValue })!.editingText == text, "\(format.title) modal Apply failed")
        }
    }

    private struct ConfigHost: View {
        @ObservedObject var model: NotebookModel
        var inputID = "training"
        var format: NotebookConfigFormat = .json
        var body: some View {
            if let input = model.snapshot?.inputs?.first(where: { $0.id == inputID }) {
                NotebookBoardInputView(model: model, input: input, control: .init(style: "json", config_format: format.rawValue))
            }
        }
    }
    private static func quote(_ text: String) -> String { String(decoding: try! JSONEncoder().encode(text), as: UTF8.self) }
    @MainActor private static func cell(_ model: NotebookModel, _ id: String) -> NotebookCell { model.snapshot!.tabs.first!.cells.first { $0.id == id }! }
    @MainActor private static func perform(_ model: NotebookModel, _ action: String) async -> Bool {
        await withCheckedContinuation { c in model.perform(action) { c.resume(returning: $0) } }
    }
    @MainActor private static func inputs(_ model: NotebookModel, _ values: [String: String]) async -> Bool {
        await withCheckedContinuation { c in model.setProjectInputs(values) { c.resume(returning: $0) } }
    }
    @MainActor private static func shutdown(_ model: NotebookModel) async { await withCheckedContinuation { c in model.shutdown { c.resume() } } }
    private static func option(_ name: String) -> String? {
        CommandLine.arguments.firstIndex(of: name).flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
    }
    @MainActor private static func capture(_ view: NSView, name: String) throws {
        guard let output = option("--output") else { return }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ConfigFailure(message: "bitmap missing") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ConfigFailure(message: "PNG missing") }
        let root = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(name))
    }
}

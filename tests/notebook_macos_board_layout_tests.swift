import AppKit
import SwiftUI

private struct BoardLayoutFailure: Error { let message: String }
private func check(_ value: Bool, _ message: String) throws {
    if !value { throw BoardLayoutFailure(message: message) }
}

private final class CellMeasurements {
    var frames: [Int: CGRect] = [:]
}

private final class RangeSliderTestState: ObservableObject {
    @Published var text = "(5..15:3)"
    @Published var control = NotebookInputControl(style: "slider", minimum: 0, maximum: 20, step: 1,
        start_minimum: 0, start_maximum: 10, finish_minimum: 10, finish_maximum: 20)
}
private struct RangeSliderHarness: View {
    @ObservedObject var state: RangeSliderTestState
    var body: some View {
        NotebookRangeControlView(text: $state.text, control: state.control)
            .padding(24).frame(width: 480)
            .background(NotebookPalette.canvas).foregroundStyle(NotebookPalette.ink)
    }
}
private struct MeasuredCell: NSViewRepresentable {
    let index: Int, measurements: CellMeasurements
    func makeNSView(context: Context) -> MeasuringView {
        let view = MeasuringView()
        view.index = index; view.measurements = measurements
        return view
    }
    func updateNSView(_ view: MeasuringView, context: Context) {}
}
private final class MeasuringView: NSView {
    var index = 0
    var measurements: CellMeasurements?
    override var intrinsicContentSize: NSSize { NSSize(width: 80, height: 70) }
    override func layout() {
        super.layout()
        measurements?.frames[index] = convert(bounds, to: nil)
    }
}

@main
private enum BoardLayoutTests {
    @MainActor static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sputnik-board-layout-\(UUID().uuidString)")
        let model = NotebookModel()
        var window: NSWindow?
        defer { window?.close(); try? FileManager.default.removeItem(at: root) }
        do {
            try await dragTests()
            try panelGridTests()
            try inputBindingTests()
            try await rangeSliderUITests()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await inputAuthoringTests(root: root)
            let project = root.appendingPathComponent("Designer.sputnikbook")
            let opened = await withCheckedContinuation { continuation in
                model.open(url: project, create: true) { continuation.resume(returning: $0) }
            }
            try check(opened, model.error ?? "open test project")
            let input = await withCheckedContinuation { continuation in
                model.perform("new_input", text: #"{"id":"gain","title":"Gain","type":"number","default":2}"#) {
                    continuation.resume(returning: $0)
                }
            }
            try check(input, "create test input")
            var board = NotebookBoard(id: "dashboard", title: "Training Dashboard", sheet: "main", columns: 2, components: [],
                                      rows: [NotebookBoardRow(id: "controls", height: 120), NotebookBoardRow(id: "charts", height: 220)])
            board.components = [
                NotebookBoardComponent(id: "gain", kind: "input", title: "Learning rate", input: "gain", row: "controls", span: 4),
                NotebookBoardComponent(id: "result", kind: "text", title: "Accuracy", cell: "1", row: "controls", span: 4, h_align: "center", v_align: "center"),
                NotebookBoardComponent(id: "run", kind: "run", title: "Train model", cell: "1", row: "controls", span: 4, h_align: "trailing", v_align: "bottom"),
                NotebookBoardComponent(id: "loss", kind: "live_chart", title: "Training loss", chart_id: "loss", x_label: "Step", y_label: "Loss",
                                       stroke: "#b98391", row: "charts", span: 8, v_align: "stretch")
            ]
            let saved = await withCheckedContinuation { continuation in
                model.saveBoard(board) { continuation.resume(returning: $0) }
            }
            try check(saved, model.error ?? "save row fixture")
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
            guard let window else { throw BoardLayoutFailure(message: "window missing") }
            window.isReleasedWhenClosed = false
            window.title = "Board Designer Verification"
            window.center()

            let measurements = CellMeasurements()
            let layout = NSHostingView(rootView: NotebookBoardRowLayout(height: 180) {
                MeasuredCell(index: 0, measurements: measurements).layoutValue(key: BoardColumnSpan.self, value: 4)
                MeasuredCell(index: 1, measurements: measurements).layoutValue(key: BoardColumnSpan.self, value: 8)
            }.frame(width: 768, height: 180))
            layout.frame = NSRect(x: 0, y: 0, width: 768, height: 180)
            window.contentView = layout
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds: 150_000_000)
            layout.layoutSubtreeIfNeeded()
            let frames = measurements.frames
            try check(frames.count == 2, "layout measured both cells")
            try check(abs((frames[0]?.width ?? 0) - 248) < 1 &&
                      abs((frames[1]?.width ?? 0) - 508) < 1 &&
                      abs((frames[1]?.minX ?? 0) - (frames[0]?.maxX ?? 0) - 12) < 1 &&
                      abs((frames[0]?.height ?? 0) - 180) < 1, "4/8 spans, gutter and explicit height reach the native view")

            let output = CommandLine.arguments.firstIndex(of: "--output").map { CommandLine.arguments[$0 + 1] }
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: NotebookBoardEditor(model: model, board: board, document: model.documentIdentity)
                    .environment(\.colorScheme, scheme))
                window.contentView = host
                try await Task.sleep(nanoseconds: 200_000_000)
                host.layoutSubtreeIfNeeded()
                if let output {
                    let name = scheme == .light ? "board-designer-light.png" : "board-designer-dark.png"
                    try snapshot(host, path: URL(fileURLWithPath: output).appendingPathComponent(name))
                }
            }
            model.boardEditorOpen = false
            let running = NSHostingView(rootView: NotebookBoardView(model: model, board: board, onDesign: {}))
            window.contentView = running
            try await Task.sleep(nanoseconds: 200_000_000)
            running.layoutSubtreeIfNeeded()
            if let output { try snapshot(running, path: URL(fileURLWithPath: output).appendingPathComponent("board-runtime.png")) }

            try check(board.moveComponent("gain", to: "charts"), "move component into exactly four remaining columns")
            let moved = await withCheckedContinuation { continuation in
                model.saveBoard(board) { continuation.resume(returning: $0) }
            }
            try check(moved && model.activeBoard?.components(in: "charts").map(\.id) == ["loss", "gain"] &&
                      model.activeBoard?.components.first(where: { $0.id == "gain" })?.input == "gain",
                      "cross-row move saves target order and input binding")
            try await tabsUITests(model: model, window: window, board: board, output: output)
            try await presentationUITests(model: model, window: window, output: output)
            await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
            print("notebook macOS board layout tests passed")
        } catch {
            fputs("board layout tests failed: \(error)\n", stderr)
            exit(1)
        }
    }
    @MainActor private static func dragTests() async throws {
        let session = UUID()
        var board = NotebookBoard(id: "drag", title: "Drag", sheet: "main", columns: 2, components: [
            NotebookBoardComponent(id: "source", kind: "text", title: "Value", cell: "1", binding: "accuracy",
                                   row: "a", span: 4, h_align: "center", v_align: "bottom"),
            NotebookBoardComponent(id: "first", kind: "text", title: "First", cell: "1", row: "b", span: 4),
            NotebookBoardComponent(id: "second", kind: "text", title: "Second", cell: "1", row: "b", span: 4)
        ], rows: [NotebookBoardRow(id: "a"), NotebookBoardRow(id: "b"), NotebookBoardRow(id: "empty")])
        let original = board.components[0]
        let drag = NotebookBoardComponentDrag(session: session, board: board.id, component: original.id)
        try check(drag.canDrop(in: board, session: session, row: "b") &&
                  drag.canDrop(in: board, session: session, row: "empty"), "drop accepts partially filled and empty rows")
        try check(!drag.canDrop(in: board, session: session, row: "a") &&
                  !drag.canDrop(in: board, session: UUID(), row: "b") &&
                  !drag.canDrop(in: board, session: session, row: "deleted"), "same row, other editor and missing row reject drops")
        var foreign = board; foreign.id = "other"
        try check(!drag.canDrop(in: foreign, session: session, row: "b"), "another board cannot receive the component")
        let geometry = NotebookBoardDragGeometry(rows: ["a": CGRect(x: 0, y: -20, width: 800, height: 100),
                                                       "b": CGRect(x: 0, y: 96, width: 800, height: 180)],
                                                  viewport: CGRect(x: 0, y: 0, width: 800, height: 200))
        try check(geometry.row(at: CGPoint(x: 200, y: 30)) == "a" &&
                  geometry.row(at: CGPoint(x: 200, y: 120)) == "b" &&
                  geometry.row(at: CGPoint(x: 200, y: 90)) == nil &&
                  geometry.row(at: CGPoint(x: 200, y: 240)) == nil &&
                  geometry.row(at: CGPoint(x: -10, y: 120)) == nil,
                  "drop hit testing follows scrolled row frames and excludes gaps and clipped rows")
        board.components[0].span = 5
        try check(!drag.canDrop(in: board, session: session, row: "b") &&
                  !board.moveComponent(original.id, to: "b") && board.components[0].row == "a",
                  "full row rejects a drop without moving or shrinking the component")
        board.components[0] = original
        try check(board.moveComponent(original.id, to: "b") && board.components(in: "b").map(\.id) == ["first", "second", "source"] &&
                  board.availableColumns(in: "a") == 12 && board.availableColumns(in: "b") == 0,
                  "drop appends to target and releases source capacity")
        let moved = board.components.last!
        try check(moved.span == original.span && moved.binding == original.binding && moved.cell == original.cell &&
                  moved.h_align == original.h_align && moved.v_align == original.v_align,
                  "drag retains width, binding and both alignments")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(board)
        try check(board.moveComponent(original.id, to: "b") && before == encoder.encode(board),
                  "same-row move keeps ordering unchanged")
        board.components.removeAll { $0.id == original.id }
        try check(!drag.canDrop(in: board, session: session, row: "empty"), "a component removed during drag cannot be dropped")
    }
    private static func panelGridTests() throws {
        let nested = NotebookBoardComponent(id: "nested", kind: "tabs", title: "Nested", row: "content", span: 12,
            panels: [NotebookBoardPanel(id: "deep", title: "Deep", rows: [NotebookBoardRow(id: "content")], components: [])])
        var board = NotebookBoard(id: "panels", title: "Panels", sheet: "main", columns: 2, components: [
            NotebookBoardComponent(id: "tabs", kind: "tabs", title: "Workspace", row: "root", span: 12, panels: [
                NotebookBoardPanel(id: "first", title: "First", rows: [NotebookBoardRow(id: "content")], components: [nested]),
                NotebookBoardPanel(id: "second", title: "Second", rows: [NotebookBoardRow(id: "content")], components: [
                    NotebookBoardComponent(id: "sibling", kind: "text", title: "Sibling", cell: "1", row: "content", span: 12)])])
        ], rows: [NotebookBoardRow(id: "root")])
        let path = [NotebookBoardGridPath(component: "tabs", panel: "first"), NotebookBoardGridPath(component: "nested", panel: "deep")]
        guard var grid = board.grid(at: path) else { throw BoardLayoutFailure(message: "nested grid missing") }
        grid.rows?[0].height = 240
        grid.components.append(NotebookBoardComponent(id: "leaf", kind: "text", title: "Value", cell: "1", binding: "loss",
                                                       row: "content", span: 7, h_align: "center", v_align: "bottom"))
        let added = grid.appendRow()
        let drag = NotebookBoardComponentDrag(session: UUID(), board: board.id, component: "leaf")
        try check(drag.canDrop(in: grid, session: drag.session, row: added) && grid.moveComponent("leaf", to: added),
                  "drag operations work inside a panel grid")
        try check(board.updateGrid(grid, at: path), "nested panel updates reach their owner")
        try check(board.grid(at: path)?.components.first?.binding == "loss" &&
                  board.grid(at: path)?.rows?.first?.height == 240 &&
                  board.grid(at: [NotebookBoardGridPath(component: "tabs", panel: "second")])?.components.first?.id == "sibling" &&
                  board.components.first?.row == "root" && board.allComponents.count == 4 && board.allRows.count == 5,
                  "nested geometry, bindings and counts survive independently of sibling and parent grids")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(board)
        try check(!board.updateGrid(grid, at: [NotebookBoardGridPath(component: "deleted", panel: "first")]) &&
                  before == encoder.encode(board), "stale panel paths cannot overwrite the root grid")
        let roundtrip = try JSONDecoder().decode(NotebookBoard.self, from: before)
        try check(roundtrip.grid(at: path)?.components.first?.row == added, "Swift Codable preserves nested grids")
        board.removeRow("root")
        try check(board.allComponents.isEmpty && board.allRows.isEmpty, "deleting a container row deletes its panel subtree")
    }

    private static func inputBindingTests() throws {
        let range = try NotebookRangeValue.parse("(0...15:3)")
        try check(!range.inclusive && range.step == "3" && range.expression == "(0...15:3)", "exclusive stepped Sputnik range parses")
        let exact = try NotebookRangeValue.decode(#"{"start":9007199254740993,"finish":9223372036854775807,"inclusive_end":true,"step":2}"#)
        try check(exact.start == "9007199254740993" && exact.finish == "9223372036854775807", "range JSON preserves Int64")
        let decimal = try NotebookRangeValue.decode(#"{"start":0.0,"finish":1.0,"inclusive_end":false,"step":0.25}"#)
        try check(decimal.start == "0.0" && decimal.step == "0.25", "range JSON retains Float endpoint types")
        let descending = try NotebookRangeValue.parse("(15..0:-3)")
        try check(descending.inclusive && descending.step == "-3", "descending ranges use negative steps")
        let shared = NotebookInputControl(style: "slider", minimum: 0, maximum: 20, step: 1)
        let sharedRules = try NotebookRangeSliderRules(control: shared, value: range)
        let crossing = sharedRules.moving(range, start: true, to: 99)
        try check(crossing.start == "15" && crossing.finish == "15" && crossing.step == "3" && !crossing.inclusive,
                  "shared slider clamps crossing and retains Range step and boundary mode")
        let equal = sharedRules.moving(crossing, start: false, to: -99)
        try check(equal.start == equal.finish, "finish thumb cannot cross start")
        let split = NotebookInputControl(style: "range_sliders", step: 1, start_minimum: 0, start_maximum: 10, finish_minimum: 5, finish_maximum: 20)
        let separateRules = try NotebookRangeSliderRules(control: split, value: range)
        try check(separateRules.moving(range, start: true, to: 99).start == "10" &&
                  separateRules.moving(range, start: false, to: -99).finish == "5", "separate sliders use independent domains")
        var moving = try NotebookRangeValue.parse("(5..15:3)")
        for _ in 0..<20 {
            moving = separateRules.moving(moving, start: true, to: 19)
            moving = separateRules.moving(moving, start: false, to: -5)
            try check(separateRules.error(moving) == nil, "repeated moves preserve domains and order")
        }
        let savedControl = try JSONDecoder().decode(NotebookInputControl.self, from: JSONEncoder().encode(split))
        try check(savedControl.start_maximum == 10 && savedControl.finish_minimum == 5 && savedControl.style == "range_sliders", "slider modes and endpoint domains roundtrip")
        let rangeInput = NotebookProjectInput(id: "r", title: "Range", type: "range", value_json: range.json, minimum: nil, maximum: nil)
        try check(NotebookInputEditing.error("(9..7:1)", input: rangeInput, control: split) != nil &&
                  NotebookInputEditing.error("(0..21:1)", input: rangeInput, control: shared) != nil,
                  "UI rejects crossing endpoints and out-of-domain values")
        let floatRules = try NotebookRangeSliderRules(control: NotebookInputControl(style: "slider", minimum: 0, maximum: 1, step: 0.1), value: decimal)
        let floatMove = floatRules.moving(decimal, start: false, to: 0.43)
        try check(abs((Double(floatMove.finish) ?? 0) - 0.4) < 1e-12 && floatMove.step == "0.25", "slider increment is independent of Range step")
        for text in ["(0...15:0)", "(0...15:0.5)", "(0...15:1e999)", "(0...9223372036854775808:1)", "(0...15:3"] {
            var rejected = false; do { _ = try NotebookRangeValue.parse(text) } catch { rejected = true }
            try check(rejected, "invalid range rejected: " + text)
        }
        let inputs = [
            NotebookProjectInput(id: "gain", title: "Gain", type: "number", value_json: "2", minimum: nil, maximum: nil),
            NotebookProjectInput(id: "range", title: "Range", type: "range", value_json: #"{"start":0,"finish":15,"inclusive_end":false,"step":3}"#, minimum: nil, maximum: nil),
            NotebookProjectInput(id: "path", title: "Path", type: "string", value_json: "\"\"", minimum: nil, maximum: nil)
        ]
        for kind in ["input", "range_input", "date_input", "file_input"] {
            var board = NotebookBoard(id: "draft", title: "Draft", sheet: "main", columns: 1, components: [
                NotebookBoardComponent(id: "control", kind: kind, title: "Unbound control")
            ])
            try check(board.inputBindingError(inputs: [])?.contains("Unbound control") == true,
                      "unbound \(kind) stays editable but explains why saving is unavailable")
            board.components[0].input = kind == "range_input" ? "range" : kind == "input" ? "gain" : "path"
            try check(board.inputBindingError(inputs: inputs) == nil, "valid \(kind) binding allows saving")
            if kind == "range_input" {
                board.components[0].input = "gain"
                try check(board.inputBindingError(inputs: inputs) != nil, "range rejects scalar parameters")
                board.components[0].input = "path"
                try check(board.inputBindingError(inputs: inputs) != nil, "range rejects String parameters")
            } else if kind != "input" {
                board.components[0].input = "gain"
                try check(board.inputBindingError(inputs: inputs) != nil, "\(kind) requires a String parameter")
            }
        }
        let nested = NotebookBoard(id: "nested", title: "Nested", sheet: "main", columns: 1, components: [
            NotebookBoardComponent(id: "tabs", kind: "tabs", title: "Tabs", panels: [
                NotebookBoardPanel(id: "panel", title: "Panel", rows: [], components: [
                    NotebookBoardComponent(id: "control", kind: "input", title: "Nested input", input: "missing")])])
        ])
        try check(nested.inputBindingError(inputs: inputs)?.contains("Nested input") == true,
                  "unbound inputs in nested grids prevent invalid board saves")
    }

    @MainActor private static func rangeSliderUITests() async throws {
        let state = RangeSliderTestState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let host = NSHostingView(rootView: RangeSliderHarness(state: state))
        window.contentView = host; window.setContentSize(host.fittingSize); window.makeKeyAndOrderFront(nil)
        let output = CommandLine.arguments.firstIndex(of: "--output").map { URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) }
        try await Task.sleep(nanoseconds: 150_000_000); host.layoutSubtreeIfNeeded()
        if let output { try snapshot(host, path: output.appendingPathComponent("range-slider-shared.png")) }
        func sliders(_ view: NSView) -> [NSSlider] { (view as? NSSlider).map { [$0] } ?? view.subviews.flatMap(sliders) }
        let shared = sliders(host)
        try check(shared.count == 2, "shared range uses two live native sliders")
        let sharedFrames = shared.map { $0.convert($0.bounds, to: host) }
        try check(sharedFrames[0] == sharedFrames[1], "both native endpoints use the same track coordinates")
        shared[0].doubleValue = shared[0].maxValue
        _ = shared[0].sendAction(shared[0].action, to: shared[0].target)
        try await Task.sleep(nanoseconds: 50_000_000)
        let movedStart = try NotebookRangeValue.parse(state.text)
        try check(movedStart.start == "15" && movedStart.finish == "15" && movedStart.step == "3" && movedStart.inclusive,
                  "shared native start stops at finish and preserves range options: \(movedStart.expression)")
        state.text = "(5..15:3)"
        try await Task.sleep(nanoseconds: 50_000_000)
        shared[1].doubleValue = shared[1].minValue
        _ = shared[1].sendAction(shared[1].action, to: shared[1].target)
        try await Task.sleep(nanoseconds: 50_000_000)
        let movedFinish = try NotebookRangeValue.parse(state.text)
        try check(movedFinish.start == "5" && movedFinish.finish == "5" && movedFinish.step == "3",
                  "shared native finish stops at start: \(movedFinish.expression)")
        state.text = "(5..15:3)"; state.control.style = "range_sliders"
        try await Task.sleep(nanoseconds: 150_000_000); window.setContentSize(host.fittingSize); host.layoutSubtreeIfNeeded()
        let controls = sliders(host)
        try check(controls.count == 2, "native separate sliders are present: \(controls.count)")
        try check(ObjectIdentifier(type(of: shared[0])) == ObjectIdentifier(type(of: controls[0])) &&
                  ObjectIdentifier(type(of: shared[0].cell!)) == ObjectIdentifier(type(of: controls[0].cell!)),
                  "shared thumbs use the same native implementation as ordinary sliders")
        controls[0].doubleValue = controls[0].maxValue
        _ = controls[0].sendAction(controls[0].action, to: controls[0].target)
        try await Task.sleep(nanoseconds: 50_000_000)
        try check(try NotebookRangeValue.parse(state.text).start == "10", "native separate slider updates Range value")
        controls[1].doubleValue = controls[1].minValue
        _ = controls[1].sendAction(controls[1].action, to: controls[1].target)
        try await Task.sleep(nanoseconds: 50_000_000)
        try check(try NotebookRangeValue.parse(state.text).finish == "10", "native finish slider uses its own lower bound")
        if let output { try snapshot(host, path: output.appendingPathComponent("range-slider-separate.png")) }
    }

    @MainActor private static func inputAuthoringTests(root: URL) async throws {
        let model = NotebookModel()
        let opened = await withCheckedContinuation { c in model.open(url: root.appendingPathComponent("Inputs.sputnikbook"), create: true) { c.resume(returning: $0) } }
        try check(opened && model.snapshot?.inputs?.isEmpty != false, "start authoring without project parameters")
        let board = NotebookBoard(id: "inputs", title: "Inputs", sheet: "main", columns: 1, components: [], rows: [NotebookBoardRow(id: "controls")])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let host = NSHostingView(rootView: NotebookBoardEditor(model: model, board: board, document: model.documentIdentity))
        window.contentView = host; window.center(); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 200_000_000); host.layoutSubtreeIfNeeded()
        try click(host, window: window, x: 90, fromTop: 190)
        try await Task.sleep(nanoseconds: 150_000_000); host.layoutSubtreeIfNeeded()
        let output = CommandLine.arguments.firstIndex(of: "--output").map { URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) }
        if let output { try snapshot(host, path: output.appendingPathComponent("input-unbound.png")) }
        // The inspector puts the parameter binding before layout properties.
        try click(host, window: window, x: 905, fromTop: 455)
        for _ in 0..<100 where window.attachedSheet == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        guard let sheet = window.attachedSheet, let content = sheet.contentView else { throw BoardLayoutFailure(message: "create parameter from the input inspector") }
        try await Task.sleep(nanoseconds: 150_000_000)
        try editField("Name used in notebook.input(…)", text: "created_gain", window: sheet)
        try editField("Display title", text: "Created Gain", window: sheet)
        try editField("Default value", text: "3", window: sheet)
        try await Task.sleep(nanoseconds: 150_000_000); content.layoutSubtreeIfNeeded()
        if let output { try snapshot(content, path: output.appendingPathComponent("input-new-parameter.png")) }
        try click(content, window: sheet, x: content.bounds.width - 90, fromTop: content.bounds.height - 35)
        for _ in 0..<100 where window.attachedSheet != nil { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(model.snapshot?.inputs?.contains { $0.id == "created_gain" && $0.type == "number" && Double($0.value_json) == 3 } == true,
                  model.error ?? "creation publishes the parameter: \(model.snapshot?.inputs?.map { $0.id + "=" + $0.value_json } ?? [])")
        try await Task.sleep(nanoseconds: 100_000_000)
        if let output { try snapshot(host, path: output.appendingPathComponent("input-created.png")) }
        try click(host, window: window, x: 1060, fromTop: 713)
        for _ in 0..<100 where model.busy { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(model.activeBoard?.components.first?.input == "created_gain",
                  model.error ?? "newly created parameter is immediately bound and saves with the board")
        model.boardEditorOpen = false
        let reopened = await withCheckedContinuation { c in model.open(url: root.appendingPathComponent("Inputs.sputnikbook")) { c.resume(returning: $0) } }
        try check(reopened && model.snapshot?.boards?.first?.components.first?.input == "created_gain", "created binding survives reopening")
        for (type, name, value) in [("integer", "exact_count", "9223372036854775807"), ("string", "caption", "a\"b"), ("range", "some_range", "(2..20:3)")] {
            var created = false
            let editor = NSHostingView(rootView: NotebookInputEditor(model: model, document: model.documentIdentity) { _ in created = true })
            window.contentView = editor; window.setContentSize(editor.fittingSize)
            try await Task.sleep(nanoseconds: 150_000_000)
            try chooseParameter(NotebookProjectInput.typeTitle(type), in: editor)
            try await Task.sleep(nanoseconds: 100_000_000); window.setContentSize(editor.fittingSize)
            try editField("Name used in notebook.input(…)", text: name, window: window)
            try editField("Display title", text: name, window: window)
            if type == "range" {
                try editField("Start", text: "2", window: window)
                try editField("Finish", text: "20", window: window)
                try editField("Step", text: "3", window: window)
                try chooseParameter("Inclusive (..)", in: editor)
            } else { try editField("Default value", text: value, window: window) }
            try await Task.sleep(nanoseconds: 100_000_000); editor.layoutSubtreeIfNeeded()
            if let output { try snapshot(editor, path: output.appendingPathComponent("input-type-\(type).png")) }
            try click(editor, window: window, x: editor.bounds.width - 90, fromTop: editor.bounds.height - 35)
            for _ in 0..<100 where !created { try await Task.sleep(nanoseconds: 20_000_000) }
            let input = model.snapshot?.inputs?.first { $0.id == name }
            try check(created && input?.type == type && input?.editingText == value, "native type picker creates \(type) parameters without losing the value")
        }
        let rangeBoard = NotebookBoard(id: "ranges", title: "Range input", sheet: "main", columns: 1, components: [
            NotebookBoardComponent(id: "range", kind: "range_input", title: "Range Input", input: "some_range", row: "r", span: 12)
        ], rows: [NotebookBoardRow(id: "r")])
        let rangeSaved = await withCheckedContinuation { c in model.saveBoard(rangeBoard) { c.resume(returning: $0) } }
        try check(rangeSaved, model.error ?? "save Range board")
        let rangeEditor = NSHostingView(rootView: NotebookBoardEditor(model: model, board: rangeBoard, document: model.documentIdentity))
        window.contentView = rangeEditor; window.setContentSize(rangeEditor.fittingSize)
        try await Task.sleep(nanoseconds: 150_000_000); rangeEditor.layoutSubtreeIfNeeded()
        func labels(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(labels) }
        try check(!labels(rangeEditor).contains { $0.stringValue == "Cell result" } &&
                  labels(rangeEditor).contains { $0.placeholderString == "Step" }, "Range preview shows its controls instead of Cell result")
        if let output { try snapshot(rangeEditor, path: output.appendingPathComponent("range-designer.png")) }
        model.boardEditorOpen = false
        let manager = NSHostingView(rootView: NotebookProjectInputsView(model: model))
        window.contentView = manager; window.setContentSize(manager.fittingSize)
        try await Task.sleep(nanoseconds: 150_000_000); manager.layoutSubtreeIfNeeded()
        if let output { try snapshot(manager, path: output.appendingPathComponent("project-inputs-manager.png")) }
        guard let integer = model.snapshot?.inputs?.first(where: { $0.id == "exact_count" }) else { throw BoardLayoutFailure(message: "integer parameter missing") }
        let deleted = await withCheckedContinuation { c in model.deleteProjectInput(integer) { c.resume(returning: $0) } }
        try check(deleted && model.snapshot?.inputs?.contains { $0.id == "exact_count" } == false, "model deletion refreshes the parameter manager")
        let reopenedInputs = await withCheckedContinuation { c in model.open(url: root.appendingPathComponent("Inputs.sputnikbook")) { c.resume(returning: $0) } }
        try check(reopenedInputs && model.snapshot?.inputs?.contains { $0.id == "exact_count" } == false &&
                  model.snapshot?.inputs?.first { $0.id == "caption" }?.editingText == "a\"b", "typed inputs and deletion survive reopening")
        await withCheckedContinuation { c in model.shutdown { c.resume() } }
    }

    @MainActor private static func editField(_ placeholder: String, text: String, window: NSWindow) throws {
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        guard let root = window.contentView, let field = fields(root).first(where: { $0.isEditable && $0.placeholderString == placeholder }) else {
            throw BoardLayoutFailure(message: "missing input field: " + placeholder)
        }
        field.selectText(nil)
        guard let editor = field.currentEditor() as? NSTextView else { throw BoardLayoutFailure(message: "missing field editor") }
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText(text, replacementRange: editor.selectedRange())
        window.makeFirstResponder(nil)
    }

    @MainActor private static func chooseParameter(_ title: String, in view: NSView) throws {
        func pickers(_ view: NSView) -> [NSPopUpButton] { (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(pickers) }
        for picker in pickers(view) { picker.menu?.update() }
        guard let picker = pickers(view).first(where: { $0.itemTitles.contains(title) }), let menu = picker.menu else {
            throw BoardLayoutFailure(message: "missing parameter picker: " + title)
        }
        picker.selectItem(withTitle: title)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: title))
    }

    @MainActor private static func presentationUITests(model: NotebookModel, window: NSWindow, output: String?) async throws {
        guard let tab = model.snapshot?.tabs.first(where: { $0.kind == "sheet" }), let cell = tab.cells.first else {
            throw BoardLayoutFailure(message: "presentation controller missing")
        }
        model.editSource("answer = 42\nnotebook.progress(\"training\", 2, 2, \"Training\", true)\n[answer, \"complete\"]\n", cell: cell, tab: tab)
        let ran = await withCheckedContinuation { c in model.perform("run_all", tab: tab) { c.resume(returning: $0) } }
        try check(ran, model.error ?? "run presentation fixture")
        var board = NotebookBoard(id: "presentation", title: "Shared notebook components", sheet: "main", columns: 2, components: [
            NotebookBoardComponent(id: "note", kind: "rich_text", title: "Rich text", row: "notes", span: 6,
                text_content: NotebookTextContent(source: "Answer: {{answer}}", formatting: #"{"version":1,"runs":[{"start":0,"length":6,"style":"heading2"}]}"#), text_mode: "richtext"),
            NotebookBoardComponent(id: "markdown", kind: "rich_text", title: "Markdown", row: "notes", span: 6,
                text_content: NotebookTextContent(source: "# Summary\n\n**Answer:** {{answer}}"), text_mode: "markdown"),
            NotebookBoardComponent(id: "inspector", kind: "result", title: "Result Inspector", cell: cell.id, row: "outputs", span: 8),
            NotebookBoardComponent(id: "progress", kind: "progress", title: "Progress", cell: cell.id, row: "outputs", span: 4, progress_id: "training")
        ], rows: [NotebookBoardRow(id: "notes"), NotebookBoardRow(id: "outputs", height: 190)])
        let saved = await withCheckedContinuation { c in model.saveBoard(board) { c.resume(returning: $0) } }
        try check(saved, model.error ?? "save shared components")
        guard let controller = model.controller(for: board), let published = controller.cells.first else {
            throw BoardLayoutFailure(message: "published presentation missing")
        }
        let state = model.presentation(for: published, in: controller)
        try check(state.hasResult && published.result_format?.is_container == true && state.progress.map(\.id) == ["training"],
                  "sheet and board adapter receive typed result and progress from the real runtime")
        let before = try Data(contentsOf: URL(fileURLWithPath: model.snapshot!.path).appendingPathComponent("project.json"))
        let host = NSHostingView(rootView: NotebookBoardView(model: model, board: board, onDesign: {}))
        window.contentView = host
        try await Task.sleep(nanoseconds: 200_000_000); host.layoutSubtreeIfNeeded()
        let previews = textViews(host).filter { $0.accessibilityIdentifier() == "notebook-text-preview" }
        try check(previews.count == 2 && previews.allSatisfy { !$0.isEditable && $0.string.contains("42") && !$0.string.contains("{{answer}}") },
                  "run mode renders rich text and Markdown with published values and no editing surface")
        if let output { try snapshot(host, path: URL(fileURLWithPath: output).appendingPathComponent("components-runtime.png")) }
        model.editSource("answer = 84\n[answer, \"updated\"]\n", cell: published, tab: controller)
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(previews.allSatisfy { $0.string.contains("stale") }, "retained text labels stale references after code edits")
        let reran = await withCheckedContinuation { c in model.perform("run_all", tab: controller) { c.resume(returning: $0) } }
        try await Task.sleep(nanoseconds: 150_000_000)
        try check(reran && previews.allSatisfy { $0.string.contains("84") && !$0.string.contains("stale") },
                  "run mode refreshes interpolation after evaluation")
        try check(before == Data(contentsOf: URL(fileURLWithPath: model.snapshot!.path).appendingPathComponent("project.json")),
                  "running and rendering never persist interpolated values")

        let editor = NSHostingView(rootView: NotebookBoardEditor(model: model, board: board, document: model.documentIdentity))
        window.contentView = editor
        try await Task.sleep(nanoseconds: 200_000_000); editor.layoutSubtreeIfNeeded()
        guard let sourceView = textViews(editor).first(where: { $0.isEditable && $0.string == "Answer: {{answer}}" }) else {
            throw BoardLayoutFailure(message: "designer must edit the template source")
        }
        try check(model.activeBoard?.components.first?.text_content?.source == "Answer: {{answer}}", "opening designer preserves the saved template")
        sourceView.setSelectedRange(NSRange(location: 0, length: (sourceView.string as NSString).length))
        sourceView.insertText("Edited answer: {{answer}}", replacementRange: sourceView.selectedRange())
        try await Task.sleep(nanoseconds: 100_000_000)
        if let output { try snapshot(editor, path: URL(fileURLWithPath: output).appendingPathComponent("components-designer.png")) }
        try check(model.activeBoard?.components.first?.text_content?.source == "Answer: {{answer}}", "text editing remains a board draft until Save Board")
        try click(editor, window: window, x: 1060, fromTop: 713)
        for _ in 0..<100 where model.busy { try await Task.sleep(nanoseconds: 20_000_000) }
        try check(model.activeBoard?.components.first?.text_content?.source == "Edited answer: {{answer}}", "Save Board commits source instead of rendered values")
        model.boardEditorOpen = false
        board = model.activeBoard ?? board
        let reopened = await withCheckedContinuation { c in model.open(url: URL(fileURLWithPath: model.snapshot!.path)) { c.resume(returning: $0) } }
        try check(reopened && model.snapshot?.boards?.first(where: { $0.id == board.id })?.components.first?.text_content?.source == "Edited answer: {{answer}}",
                  "text source, format and explicit layout reopen through the native bridge")
    }

    @MainActor private static func textViews(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews($0) }
    }

    @MainActor private static func tabsUITests(model: NotebookModel, window: NSWindow, board original: NotebookBoard, output: String?) async throws {
        var board = original
        board.rows = [NotebookBoardRow(id: "workspace")]
        board.components = []
        board.components.append(NotebookBoardComponent(id: "workspace_tabs", kind: "tabs", title: "Workspace", row: "workspace", span: 12, panels: [
            NotebookBoardPanel(id: "overview", title: "Overview", rows: [NotebookBoardRow(id: "content", height: 120)], components: [
                NotebookBoardComponent(id: "tab_value", kind: "text", title: "Panel value", cell: "1", row: "content", span: 4),
                NotebookBoardComponent(id: "tab_run", kind: "run", title: "Run controller", cell: "1", row: "content", span: 8)]),
            NotebookBoardPanel(id: "charts", title: "Charts", rows: [NotebookBoardRow(id: "content", height: 220)], components: [
                NotebookBoardComponent(id: "tab_loss", kind: "live_chart", title: "Panel loss", chart_id: "loss", row: "content", span: 12, v_align: "stretch")])]))
        let saved = await withCheckedContinuation { continuation in model.saveBoard(board) { continuation.resume(returning: $0) } }
        try check(saved && model.activeBoard?.components.last?.panels?.last?.components.first?.chart_id == "loss",
                  "tabs persist through native encoding, backend validation and snapshot decoding")
        let source = try Data(contentsOf: URL(fileURLWithPath: model.snapshot!.path).appendingPathComponent("project.json"))
        window.setContentSize(NSSize(width: 1120, height: 740))
        let editor = NSHostingView(rootView: NotebookBoardEditor(model: model, board: board, document: model.documentIdentity))
        window.contentView = editor
        try await Task.sleep(nanoseconds: 200_000_000); editor.layoutSubtreeIfNeeded()
        if let output { try snapshot(editor, path: URL(fileURLWithPath: output).appendingPathComponent("tabs-before-selection.png")) }
        try click(editor, window: window, x: 400, fromTop: 480)
        try await Task.sleep(nanoseconds: 100_000_000); editor.layoutSubtreeIfNeeded()
        if let output { try snapshot(editor, path: URL(fileURLWithPath: output).appendingPathComponent("tabs-designer.png")) }
        try click(editor, window: window, x: 885, fromTop: 502)
        try await Task.sleep(nanoseconds: 100_000_000); editor.layoutSubtreeIfNeeded()
        try click(editor, window: window, x: 755, fromTop: 306)
        try await Task.sleep(nanoseconds: 100_000_000)
        try click(editor, window: window, x: 100, fromTop: 197)
        try await Task.sleep(nanoseconds: 100_000_000); editor.layoutSubtreeIfNeeded()
        try chooseParameter("Gain · gain · Number (decimal)", in: editor)
        try await Task.sleep(nanoseconds: 100_000_000); editor.layoutSubtreeIfNeeded()
        if let output { try snapshot(editor, path: URL(fileURLWithPath: output).appendingPathComponent("tabs-panel-grid.png")) }
        try click(editor, window: window, x: 50, fromTop: 256)
        try await Task.sleep(nanoseconds: 100_000_000)
        try click(editor, window: window, x: 890, fromTop: 673)
        try await Task.sleep(nanoseconds: 100_000_000)
        try click(editor, window: window, x: 1060, fromTop: 713)
        for _ in 0..<100 where model.busy { try await Task.sleep(nanoseconds: 20_000_000) }
        guard let persisted = model.activeBoard else { throw BoardLayoutFailure(message: "saved tabs board missing") }
        try check(persisted.components.last?.panels?.count == 3 &&
                  persisted.components.last?.panels?.first?.rows.count == 2 &&
                  persisted.components.last?.panels?.first?.components.last?.input == "gain" &&
                  persisted.components.last?.panels?.last?.components.isEmpty == true,
                  "designer edits the panel grid, returns to parent and adds a panel before saving")
        model.boardEditorOpen = false
        let running = NSHostingView(rootView: NotebookBoardView(model: model, board: persisted, onDesign: {}))
        window.contentView = running
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 200_000_000); running.layoutSubtreeIfNeeded()
        let before = try Data(contentsOf: URL(fileURLWithPath: model.snapshot!.path).appendingPathComponent("project.json"))
        try check(source != before, "designer save commits panel changes")
        let firstPanel = try snapshotBytes(running)
        if let output { try firstPanel.write(to: URL(fileURLWithPath: output).appendingPathComponent("tabs-runtime-overview.png")) }
        try click(running, window: window, x: 162, fromTop: 149)
        try await Task.sleep(nanoseconds: 100_000_000); running.layoutSubtreeIfNeeded()
        if let output { try snapshot(running, path: URL(fileURLWithPath: output).appendingPathComponent("tabs-runtime-after-click.png")) }
        try check(firstPanel != snapshotBytes(running), "runtime tab click switches the visible grid")
        if let output { try snapshot(running, path: URL(fileURLWithPath: output).appendingPathComponent("tabs-runtime.png")) }
        try click(running, window: window, x: 85, fromTop: 149)
        try await Task.sleep(nanoseconds: 100_000_000)
        try check(before == Data(contentsOf: URL(fileURLWithPath: model.snapshot!.path).appendingPathComponent("project.json")),
                  "switching tabs keeps the manifest unchanged")
    }

    @MainActor private static func click(_ view: NSView, window: NSWindow, x: Double, fromTop: Double) throws {
        let point = view.convert(NSPoint(x: x, y: view.isFlipped ? fromTop : view.bounds.height - fromTop), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw BoardLayoutFailure(message: "mouse event missing")
            }
            window.sendEvent(event)
        }
    }
    @MainActor private static func snapshotBytes(_ view: NSView) throws -> Data {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw BoardLayoutFailure(message: "bitmap missing") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let bytes = bitmap.representation(using: .png, properties: [:]) else { throw BoardLayoutFailure(message: "PNG missing") }
        return bytes
    }

    @MainActor private static func snapshot(_ view: NSView, path: URL) throws {
        let bytes = try snapshotBytes(view)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: path)
    }
}

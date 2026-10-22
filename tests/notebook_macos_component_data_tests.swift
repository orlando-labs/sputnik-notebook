import AppKit
import SwiftUI

private struct ComponentDataFailure: Error { let message: String }
@main private enum ComponentDataTests {
    static func check(_ ok: @autoclosure () -> Bool, _ message: String) throws { if !ok() { throw ComponentDataFailure(message: message) } }
    static func option(_ key: String) -> String? { CommandLine.arguments.firstIndex(of: key).flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } }
    @MainActor static func action(_ model: NotebookModel, _ name: String) async -> Bool { await withCheckedContinuation { c in model.perform(name) { c.resume(returning: $0) } } }
    static func viewportTests() throws {
        try check(NotebookAnnotationNumberField.parse("0.125") == 0.125 && NotebookAnnotationNumberField.parse("0,125") == 0.125, "audio and attribute number inputs retain decimal precision")
        try check(NotebookAnnotationNumberField.parse("12", integersOnly: true) == 12 && NotebookAnnotationNumberField.parse("0", integersOnly: true) == 0, "image coordinate inputs accept whole pixels")
        try check(NotebookAnnotationNumberField.parse("0.125", integersOnly: true) == nil && NotebookAnnotationNumberField.parse("0,125", integersOnly: true) == nil, "image coordinate inputs reject fractions with either decimal separator")
        try check(NotebookAnnotationNumberField.parse("1.00000000000000001", integersOnly: true) == nil, "fractional input cannot become valid through floating-point rounding")
        try check(NotebookAnnotationNumberField.parse("1.5oops") == nil && NotebookAnnotationNumberField.parse("NaN") == nil && NotebookAnnotationNumberField.parse("1e309") == nil, "coordinate parsing rejects partial and non-finite values")
        let size = CGSize(width: 600, height: 400), width = 1200, height = 800
        let fit = NotebookImageAnnotationViewport()
        let zoom = fit.zoomed(to: 4, size: size, width: width, height: height)
        let pan = zoom.panned(CGSize(width: 120, height: -80), size: size, width: width, height: height)
        let rect = pan.imageRect(size, width: width, height: height)
        let source = NotebookImageAnnotationViewport.sourcePoint(CGPoint(x: 300, y: 200), rect: rect, width: width, height: height)
        try check(abs(source.x - 540) < 1e-9 && abs(source.y - 440) < 1e-9, "zoom/pan maps drawn coordinates back to original pixels")
        let edge = pan.panned(CGSize(width: 1e6, height: -1e6), size: size, width: width, height: height).imageRect(size, width: width, height: height)
        try check(edge.minX == 0 && edge.maxY == size.height, "pan stays inside image edges")
        let actual = fit.actualSize(size, width: width, height: height).imageRect(size, width: width, height: height)
        try check(actual.width == Double(width) && actual.height == Double(height), "100% shows original source pixels")
        let shape = NotebookImageAnnotations.Shape(id: "focus", kind: "rect", label: "", x: 800, y: 400, width: 100, height: 80)
        let focused = fit.focusing(shape, size: size, width: width, height: height).imageRect(size, width: width, height: height)
        let middle = NotebookImageAnnotationViewport.sourcePoint(CGPoint(x: 300, y: 200), rect: focused, width: width, height: height)
        try check(abs(middle.x - 850) < 1e-9 && abs(middle.y - 440) < 1e-9, "zoom to selection centers its source coordinates")
        let small = fit.actualSize(size, width: 2, height: 2).imageRect(size, width: 2, height: 2)
        try check(small.width == 2 && small.height == 2, "100% also works for tiny images")
        try pixelSnappingTests()
    }
    static func pixelSnappingTests() throws {
        typealias Shape = NotebookImageAnnotations.Shape
        let start = CGPoint(x: 0.35965429, y: 0.74351415), end = CGPoint(x: 1.16304617, y: 1.51205623)
        let size = CGSize(width: 600, height: 400)
        for zoom in [0.01, 1.0, 4.0, 128.0] {
            let viewport = NotebookImageAnnotationViewport().zoomed(to: zoom, size: size, width: 2, height: 2).panned(CGSize(width: 80, height: -50), size: size, width: 2, height: 2)
            let rect = viewport.imageRect(size, width: 2, height: 2)
            func source(_ point: CGPoint) -> CGPoint {
                NotebookImageAnnotationViewport.sourcePoint(CGPoint(x: rect.minX + point.x / 2 * rect.width, y: rect.minY + point.y / 2 * rect.height), rect: rect, width: 2, height: 2)
            }
            for (a, b) in [(start, end), (end, start)] {
                let shape = Shape.drawn(kind: "rect", label: "object", from: source(a), to: source(b), width: 2, height: 2)!
                try check(shape.x == 0 && shape.y == 1 && shape.width == 1 && shape.height == 1, "forward/reverse drags snap to source pixel boundaries independently of zoom/pan")
            }
        }
        let point = Shape.drawn(kind: "point", label: "", from: CGPoint(x: 0.9, y: 1.9), to: .zero, width: 2, height: 2)!
        try check(point.x == 0 && point.y == 1, "a point selects the pixel under the cursor")
        let last = Shape.drawn(kind: "point", label: "", from: CGPoint(x: 2, y: 2), to: .zero, width: 2, height: 2)!
        try check(last.x == 1 && last.y == 1, "point indices stay inside the last pixel")
        let full = Shape.drawn(kind: "rect", label: "", from: .zero, to: CGPoint(x: 2, y: 2), width: 2, height: 2)!
        try check(full.width == 2 && full.height == 2, "rectangle can include the entire image with exclusive right/bottom edges")
        try check(Shape.drawn(kind: "rect", label: "", from: CGPoint(x: 0.1, y: 0.1), to: CGPoint(x: 0.4, y: 0.4), width: 2, height: 2) == nil, "subpixel-only rectangles are not created")
        let legacy = Shape(id: "legacy", kind: "rect", label: "", x: 1.8, y: 1.9, width: 0.1, height: 0.05).snapped(width: 2, height: 2)
        try check(legacy.x == 1 && legacy.y == 1 && legacy.width == 1 && legacy.height == 1, "legacy fractional drafts at the edge retain at least one whole pixel")
        try check(legacy.snapped(width: 2, height: 2) == legacy, "already aligned drafts are unchanged")
    }
    @MainActor static func coordinateInputTests(panel: NotebookFigurePanel, labels: NotebookImageAnnotations) async throws -> NotebookImageAnnotations {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil); defer { window.close() }
        var rectangle = labels
        for kind in ["rect", "point"] {
            var initial = labels
            if kind == "point" { initial.shapes = [.init(id: "point", kind: "point", label: "landmark", x: 0, y: 0)] }
            var applied: NotebookImageAnnotations?
            let binding = NotebookImageAnnotationBinding(channel: labels.channel, accepted: initial, disabled: false, apply: { value, done in applied = value; done(true) })
            window.contentView = NSHostingView(rootView: NotebookImageAnnotatorView(panel: panel, binding: binding).environment(\.locale, Locale(identifier: "en_US_POSIX")))
            try await Task.sleep(nanoseconds: 200_000_000)
            let fields: [(String, String)] = kind == "rect" ? [("X2", "2"), ("Y2", "2"), ("X1", "1"), ("Y1", "1")] : [("X", "1"), ("Y", "1")]
            for (name, value) in fields { try AnnotationSheetTestSupport.edit(name, text: value, window: window); try await Task.sleep(nanoseconds: 30_000_000) }
            for (name, value) in fields {
                for invalid in ["0.25", "0,75", "1oops"] {
                    try AnnotationSheetTestSupport.edit(name, text: invalid, window: window)
                    try await Task.sleep(nanoseconds: 30_000_000)
                    try AnnotationSheetTestSupport.click("image-annotations-apply", window: window)
                    try check(applied == nil, "fractional/invalid coordinate text disables Apply for every image coordinate")
                }
                try AnnotationSheetTestSupport.edit(name, text: value, window: window)
            }
            // Crossing the opposite corner or image edge must clamp by a whole
            // pixel rather than introducing nextUp/nextDown fractional values.
            for (name, value) in (kind == "rect" ? [("X1", "2"), ("Y1", "2"), ("X2", "0"), ("Y2", "0")] : [("X", "99"), ("Y", "-3")]) {
                try AnnotationSheetTestSupport.edit(name, text: value, window: window)
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            try await Task.sleep(nanoseconds: 30_000_000)
            try AnnotationSheetTestSupport.click("image-annotations-apply", window: window)
            try await Task.sleep(nanoseconds: 80_000_000)
            guard let result = applied, let shape = result.shapes.first else { throw ComponentDataFailure(message: "native image coordinate fields were not applied") }
            if kind == "rect" {
                try check(shape.x == 1 && shape.y == 1 && shape.width == 1 && shape.height == 1, "corner edits preserve whole pixels and minimum 1×1 size in Apply: \(shape)")
                rectangle = result
            } else { try check(shape.x == 1 && shape.y == 0, "point coordinate inputs clamp to integer pixel indices") }
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
            let encoded = (json["shapes"] as! [[String: Any]])[0]
            for key in ["x", "y", "width", "height"] {
                if let value = encoded[key] as? NSNumber { try check(value.doubleValue.rounded() == value.doubleValue, "export and Apply encode whole-pixel geometry") }
            }
        }
        return rectangle
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("component-data-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Selection.sputnikbook")
        let model = NotebookModel(workerExecutable: option("--worker"), remoteStorage: root.appendingPathComponent("settings"))
        do {
            try viewportTests()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "tools/notebook-macos/Samples/Selection and Labels.sputnikbook"), to: project)
            let manifest = project.appendingPathComponent("project.json")
            var document = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
            document["dependencies"] = [["path": URL(fileURLWithPath: "../sputnik-lang/packages/notebook_ui").standardizedFileURL.path, "auto_import": false]]
            try JSONSerialization.data(withJSONObject: document).write(to: manifest)
            let opened = await withCheckedContinuation { c in model.open(url: project) { c.resume(returning: $0) } }
            try check(opened, model.error ?? "open")
            let ran = await action(model, "run_all")
            try check(ran && model.activeTab!.cells.allSatisfy(\.ok), model.activeTab!.cells.map { $0.error }.joined(separator: " / ") + " / " + model.activeTab!.environment_error)
            var board = model.snapshot!.boards![0]
            let tableComponent = board.components.first { $0.kind == "table" }!
            let panel = model.presentation(for: model.activeTab!.cells[0], in: model.activeTab!).figures.first { $0.id == "corpus" }!
            let table = NotebookTableSnapshot.decode(String(decoding: panel.data, as: UTF8.self))!
            let row = table.rows[1]
            let keyIndex = table.columns.firstIndex { $0.title == "id" }!
            let selection = NotebookSharedSelection(source: notebookAssetID(panel.data), key: row.values[keyIndex], row: table.columns.enumerated().reduce(into: [:]) { $0[$1.element.title] = row.values[$1.offset] })
            let accepted = await withCheckedContinuation { c in model.editComponentData(selection, kind: "selection", board: board, component: tableComponent) { c.resume(returning: $0) } }
            try check(accepted, model.error ?? "selection Apply")
            try check(model.acceptedComponentData(NotebookSharedSelection.self, kind: "selection", channel: "record")?.key == .text("sample_b"), "selection snapshot decoded")
            var imageComponent = board.components.first { $0.kind == "image_carousel" }!
            let images = model.imageSeries("frames", in: model.activeTab!)!
            let filtered = model.selectedImageSeries(images, component: imageComponent)
            try check(images.images.count == 2 && filtered.images.count == 1 && filtered.images[0].caption == "Sample B", "linked image follows stable asset identity")
            var draft = NotebookAnnotationDraft(shapes: [])
            let schema = [NotebookAnnotationClass(id: "digit", title: "Digit", attributes: [.init(id: "confidence", title: "Confidence", type: "number", options: [])])]
            imageComponent.annotation_classes = schema
            imageComponent = try await AnnotationSheetTestSupport.designerConfiguration(imageComponent)
            board.components[board.components.firstIndex { $0.id == imageComponent.id }!] = imageComponent
            let saved = await withCheckedContinuation { c in model.saveBoard(board) { c.resume(returning: $0) } }
            try check(saved, model.error ?? "designer image schema save")
            board = model.snapshot!.boards![0]; imageComponent = board.components.first { $0.kind == "image_carousel" }!
            try check(imageComponent.annotation_classes == schema.map { var item = $0; item.title = "Configured class"; item.attributes[0].title = "Configured attribute"; return item }, "image designer schema roundtrip")
            let shape = NotebookImageAnnotations.Shape(id: "box", kind: "rect", label: "digit", x: 0, y: 0, width: 1, height: 1, classes: ["digit"], attributes: ["digit": ["confidence": .number(0.75)]])
            draft.replace([shape]); draft.undoEdit(); try check(draft.shapes.isEmpty, "Undo"); draft.redoEdit(); try check(draft.shapes == [shape], "Redo")
            let image = filtered.images[0]
            var labels = NotebookImageAnnotations(asset: notebookAssetID(image.data), channel: "frames", width: image.width, height: image.height, shapes: draft.shapes, classes: imageComponent.annotationClasses)
            labels = try await coordinateInputTests(panel: image, labels: labels)
            let applied = await withCheckedContinuation { c in model.editComponentData(labels, kind: "annotations", board: board, component: imageComponent) { c.resume(returning: $0) } }
            try check(applied, model.error ?? "annotation Apply")
            try check(model.acceptedComponentData(NotebookImageAnnotations.self, kind: "annotations", channel: imageComponent.annotation_id ?? imageComponent.id + "_labels")?.shapes == labels.shapes, "typed image corners survive backend persistence")
            try check(model.activeTab!.cells[1].dirty, "Apply invalidates consumers without Run")
            let reread = await action(model, "run_all"); try check(reread && model.activeTab!.cells[1].ok, "accepted data survives a new kernel run")
            let result = model.activeTab!.cells[1].result
            try check(result.contains("sample_b") && result.contains("digit"), "kernel receives typed selection and labels")
            let record = try model.runHistory.load(model.runHistory.runs[0].id)
            try check(record.acceptedData?.contains { $0.kind == "annotations" && $0.json.contains("digit") } == true, "history freezes the accepted labels used by Run")
            board = model.snapshot!.boards![0]
            if let output = option("--output") {
                let directory = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 1160), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil); defer { window.close() }
                for scheme in [ColorScheme.light, .dark] {
                    let view = NSHostingView(rootView: NotebookBoardView(model: model, board: board, onDesign: {}).environment(\.colorScheme, scheme))
                    window.contentView = view; try await Task.sleep(nanoseconds: 300_000_000); view.layoutSubtreeIfNeeded()
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!; view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(scheme == .light ? "selection-light.png" : "selection-dark.png"))
                }
                let editor = NSHostingView(rootView: NotebookImageAnnotatorView(panel: image, binding: model.annotationBinding(board: board, component: imageComponent)!))
                window.setContentSize(NSSize(width: 960, height: 680)); window.contentView = editor
                try await Task.sleep(nanoseconds: 200_000_000); editor.layoutSubtreeIfNeeded()
                let bitmap = editor.bitmapImageRepForCachingDisplay(in: editor.bounds)!; editor.cacheDisplay(in: editor.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("annotator.png"))
            }
            // Exercise the actual first-click sheet path after Run, not a standalone editor.
            let sheetWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
            sheetWindow.isReleasedWhenClosed = false; sheetWindow.makeKeyAndOrderFront(nil)
            let imageHost = NSHostingView(rootView: NotebookImageView(series: images, carousel: true, allowSave: true, annotationBinding: model.annotationBinding(board: board, component: imageComponent)).padding(20))
            sheetWindow.contentView = imageHost
            try await Task.sleep(nanoseconds: 250_000_000)
            let sheetPNG = option("--output").map { URL(fileURLWithPath: $0).appendingPathComponent("image-sheet-click.png") }
            try await AnnotationSheetTestSupport.opens(window: sheetWindow, button: "image-annotate", editor: "image-annotation-editor", discard: "image-annotations-discard", output: sheetPNG)
            try await AnnotationSheetTestSupport.opens(window: sheetWindow, button: "image-annotate", editor: "image-annotation-editor", discard: "image-annotations-discard")
            sheetWindow.close()
            let media = project.appendingPathComponent("audio")
            try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
            let unused = media.appendingPathComponent("123_456_1.wav")
            let referenced = media.appendingPathComponent("123_456_2.wav")
            try Data([1, 2]).write(to: unused); try Data([3, 4]).write(to: referenced)
            try FileManager.default.createSymbolicLink(atPath: media.appendingPathComponent("123_456_3.wav").path, withDestinationPath: referenced.path)
            let files = try NotebookUnusedMedia.scan(project: project, sources: referenced.lastPathComponent)
            try check(files.map(\.id) == ["audio/123_456_1.wav"], "archive preview excludes references and symlinks")
            let destination = try NotebookUnusedMedia.archive(Set(files.map(\.id)), project: project, sources: referenced.lastPathComponent)!
            try check(!FileManager.default.fileExists(atPath: unused.path) && FileManager.default.fileExists(atPath: destination.appendingPathComponent("audio/123_456_1.wav").path) && FileManager.default.fileExists(atPath: referenced.path), "unused media moves to a recoverable archive")
            await withCheckedContinuation { c in model.shutdown { c.resume() } }
            print("Native component data passed: worker sample, stable row keys, linked image, Apply/invalidation, zoom/pan, native corner/point inputs, annotations, Undo/Redo and themes")
        } catch { fputs("Component data failed: \(error) · \(model.error ?? "")\n", stderr); exit(1) }
    }
}

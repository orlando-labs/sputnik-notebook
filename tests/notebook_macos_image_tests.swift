import AppKit
import SwiftUI

private struct ImageFailure: Error { let message: String }
private func check(_ value: Bool, _ message: String) throws {
    if !value { throw ImageFailure(message: message) }
}
@main
private enum ImageTests {
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sputnik-image-ui-\(UUID().uuidString)")
        let output = CommandLine.arguments.firstIndex(of: "--output").map { URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) }
        let model = NotebookModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if let output {
                for name in ["gray", "rgb", "rgba"] {
                    let data = try Data(contentsOf: output.appendingPathComponent(name + ".png"))
                    let frame = NotebookFigurePanel(mime: "image/png", caption: "", width: 2, height: 1, data: data)
                    try check(frame.image() != nil, "runtime \(name) PNG must decode with ImageIO")
                }
            }
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 120,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<120 { for x in 0..<240 {
                let offset = y * bitmap.bytesPerRow + x * 4
                bitmap.bitmapData![offset] = x < 80 ? 255 : 0
                bitmap.bitmapData![offset + 1] = x >= 80 && x < 160 ? 255 : 0
                bitmap.bitmapData![offset + 2] = x >= 160 ? 255 : 0
                bitmap.bitmapData![offset + 3] = 255
            } }
            let png = bitmap.representation(using: .png, properties: [:])!
            let jpeg = bitmap.representation(using: .jpeg, properties: [:])!
            let panel = NotebookFigurePanel(mime: "image/png", caption: "Per-image caption · red / green / blue", width: 240, height: 120, data: png)
            let jpg = NotebookFigurePanel(mime: "image/jpeg", caption: "JPEG frame", width: 240, height: 120, data: jpeg)
            let pngFile = root.appendingPathComponent("Imported PNG.png"), jpegFile = root.appendingPathComponent("Imported JPEG.jpg")
            try panel.saveImageFile(pngFile); try jpg.saveImageFile(jpegFile)
            let loadedPNG = try NotebookFigurePanel.loadImageFile(pngFile), loadedJPEG = try NotebookFigurePanel.loadImageFile(jpegFile)
            try check(loadedPNG.data == png && loadedJPEG.data == jpeg && loadedJPEG.mime == "image/jpeg", "file saving and loading preserve original PNG/JPEG bytes")
            let invalidFile = root.appendingPathComponent("invalid.png")
            try Data("invalid".utf8).write(to: invalidFile)
            do { _ = try NotebookFigurePanel.loadImageFile(invalidFile); throw ImageFailure(message: "malformed file accepted") }
            catch let failure as ImageFailure { throw failure } catch { }
            if let output { try png.write(to: output.appendingPathComponent("source.png")) }
            try check(jpg.image() != nil, "JPEG decodes with matching dimensions")
            let series = NotebookImageSeries(id: "gallery", caption: "Series caption · two images published from code", images: [panel, jpg])
            for mode in ["fit", "fill", "auto-height"] {
                let view = NSHostingView(rootView: NotebookImageView(series: series, carousel: true, mode: mode, cellHeight: mode == "auto-height" ? nil : 420)
                    .padding(20).frame(width: 360).background(NotebookPalette.card))
                view.frame = NSRect(x: 0, y: 0, width: 360, height: 500)
                window.contentView = view; window.setContentSize(NSSize(width: 360, height: 500)); window.makeKeyAndOrderFront(nil)
                try await Task.sleep(nanoseconds: 120_000_000); view.layoutSubtreeIfNeeded()
                if let output { try snapshot(view, path: output.appendingPathComponent(mode + ".png")) }
                if mode == "fit" {
                    let firstFrame = try snapshotBytes(view)
                    try click(view, window: window, x: 110, fromBottom: 50)
                    try await Task.sleep(nanoseconds: 120_000_000); view.layoutSubtreeIfNeeded()
                    try check(try snapshotBytes(view) != firstFrame, "Next changes the displayed image/caption")
                    if let output { try snapshot(view, path: output.appendingPathComponent("carousel-next.png")) }
                    try click(view, window: window, x: 34, fromBottom: 50)
                    try await Task.sleep(nanoseconds: 120_000_000); view.layoutSubtreeIfNeeded()
                    if let output { try snapshot(view, path: output.appendingPathComponent("carousel-previous.png")) }
                }
            }
            let autoWide = NSHostingView(rootView: NotebookImageView(series: series, carousel: false, mode: "auto-height").frame(width: 480))
            let autoNarrow = NSHostingView(rootView: NotebookImageView(series: series, carousel: false, mode: "auto-height").frame(width: 240))
            try check(abs(autoWide.fittingSize.height - autoNarrow.fittingSize.height - 120) < 30,
                      "auto-height grows with width while preserving aspect ratio")
            let opened = await withCheckedContinuation { continuation in
                model.open(url: root.appendingPathComponent("Images.sputnikbook"), create: true) { continuation.resume(returning: $0) }
            }
            try check(opened, model.error ?? "open project")
            guard let tab = model.activeTab, let cell = tab.cells.first else { throw ImageFailure(message: "missing sheet cell") }
            model.editSource("notebook.images(\"gallery\", [{data: [0, 255], width: 2, height: 1, format: :gray, caption: \"First\"}, {data: [255, 0], width: 2, height: 1, format: :gray, caption: \"Second\"}], caption: \"Series\")\n", cell: cell, tab: tab)
            let ran = await withCheckedContinuation { continuation in
                model.perform("run", tab: tab, cell: cell) { continuation.resume(returning: $0) }
            }
            try check(ran, model.error ?? "run image cell")
            guard let current = model.activeTab, let evaluated = current.cells.first else { throw ImageFailure(message: "missing current cell") }
            try check(model.imageSeries("gallery", in: current)?.images.count == 2 && !model.imageSeriesIsStale("gallery", in: current), "native model exposes fresh channel")
            model.editSource("notebook.images(\"gallery\", [])\n", cell: evaluated, tab: current)
            try check(model.imageSeriesIsStale("gallery", in: current), "code edits stale prior images")
            let cleared = await withCheckedContinuation { continuation in
                model.perform("run", tab: current, cell: evaluated) { continuation.resume(returning: $0) }
            }
            try check(cleared && model.activeTab.flatMap { model.imageSeries("gallery", in: $0) }?.images.isEmpty == true, "native model clears series on rerun")
            guard let jpegTab = model.activeTab, let jpegCell = jpegTab.cells.first else { throw ImageFailure(message: "JPEG test cell missing") }
            let jpegBytes = jpeg.map { String($0) }.joined(separator: ",")
            model.editSource("notebook.images(\"jpeg\", [{data: [\(jpegBytes)], format: :jpeg, caption: \"JPEG from code\"}])\n", cell: jpegCell, tab: jpegTab)
            let jpegRan = await withCheckedContinuation { continuation in model.perform("run", tab: jpegTab, cell: jpegCell) { continuation.resume(returning: $0) } }
            let publishedJPEG = model.activeTab.flatMap { model.imageSeries("jpeg", in: $0) }?.images.first
            try check(jpegRan && publishedJPEG?.width == 240 && publishedJPEG?.height == 120 && publishedJPEG?.image() != nil,
                      "real JPEG header inference, VM publication and native decode")
            let board = NotebookBoard(id: "images", title: "Image components", sheet: "main", columns: 2, components: [
                NotebookBoardComponent(id: "cover", kind: "image", title: "Image", image_id: "cover", image_mode: "fit", row: "media", span: 6),
                NotebookBoardComponent(id: "gallery", kind: "image_carousel", title: "Image Carousel", image_id: "gallery", image_mode: "auto-height", caption: "Default series caption",
                                       image_allow_save: true, image_allow_load: true, image_allow_read: true, row: "media", span: 6)
            ], rows: [NotebookBoardRow(id: "media")])
            let saved = await withCheckedContinuation { continuation in model.saveBoard(board) { continuation.resume(returning: $0) } }
            try check(saved && model.snapshot?.boards?.first?.components.last?.image_mode == "auto-height", "designer properties persist")
            try check(model.snapshot?.boards?.first?.components.last?.image_allow_save == true &&
                      model.snapshot?.boards?.first?.components.last?.image_allow_load == true &&
                      model.snapshot?.boards?.first?.components.last?.image_allow_read == true, "all three access settings persist")
            let imported = await withCheckedContinuation { continuation in
                model.editImages([loadedPNG, loadedJPEG], caption: "Imported files", selected: 1, board: board,
                                 component: board.components[1]) { continuation.resume(returning: $0) }
            }
            guard let importedTab = model.activeTab, let importedCell = importedTab.cells.first else { throw ImageFailure(message: "image input cell missing") }
            try check(imported && model.imageSeries("gallery", in: importedTab)?.images.last?.data == jpeg && model.imageSelection("gallery", in: importedTab) == 1,
                      "native UI input collection contains loaded PNG/JPEG and selected index")
            model.editSource("frames = notebook.read_images(\"gallery\")\nnotebook.read_image(\"gallery\")[:caption] == \"Imported JPEG\" and frames.count == 2\n", cell: importedCell, tab: importedTab)
            let readRan = await withCheckedContinuation { continuation in model.perform("run", tab: importedTab, cell: importedCell) { continuation.resume(returning: $0) } }
            try check(readRan && model.activeTab?.cells.first?.result == "true", "native cell reads current image and ordered collection: \(model.error ?? "") / \(model.activeTab?.cells.first?.error ?? "") / \(model.activeTab?.cells.first?.result ?? "")")
            let reordered = await withCheckedContinuation { continuation in
                model.editImages([loadedJPEG, loadedPNG], caption: "Imported files", selected: 0, board: board,
                                 component: board.components[1]) { continuation.resume(returning: $0) }
            }
            try check(reordered && model.activeTab.flatMap { model.imageSeries("gallery", in: $0) }?.images.first?.data == jpeg,
                      "native reorder updates the current collection")
            let controls = NSHostingView(rootView: NotebookImageView(series: NotebookImageSeries(id: "gallery", caption: "Imported files", images: [loadedPNG, loadedJPEG]),
                carousel: true, mode: "fit", cellHeight: 420, selected: 1, allowSave: true, allowLoad: true).padding(20).frame(width: 520).background(NotebookPalette.card))
            window.contentView = controls; window.setContentSize(NSSize(width: 520, height: 500))
            try await Task.sleep(nanoseconds: 120_000_000); controls.layoutSubtreeIfNeeded()
            if let output { try snapshot(controls, path: output.appendingPathComponent("image-controls.png")) }
            let editor = NSHostingView(rootView: NotebookBoardEditor(model: model, board: board, document: model.documentIdentity))
            window.setContentSize(NSSize(width: 1120, height: 740)); window.contentView = editor
            try await Task.sleep(nanoseconds: 120_000_000); editor.layoutSubtreeIfNeeded()
            if let output { try snapshot(editor, path: output.appendingPathComponent("palette.png")) }
            try click(editor, window: window, x: 600, fromBottom: 260)
            try await Task.sleep(nanoseconds: 120_000_000); editor.layoutSubtreeIfNeeded()
            if let output { try snapshot(editor, path: output.appendingPathComponent("image-settings.png")) }
            await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
            let reopened = NotebookModel()
            let reopenedOK = await withCheckedContinuation { continuation in reopened.open(url: root.appendingPathComponent("Images.sputnikbook"), create: false) { continuation.resume(returning: $0) } }
            try check(reopenedOK && reopened.activeTab.flatMap { reopened.imageSeries("gallery", in: $0) }?.images.first?.data == jpeg,
                      "reopening preserves file bytes and carousel order without running code")
            await withCheckedContinuation { continuation in reopened.shutdown { continuation.resume() } }
            if let flag = CommandLine.arguments.firstIndex(of: "--mnist"), let output {
                try await trainingPreview(project: URL(fileURLWithPath: CommandLine.arguments[flag + 1]),
                    worker: CommandLine.arguments[flag + 2], window: window, output: output)
            }
            print("notebook macOS image tests passed")
        } catch { fputs("image UI tests failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor private static func click(_ view: NSView, window: NSWindow, x: Double, fromBottom: Double) throws {
        let point = view.convert(NSPoint(x: x, y: view.isFlipped ? view.bounds.height - fromBottom : fromBottom), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { throw ImageFailure(message: "mouse event missing") }
            window.sendEvent(event)
        }
    }
    @MainActor private static func trainingPreview(project: URL, worker: String, window: NSWindow, output: URL) async throws {
        let trainer = NotebookModel(workerExecutable: worker)
        let opened = await withCheckedContinuation { continuation in trainer.open(url: project, create: false) { continuation.resume(returning: $0) } }
        try check(opened, trainer.error ?? "open MNIST")
        guard let tab = trainer.activeTab else { throw ImageFailure(message: "MNIST tab missing") }
        let ran = await withCheckedContinuation { continuation in trainer.perform("run_all", tab: tab) { continuation.resume(returning: $0) } }
        try check(ran, trainer.error ?? "train MNIST")
        guard let current = trainer.activeTab, let series = trainer.imageSeries("worst-validation", in: current) else { throw ImageFailure(message: "validation images missing") }
        try check(series.images.count == 10 && series.images.allSatisfy { $0.image() != nil }, "all ten real MNIST images decode")
        let view = NSHostingView(rootView: NotebookImageView(series: series, carousel: true, mode: "fit", cellHeight: 480)
            .padding(24).frame(width: 720).background(NotebookPalette.card))
        window.contentView = view; window.setContentSize(NSSize(width: 720, height: 540)); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(nanoseconds: 200_000_000); view.layoutSubtreeIfNeeded()
        try snapshot(view, path: output.appendingPathComponent("mnist-worst-10.png"))
        for (index, image) in series.images.enumerated() { try image.data.write(to: output.appendingPathComponent("mnist-\(index + 1).png")) }
        print("MNIST native carousel: \(series.images.count) images; \(series.images[0].caption)")
        await withCheckedContinuation { continuation in trainer.shutdown { continuation.resume() } }
    }
    @MainActor private static func snapshot(_ view: NSView, path: URL) throws {
        let png = try snapshotBytes(view)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: path)
    }
    @MainActor private static func snapshotBytes(_ view: NSView) throws -> Data {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw ImageFailure(message: "bitmap missing") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ImageFailure(message: "PNG missing") }
        return png
    }
}

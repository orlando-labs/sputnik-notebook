import AppKit
import Charts
import Foundation
import SwiftUI

private enum TestError: Error { case failed(String) }
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestError.failed(message) }
}

private enum Renderer: String { case none, legacy, native }
private final class BenchmarkDriver: ObservableObject {
    @Published var renderer = Renderer.none
}

private final class LiveChartFixtureStore: ObservableObject {
    @Published var chart: NotebookLiveChart
    init(_ chart: NotebookLiveChart) { self.chart = chart }
}

private struct LiveChartFixture: View {
    @ObservedObject var store: LiveChartFixtureStore
    var body: some View {
        NotebookLiveChartView(chart: store.chart, title: "Training loss", xLabel: "Optimizer step",
                              yLabel: "Cross-entropy loss", stroke: "#d97706").equatable().padding(16)
    }
}

/// Previous implementation, retained only as a benchmark reference.
private struct LegacyChart: View {
    let chart: NotebookLiveChart, title: String, xLabel: String, yLabel: String, color: Color
    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            Chart(Array(chart.sampledPoints(maxCount: 3600).enumerated()), id: \.offset) { item in
                LineMark(x: .value(xLabel, item.element.x), y: .value(yLabel, item.element.y))
                    .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartXAxisLabel(position: .bottom) { Text(xLabel).font(.caption) }
            .chartYAxisLabel(position: .leading) { Text(yLabel).font(.caption) }
            .chartLegend(.hidden)
        }.frame(height: 360)
    }
}

private struct BenchmarkBoard: View {
    @ObservedObject var model: NotebookModel
    @ObservedObject var driver: BenchmarkDriver
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if driver.renderer != .none, let tab = model.activeTab {
                    let progress = model.boardProgress(in: tab)
                    if !progress.isEmpty { NotebookProgressView(items: progress, running: model.executingWorker) }
                    let loss = model.liveChart("loss", in: tab) ?? NotebookLiveChart(id: "loss", points: [], total_points: 0, replace_chart: true)
                    let accuracy = model.liveChart("accuracy", in: tab) ?? NotebookLiveChart(id: "accuracy", points: [], total_points: 0, replace_chart: true)
                    if driver.renderer == .legacy {
                        LegacyChart(chart: loss, title: "Training loss", xLabel: "Optimizer step",
                                    yLabel: "Cross-entropy loss", color: .orange)
                        LegacyChart(chart: accuracy, title: "Held-out test accuracy", xLabel: "Epoch",
                                    yLabel: "Accuracy (%)", color: .green)
                    } else {
                        NotebookLiveChartView(chart: loss, title: "Training loss", xLabel: "Optimizer step",
                                              yLabel: "Cross-entropy loss", stroke: "#d97706",
                                              running: model.executingWorker).equatable()
                        NotebookLiveChartView(chart: accuracy, title: "Held-out test accuracy", xLabel: "Epoch",
                                              yLabel: "Accuracy (%)", stroke: "#059669", yMin: 0, yMax: 100,
                                              running: model.executingWorker).equatable()
                    }
                } else { Text("Training without visualization").padding(40) }
            }.padding(24)
        }
    }
}

@main
private enum LiveChartTests {
    @MainActor
    static func main() async {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        do {
            try rendererTests()
            if let flag = CommandLine.arguments.firstIndex(of: "--training-benchmark") {
                try await trainingBenchmark(worker: CommandLine.arguments[flag + 1],
                                            project: CommandLine.arguments[flag + 2])
            }
            print("notebook macOS live chart tests passed")
        } catch {
            fputs("live chart tests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func rendererTests() throws {
        try check(NotebookPlotTypography.title.pointSize == 20 &&
                  NotebookPlotTypography.tick.pointSize == 11 && NotebookPlotTypography.axis.pointSize == 13 &&
                  [NotebookPlotTypography.title, NotebookPlotTypography.tick, NotebookPlotTypography.axis]
                    .allSatisfy(\.isFixedPitch) &&
                  NSFontManager.shared.weight(of: NotebookPlotTypography.title) >
                    NSFontManager.shared.weight(of: NotebookPlotTypography.tick),
                  "native plots use monospaced titles, ticks and axis labels with a semibold title")
        let points = (0..<2400).map {
            NotebookChartPoint(x: Double($0), y: 0.15 + 2 * exp(-Double($0) / 250) + Double($0 % 13) / 100)
        }
        let chart = NotebookLiveChart(id: "loss", points: points, total_points: 2400, replace_chart: true)
        let style = NotebookLiveChartStyle(title: "Training loss", xLabel: "Optimizer step",
                                           yLabel: "Cross-entropy loss", stroke: "#d97706")
        let large = NotebookLiveChartScene.make(chart: chart, style: style, size: CGSize(width: 900, height: 420))!
        let small = NotebookLiveChartScene.make(chart: chart, style: style, size: CGSize(width: 450, height: 320))!
        try check(large.bounds == small.bounds && large.background == "#ffffff" && large.padding == small.padding,
                  "responsive layouts share the plot package style and numeric domain")
        try check(large.originalFrame.width - small.originalFrame.width == 450 &&
                  small.originalFrame.width > 0 &&
                  large.layers[0].commands[0].width == small.layers[0].commands[0].width,
                  "resizing changes geometry without scaling line width or typography")
        let last = large.layers[0].commands[0].points.last!
        let terminal = large.dataPoint(CGPoint(x: last[0], y: last[1]), view: large.initialViewport, frame: large.originalFrame)
        try check(large.layers[0].commands[0].points.count < chart.points.count && abs(terminal.x - 2399) < 1e-9,
                  "display sampling retains the terminal point")
        let output = URL(fileURLWithPath: "build", isDirectory: true)
        try large.png(view: large.initialViewport, width: 900, height: 420)!.write(to: output.appendingPathComponent("live-chart-plot-style.png"))
        try small.png(view: small.initialViewport, width: 450, height: 320)!.write(to: output.appendingPathComponent("live-chart-plot-style-narrow.png"))
        let accuracy = NotebookLiveChart(id: "accuracy", points: [NotebookChartPoint(x: 1, y: 98)], total_points: 1, replace_chart: true)
        let accuracyStyle = NotebookLiveChartStyle(title: "Held-out test accuracy", xLabel: "Epoch",
                                                   yLabel: "Accuracy (%)", stroke: "#059669", yMin: 0, yMax: 100)
        let accuracyScene = NotebookLiveChartScene.make(chart: accuracy, style: accuracyStyle, size: CGSize(width: 450, height: 320))!
        try check(accuracyScene.bounds[0] == 0 && accuracyScene.bounds[2] == 2 &&
                  accuracyScene.bounds[1] == 0 && accuracyScene.bounds[3] == 100 &&
                  accuracyScene.layers[0].commands[0].kind == 3, "single-epoch accuracy renders a point on a 0–100 percent axis")
        try accuracyScene.png(view: accuracyScene.initialViewport, width: 450, height: 320)!.write(to: output.appendingPathComponent("live-chart-accuracy-style.png"))
        let smallValues = NotebookLiveChart(id: "loss", points: [NotebookChartPoint(x: 0, y: 0.006684), NotebookChartPoint(x: 1, y: 2.37)],
                                           total_points: 2, replace_chart: true)
        let smallValueScene = NotebookLiveChartScene.make(chart: smallValues, style: style, size: CGSize(width: 450, height: 320))!
        let tickText = NotebookPlotScene.tick(0.006684, span: 2.37 - 0.006684) as NSString
        let tickWidth = tickText.size(withAttributes: [.font: NotebookPlotTypography.tick]).width
        try check(smallValueScene.originalFrame.minX - 8 - tickWidth >= 8,
                  "small numeric tick labels have measured space instead of clipping at the canvas edge")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = NotebookLiveChartCanvasView(frame: window.contentView!.bounds)
        let renderState = NotebookLiveChartRenderState()
        view.renderState = renderState
        view.configureInteraction(); window.contentView = view
        view.update(chart: chart, style: style, running: false)
        try check(view.accessibilityLabel()?.contains("Cross-entropy loss") == true,
                  "native chart remains identified to accessibility clients")
        func paint() {
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        paint()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        try check(renderState.initialViewport == view.scene?.initialViewport,
                  "axis controls receive the displayed automatic range")
        let originalExport = renderState.png(viewport: nil)!
        let originalBitmap = NSBitmapImageRep(data: originalExport)!
        try check(originalBitmap.pixelsWide == Int(900 * renderState.backingScale) &&
                  originalBitmap.pixelsHigh == Int(420 * renderState.backingScale),
                  "PNG export uses the chart's Retina backing scale")
        let builds = view.sceneBuildCount
        var latest = chart
        for i in 1...20 {
            latest.total_points = UInt64(2400 + i)
            latest.points.append(NotebookChartPoint(x: Double(2399 + i), y: 0.25))
            view.update(chart: latest, style: style, running: true)
        }
        try check(view.displayedChart == chart && view.sceneBuildCount == builds,
                  "high-frequency input is coalesced instead of scheduling every intermediate paint")
        try check(renderState.png(viewport: nil) == originalExport,
                  "export freezes the displayed snapshot while newer points await paint")
        view.update(chart: latest, style: style, running: false); paint()
        try check(view.displayedChart == latest && view.sceneBuildCount == builds + 1,
                  "completion immediately flushes all final samples")
        view.update(chart: latest, style: style, running: false); paint()
        try check(view.sceneBuildCount == builds + 1, "progress-only updates do not rebuild the plot scene")
        let zoom = PlotViewport([1000, 0.15, 2000, 0.5])!
        var reportedViewport: PlotViewport?? = nil
        view.onViewportChanged = { reportedViewport = .some($0) }
        view.onZoom?(zoom); paint()
        try check(view.viewport == zoom && reportedViewport == .some(zoom),
                  "zoom reports its selected range to the shared controls and Reset axes badge")
        let zoomExport = renderState.png(viewport: zoom)!
        try check(zoomExport != renderState.png(viewport: nil) &&
                  NSBitmapImageRep(data: zoomExport)?.pixelsWide == originalBitmap.pixelsWide,
                  "PNG export uses the selected axes and the same canvas geometry")
        try zoomExport.write(to: output.appendingPathComponent("live-chart-zoom-export.png"))
        view.onReset?(); paint()
        try check(view.viewport == view.scene?.initialViewport && reportedViewport == .some(nil),
                  "double-click reset clears the selected range and hides Reset axes")
        view.selectViewport(zoom); paint()
        try check(view.viewport == zoom, "explicit axis fields set the same viewport as mouse zoom")
        view.selectViewport(nil); paint()
        view.setFrameSize(CGSize(width: 450, height: 320)); paint()
        try check(view.imageSize == view.bounds.size && view.scene?.originalFrame == small.originalFrame,
                  "native canvas renders at the actual new size")
        window.orderOut(nil)

        // The SwiftUI wrapper must retain the selected viewport, expose its
        // reset badge, and feed it back to the native canvas after updates.
        let store = LiveChartFixtureStore(chart)
        let hosting = NSHostingView(rootView: LiveChartFixture(store: store))
        let hostWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 450),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        hostWindow.contentView = hosting
        hostWindow.orderFront(nil)
        func settleHost() {
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            hosting.layoutSubtreeIfNeeded()
        }
        func canvases(_ node: NSView) -> [NotebookLiveChartCanvasView] {
            (node as? NotebookLiveChartCanvasView).map { [$0] } ?? node.subviews.flatMap(canvases)
        }
        settleHost()
        let mounted = canvases(hosting).first!
        try check(canvases(hosting).count == 1, "live wrapper mounts one native canvas with its shared controls")
        mounted.onZoom?(zoom); settleHost()
        try check(mounted.viewport == zoom,
                  "mouse zoom retains the selected range through a SwiftUI wrapper update")
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("live-chart-controls-preview.png"))
        }
        store.chart = latest; settleHost()
        try check(mounted.viewport == zoom,
                  "incoming samples retain the user's viewport in the shared controls")
        mounted.onReset?(); settleHost()
        try check(mounted.viewport == mounted.scene?.initialViewport,
                  "reset restores automatic axes through the live wrapper's state binding")

        let captioned = NotebookLiveChartView(chart: chart, title: "Training loss",
            caption: "Training cross-entropy · every optimizer step. Held-out data is reserved for validation.",
            xLabel: "Optimizer step", yLabel: "Cross-entropy loss", stroke: "#d97706", cellHeight: 320)
        let captionHost = NSHostingView(rootView: captioned.equatable().frame(width: 350, height: 320))
        hostWindow.setContentSize(CGSize(width: 350, height: 320))
        hostWindow.contentView = captionHost
        func settleCaption() {
            captionHost.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            captionHost.layoutSubtreeIfNeeded()
        }
        settleCaption()
        let captionCanvasHeight = canvases(captionHost).first!.bounds.height
        try check(captionCanvasHeight > 144 && captionCanvasHeight < 290,
                  "wrapped caption reserves space below the canvas within a fixed-height card")
        let captionBitmap = captionHost.bitmapImageRepForCachingDisplay(in: captionHost.bounds)!
        captionHost.cacheDisplay(in: captionHost.bounds, to: captionBitmap)
        try captionBitmap.representation(using: .png, properties: [:])!
            .write(to: output.appendingPathComponent("live-chart-caption-preview.png"))
        var withoutCaption = captioned
        withoutCaption.caption = ""
        captionHost.rootView = withoutCaption.equatable().frame(width: 350, height: 320)
        settleCaption()
        try check(canvases(captionHost).first!.bounds.height > captionCanvasHeight + 20,
                  "caption edits update an equatable live chart and clearing restores canvas space")
        hostWindow.orderOut(nil)
    }

    @MainActor
    private static func trainingBenchmark(worker: String, project: String) async throws {
        try check(CommandLine.arguments.contains("--trust-native"), "benchmark requires explicit test-only native trust")
        func option(_ name: String, default value: Int) -> Int {
            guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return value }
            return Int(CommandLine.arguments[index + 1]) ?? value
        }
        let epochs = option("--epochs", default: 2), testLimit = option("--test-limit", default: 1024)
        try check(epochs > 0 && testLimit > 0, "benchmark dimensions must be positive")
        let model = NotebookModel(workerExecutable: worker)
        let driver = BenchmarkDriver()
        let opened = await withCheckedContinuation { continuation in
            model.open(url: URL(fileURLWithPath: project)) { continuation.resume(returning: $0) }
        }
        try check(opened, model.error ?? "benchmark project open failed")
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 820),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "MNIST · live chart renderer benchmark"
        window.contentView = NSHostingView(rootView: BenchmarkBoard(model: model, driver: driver))
        window.orderFront(nil)
        do {
            guard let tab = model.activeTab,
                  let training = tab.cells.first(where: { $0.source.contains("metrics = train_mnist") }) else {
                throw TestError.failed("missing training cell")
            }
            var results: [String: [Double]] = [:]
            let nativeOnly = CommandLine.arguments.contains("--native-only")
            let renderers = nativeOnly ? [Renderer.native] : [Renderer.none, .none, .legacy, .native, .native, .legacy, .none]
            for (index, renderer) in renderers.enumerated() {
                driver.renderer = renderer
                let mode = renderer == .none ? "none" : "board"
                let warmup = !nativeOnly && index == 0
                let runEpochs = warmup ? 1 : epochs
                let source = """
                metrics = train_mnist(dataset, device: "mps", epochs: \(runEpochs), batch_size: 128, train_limit: 60000, test_limit: \(testLimit), visualization: :\(mode))
                seconds = metrics[:seconds]
                accuracy = metrics[:accuracy]
                metrics

                """
                guard let current = model.activeTab, let cell = current.cells.first(where: { $0.id == training.id }) else {
                    throw TestError.failed("training cell lost")
                }
                model.editSource(source, cell: cell, tab: current)
                let ran = await withCheckedContinuation { continuation in
                    model.perform("run_all") { continuation.resume(returning: $0) }
                }
                try check(ran, model.error ?? "training run failed")
                guard let result = model.activeTab?.cells.first(where: { $0.id == training.id }),
                      result.ok, let text = result.locals.first(where: { $0.name == "seconds" })?.value,
                      let seconds = Double(text), seconds > 0 else {
                    throw TestError.failed("missing benchmark duration")
                }
                if !warmup { results[renderer.rawValue, default: []].append(seconds) }
                print("\(warmup ? "warmup" : renderer.rawValue): \(seconds) s, \(Double(469 * runEpochs) / seconds) optimizer steps/s")
                fflush(stdout)
                if renderer == .native, let current = model.activeTab {
                    for (id, style) in [
                        ("loss", NotebookLiveChartStyle(title: "Training loss", xLabel: "Optimizer step",
                            yLabel: "Cross-entropy loss", stroke: "#d97706")),
                        ("accuracy", NotebookLiveChartStyle(title: "Held-out test accuracy", xLabel: "Epoch",
                            yLabel: "Accuracy (%)", stroke: "#059669", yMin: 0, yMax: 100))
                    ] {
                        guard let chart = model.liveChart(id, in: current),
                              let scene = NotebookLiveChartScene.make(chart: chart, style: style, size: CGSize(width: 900, height: 420)),
                              let png = scene.png(view: scene.initialViewport, width: 900, height: 420) else {
                            throw TestError.failed("missing completed \(id) series")
                        }
                        try png.write(to: URL(fileURLWithPath: "build/mnist-live-\(id)-preview.png"))
                    }
                }
            }
            func mean(_ renderer: Renderer) -> Double {
                let values = results[renderer.rawValue]!
                return values.reduce(0, +) / Double(values.count)
            }
            if !nativeOnly {
                print("GUI legacy overhead vs none: \((mean(.legacy) / mean(.none) - 1) * 100)%")
                print("GUI native overhead vs none: \((mean(.native) / mean(.none) - 1) * 100)%")
                print("GUI native speedup vs legacy: \((mean(.legacy) / mean(.native) - 1) * 100)%")
            }
            window.orderOut(nil)
            await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
        } catch {
            window.orderOut(nil)
            await withCheckedContinuation { continuation in model.shutdown { continuation.resume() } }
            throw error
        }
    }
}

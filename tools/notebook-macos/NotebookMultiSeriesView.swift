import AppKit
import SwiftUI

struct NotebookChartSeriesSnapshot: Equatable {
    let settings: NotebookChartSeries
    let chart: NotebookLiveChart
}
enum NotebookMultiSeriesScene {
    static func make(_ series: [NotebookChartSeriesSnapshot], style: NotebookLiveChartStyle, size: CGSize, full: Bool = false) -> NotebookPlotScene? {
        let points = series.flatMap { $0.chart.points }
        guard !points.isEmpty,
              let scene = NotebookLiveChartScene.make(chart: NotebookLiveChart(id: "combined", points: points, total_points: UInt64(points.count), replace_chart: true), style: style, size: size, maximumPoints: 4) else { return nil }
        let bounds = scene.bounds, frame = scene.frame
        let layers: [PlotSceneLayer] = series.compactMap { series in
            let points = series.chart.sampledPoints(maxCount: full ? series.chart.points.count : max(256, Int(frame[2] * 2))).map { point in
                [frame[0] + (point.x - bounds[0]) / (bounds[2] - bounds[0]) * frame[2],
                 frame[1] + (bounds[3] - point.y) / (bounds[3] - bounds[1]) * frame[3]]
            }
            guard !points.isEmpty else { return nil }
            let command = points.count == 1 ? PlotCommand(point: points[0], color: series.settings.stroke, radius: 3) : PlotCommand(line: points, stroke: series.settings.stroke, width: 2)
            return PlotSceneLayer(kind: points.count == 1 ? "points" : "line", commands: [command])
        }
        return NotebookPlotScene(version: scene.version, bounds: bounds, frame: frame, padding: scene.padding, color_scale: false, aspect_equal: false, y_down: false, axes: true, background: scene.background, title: scene.title, x_label: scene.x_label, y_label: scene.y_label, layers: layers, decorations: scene.decorations)
    }
}
final class NotebookMultiSeriesRenderState: ObservableObject {
    @Published private(set) var domain: PlotViewport?
    private var series: [NotebookChartSeriesSnapshot] = []
    private var style: NotebookLiveChartStyle?
    private var size = CGSize.zero
    private var revision = 0
    func capture(_ series: [NotebookChartSeriesSnapshot], style: NotebookLiveChartStyle, size: CGSize, scene: NotebookPlotScene?) {
        self.series = series; self.style = style; self.size = size; revision += 1
        let revision = revision, domain = scene?.initialViewport
        if domain != self.domain { DispatchQueue.main.async { [weak self] in if self?.revision == revision { self?.domain = domain } } }
    }
    func png(viewport: PlotViewport?) -> Data? {
        guard let style, let scene = NotebookMultiSeriesScene.make(series, style: style, size: size, full: true) else { return nil }
        // Keep visible series names and colors in the exported image too.
        let columns = max(1, Int(size.width / 180)), rows = (series.count + columns - 1) / columns
        let height = size.height + Double(rows * 22 + 16), scale = 2.0
        let width = Int(size.width * scale), pixelsHigh = Int(height * scale)
        guard width > 0, pixelsHigh > 0, width <= 8192, pixelsHigh <= 8192, width * pixelsHigh <= 16_000_000,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        let cg = graphics.cgContext; cg.translateBy(x: 0, y: Double(pixelsHigh)); cg.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        NSColor.white.setFill(); NSBezierPath(rect: CGRect(x: 0, y: 0, width: size.width, height: height)).fill()
        scene.draw(view: viewport ?? scene.initialViewport, size: size)
        for (index, value) in series.enumerated() {
            let x = Double(index % columns) * size.width / Double(columns) + 14, y = size.height + 8 + Double(index / columns) * 22
            let color = PlotCommand.color(value.settings.stroke) ?? .black
            color.setFill(); NSBezierPath(ovalIn: CGRect(x: x, y: y + 4, width: 7, height: 7)).fill()
            let text = value.settings.title as NSString
            text.draw(in: CGRect(x: x + 13, y: y, width: size.width / Double(columns) - 30, height: 18), withAttributes: [.font: NotebookPlotTypography.tick, .foregroundColor: color])
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
final class NotebookMultiSeriesCanvasView: PlotCanvasView {
    var renderState: NotebookMultiSeriesRenderState?
    var onViewportChanged: ((PlotViewport?) -> Void)?
    private(set) var displayed: [NotebookChartSeriesSnapshot] = []
    private var pending: [NotebookChartSeriesSnapshot]?
    private var style: NotebookLiveChartStyle?
    private var selectedViewport: PlotViewport?
    private var renderedSize = CGSize.zero
    private var sceneDirty = true
    private var lastDisplay = -Double.infinity
    private var refreshWork: DispatchWorkItem?
    private(set) var sceneBuildCount = 0
    deinit { refreshWork?.cancel() }
    func configure() {
        setAccessibilityElement(true); setAccessibilityRole(.image)
        onZoom = { [weak self] value in self?.selectViewport(value); self?.onViewportChanged?(value) }
        onReset = { [weak self] in self?.selectViewport(nil); self?.onViewportChanged?(nil) }
    }
    func selectViewport(_ value: PlotViewport?) {
        guard selectedViewport != value else { return }
        selectedViewport = value; viewport = value ?? scene?.initialViewport
        dragStart = nil; dragEnd = nil; sceneDirty = true; needsDisplay = true
    }
    func update(_ series: [NotebookChartSeriesSnapshot], style: NotebookLiveChartStyle, running: Bool) {
        let changedStyle = self.style != style || (pending ?? displayed).map(\.settings) != series.map(\.settings)
        self.style = style
        if !changedStyle && (pending ?? displayed) == series { if !running && pending != nil { flush() }; return }
        pending = series
        let remaining = NotebookLiveChartCanvasView.refreshInterval - (ProcessInfo.processInfo.systemUptime - lastDisplay)
        if !running || changedStyle || displayed.isEmpty || remaining <= 0 { flush() }
        else if refreshWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.flush() }; refreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
        }
    }
    private func flush() {
        refreshWork?.cancel(); refreshWork = nil
        guard let pending else { return }
        displayed = pending; self.pending = nil; lastDisplay = ProcessInfo.processInfo.systemUptime
        sceneDirty = true; needsDisplay = true
        setAccessibilityLabel("Multi-series chart: " + displayed.map { $0.settings.title }.joined(separator: ", "))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        if sceneDirty || renderedSize != bounds.size {
            scene = NotebookMultiSeriesScene.make(displayed, style: style, size: bounds.size)
            imageSize = bounds.size; viewport = selectedViewport ?? scene?.initialViewport
            renderedSize = bounds.size; sceneDirty = false; sceneBuildCount += 1
            renderState?.capture(displayed, style: style, size: bounds.size, scene: scene)
        }
        super.draw(dirtyRect)
    }
}
private struct NotebookMultiSeriesCanvas: NSViewRepresentable {
    let series: [NotebookChartSeriesSnapshot], style: NotebookLiveChartStyle
    let running: Bool
    @Binding var viewport: PlotViewport?
    let renderState: NotebookMultiSeriesRenderState
    func makeNSView(context: Context) -> NotebookMultiSeriesCanvasView { let view = NotebookMultiSeriesCanvasView(); view.configure(); return view }
    func updateNSView(_ view: NotebookMultiSeriesCanvasView, context: Context) {
        view.renderState = renderState; view.onViewportChanged = { viewport = $0 }
        view.selectViewport(viewport); view.update(series, style: style, running: running)
    }
}
struct NotebookMultiSeriesView: View {
    @ObservedObject var model: NotebookModel
    let component: NotebookBoardComponent, tab: NotebookTab
    var height: CGFloat? = nil
    var sourceCell: NotebookCell? = nil
    @State private var hidden: Set<String> = []
    @State private var viewport: PlotViewport?
    @State private var error: String?
    @StateObject private var renderState = NotebookMultiSeriesRenderState()
    private var all: [NotebookChartSeriesSnapshot] {
        (component.settings.series ?? []).map { settings in
            let chart: NotebookLiveChart?
            if let sourceCell { chart = model.cellChart(settings.id, cell: sourceCell, tab: tab) }
            else { chart = model.liveChart(settings.id, in: tab) }
            return .init(settings: settings, chart: chart ?? NotebookLiveChart(id: settings.id, points: [], total_points: 0, replace_chart: true))
        }
    }
    private var style: NotebookLiveChartStyle { .init(title: component.title, xLabel: component.x_label ?? "X", yLabel: component.y_label ?? "Y", stroke: component.stroke ?? "#86505f", yMin: component.y_min, yMax: component.y_max, xMin: component.x_min, xMax: component.x_max) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) { HStack {
                ForEach(component.settings.series ?? []) { series in
                    Button { if !hidden.insert(series.id).inserted { hidden.remove(series.id) } } label: {
                        Label(series.title, systemImage: hidden.contains(series.id) ? "circle" : "circle.fill")
                            .foregroundStyle(Color(nsColor: NotebookPalette.native(UInt32(series.stroke.dropFirst(), radix: 16) ?? 0x86505f)))
                    }.buttonStyle(.plain).font(.caption).accessibilityLabel("Toggle series \(series.title)")
                }
            } }
            NotebookPlotControls(initialViewport: renderState.domain, viewport: $viewport, onSave: save) {
                if all.contains(where: { !hidden.contains($0.settings.id) && !$0.chart.points.isEmpty }) {
                    NotebookMultiSeriesCanvas(series: all.filter { !hidden.contains($0.settings.id) }, style: style,
                        running: model.executingWorker, viewport: $viewport, renderState: renderState)
                } else { ContentUnavailableView("Waiting for series", systemImage: "chart.xyaxis.line", description: Text("Publish points to the configured channels.")) }
            }.frame(height: height.map { max(180, $0 - 60) } ?? 300)
                .background(.white, in: RoundedRectangle(cornerRadius: 8)).clipShape(RoundedRectangle(cornerRadius: 8))
            ForEach(all, id: \.settings.id) { series in
                if isStale(series.settings.id) || series.chart.total_points > UInt64(series.chart.points.count) {
                    Text("\(series.settings.title): \(series.chart.points.count) retained / \(series.chart.total_points) points" + (isStale(series.settings.id) ? " · stale" : ""))
                        .font(.caption2).foregroundStyle(NotebookPalette.muted)
                }
            }
            if let caption = component.caption, !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(NotebookPalette.muted) }
            if let error { Text(error).font(.caption).foregroundStyle(NotebookPalette.error) }
        }
    }
    private func isStale(_ channel: String) -> Bool {
        if let sourceCell { return model.executingCells[tab.id] != sourceCell.id && model.figureIsStale(for: sourceCell, in: tab) }
        return model.liveChartIsStale(channel, in: tab)
    }
    private func save() {
        guard let bytes = renderState.png(viewport: viewport) else { error = "Unable to render plot."; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "series.png"
        if panel.runModal() == .OK, let url = panel.url { do { try bytes.write(to: url, options: .atomic) } catch { self.error = error.localizedDescription } }
    }
}

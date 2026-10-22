import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotebookLiveChartStyle: Equatable {
    var title: String, xLabel: String, yLabel: String, stroke: String
    var yMin: Double? = nil, yMax: Double? = nil
    var xMin: Double? = nil, xMax: Double? = nil
}

/// Resolve the plot package's scene vocabulary at the actual card size.
/// Font sizes and line widths remain UI points; no fixed-size canvas is scaled.
enum NotebookLiveChartScene {
    static func make(chart: NotebookLiveChart, style: NotebookLiveChartStyle,
                     size: CGSize, maximumPoints: Int? = nil,
                     viewport: PlotViewport? = nil) -> NotebookPlotScene? {
        guard let first = chart.points.first, size.width > 144, size.height > 144 else { return nil }
        var bounds = [first.x, first.y, first.x, first.y]
        var integralX = true
        for point in chart.points {
            bounds[0] = min(bounds[0], point.x); bounds[2] = max(bounds[2], point.x)
            bounds[1] = min(bounds[1], point.y); bounds[3] = max(bounds[3], point.y)
            integralX = integralX && point.x.rounded() == point.x
        }
        if integralX {
            if style.xMin == nil { bounds[0] = min(0, bounds[0]) }
            if style.xMax == nil { bounds[2] = max(0, bounds[2]) }
            let rough = max(1, (bounds[2] - bounds[0]) / 5)
            let power = pow(10, floor(log10(rough)))
            let fraction = rough / power
            let step = (fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10) * power
            if style.xMin == nil { bounds[0] = floor(bounds[0] / step) * step }
            if style.xMax == nil {
                bounds[2] = ceil(bounds[2] / step) * step
                if chart.points.count == 1 { bounds[2] += step }
            }
        }
        if let low = style.xMin { bounds[0] = low }
        if let high = style.xMax { bounds[2] = high }
        if let low = style.yMin { bounds[1] = low }
        if let high = style.yMax { bounds[3] = high }
        for axis in 0...1 {
            let scale = max(abs(bounds[axis]), abs(bounds[axis + 2]))
            if bounds[axis + 2] - bounds[axis] <= max(1e-100, scale * 1e-13) {
                let delta = max(0.5, scale * 1e-6)
                let low = axis == 0 ? style.xMin : style.yMin
                let high = axis == 0 ? style.xMax : style.yMax
                if low != nil && high == nil {
                    bounds[axis + 2] = bounds[axis] + 2 * delta
                } else if high != nil && low == nil {
                    bounds[axis] = bounds[axis + 2] - 2 * delta
                } else {
                    let center = (bounds[axis] + bounds[axis + 2]) / 2
                    bounds[axis] = center - delta; bounds[axis + 2] = center + delta
                }
            }
        }
        guard PlotViewport(bounds) != nil else { return nil }
        let title = fitted(style.title, width: size.width - 80, font: NotebookPlotTypography.title)
        let tickAttributes: [NSAttributedString.Key: Any] = [.font: NotebookPlotTypography.tick]
        let tickLow = viewport?.yMin ?? bounds[1], tickHigh = viewport?.yMax ?? bounds[3]
        let widestTick = (0...5).map { index -> Double in
            let value = tickHigh - Double(index) / 5 * (tickHigh - tickLow)
            let text = NotebookPlotScene.tick(value, span: tickHigh - tickLow)
            return Double((text as NSString).size(withAttributes: tickAttributes).width)
        }.max() ?? 0
        let padding = max(56, widestTick + 16)
        let frame = CGRect(x: padding, y: padding + (title.isEmpty ? 0 : 24),
                           width: size.width - 2 * padding,
                           height: size.height - 2 * padding - (title.isEmpty ? 0 : 24))
        guard frame.width > 0, frame.height > 0 else { return nil }
        let points = chart.sampledPoints(maxCount: maximumPoints ?? max(256, Int(frame.width * 2))).map { point in
            [frame.minX + (point.x - bounds[0]) / (bounds[2] - bounds[0]) * frame.width,
             frame.minY + (bounds[3] - point.y) / (bounds[3] - bounds[1]) * frame.height]
        }
        let command = points.count == 1
            ? PlotCommand(point: points[0], color: style.stroke, radius: 3)
            : PlotCommand(line: points, stroke: style.stroke, width: 2)
        return NotebookPlotScene(
            version: 1, bounds: bounds, frame: [frame.minX, frame.minY, frame.width, frame.height],
            padding: padding, color_scale: false, aspect_equal: false, y_down: false,
            axes: true, background: "#ffffff", title: title,
            x_label: fitted(style.xLabel, width: frame.width, font: NotebookPlotTypography.axis),
            y_label: fitted(style.yLabel, width: frame.width, font: NotebookPlotTypography.axis),
            layers: [PlotSceneLayer(kind: points.count == 1 ? "points" : "line", commands: [command])],
            decorations: [])
    }

    private static func fitted(_ text: String, width: Double, font: NSFont) -> String {
        let characters = Array(text.prefix(512))
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let value = String(characters)
        if characters.count == text.count && (value as NSString).size(withAttributes: attributes).width <= width {
            return value
        }
        var low = 0, high = characters.count
        while low < high {
            let mid = (low + high + 1) / 2
            let candidate = String(characters.prefix(mid)) + "…"
            if (candidate as NSString).size(withAttributes: attributes).width <= width { low = mid }
            else { high = mid - 1 }
        }
        return String(characters.prefix(low)) + "…"
    }
}

/// A snapshot of the actual displayed chart, used by the shared axis controls
/// and export. Publishing its automatic domain happens outside AppKit's draw.
final class NotebookLiveChartRenderState: ObservableObject {
    @Published private(set) var initialViewport: PlotViewport?
    private var chart: NotebookLiveChart?
    private var style: NotebookLiveChartStyle?
    private var size = CGSize.zero
    private var revision = 0
    private(set) var backingScale = 1.0

    func capture(chart: NotebookLiveChart, style: NotebookLiveChartStyle, size: CGSize,
                 scene: NotebookPlotScene?, backingScale: Double) {
        self.chart = chart; self.style = style; self.size = size
        self.backingScale = backingScale
        revision += 1
        let revision = revision, domain = scene?.initialViewport
        guard initialViewport != domain else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revision == revision else { return }
            self.initialViewport = domain
        }
    }

    func png(viewport: PlotViewport?) -> Data? {
        guard let chart, let style,
              let scene = NotebookLiveChartScene.make(chart: chart, style: style, size: size,
                                                      maximumPoints: chart.points.count,
                                                      viewport: viewport) else { return nil }
        return scene.png(view: viewport ?? scene.initialViewport, size: size, scale: backingScale)
    }
}

/// One native drawing surface replaces per-sample Swift Charts view nodes.
/// Incoming data is retained immediately; live paints are coalesced to 2 Hz.
final class NotebookLiveChartCanvasView: PlotCanvasView {
    var renderState: NotebookLiveChartRenderState?
    var onViewportChanged: ((PlotViewport?) -> Void)?
    private(set) var displayedChart: NotebookLiveChart?
    private var pendingChart: NotebookLiveChart?
    private var style: NotebookLiveChartStyle?
    private var selectedViewport: PlotViewport?
    private var renderedSize = CGSize.zero
    private var sceneDirty = true
    private var lastDisplay = -Double.infinity
    private var refreshWork: DispatchWorkItem?
    private(set) var sceneBuildCount = 0
    static let refreshInterval = 0.5

    deinit { refreshWork?.cancel() }

    func configureInteraction() {
        setAccessibilityElement(true); setAccessibilityRole(.image)
        onZoom = { [weak self] viewport in
            self?.selectViewport(viewport); self?.onViewportChanged?(viewport)
        }
        onReset = { [weak self] in
            self?.selectViewport(nil); self?.onViewportChanged?(nil)
        }
    }

    func selectViewport(_ viewport: PlotViewport?) {
        guard selectedViewport != viewport else { return }
        selectedViewport = viewport; self.viewport = viewport ?? scene?.initialViewport
        dragStart = nil; dragEnd = nil; sceneDirty = true; needsDisplay = true
    }

    func update(chart: NotebookLiveChart, style: NotebookLiveChartStyle, running: Bool) {
        let styleChanged = self.style != style
        self.style = style
        if !styleChanged && (pendingChart ?? displayedChart) == chart {
            if !running && pendingChart != nil { flushPending() }
            return
        }
        pendingChart = chart
        let remaining = Self.refreshInterval - (ProcessInfo.processInfo.systemUptime - lastDisplay)
        if !running || styleChanged || displayedChart == nil || remaining <= 0 {
            flushPending()
        } else if refreshWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.flushPending() }
            refreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
        }
    }

    private func flushPending() {
        refreshWork?.cancel(); refreshWork = nil
        guard let chart = pendingChart else { return }
        displayedChart = chart; pendingChart = nil
        if let style {
            setAccessibilityLabel("Live chart: \(chart.id), \(style.title), \(style.yLabel) by \(style.xLabel)")
            setAccessibilityValue("\(chart.total_points) published points")
        }
        lastDisplay = ProcessInfo.processInfo.systemUptime
        sceneDirty = true; needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let chart = displayedChart, let style else { return }
        if sceneDirty || renderedSize != bounds.size {
            scene = NotebookLiveChartScene.make(chart: chart, style: style, size: bounds.size,
                                               viewport: selectedViewport)
            imageSize = bounds.size
            viewport = selectedViewport ?? scene?.initialViewport
            renderedSize = bounds.size; sceneDirty = false; sceneBuildCount += 1
            renderState?.capture(chart: chart, style: style, size: bounds.size, scene: scene,
                                 backingScale: Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2))
        }
        super.draw(dirtyRect)
    }
}

private struct NotebookLiveChartCanvas: NSViewRepresentable {
    let chart: NotebookLiveChart, style: NotebookLiveChartStyle
    let running: Bool
    @Binding var viewport: PlotViewport?
    let renderState: NotebookLiveChartRenderState

    func makeNSView(context: Context) -> NotebookLiveChartCanvasView {
        let view = NotebookLiveChartCanvasView()
        view.renderState = renderState
        view.configureInteraction()
        return view
    }
    func updateNSView(_ view: NotebookLiveChartCanvasView, context: Context) {
        view.renderState = renderState
        view.onViewportChanged = { viewport = $0 }
        view.selectViewport(viewport)
        view.update(chart: chart, style: style, running: running)
    }
}

struct NotebookLiveChartView: View, Equatable {
    let chart: NotebookLiveChart
    var title = ""
    var caption = ""
    let xLabel: String, yLabel: String, stroke: String
    var yMin: Double? = nil, yMax: Double? = nil
    var xMin: Double? = nil, xMax: Double? = nil
    var running = false
    var cellHeight: Double? = nil
    @StateObject private var renderState = NotebookLiveChartRenderState()
    @State private var viewport: PlotViewport?
    @State private var exportError: String?
    private var style: NotebookLiveChartStyle {
        NotebookLiveChartStyle(title: title, xLabel: xLabel, yLabel: yLabel,
                               stroke: stroke, yMin: yMin, yMax: yMax, xMin: xMin, xMax: xMax)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chart == rhs.chart && lhs.style == rhs.style && lhs.caption == rhs.caption &&
            lhs.running == rhs.running && lhs.cellHeight == rhs.cellHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Group {
                if chart.points.isEmpty {
                    VStack(spacing: 6) {
                        Text(title).font(Font(NotebookPlotTypography.title))
                            .foregroundStyle(Color(nsColor: NotebookPlotTypography.titleColor)).padding(.top, 18)
                        ContentUnavailableView("Waiting for data", systemImage: "chart.xyaxis.line",
                                               description: Text("Publish points to \(chart.id)."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minHeight: cellHeight == nil ? 280 : 48,
                           idealHeight: cellHeight == nil ? 360 : nil, maxHeight: cellHeight == nil ? 420 : .infinity)
                } else {
                    NotebookPlotControls(initialViewport: renderState.initialViewport, viewport: $viewport,
                                         onSave: save) {
                        NotebookLiveChartCanvas(chart: chart, style: style, running: running,
                                                viewport: $viewport, renderState: renderState)
                            .frame(minHeight: cellHeight == nil ? 280 : 48,
                                   idealHeight: cellHeight == nil ? 360 : nil, maxHeight: cellHeight == nil ? 420 : .infinity)
                            .accessibilityLabel("Live chart: \(chart.id), \(title), \(yLabel) by \(xLabel), \(chart.total_points) points")
                            .help("Drag to zoom · double-click to reset")
                    }
                }
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .environment(\.colorScheme, .light)
            if !caption.isEmpty {
                Text(caption).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(NotebookPalette.muted).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("live-chart-caption")
            }
            if let exportError { Text(exportError).font(.caption).foregroundStyle(.red) }
            if chart.total_points > UInt64(chart.points.count) {
                Text("Showing latest \(chart.points.count) of \(chart.total_points) points")
                    .font(.caption2).foregroundStyle(NotebookPalette.muted).padding(.bottom, 8)
            }
        }
        .frame(height: cellHeight.map { CGFloat($0) }, alignment: .top)
        .onChange(of: chart.id) { viewport = nil; exportError = nil }
    }

    private func save() {
        // Freeze the displayed data and selected axes before the save panel
        // opens; training can continue to publish while the dialog is shown.
        guard let bytes = renderState.png(viewport: viewport) else {
            exportError = "Unable to render current plot view"; return
        }
        exportError = nil
        let dialog = NSSavePanel()
        dialog.allowedContentTypes = [.png]
        let filename = chart.id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        dialog.nameFieldStringValue = String(filename.prefix(80)) + ".png"
        dialog.begin { response in
            guard response == .OK, let url = dialog.url else { return }
            do { try bytes.write(to: url, options: .atomic) }
            catch { exportError = error.localizedDescription }
        }
    }
}

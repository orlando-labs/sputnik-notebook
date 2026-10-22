import AppKit
import SwiftUI

/// A persistent label stays visible after the field's placeholder is replaced.
struct NotebookPlotField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content().accessibilityLabel(title)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NotebookPlotView: View {
    let scene: NotebookPlotScene
    let width: Int, height: Int
    @Binding var viewport: PlotViewport?
    var onOpen: (() -> Void)? = nil
    var onSave: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil
    private var current: PlotViewport { viewport ?? scene.initialViewport }

    var body: some View {
        NotebookPlotControls(initialViewport: scene.initialViewport, viewport: $viewport,
                             onOpen: onOpen, onSave: onSave, onShare: onShare) {
            PlotCanvas(scene: scene, imageSize: CGSize(width: width, height: height), viewport: current,
                       onZoom: { viewport = $0 }, onOpen: onOpen, onReset: { viewport = nil })
                .aspectRatio(CGFloat(width) / CGFloat(height), contentMode: .fit)
                .accessibilityLabel("Interactive plot: drag a rectangle to zoom; double-click to reset")
                .help("Drag to zoom · double-click to reset · click to open")
        }
    }
}

/// Static figures and board charts share the same controls and axis editor.
struct NotebookPlotControls<Canvas: View>: View {
    let initialViewport: PlotViewport?
    @Binding var viewport: PlotViewport?
    var onOpen: (() -> Void)? = nil
    var onSave: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil
    @ViewBuilder var canvas: () -> Canvas
    @State private var showAxes = false
    @State private var xMin = ""
    @State private var xMax = ""
    @State private var yMin = ""
    @State private var yMax = ""
    @State private var error: String?
    @State private var fieldsEdited = false
    private var current: PlotViewport? { viewport ?? initialViewport }
    private var hasView: Bool { viewport != nil && viewport != initialViewport }

    var body: some View {
        VStack(spacing: 6) {
            canvas()
                .overlay(alignment: .topTrailing) {
                    NotebookObjectMenu(title: "Plot actions") {
                        Button(showAxes ? "Hide axes settings" : "Axes…") { showAxes.toggle(); loadFields() }
                            .disabled(current == nil)
                        if hasView { Button("Reset axes") { viewport = nil; loadFields() } }
                        if let onOpen { Button("Open…", action: onOpen) }
                        if let onSave { Divider(); Button("Save PNG…", action: onSave) }
                        if let onShare { Button("Share…", action: onShare) }
                    }.padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    if hasView {
                        Button("Reset axes") { viewport = nil; loadFields() }
                            .buttonStyle(.plain).font(.caption)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .accessibilityIdentifier("plot-reset-axes")
                            .padding(6)
                    }
                }
            if showAxes {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Axis limits").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button { showAxes = false } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                                .frame(width: 24, height: 24).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Close axes settings").accessibilityLabel("Close axes settings")
                    }
                    ViewThatFits(in: .horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            GridRow {
                                axisLabel("X minimum"); axisLabel("X maximum")
                                axisLabel("Y minimum"); axisLabel("Y maximum")
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                            GridRow {
                                axisField("X minimum", value: $xMin); axisField("X maximum", value: $xMax)
                                axisField("Y minimum", value: $yMin); axisField("Y maximum", value: $yMax)
                                applyButton
                            }
                        }.fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 12) {
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                                GridRow { axisLabel("X minimum"); axisLabel("X maximum") }
                                GridRow { axisField("X minimum", value: $xMin, compact: true); axisField("X maximum", value: $xMax, compact: true) }
                                GridRow { axisLabel("Y minimum"); axisLabel("Y maximum") }
                                GridRow { axisField("Y minimum", value: $yMin, compact: true); axisField("Y maximum", value: $yMax, compact: true) }
                            }
                            applyButton
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                .padding(16)
                .frame(maxWidth: 624, alignment: .leading)
                .background(NotebookPalette.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(NotebookPalette.rule.opacity(0.5)))
                .padding(.horizontal, 12).padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear(perform: loadFields)
        .onChange(of: viewport) { loadFields() }
        .onChange(of: current) { if !fieldsEdited { loadFields() } }
    }
    private func axisLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
    }
    private func axisField(_ title: String, value: Binding<String>, compact: Bool = false) -> some View {
        TextField(title, text: editing(value)).textFieldStyle(.plain)
            .font(.system(size: 13)).padding(.horizontal, 8)
            .frame(minWidth: compact ? 60 : 110, idealWidth: 110, maxWidth: 110)
            .frame(height: 30)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(NotebookPalette.rule.opacity(0.7)))
            .accessibilityLabel(title).onSubmit(apply)
    }
    private var applyButton: some View {
        Button(action: apply) {
            Text("Apply axes").font(.system(size: 12, weight: .medium))
                .frame(width: 104, height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).foregroundStyle(NotebookPalette.sputnik)
            .background(NotebookPalette.sputnik.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(NotebookPalette.sputnik.opacity(0.2)))
    }
    private func editing(_ value: Binding<String>) -> Binding<String> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; fieldsEdited = true })
    }
    private func loadFields() {
        guard let current else { return }
        xMin = String(current.xMin); xMax = String(current.xMax)
        yMin = String(current.yMin); yMax = String(current.yMax); error = nil; fieldsEdited = false
    }
    private func apply() {
        let values = [xMin, yMin, xMax, yMax].compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")) }
        guard let value = PlotViewport(values) else {
            error = "Enter finite bounds with minimum < maximum (and a resolvable interval)."; return
        }
        viewport = value; loadFields()
    }
}

struct PlotCanvas: NSViewRepresentable {
    let scene: NotebookPlotScene, imageSize: CGSize, viewport: PlotViewport
    let onZoom: (PlotViewport) -> Void
    let onOpen: (() -> Void)?
    let onReset: () -> Void

    func makeNSView(context: Context) -> PlotCanvasView { PlotCanvasView() }
    func updateNSView(_ view: PlotCanvasView, context: Context) {
        if view.viewport != viewport { view.dragStart = nil; view.dragEnd = nil }
        view.scene = scene; view.imageSize = imageSize; view.viewport = viewport
        view.onZoom = onZoom; view.onOpen = onOpen; view.onReset = onReset
        view.needsDisplay = true
    }
}

class PlotCanvasView: NSView {
    var scene: NotebookPlotScene?
    var imageSize = CGSize(width: 800, height: 540)
    var viewport: PlotViewport?
    var onZoom: ((PlotViewport) -> Void)?, onOpen: (() -> Void)?, onReset: (() -> Void)?
    var dragStart: CGPoint?, dragEnd: CGPoint?
    private var pendingOpen: DispatchWorkItem?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        guard let scene, let viewport, bounds.width > 0, bounds.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.scaleBy(x: bounds.width / imageSize.width, y: bounds.height / imageSize.height)
        scene.draw(view: viewport, size: imageSize)
        NSGraphicsContext.restoreGraphicsState()
        if let start = dragStart, let end = dragEnd {
            let rectangle = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            NotebookPalette.nativeAccent.withAlphaComponent(0.15).setFill(); NSBezierPath(rect: rectangle).fill()
            NotebookPalette.nativeAccent.setStroke(); let path = NSBezierPath(rect: rectangle); path.lineWidth = 1.5; path.stroke()
        }
    }
    private func imagePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * imageSize.width / max(1, bounds.width), y: p.y * imageSize.height / max(1, bounds.height))
    }
    override func mouseDown(with event: NSEvent) {
        pendingOpen?.cancel(); pendingOpen = nil
        if event.clickCount == 2 { dragStart = nil; dragEnd = nil; onReset?(); return }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let scene, let viewport, scene.plotFrame(view: viewport, size: imageSize).contains(imagePoint(p)) else { return }
        dragStart = p; dragEnd = p
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil, let scene, let viewport else { return }
        let f = scene.plotFrame(view: viewport, size: imageSize)
        let p = imagePoint(convert(event.locationInWindow, from: nil))
        dragEnd = CGPoint(x: min(max(p.x, f.minX), f.maxX) * bounds.width / imageSize.width,
                          y: min(max(p.y, f.minY), f.maxY) * bounds.height / imageSize.height)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragEnd = nil; needsDisplay = true }
        guard let start = dragStart, let end = dragEnd, let scene, let viewport else { return }
        if abs(end.x - start.x) < 5 || abs(end.y - start.y) < 5 {
            if abs(end.x - start.x) < 5 && abs(end.y - start.y) < 5 && onOpen != nil {
                // A first click must not open a sheet before the second click
                // can perform reset on this canvas.
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.window != nil else { return }
                    self.onOpen?(); self.pendingOpen = nil
                }
                pendingOpen = work
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
            }
            return
        }
        let a = imagePoint(start), b = imagePoint(end)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        if let view = scene.selectedViewport(rect, view: viewport, size: imageSize) { onZoom?(view) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { pendingOpen?.cancel(); pendingOpen = nil; dragStart = nil; dragEnd = nil; needsDisplay = true }
        else { super.keyDown(with: event) }
    }
}

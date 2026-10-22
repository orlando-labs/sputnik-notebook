import SwiftUI
import AppKit

struct NotebookImageAnnotatorView: View {
    let panel: NotebookFigurePanel
    let binding: NotebookImageAnnotationBinding
    private let snappedLegacyCoordinates: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NotebookAnnotationDraft
    @State private var tool = "rect"
    @State private var label = "object"
    @State private var selected: String?
    @State private var preview: NotebookImageAnnotations.Shape?
    @State private var viewport = NotebookImageAnnotationViewport()
    @State private var panStart: NotebookImageAnnotationViewport?
    @State private var canvasSize = CGSize(width: 660, height: 450)
    @State private var decodedImage: NSImage?
    @State private var saving = false
    @State private var error: String?
    @State private var invalidCoordinates: Set<String> = []
    init(panel: NotebookFigurePanel, binding: NotebookImageAnnotationBinding) {
        self.panel = panel; self.binding = binding
        let previous = binding.accepted?.matches(panel) == true ? binding.accepted!.shapes : []
        var shapes = previous.map { $0.snapped(width: panel.width, height: panel.height) }
        snappedLegacyCoordinates = shapes != previous
        let definitions = binding.classes ?? binding.accepted?.classes ?? []
        for index in shapes.indices {
            shapes[index].classes = (shapes[index].classes ?? []).filter { key in definitions.contains { $0.id == key } }
            shapes[index].attributes = notebookAnnotationAttributes(classes: shapes[index].classes ?? [], values: shapes[index].attributes ?? [:], definitions: definitions)
        }
        _draft = State(initialValue: NotebookAnnotationDraft(shapes: shapes))
        _selected = State(initialValue: shapes.first?.id)
    }
    private var value: NotebookImageAnnotations {
        .init(asset: notebookAssetID(panel.data), channel: binding.channel, width: panel.width, height: panel.height, shapes: draft.shapes, classes: definitions)
    }
    private var definitions: [NotebookAnnotationClass] { binding.classes ?? binding.accepted?.classes ?? [] }
    private var selectedShape: NotebookImageAnnotations.Shape? { draft.shapes.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Image annotations").font(.title2.bold())
            HStack {
                Picker("Tool", selection: $tool) { Text("Rectangle").tag("rect"); Text("Point").tag("point"); Text("Pan").tag("pan") }.frame(width: 200)
                TextField("Region title", text: $label).textFieldStyle(.roundedBorder).frame(width: 220)
                Button("Undo") { draft.undoEdit() }.disabled(draft.undo.isEmpty)
                Button("Redo") { draft.redoEdit() }.disabled(draft.redo.isEmpty)
                Spacer()
                Text("\(panel.width) × \(panel.height) · source pixels").font(.caption).foregroundStyle(NotebookPalette.muted)
            }
            zoomControls
            HStack(alignment: .top, spacing: 14) {
                canvas
                VStack(alignment: .leading) {
                    Text("\(draft.shapes.count) shapes").font(.headline)
                    List(selection: $selected) { ForEach(draft.shapes) { shape in
                        VStack(alignment: .leading) {
                            Text(shape.label.isEmpty ? shape.kind : shape.label)
                            Text("\(shape.kind) · \(shape.x.formatted(.number.precision(.fractionLength(0)))), \(shape.y.formatted(.number.precision(.fractionLength(0))))").font(.caption).foregroundStyle(NotebookPalette.muted)
                        }.tag(shape.id)
                    } }
                    ScrollView { VStack(alignment: .leading, spacing: 8) { if selectedShape != nil {
                        TextField("Label", text: Binding(get: { draft.shapes.first { $0.id == selected }?.label ?? "" }, set: { text in
                            guard let current = draft.shapes.firstIndex(where: { $0.id == selected }), text.utf8.count <= 128, !text.contains("\0") else { return }; var shapes = draft.shapes; shapes[current].label = text; draft.replace(shapes)
                        })).textFieldStyle(.roundedBorder)
                        if draft.shapes.first(where: { $0.id == selected })?.kind == "rect" {
                            HStack { coordinate("X1", property: "x"); coordinate("Y1", property: "y") }
                            HStack { coordinate("X2", property: "right"); coordinate("Y2", property: "bottom") }
                        } else { HStack { coordinate("X", property: "x"); coordinate("Y", property: "y") } }
                        Text("Whole pixels · origin at top left").font(.caption).foregroundStyle(NotebookPalette.muted)
                        classAssignments
                        Button("Delete shape", role: .destructive) { draft.replace(draft.shapes.filter { $0.id != selected }); selected = nil }
                    } } }.frame(maxHeight: 300)
                }.frame(width: 210)
            }
            if let accepted = binding.accepted, !accepted.matches(panel) {
                Text("Image changed. This draft belongs to the current image; previous labels will be replaced on Apply.").font(.caption).foregroundStyle(NotebookPalette.sputnik)
            }
            if let error { Text(error).foregroundStyle(NotebookPalette.error) }
            if snappedLegacyCoordinates { Text("Previous fractional coordinates were snapped to pixels. Review and Apply.").font(.caption).foregroundStyle(NotebookPalette.sputnik) }
            if let accepted = binding.accepted, (accepted.classes ?? []) != definitions { Text("Class schema changed in Board Designer. Review the updated draft and Apply.").font(.caption).foregroundStyle(NotebookPalette.sputnik) }
            HStack {
                Button("Export JSON…") { export() }
                Text("Draw to annotate · Pan to move · Apply saves without Run").font(.caption).foregroundStyle(NotebookPalette.muted)
                Spacer()
                Button("Discard", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("image-annotations-discard")
                Button("Apply") { saving = true; binding.apply(value) { ok in saving = false; if ok { dismiss() } else { error = "Could not apply annotations. Check the current image and try again." } } }
                    .buttonStyle(.borderedProminent).disabled(!invalidCoordinates.isEmpty).keyboardShortcut(.defaultAction).accessibilityIdentifier("image-annotations-apply")
            }
        }.padding(20).frame(width: 960, height: 680).background(NotebookPalette.canvas).foregroundStyle(NotebookPalette.ink)
            .disabled(saving || binding.disabled).interactiveDismissDisabled().accessibilityIdentifier("image-annotation-editor")
            .task {
                decodedImage = panel.image(maxPixelSize: max(panel.width, panel.height))
                if decodedImage == nil { error = "Image could not be decoded" }
            }
    }
    private var classAssignments: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider(); Text("Classes").font(.headline)
            if definitions.isEmpty { Text("Configure allowed classes in Board Designer.").font(.caption).foregroundStyle(NotebookPalette.muted) }
            ForEach(definitions) { definition in
                Toggle(definition.title, isOn: Binding(get: { selectedShape?.classes?.contains(definition.id) == true }, set: { enabled in editSelected { shape in
                    var assigned = shape.classes ?? []; assigned.removeAll { $0 == definition.id }
                    var attributes = shape.attributes ?? [:]; attributes.removeValue(forKey: definition.id)
                    if enabled { assigned.append(definition.id); attributes[definition.id] = Dictionary(uniqueKeysWithValues: definition.attributes.map { ($0.id, $0.defaultValue) }) }
                    shape.classes = assigned; shape.attributes = attributes
                } })).accessibilityIdentifier("image-class-" + definition.id)
                if selectedShape?.classes?.contains(definition.id) == true { ForEach(definition.attributes) { attribute in
                    NotebookAnnotationAttributeField(attribute: attribute, value: Binding(get: { selectedShape?.attributes?[definition.id]?[attribute.id] ?? attribute.defaultValue }, set: { scalar in editSelected { shape in
                        var values = shape.attributes ?? [:]; values[definition.id, default: [:]][attribute.id] = scalar; shape.attributes = values
                    } }), validity: { valid in
                        let key = definition.id + ":" + attribute.id
                        if valid { invalidCoordinates.remove(key) } else { invalidCoordinates.insert(key) }
                    }).id((selected ?? "") + definition.id + attribute.id)
                } }
            }
        }
    }
    private func editSelected(_ action: (inout NotebookImageAnnotations.Shape) -> Void) {
        guard let index = draft.shapes.firstIndex(where: { $0.id == selected }) else { return }
        var shapes = draft.shapes; action(&shapes[index]); draft.replace(shapes)
    }
    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button("−") { zoom(viewport.zoom / 2) }.accessibilityLabel("Zoom out").accessibilityIdentifier("image-zoom-out")
            Button("+") { zoom(viewport.zoom * 2) }.accessibilityLabel("Zoom in").accessibilityIdentifier("image-zoom-in")
            Button("Fit") { viewport = .init() }.accessibilityIdentifier("image-zoom-fit")
            Button("100%") { viewport = viewport.actualSize(canvasSize, width: panel.width, height: panel.height) }.help("One screen point per source pixel")
            Button("Zoom to selection") {
                if let shape = draft.shapes.first(where: { $0.id == selected }) { viewport = viewport.focusing(shape, size: canvasSize, width: panel.width, height: panel.height) }
            }.disabled(selected == nil).accessibilityIdentifier("image-zoom-selection")
            let scale = viewport.imageRect(canvasSize, width: panel.width, height: panel.height).width / Double(panel.width)
            Text(scale.formatted(.percent.precision(.fractionLength(0...1)))).font(.caption.monospacedDigit()).accessibilityIdentifier("image-zoom-level")
            Spacer()
        }.buttonStyle(.bordered).controlSize(.small)
    }
    private func zoom(_ value: Double) { viewport = viewport.zoomed(to: value, size: canvasSize, width: panel.width, height: panel.height) }
    private var canvas: some View {
        GeometryReader { geometry in
            let rect = viewport.imageRect(geometry.size, width: panel.width, height: panel.height)
            ZStack(alignment: .topLeading) {
                if let image = decodedImage {
                    Image(nsImage: image).resizable().interpolation(.none).frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                }
                Canvas { context, _ in
                    for shape in draft.shapes + (preview.map { [$0] } ?? []) {
                        let x = rect.minX + (shape.x + (shape.kind == "point" ? 0.5 : 0)) / Double(panel.width) * rect.width
                        let y = rect.minY + (shape.y + (shape.kind == "point" ? 0.5 : 0)) / Double(panel.height) * rect.height
                        let bounds = shape.kind == "point" ? CGRect(x: x - 4, y: y - 4, width: 8, height: 8) : CGRect(x: x, y: y, width: (shape.width ?? 0) / Double(panel.width) * rect.width, height: (shape.height ?? 0) / Double(panel.height) * rect.height)
                        let path = shape.kind == "point" ? Path(ellipseIn: bounds) : Path(bounds)
                        let color = shape.id == selected ? Color.orange : NotebookPalette.sputnik
                        context.fill(path, with: .color(color.opacity(0.12))); context.stroke(path, with: .color(color), lineWidth: 2)
                        context.draw(Text(shape.label).font(.caption.bold()).foregroundColor(color), at: CGPoint(x: x + 3, y: max(0, y - 16)), anchor: .topLeading)
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).contentShape(Rectangle()).clipped()
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if tool == "pan" {
                            if panStart == nil { panStart = viewport }
                            viewport = panStart!.panned(drag.translation, size: geometry.size, width: panel.width, height: panel.height)
                        } else { preview = shape(from: drag, rect: rect) }
                    }
                    .onEnded { drag in
                        if tool != "pan", let shape = shape(from: drag, rect: rect), draft.shapes.count < 500 { draft.replace(draft.shapes + [shape]); selected = shape.id }
                        preview = nil; panStart = nil
                    })
                .onAppear { canvasSize = geometry.size }.onChange(of: geometry.size) { _, size in canvasSize = size }
        }.background(NotebookPalette.canvas).frame(minWidth: 450, minHeight: 400).accessibilityIdentifier("image-annotation-canvas")
    }
    private func coordinate(_ title: String, property: String) -> some View {
        HStack {
            Text(title).font(.caption)
            NotebookAnnotationNumberField(title: title, value: Binding<Double>(get: {
                guard let shape = draft.shapes.first(where: { $0.id == selected }) else { return 0 }
                switch property { case "x": return shape.x; case "y": return shape.y; case "right": return shape.x + (shape.width ?? 0); default: return shape.y + (shape.height ?? 0) }
            }, set: { number in
                guard number.isFinite, number.rounded() == number, let index = draft.shapes.firstIndex(where: { $0.id == selected }) else { return }
                var shapes = draft.shapes, shape = shapes[index]
                if shape.kind == "rect" {
                    let right = shape.x + (shape.width ?? 1), bottom = shape.y + (shape.height ?? 1)
                    switch property {
                    case "x": shape.x = max(0, min(right - 1, number)); shape.width = right - shape.x
                    case "y": shape.y = max(0, min(bottom - 1, number)); shape.height = bottom - shape.y
                    case "right": shape.width = max(shape.x + 1, min(Double(panel.width), number)) - shape.x
                    default: shape.height = max(shape.y + 1, min(Double(panel.height), number)) - shape.y
                    }
                } else if property == "x" { shape.x = min(Double(panel.width - 1), max(0, number)) }
                else { shape.y = min(Double(panel.height - 1), max(0, number)) }
                shapes[index] = shape; draft.replace(shapes)
            }), integersOnly: true, validity: { valid in if valid { invalidCoordinates.remove(property) } else { invalidCoordinates.insert(property) } })
                .id((selected ?? "") + property).textFieldStyle(.roundedBorder).accessibilityIdentifier("image-coordinate-" + property)
        }
    }
    private func shape(from drag: DragGesture.Value, rect: CGRect) -> NotebookImageAnnotations.Shape? {
        guard rect.contains(drag.startLocation), !label.contains("\0"), label.utf8.count <= 128 else { return nil }
        func point(_ p: CGPoint) -> CGPoint { NotebookImageAnnotationViewport.sourcePoint(p, rect: rect, width: panel.width, height: panel.height) }
        let a = point(drag.startLocation), b = point(drag.location)
        return .drawn(kind: tool, label: label, from: a, to: b, width: panel.width, height: panel.height)
    }
    private func export() {
        let save = NSSavePanel(); save.nameFieldStringValue = "annotations.json"
        guard save.runModal() == .OK, let url = save.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(value).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
}

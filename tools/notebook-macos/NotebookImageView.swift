import SwiftUI
import UniformTypeIdentifiers

/// Measures captions before allocating the viewport, so fixed-height rows
/// keep their navigation visible and auto-height follows the image's ratio.
struct NotebookImageLayout: Layout {
    let ratio: Double
    let mode: String
    let height: Double?
    private func sizes(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (Double, Double, Double) {
        let width = max(1, proposal.width ?? 320)
        let footer = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let viewport = mode == "auto-height" ? width / max(0.0001, ratio) : max(48, (height ?? 340) - footer - 12)
        return (width, viewport, footer)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (width, viewport, footer) = sizes(proposal, subviews)
        return CGSize(width: width, height: viewport + footer + 12)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (width, viewport, footer) = sizes(ProposedViewSize(width: bounds.width, height: bounds.height), subviews)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: width, height: viewport))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + viewport + 12), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: footer))
    }
}

private struct NotebookImageAnnotationPresentation: Identifiable {
    let id = UUID()
    let panel: NotebookFigurePanel
    let binding: NotebookImageAnnotationBinding
}

struct NotebookImageView: View {
    let series: NotebookImageSeries
    let carousel: Bool
    var mode = "fit"
    var caption = ""
    var cellHeight: Double? = nil
    var selected: Int? = nil
    var allowSave = false
    var allowLoad = false
    var controlsDisabled = false
    var onSelection: ((Int) -> Void)? = nil
    var onEdit: (([NotebookFigurePanel], String, Int) -> Void)? = nil
    var annotationBinding: NotebookImageAnnotationBinding? = nil
    @State private var annotationEditor: NotebookImageAnnotationPresentation?
    @State private var selection = 0
    @State private var fileError: String? = nil
    private var index: Int { max(0, min(selected ?? selection, series.images.count - 1)) }
    private var seriesCaption: String { series.caption.isEmpty ? caption : series.caption }

    var body: some View {
        Group {
            if !series.images.isEmpty {
                let panel = series.images[carousel ? index : 0]
                NotebookImageLayout(ratio: Double(panel.width) / Double(max(1, panel.height)), mode: mode, height: cellHeight) {
                    GeometryReader { geometry in
                        if let image = panel.image(maxPixelSize: min(1600, max(panel.width, panel.height))) {
                            Image(nsImage: image).resizable()
                                .interpolation(panel.width <= 64 && panel.height <= 64 ? .none : .high)
                                .aspectRatio(contentMode: mode == "fill" ? .fill : .fit)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped().accessibilityLabel(panel.caption.isEmpty ? "Image \(index + 1)" : panel.caption)
                        } else {
                            Label("Image could not be decoded", systemImage: "exclamationmark.triangle")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }.background(NotebookPalette.canvas).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 8) {
                        if !panel.caption.isEmpty { Text(panel.caption).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        if carousel {
                            HStack(spacing: 12) {
                                Button { choose(max(0, index - 1)) } label: { Image(systemName: "chevron.left") }
                                    .disabled(index == 0 || controlsDisabled).accessibilityLabel("Previous image").accessibilityIdentifier("image-carousel-previous")
                                Text("\(index + 1) / \(series.images.count)").font(.caption.monospacedDigit())
                                    .accessibilityIdentifier("image-carousel-position")
                                Button { choose(min(series.images.count - 1, index + 1)) } label: { Image(systemName: "chevron.right") }
                                    .disabled(index + 1 == series.images.count || controlsDisabled).accessibilityLabel("Next image").accessibilityIdentifier("image-carousel-next")
                                Spacer()
                            }.buttonStyle(.bordered).controlSize(.small)
                        }
                        if !seriesCaption.isEmpty { Text(seriesCaption).font(.caption).foregroundStyle(NotebookPalette.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        imageActions
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: carousel ? "photo.on.rectangle.angled" : "photo").font(.system(size: 32))
                    Text(allowLoad ? "Load \(carousel ? "images" : "an image") or run the sheet" : "Run the sheet to publish \(carousel ? "images" : "an image")")
                    if !seriesCaption.isEmpty { Text(seriesCaption).font(.caption) }
                    imageActions
                }.foregroundStyle(NotebookPalette.muted).frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .sheet(item: $annotationEditor) { editor in
            NotebookImageAnnotatorView(panel: editor.panel, binding: editor.binding)
        }
        .onChange(of: series.images.count) { selection = max(0, min(selection, series.images.count - 1)) }
        .accessibilityIdentifier(carousel ? "notebook-image-carousel" : "notebook-image")
        .alert("Image file", isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })) {
            Button("OK") { fileError = nil }
        } message: { Text(fileError ?? "") }
    }

    private func choose(_ index: Int) {
        selection = index
        onSelection?(index)
    }

    @ViewBuilder private var imageActions: some View {
        if allowSave || allowLoad || annotationBinding != nil {
            HStack(spacing: 10) {
                if let annotationBinding {
                    Button("Annotate…", systemImage: "pencil.tip.crop.circle") { annotationEditor = .init(panel: series.images[carousel ? index : 0], binding: annotationBinding) }
                        .disabled(series.images.isEmpty || annotationBinding.disabled).accessibilityIdentifier("image-annotate")
                    if let annotations = annotationBinding.accepted, !series.images.isEmpty, annotations.matches(series.images[carousel ? index : 0]) {
                        Text("\(annotations.shapes.count) labels").font(.caption)
                    }
                }
                if allowLoad {
                    Button(carousel ? "Add images…" : "Load image…", systemImage: "plus") { loadFiles() }
                        .accessibilityIdentifier("image-load-file")
                }
                if allowSave {
                    Button("Save image…", systemImage: "square.and.arrow.down") { saveFile() }
                        .disabled(series.images.isEmpty).accessibilityIdentifier("image-save-file")
                }
                if allowLoad && !series.images.isEmpty {
                    Menu {
                        if carousel {
                            Button("Move earlier", systemImage: "arrow.left") { reorder(-1) }.disabled(index == 0)
                            Button("Move later", systemImage: "arrow.right") { reorder(1) }.disabled(index + 1 == series.images.count)
                            Divider()
                        }
                        Button("Remove image", systemImage: "trash", role: .destructive) {
                            var images = series.images; images.remove(at: index)
                            onEdit?(images, series.caption, max(0, min(index, images.count - 1)))
                        }
                    } label: { Label("Edit", systemImage: "ellipsis") }
                    .accessibilityIdentifier("image-edit-menu")
                }
            }.buttonStyle(.bordered).controlSize(.small).disabled(controlsDisabled)
        }
    }

    private func reorder(_ offset: Int) {
        var images = series.images
        let target = index + offset
        guard images.indices.contains(target) else { return }
        images.swapAt(index, target)
        onEdit?(images, series.caption, target)
    }
    private func loadFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = carousel
        guard panel.runModal() == .OK else { return }
        do {
            let incoming = try panel.urls.map { try NotebookFigurePanel.loadImageFile($0) }
            let images = carousel ? series.images + incoming : incoming
            guard images.count <= 64, images.reduce(0, { $0 + $1.data.count }) <= 64 * 1024 * 1024 else {
                throw NSError(domain: "NotebookImage", code: 4, userInfo: [NSLocalizedDescriptionKey: "A collection accepts up to 64 images and 64 MiB."])
            }
            onEdit?(images, series.caption, carousel ? series.images.count : 0)
        } catch { fileError = error.localizedDescription }
    }
    private func saveFile() {
        guard !series.images.isEmpty else { return }
        let image = series.images[carousel ? index : 0]
        let panel = NSSavePanel(); panel.allowedContentTypes = [image.mime == "image/jpeg" ? .jpeg : .png]
        panel.nameFieldStringValue = "image-\(index + 1).\(image.mime == "image/jpeg" ? "jpg" : "png")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try image.saveImageFile(url) } catch { fileError = error.localizedDescription }
    }
}

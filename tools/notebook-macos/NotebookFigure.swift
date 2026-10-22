import AppKit
import ImageIO

/// Bytes and captions are runtime output, not persisted project content.
struct NotebookFigurePanel: Codable {
    var id: String? = nil
    var plot_scene: String? = nil {
        didSet { scene = NotebookPlotScene.decode(plot_scene, width: width, height: height) }
    }
    let mime: String
    let caption: String
    let width: Int
    let height: Int
    let data: Data
    private(set) var scene: NotebookPlotScene? = nil

    private enum CodingKeys: String, CodingKey { case id, plot_scene, mime, caption, width, height, data }
    init(plot_scene: String? = nil, mime: String, caption: String, width: Int, height: Int, data: Data, id: String? = nil) {
        self.id = id
        self.plot_scene = plot_scene; self.mime = mime; self.caption = caption
        self.width = width; self.height = height; self.data = data
        scene = NotebookPlotScene.decode(plot_scene, width: width, height: height)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(plot_scene: try c.decodeIfPresent(String.self, forKey: .plot_scene),
                  mime: try c.decode(String.self, forKey: .mime), caption: try c.decode(String.self, forKey: .caption),
                  width: try c.decode(Int.self, forKey: .width), height: try c.decode(Int.self, forKey: .height),
                  data: try c.decode(Data.self, forKey: .data), id: try c.decodeIfPresent(String.self, forKey: .id))
    }

    func image(maxPixelSize: Int = 1200) -> NSImage? {
        if mime == "application/vnd.sputnik.plot+json", data.isEmpty, let scene,
           let png = scene.png(view: scene.initialViewport, width: width, height: height) {
            return NSImage(data: png)
        }
        guard mime == "image/png" || mime == "image/jpeg", data.count <= 16 * 1024 * 1024,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == (mime == "image/png" ? "public.png" : "public.jpeg"),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? Int) == width,
              (properties[kCGImagePropertyPixelHeight] as? Int) == height else { return nil }
        // A notebook may contain many high-resolution panels. Decode bounded
        // previews; only the selected lightbox/share image needs full pixels.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(8192, maxPixelSize)),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func label(_ index: Int) -> String {
        var n = index + 1, label = ""
        while n > 0 { n -= 1; label = String(UnicodeScalar(97 + n % 26)!) + label; n /= 26 }
        return label + ")"
    }

    static func loadImageFile(_ url: URL) throws -> Self {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 16 * 1024 * 1024 else {
            throw NSError(domain: "NotebookImage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Image exceeds 16 MiB."])
        }
        let bytes = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, type == "public.png" || type == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw NSError(domain: "NotebookImage", code: 2, userInfo: [NSLocalizedDescriptionKey: "Choose a PNG or JPEG image."])
        }
        let panel = Self(mime: type == "public.png" ? "image/png" : "image/jpeg", caption: url.deletingPathExtension().lastPathComponent,
                         width: width, height: height, data: bytes)
        guard panel.image() != nil else {
            throw NSError(domain: "NotebookImage", code: 3, userInfo: [NSLocalizedDescriptionKey: "Image cannot be decoded or exceeds the pixel limit."])
        }
        return panel
    }

    func saveImageFile(_ url: URL) throws { try data.write(to: url, options: .atomic) }
}

extension NotebookFigurePanel: Equatable {
    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.mime == b.mime && a.caption == b.caption && a.width == b.width && a.height == b.height &&
            a.data == b.data && a.plot_scene == b.plot_scene
    }
}

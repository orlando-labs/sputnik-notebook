import Foundation
import CryptoKit

func notebookAssetID(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

enum NotebookTableValue: Codable, Equatable {
    case null, boolean(Bool), integer(Int64), number(Double), text(String)
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .boolean(v) }
        else if let v = try? value.decode(Int64.self) { self = .integer(v) }
        else if let v = try? value.decode(Double.self), v.isFinite { self = .number(v) }
        else { self = .text(try value.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .boolean(let v): try value.encode(v)
        case .integer(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .text(let v): try value.encode(v)
        }
    }
    var text: String {
        switch self {
        case .null: return ""
        case .boolean(let v): return v ? "true" : "false"
        case .integer(let v): return String(v)
        case .number(let v): return String(v)
        case .text(let v): return v
        }
    }
    private var numeric: Bool {
        switch self { case .integer, .number: return true; default: return false }
    }
    func compare(_ other: Self) -> ComparisonResult {
        if numeric && other.numeric, let left = Decimal(string: text), let right = Decimal(string: other.text) {
            return left < right ? .orderedAscending : left > right ? .orderedDescending : .orderedSame
        }
        return text.localizedStandardCompare(other.text)
    }
}

struct NotebookAnnotationClass: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var title: String
    var attributes: [NotebookAnnotationAttribute] = []
}
struct NotebookAnnotationAttribute: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var title: String
    var type = "text"
    var options: [String] = []
    func accepts(_ value: NotebookTableValue) -> Bool {
        switch (type, value) {
        case ("text", .text(let text)): return text.utf8.count <= 2048 && !text.contains("\0")
        case ("choice", .text(let text)): return options.contains(text)
        case ("boolean", .boolean), ("number", .integer): return true
        case ("number", .number(let number)): return number.isFinite
        default: return false
        }
    }
    var defaultValue: NotebookTableValue {
        switch type { case "number": return .number(0); case "boolean": return .boolean(false); case "choice": return .text(options.first ?? ""); default: return .text("") }
    }
}
func notebookAnnotationAttributes(classes: [String], values: [String: [String: NotebookTableValue]], definitions: [NotebookAnnotationClass]) -> [String: [String: NotebookTableValue]] {
    var result: [String: [String: NotebookTableValue]] = [:]
    for definition in definitions where classes.contains(definition.id) {
        for attribute in definition.attributes {
            if let value = values[definition.id]?[attribute.id], attribute.accepts(value) { result[definition.id, default: [:]][attribute.id] = value }
        }
    }
    return result
}
struct NotebookAudioTranscriptPolicy: Equatable {
    var trackAllowed = true, trackRequired = false
    var segmentAllowed = true, segmentRequired = false
    func validationError(_ value: NotebookAudioAnnotations) -> String? {
        if !trackAllowed && !value.transcript.isEmpty { return "Whole-track transcripts are disabled in Board Designer." }
        if trackRequired && value.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "A whole-track transcript is required." }
        if !segmentAllowed && value.segments.contains(where: { !$0.transcript.isEmpty }) { return "Segment transcripts are disabled in Board Designer." }
        if segmentRequired && value.segments.contains(where: { $0.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return "A transcript is required for every segment." }
        return nil
    }
}

struct NotebookImageAnnotations: Codable, Equatable {
    var version = 1
    let asset: String
    let channel: String
    let width: Int, height: Int
    var shapes: [Shape]
    var classes: [NotebookAnnotationClass]? = nil
    struct Shape: Codable, Identifiable, Equatable {
        var id: String
        var kind: String
        var label: String
        var x: Double, y: Double
        var width: Double? = nil, height: Double? = nil
        var classes: [String]? = nil
        var attributes: [String: [String: NotebookTableValue]]? = nil

        /// Points address pixels; rectangle corners address pixel boundaries.
        static func drawn(kind: String, label: String, from start: CGPoint, to end: CGPoint, width: Int, height: Int) -> Self? {
            if kind == "point" {
                return .init(id: UUID().uuidString, kind: kind, label: label,
                    x: max(0, min(Double(width - 1), floor(start.x))),
                    y: max(0, min(Double(height - 1), floor(start.y))))
            }
            let x1 = max(0, min(Double(width), start.x.rounded())), y1 = max(0, min(Double(height), start.y.rounded()))
            let x2 = max(0, min(Double(width), end.x.rounded())), y2 = max(0, min(Double(height), end.y.rounded()))
            guard x1 != x2, y1 != y2 else { return nil }
            return .init(id: UUID().uuidString, kind: kind, label: label,
                x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
        }

        /// Keep legacy fractional drafts editable, with at least one whole pixel per side.
        func snapped(width imageWidth: Int, height imageHeight: Int) -> Self {
            var shape = self
            if kind == "point" {
                shape.x = max(0, min(Double(imageWidth - 1), floor(x)))
                shape.y = max(0, min(Double(imageHeight - 1), floor(y)))
            } else {
                shape.x = max(0, min(Double(imageWidth - 1), x.rounded()))
                shape.y = max(0, min(Double(imageHeight - 1), y.rounded()))
                shape.width = max(shape.x + 1, min(Double(imageWidth), (x + (width ?? 1)).rounded())) - shape.x
                shape.height = max(shape.y + 1, min(Double(imageHeight), (y + (height ?? 1)).rounded())) - shape.y
            }
            return shape
        }
    }
    func matches(_ panel: NotebookFigurePanel) -> Bool {
        asset == notebookAssetID(panel.data) && width == panel.width && height == panel.height
    }
}

struct NotebookAnnotationDraft {
    private(set) var shapes: [NotebookImageAnnotations.Shape]
    private(set) var undo: [[NotebookImageAnnotations.Shape]] = []
    private(set) var redo: [[NotebookImageAnnotations.Shape]] = []
    mutating func replace(_ value: [NotebookImageAnnotations.Shape]) {
        guard value != shapes else { return }
        undo.append(shapes); if undo.count > 50 { undo.removeFirst() }; redo = []; shapes = value
    }
    mutating func undoEdit() { guard let value = undo.popLast() else { return }; redo.append(shapes); shapes = value }
    mutating func redoEdit() { guard let value = redo.popLast() else { return }; undo.append(shapes); shapes = value }
    static func imageRect(_ size: CGSize, width: Int, height: Int) -> CGRect {
        let scale = min(size.width / CGFloat(max(1, width)), size.height / CGFloat(max(1, height)))
        let w = CGFloat(width) * scale, h = CGFloat(height) * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

/// The viewport only changes presentation. Shapes always use source pixels.
struct NotebookImageAnnotationViewport: Equatable {
    var zoom = 1.0
    var center = CGPoint(x: 0.5, y: 0.5)
    private func fit(_ size: CGSize, width: Int, height: Int) -> Double {
        max(0.000001, min(size.width / Double(max(1, width)), size.height / Double(max(1, height))))
    }
    func imageRect(_ size: CGSize, width: Int, height: Int) -> CGRect {
        let scale = fit(size, width: width, height: height) * zoom
        let w = Double(width) * scale, h = Double(height) * scale
        func origin(_ length: Double, _ visible: Double, _ center: Double) -> Double {
            length <= visible ? (visible - length) / 2 : min(0, max(visible - length, visible / 2 - center * length))
        }
        return CGRect(x: origin(w, size.width, center.x), y: origin(h, size.height, center.y), width: w, height: h)
    }
    func zoomed(to value: Double, size: CGSize, width: Int, height: Int) -> Self {
        let oneToOne = 1 / fit(size, width: width, height: height)
        var next = self
        // Keep 100% reachable for both tiny and large images, and allow each
        // source pixel to occupy at least 32 screen points at maximum zoom.
        next.zoom = max(min(1, oneToOne), min(max(128, oneToOne * 32), value))
        let rect = imageRect(size, width: width, height: height)
        next.center = CGPoint(x: (size.width / 2 - rect.minX) / rect.width, y: (size.height / 2 - rect.minY) / rect.height)
        return next
    }
    func actualSize(_ size: CGSize, width: Int, height: Int) -> Self {
        zoomed(to: 1 / fit(size, width: width, height: height), size: size, width: width, height: height)
    }
    func panned(_ translation: CGSize, size: CGSize, width: Int, height: Int) -> Self {
        let rect = imageRect(size, width: width, height: height)
        var next = self
        let x = rect.minX + translation.width, y = rect.minY + translation.height
        next.center = CGPoint(x: (size.width / 2 - x) / rect.width, y: (size.height / 2 - y) / rect.height)
        // Resolve the clamped center so reversing a drag responds immediately.
        let clamped = next.imageRect(size, width: width, height: height)
        next.center = CGPoint(x: (size.width / 2 - clamped.minX) / clamped.width, y: (size.height / 2 - clamped.minY) / clamped.height)
        return next
    }
    func focusing(_ shape: NotebookImageAnnotations.Shape, size: CGSize, width: Int, height: Int) -> Self {
        let w = max(1, shape.width ?? 16), h = max(1, shape.height ?? 16)
        var next = zoomed(to: 0.85 * min(size.width / w, size.height / h) / fit(size, width: width, height: height), size: size, width: width, height: height)
        next.center = CGPoint(x: (shape.x + (shape.width ?? 0) / 2) / Double(width), y: (shape.y + (shape.height ?? 0) / 2) / Double(height))
        return next
    }
    static func sourcePoint(_ point: CGPoint, rect: CGRect, width: Int, height: Int) -> CGPoint {
        CGPoint(x: max(0, min(Double(width), (point.x - rect.minX) / rect.width * Double(width))), y: max(0, min(Double(height), (point.y - rect.minY) / rect.height * Double(height))))
    }
}

struct NotebookImageAnnotationBinding {
    let channel: String
    let accepted: NotebookImageAnnotations?
    let disabled: Bool
    let apply: (NotebookImageAnnotations, @escaping (Bool) -> Void) -> Void
    var classes: [NotebookAnnotationClass]? = nil
}

struct NotebookAcceptedData: Codable { let kind: String, id: String, json: String }
struct NotebookSharedSelection: Codable {
    var version = 1
    let source: String
    let key: NotebookTableValue
    let row: [String: NotebookTableValue]
}
struct NotebookTableSelectionBinding {
    let keyColumn: String
    let accepted: NotebookSharedSelection?
    let disabled: Bool
    let apply: (NotebookSharedSelection?) -> Void
}

private struct NotebookComponentDataEdit: Encodable { let board: String, component: String, kind: String, json: String }

extension NotebookModel {
    func acceptedComponentData<T: Decodable>(_ type: T.Type, kind: String, channel: String) -> T? {
        guard let json = snapshot?.accepted_data?.first(where: { $0.kind == kind && $0.id == channel })?.json else { return nil }
        return try? JSONDecoder().decode(type, from: Data(json.utf8))
    }
    func editComponentData<T: Encodable>(_ value: T?, kind: String, board: NotebookBoard, component: NotebookBoardComponent, completion: @escaping (Bool) -> Void = { _ in }) {
        do {
            let raw = try value.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? "null"
            let edit = NotebookComponentDataEdit(board: board.id, component: component.id, kind: kind, json: raw)
            perform("component_data_edit", text: String(decoding: try JSONEncoder().encode(edit), as: UTF8.self), completion: completion)
        } catch { self.error = error.localizedDescription; completion(false) }
    }
    func tableSelection(board: NotebookBoard?, component: NotebookBoardComponent?) -> NotebookTableSelectionBinding? {
        guard let board, let component, let channel = component.selection_id, !channel.isEmpty else { return nil }
        return .init(keyColumn: component.selection_key ?? "", accepted: acceptedComponentData(NotebookSharedSelection.self, kind: "selection", channel: channel), disabled: busy || remote.isSelected,
            apply: { self.editComponentData($0, kind: "selection", board: board, component: component) })
    }
    func annotationBinding(board: NotebookBoard, component: NotebookBoardComponent) -> NotebookImageAnnotationBinding? {
        guard component.image_annotator == true else { return nil }
        let channel = component.annotation_id ?? component.id + "_labels"
        return .init(channel: component.image_id ?? component.id, accepted: acceptedComponentData(NotebookImageAnnotations.self, kind: "annotations", channel: channel) ?? component.annotations, disabled: busy || remote.isSelected,
            apply: { self.editComponentData($0, kind: "annotations", board: board, component: component, completion: $1) }, classes: component.annotationClasses)
    }
    func selectedImageSeries(_ series: NotebookImageSeries, component: NotebookBoardComponent) -> NotebookImageSeries {
        guard let asset = selectedAsset(component) else { return series }
        return NotebookImageSeries(id: series.id, caption: series.caption, images: series.images.filter { notebookAssetID($0.data) == asset })
    }
    func selectedAsset(_ component: NotebookBoardComponent?) -> String? {
        guard let component, let channel = component.selection_id, !channel.isEmpty,
              let selection = acceptedComponentData(NotebookSharedSelection.self, kind: "selection", channel: channel) else { return nil }
        return selection.row[component.selection_asset ?? "asset_id"]?.text
    }
}

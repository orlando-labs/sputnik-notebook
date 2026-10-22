import Foundation

/// One catalog for authored components and sheet output adapters. Persisted
/// kind strings remain stable, including the original text/value component.
enum NotebookComponentCategory: String, CaseIterable, Identifiable {
    case layout = "Layout", controls = "Controls", display = "Display", annotations = "Annotations", services = "Services"
    var id: String { rawValue }
}

struct NotebookComponentTool: Identifiable {
    let id: String, title: String, symbol: String, detail: String
    // Image Annotator is a palette preset for the existing image contract.
    var componentKind: String { id == "image_annotator" ? "image" : id == "config_editor" ? "input" : id }
    var category: NotebookComponentCategory {
        switch id {
        case "tabs", "group", "split": return .layout
        case "input", "config_editor", "run", "parameter_form", "parameter_presets", "file_input", "audio_input", "range_input", "date_input", "action", "execution_controls": return .controls
        case "periodic_work": return .services
        case "image_annotator", "audio_annotator": return .annotations
        default: return .display
        }
    }
    static let all = [
        Self(id: "tabs", title: "Tabs", symbol: "rectangle.topthird.inset.filled", detail: "Panel grids"),
        Self(id: "split", title: "Split View", symbol: "rectangle.split.2x1", detail: "Resizable panel grids"),
        Self(id: "group", title: "Group / Accordion", symbol: "rectangle.compress.vertical", detail: "Collapsible panel grid"),
        Self(id: "input", title: "Input", symbol: "slider.horizontal.3", detail: "Project parameter"),
        Self(id: "config_editor", title: "Config Editor", symbol: "curlybraces", detail: "JSON / YAML / TOML · Import / Export"),
        Self(id: "parameter_form", title: "Parameter Form", symbol: "list.bullet.clipboard", detail: "Apply parameters together"),
        Self(id: "parameter_presets", title: "Parameter Presets", symbol: "slider.horizontal.below.square.and.square.filled", detail: "Named parameter sets"),
        Self(id: "range_input", title: "Range Input", symbol: "arrow.left.and.right", detail: "Range · Inclusive / Exclusive · Step"),
        Self(id: "date_input", title: "Date / Time Input", symbol: "calendar.badge.clock", detail: "Date · Time zone · ISO 8601"),
        Self(id: "audio_input", title: "Audio Input / Recorder", symbol: "mic.badge.plus", detail: "Import · Record · Apply"),
        Self(id: "file_input", title: "File / Dataset Input", symbol: "doc.badge.plus", detail: "File path · CSV / JSON preview"),
        Self(id: "action", title: "Action Button", symbol: "bolt.rectangle", detail: "Call an exported function"),
        Self(id: "execution_controls", title: "Execution Controls", symbol: "playpause", detail: "Run · Stop · Restart"),
        Self(id: "rich_text", title: "Text Cell", symbol: "textformat", detail: "Rich text · {{name}}"),
        Self(id: "text", title: "Text / Value", symbol: "text.alignleft", detail: "Published value"),
        Self(id: "metric", title: "Metric / KPI", symbol: "number", detail: "Value · target · delta"),
        Self(id: "status", title: "Status / Alert", symbol: "info.bubble", detail: "State · reason · source"),
        Self(id: "log", title: "Log Viewer", symbol: "text.alignleft", detail: "Output · errors · search"),
        Self(id: "artifacts", title: "Artifact Browser", symbol: "tray.full", detail: "Result files · preview · export"),
        Self(id: "result", title: "Result Inspector", symbol: "list.bullet.rectangle", detail: "Inspect · Pretty · Find"),
        Self(id: "table", title: "Data Table", symbol: "tablecells", detail: "Sort · Filter · Export"),
        Self(id: "task_monitor", title: "Task Monitor", symbol: "point.3.connected.trianglepath.dotted", detail: "Children · State · Errors"),
        Self(id: "run_history", title: "Run History", symbol: "clock.arrow.circlepath", detail: "Snapshots · Pin · Restore"),
        Self(id: "experiment_compare", title: "Experiment Compare", symbol: "tablecells.badge.ellipsis", detail: "Parameters · Metrics · Delta"),
        Self(id: "image_annotator", title: "Image Annotator", symbol: "photo.badge.checkmark", detail: "Points · Rectangles · Classes"),
        Self(id: "audio_annotator", title: "Audio Annotator", symbol: "waveform.and.magnifyingglass", detail: "Segments · Classes · Transcript · Spectrum"),
        Self(id: "audio", title: "Audio Player", symbol: "speaker.wave.2", detail: "Play · Waveform · Export"),
        Self(id: "progress", title: "Progress", symbol: "chart.bar.fill", detail: "Cell progress channel"),
        Self(id: "stopwatch", title: "Stopwatch", symbol: "stopwatch", detail: "Measure a code block"),
        Self(id: "plot", title: "Figure", symbol: "photo", detail: "Sheet display"),
        Self(id: "live_chart", title: "Live Chart", symbol: "chart.xyaxis.line", detail: "Point channel"),
        Self(id: "image", title: "Image", symbol: "photo", detail: "Image channel"),
        Self(id: "image_carousel", title: "Image Carousel", symbol: "photo.on.rectangle.angled", detail: "Image series"),
        Self(id: "run", title: "Run Button", symbol: "play.rectangle", detail: "Run a cell"),
        Self(id: "periodic_work", title: "Periodic Work", symbol: "timer", detail: "Call a module function")
    ]
    static func tool(_ kind: String) -> Self { all.first { $0.id == kind } ?? all[1] }
    static func tool(for component: NotebookBoardComponent) -> Self {
        if component.kind == "input", component.control?.style == "json" { return tool("config_editor") }
        if ["image", "image_carousel"].contains(component.kind), component.image_annotator == true {
            return tool("image_annotator")
        }
        return tool(component.kind)
    }
}

/// The same inert source/formatting shape as a sheet text cell. Formatting is
/// JSON in the document, and a JSON string only inside the native editor API.
struct NotebookTextContent: Codable {
    var source: String = ""
    var formatting: String = ""
    private enum CodingKeys: String, CodingKey { case source, formatting }
    init(source: String = "", formatting: String = "") {
        self.source = source; self.formatting = formatting
    }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        source = try fields.decode(String.self, forKey: .source)
        if let value = try fields.decodeIfPresent(NotebookFormattingJSON.self, forKey: .formatting) {
            formatting = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }
    }
    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(source, forKey: .source)
        if !formatting.isEmpty {
            let value = try JSONDecoder().decode(NotebookFormattingJSON.self, from: Data(formatting.utf8))
            try fields.encode(value, forKey: .formatting)
        }
    }
}

private indirect enum NotebookFormattingJSON: Codable {
    case object([String: Self]), array([Self]), string(String), integer(Int64), number(Double), boolean(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .boolean(v) }
        else if let v = try? value.decode(Int64.self) { self = .integer(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([Self].self) { self = .array(v) }
        else { self = .object(try value.decode([String: Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .integer(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .boolean(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
}

/// Portable JSON keeps Int64 endpoints exact; the editor uses Sputnik syntax.
struct NotebookRangeValue: Equatable {
    var start = "0", finish = "15", step = "3"
    var inclusive = false
    var expression: String { "(\(start)\(inclusive ? ".." : "...")\(finish):\(step))" }
    var json: String { "{\"start\":\(start),\"finish\":\(finish),\"inclusive_end\":\(inclusive),\"step\":\(step)}" }
    private struct Invalid: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    static func decode(_ json: String) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              Set(object.keys) == Set(["start", "finish", "step", "inclusive_end"]) else { throw Invalid("Range requires start, finish, inclusive_end and step.") }
        struct Flag: Decodable { let inclusive_end: Bool }
        let inclusive = try JSONDecoder().decode(Flag.self, from: Data(json.utf8)).inclusive_end
        // Read numeric tokens directly: decoding through Double loses Int64
        // precision, while Int64 decoding also accepts 0.0 and loses Float type.
        func token(_ key: String) throws -> String {
            let regex = try NSRegularExpression(pattern: "\"" + key + "\"" + #"\s*:\s*(-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)(?=\s*[,}])"#)
            guard let match = regex.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
                  let range = Range(match.range(at: 1), in: json) else { throw Invalid("Range bounds and step must be numbers.") }
            return String(json[range])
        }
        return try parse("(\(token("start"))\(inclusive ? ".." : "...")\(token("finish")):\(token("step")))")
    }
    static func parse(_ text: String) throws -> Self {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") { return try decode(text) }
        if text.hasPrefix("(") || text.hasSuffix(")") {
            guard text.hasPrefix("("), text.hasSuffix(")") else { throw Invalid("Close the range parentheses.") }
            text = String(text.dropFirst().dropLast())
        }
        let pattern = #"^\s*([+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?)\s*(\.\.\.?)\s*([+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?)\s*(?::\s*([+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?))?\s*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { throw Invalid("Enter a range such as (0...15:3).") }
        func part(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
        func number(_ value: String) throws -> String {
            if let integer = Int64(value) { return String(integer) }
            guard value.contains(".") || value.lowercased().contains("e"), let real = Double(value), real.isFinite else { throw Invalid("Use finite numbers or integers in the Int64 range.") }
            return String(real)
        }
        let result = try Self(start: number(part(1)!), finish: number(part(3)!), step: number(part(4) ?? "1"), inclusive: part(2) == "..")
        try result.validate(); return result
    }
    func validate() throws {
        guard let a = Double(start), let b = Double(finish), let s = Double(step), a.isFinite, b.isFinite, s.isFinite else { throw Invalid("Enter finite range values.") }
        guard s != 0 else { throw Invalid("Range step must not be zero.") }
        if Int64(start) != nil && Int64(finish) != nil && Int64(step) == nil { throw Invalid("An integer range requires an integer step.") }
    }
}

struct NotebookProjectInput: Decodable, Identifiable {
    static let types = ["number", "integer", "boolean", "string", "range"]
    static func typeTitle(_ type: String) -> String {
        switch type {
        case "number": return "Number (decimal)"
        case "integer": return "Integer (Int64)"
        case "boolean": return "Boolean"
        case "string": return "String (text)"
        case "range": return "Range"
        default: return type.capitalized
        }
    }
    let id: String, title: String, type: String, value_json: String
    let minimum: Double?, maximum: Double?
    var default_json: String? = nil

    static func initialText(for type: String) -> String {
        type == "range" ? "(0...15:3)" : type == "boolean" ? "false" : type == "string" ? "" : "0"
    }

    var editingText: String {
        if type == "range", let range = try? NotebookRangeValue.decode(value_json) { return range.expression }
        if type == "string", let value = try? JSONDecoder().decode(String.self, from: Data(value_json.utf8)) {
            return value
        }
        return value_json
    }
    static func valueJSON(_ text: String, type: String) throws -> String {
        if type == "string" { return String(decoding: try JSONEncoder().encode(text), as: UTF8.self) }
        if type == "range" { return try NotebookRangeValue.parse(text).json }
        // Preserve the spelling of integers. The backend validates types,
        // range and finite numeric values before publishing anything.
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct NotebookInputOption: Codable, Identifiable {
    var label: String
    var value_json: String
    var id: String { value_json }
}

enum NotebookConfigFormat: String, CaseIterable, Identifiable {
    case json, yaml, toml
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var initialText: String { self == .toml ? "" : "{}" }
    var extensions: [String] { self == .yaml ? ["yaml", "yml"] : [rawValue] }
}

struct NotebookInputControl: Codable {
    var style: String = "automatic"
    var config_format: String? = nil
    var configFormat: NotebookConfigFormat { NotebookConfigFormat(rawValue: config_format ?? "json") ?? .json }
    var minimum: Double? = nil, maximum: Double? = nil, step: Double? = nil
    var unit: String? = nil, precision: Int? = nil
    var options: [NotebookInputOption]? = nil
    var start_minimum: Double? = nil, start_maximum: Double? = nil
    var finish_minimum: Double? = nil, finish_maximum: Double? = nil
}

extension NotebookInputControl {
    private enum Keys: String, CodingKey { case style, config_format, minimum, maximum, step, unit, precision, options, start_minimum, start_maximum, finish_minimum, finish_maximum }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        style = try values.decodeIfPresent(String.self, forKey: .style) ?? "automatic"
        config_format = try values.decodeIfPresent(String.self, forKey: .config_format)
        minimum = try values.decodeIfPresent(Double.self, forKey: .minimum)
        maximum = try values.decodeIfPresent(Double.self, forKey: .maximum)
        step = try values.decodeIfPresent(Double.self, forKey: .step)
        unit = try values.decodeIfPresent(String.self, forKey: .unit)
        precision = try values.decodeIfPresent(Int.self, forKey: .precision)
        options = try values.decodeIfPresent([NotebookInputOption].self, forKey: .options)
        start_minimum = try values.decodeIfPresent(Double.self, forKey: .start_minimum)
        start_maximum = try values.decodeIfPresent(Double.self, forKey: .start_maximum)
        finish_minimum = try values.decodeIfPresent(Double.self, forKey: .finish_minimum)
        finish_maximum = try values.decodeIfPresent(Double.self, forKey: .finish_maximum)
    }
}

struct NotebookFormField: Codable, Identifiable {
    var input: String
    var control: NotebookInputControl
    var id: String { input }
}

/// Slider domains describe the control; Range.step still belongs to the value.
struct NotebookRangeSliderRules {
    let startDomain: ClosedRange<Double>, finishDomain: ClosedRange<Double>
    let increment: Double
    let integer: Bool
    static func applies(_ control: NotebookInputControl) -> Bool { ["slider", "range_sliders"].contains(control.style) }
    private struct Invalid: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    init(control: NotebookInputControl, value: NotebookRangeValue) throws {
        let integer = Int64(value.start) != nil && Int64(value.finish) != nil
        self.integer = integer
        func domain(_ minimum: Double?, _ maximum: Double?) throws -> ClosedRange<Double> {
            guard let minimum, let maximum, minimum.isFinite, maximum.isFinite, minimum < maximum,
                  abs(minimum) < 1e100, abs(maximum) < 1e100 else { throw Invalid("Set finite, increasing slider bounds.") }
            if integer && (minimum.rounded() != minimum || maximum.rounded() != maximum || abs(minimum) > 9007199254740991 || abs(maximum) > 9007199254740991) {
                throw Invalid("Integer slider bounds must be whole numbers within ±(2^53−1).")
            }
            return minimum...maximum
        }
        if control.style == "range_sliders" {
            startDomain = try domain(control.start_minimum, control.start_maximum)
            finishDomain = try domain(control.finish_minimum, control.finish_maximum)
        } else {
            startDomain = try domain(control.minimum, control.maximum)
            finishDomain = startDomain
        }
        guard startDomain.lowerBound <= finishDomain.upperBound else { throw Invalid("The slider domains must allow finish ≥ start.") }
        increment = control.step ?? (integer ? 1 : min(startDomain.upperBound - startDomain.lowerBound, finishDomain.upperBound - finishDomain.lowerBound) / 100)
        guard increment.isFinite, increment > 0, increment < 1e100,
              !integer || (increment.rounded() == increment && increment <= 9007199254740991) else { throw Invalid("Set a positive slider increment; use a whole number for integer ranges.") }
    }
    func error(_ value: NotebookRangeValue) -> String? {
        if !integer {
            guard let a = Double(value.start), let b = Double(value.finish), a.isFinite, b.isFinite else { return "Enter finite range bounds." }
            if a > b { return "Finish must be greater than or equal to start." }
            if !startDomain.contains(a) { return "Start is outside its allowed slider range." }
            if !finishDomain.contains(b) { return "Finish is outside its allowed slider range." }
            return nil
        }
        guard let a = Decimal(string: value.start), let b = Decimal(string: value.finish) else { return "Enter finite range bounds." }
        if a > b { return "Finish must be greater than or equal to start." }
        func contains(_ n: Decimal, _ domain: ClosedRange<Double>) -> Bool {
            guard let low = Decimal(string: String(domain.lowerBound)), let high = Decimal(string: String(domain.upperBound)) else { return false }
            return n >= low && n <= high
        }
        if !contains(a, startDomain) { return "Start is outside its allowed slider range." }
        if !contains(b, finishDomain) { return "Finish is outside its allowed slider range." }
        return nil
    }
    func moving(_ value: NotebookRangeValue, start: Bool, to proposed: Double) -> NotebookRangeValue {
        guard proposed.isFinite else { return value }
        var next = value
        let domain = start ? startDomain : finishDomain
        let other = Double(start ? value.finish : value.start) ?? (start ? domain.upperBound : domain.lowerBound)
        let snapped = domain.lowerBound + ((proposed - domain.lowerBound) / increment).rounded() * increment
        let low = start ? domain.lowerBound : max(domain.lowerBound, other)
        let high = start ? min(domain.upperBound, other) : domain.upperBound
        guard low <= high else { return value }
        let number = min(high, max(low, snapped))
        let text = integer ? String(Int64(number.rounded())) : String(number)
        if start { next.start = text } else { next.finish = text }
        return next
    }
}

extension NotebookFormField {
    private enum Keys: String, CodingKey { case input, control }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        input = try values.decode(String.self, forKey: .input)
        control = try values.decodeIfPresent(NotebookInputControl.self, forKey: .control) ?? NotebookInputControl()
    }
}

struct NotebookBoardComponent: Codable, Identifiable {
    var id: String, kind: String, title: String
    var input: String?, cell: String?, binding: String?
    var chart_id: String? = nil
    var table_id: String? = nil
    var audio_id: String? = nil
    var show_waveform: Bool? = nil
    var audio_source: String? = nil, audio_view: String? = nil
    var audio_fft_size: Int? = nil
    var audio_annotations: NotebookAudioAnnotations? = nil
    var split_fraction: Double? = nil, split_min: Double? = nil
    var split_axis: String? = nil
    var date_mode: String? = nil, date_time_zone: String? = nil
    var audio_recording: Bool? = nil
    var audio_asset: String? = nil
    var audio_name: String? = nil
    var image_id: String? = nil, image_mode: String? = nil, caption: String? = nil
    var image_allow_save: Bool? = nil, image_allow_load: Bool? = nil, image_allow_read: Bool? = nil
    var image_annotator: Bool? = nil
    var annotation_id: String? = nil
    var annotation_classes: [NotebookAnnotationClass]? = nil
    var audio_transcript_allowed: Bool? = nil, audio_transcript_required: Bool? = nil
    var audio_segment_transcript_allowed: Bool? = nil, audio_segment_transcript_required: Bool? = nil
    var annotations: NotebookImageAnnotations? = nil
    var selection_id: String? = nil, selection_key: String? = nil, selection_asset: String? = nil
    var selection: NotebookSharedSelection? = nil
    var image_items: [NotebookImageAsset]? = nil
    var image_series_caption: String? = nil
    var x_label: String? = nil, y_label: String? = nil, stroke: String? = nil
    var y_min: Double? = nil, y_max: Double? = nil
    var x_min: Double? = nil, x_max: Double? = nil
    var row: String? = nil
    var span: Int? = nil
    var h_align: String? = nil, v_align: String? = nil
    var panels: [NotebookBoardPanel]? = nil
    var module_id: String? = nil, function: String? = nil
    var period_seconds: Double? = nil, timing: String? = nil, retention: String? = nil
    var tail_limit: Int? = nil
    var store_values: Bool? = nil, store_errors: Bool? = nil, run_immediately: Bool? = nil
    var stop_on_error: Bool? = nil, pause_when_hidden: Bool? = nil
    var text_content: NotebookTextContent? = nil
    var text_mode: String? = nil
    var progress_id: String? = nil
    var stopwatch_id: String? = nil
    var control: NotebookInputControl? = nil
    var fields: [NotebookFormField]? = nil
    var p1: NotebookP1Settings? = nil

    var columnSpan: Int { max(1, min(12, span ?? 12)) }
    var isService: Bool { kind == "periodic_work" }
    var periodicSettings: NotebookPeriodicSettings {
        NotebookPeriodicSettings(module: module_id ?? "", function: function ?? "",
            period: period_seconds ?? 60, timing: timing ?? "fixed_delay", retention: retention ?? "tail",
            tailLimit: tail_limit ?? 100, storeValues: store_values ?? true, storeErrors: store_errors ?? true,
            runImmediately: run_immediately ?? true, stopOnError: stop_on_error ?? false,
            pauseWhenHidden: pause_when_hidden ?? true)
    }
}

struct NotebookImageAsset: Codable { let path: String, caption: String }

struct NotebookBoardRow: Codable, Identifiable {
    var id: String
    var height: Double? = nil
}

struct NotebookBoardPanel: Codable, Identifiable {
    var id: String, title: String
    var rows: [NotebookBoardRow]
    var components: [NotebookBoardComponent]

    static func empty(title: String) -> Self {
        Self(id: NotebookBoard.newID("panel"), title: title,
             rows: [NotebookBoardRow(id: NotebookBoard.newID("row"))], components: [])
    }
}

struct NotebookBoardGridPath: Equatable {
    var component: String, panel: String
}

struct NotebookBoard: Codable, Identifiable {
    var id: String, title: String, sheet: String
    var columns: Int
    var components: [NotebookBoardComponent]
    var rows: [NotebookBoardRow]? = nil

    static func newID(_ prefix: String) -> String {
        prefix + "_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    var allComponents: [NotebookBoardComponent] {
        components.flatMap { [$0] + ($0.panels ?? []).flatMap { $0.componentsInTree } }
    }

    func inputBindingError(inputs: [NotebookProjectInput]) -> String? {
        func hasInput(_ id: String?, types: [String] = NotebookProjectInput.types) -> Bool {
            inputs.contains { $0.id == id && types.contains($0.type) }
        }
        for component in allComponents {
            switch component.kind {
            case "input":
                if !hasInput(component.input, types: component.control?.style == "json" ? ["string"] : NotebookProjectInput.types) {
                    return "Choose or create a \(component.control?.style == "json" ? "String " : "")parameter for \(component.title)."
                }
            case "file_input", "date_input":
                if !hasInput(component.input, types: ["string"]) { return "Choose or create a String parameter for \(component.title)." }
            case "range_input":
                if !hasInput(component.input, types: ["range"]) {
                    return "Choose or create a Range parameter for \(component.title)."
                }
            case "parameter_form":
                if (component.fields ?? []).contains(where: { !hasInput($0.input) }) {
                    return "Choose an available parameter for each field in \(component.title)."
                }
            default: break
            }
        }
        return nil
    }
    var allRows: [NotebookBoardRow] {
        (rows ?? []) + components.flatMap { ($0.panels ?? []).flatMap { $0.rowsInTree } }
    }
    var panelCount: Int { allComponents.reduce(0) { $0 + ($1.panels?.count ?? 0) } }

    // A panel exposes the same grid operations as the outer board. Writes are
    // applied to its original location so sibling panels stay independent.
    func grid(at path: [NotebookBoardGridPath]) -> NotebookBoard? {
        guard let step = path.first else { return self }
        guard let panel = components.first(where: { $0.id == step.component })?.panels?.first(where: { $0.id == step.panel }) else { return nil }
        let grid = NotebookBoard(id: id, title: panel.title, sheet: sheet, columns: columns,
                                 components: panel.components, rows: panel.rows)
        return grid.grid(at: Array(path.dropFirst()))
    }
    @discardableResult mutating func updateGrid(_ grid: NotebookBoard, at path: [NotebookBoardGridPath]) -> Bool {
        guard let step = path.first else {
            rows = grid.rows; components = grid.components
            return true
        }
        guard let component = components.firstIndex(where: { $0.id == step.component }),
              let panel = components[component].panels?.firstIndex(where: { $0.id == step.panel }),
              var child = self.grid(at: [step]),
              child.updateGrid(grid, at: Array(path.dropFirst())) else { return false }
        components[component].panels?[panel].rows = child.rows ?? []
        components[component].panels?[panel].components = child.components
        return true
    }

    // Legacy boards keep their saved reading order. Conversion is only saved
    // when the user commits a designer draft, never merely on opening.
    var rowLayout: NotebookBoard {
        guard rows == nil else { return self }
        var result = self
        let count = max(1, min(6, columns))
        let visualIndices = result.components.indices.filter { !result.components[$0].isService }
        result.rows = (0..<max(1, (visualIndices.count + count - 1) / count)).map {
            NotebookBoardRow(id: "row_\($0 + 1)")
        }
        for (position, index) in visualIndices.enumerated() {
            let column = position % count
            result.components[index].row = result.rows?[position / count].id
            result.components[index].span = (column + 1) * 12 / count - column * 12 / count
        }
        return result
    }

    func components(in row: String) -> [NotebookBoardComponent] { components.filter { !$0.isService && $0.row == row } }
    var services: [NotebookBoardComponent] { components.filter(\.isService) }
    func availableColumns(in row: String, excluding id: String? = nil) -> Int {
        12 - components(in: row).filter { $0.id != id }.reduce(0) { $0 + $1.columnSpan }
    }
    mutating func appendRow() -> String {
        let id = Self.newID("row")
        if rows == nil { self = rowLayout }
        rows?.append(NotebookBoardRow(id: id))
        return id
    }
    mutating func removeRow(_ id: String) {
        rows?.removeAll { $0.id == id }
        components.removeAll { $0.row == id }
    }
    func canMoveComponent(_ id: String, to row: String) -> Bool {
        guard rows?.contains(where: { $0.id == row }) == true,
              let component = components.first(where: { $0.id == id }), !component.isService else { return false }
        return availableColumns(in: row, excluding: id) >= component.columnSpan
    }
    @discardableResult mutating func moveComponent(_ id: String, to row: String) -> Bool {
        guard canMoveComponent(id, to: row),
              let index = components.firstIndex(where: { $0.id == id }) else { return false }
        guard components[index].row != row else { return true }
        var component = components.remove(at: index)
        component.row = row
        // A cross-row move appends after the target row's existing cells.
        components.append(component)
        return true
    }

    static func empty(sheet: String, existing: [NotebookBoard] = []) -> NotebookBoard {
        let number = NotebookDefaultName.nextNumber(prefix: "Board", titles: existing.map(\.title))
        return NotebookBoard(id: "board_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "_"), title: "Board \(number)",
                      sheet: sheet, columns: 2, components: [])
    }
}

enum NotebookDefaultName {
    static func nextNumber(prefix: String, titles: [String]) -> Int {
        let start = prefix + " "
        let numbers = titles.compactMap { title -> Int? in
            guard title.hasPrefix(start) else { return nil }
            let suffix = title.dropFirst(start.count)
            guard !suffix.isEmpty, suffix.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let number = Int(suffix), number < Int.max else { return nil }
            return number
        }
        return max(titles.count, numbers.max() ?? 0) + 1
    }
}

private extension NotebookBoardPanel {
    var componentsInTree: [NotebookBoardComponent] {
        components.flatMap { [$0] + ($0.panels ?? []).flatMap { $0.componentsInTree } }
    }
    var rowsInTree: [NotebookBoardRow] {
        rows + components.flatMap { ($0.panels ?? []).flatMap { $0.rowsInTree } }
    }
}

// Cell components use the common component vocabulary without board geometry.
struct NotebookCellInputDefinition: Codable, Identifiable {
    var id: String
    var title: String
    var type = "number"
    var default_json = "0"
    var minimum: Double? = nil
    var maximum: Double? = nil
    var preview: NotebookProjectInput {
        NotebookProjectInput(id: id, title: title, type: type, value_json: default_json,
                             minimum: minimum, maximum: maximum, default_json: default_json)
    }
}
struct NotebookCellUI: Codable {
    var inputs: [NotebookCellInputDefinition] = []
    var pre: [NotebookBoardComponent] = []
    var post: [NotebookBoardComponent] = []
    static let supportedKinds = ["input", "parameter_form", "live_chart", "metric", "image", "table", "audio"]
    static let paletteKinds = ["input", "config_editor", "parameter_form", "live_chart", "metric", "image", "table", "audio"]
}

extension NotebookBoardComponent {
    // Legacy accepted audio schemas remain available until the designer saves
    // an explicit list. Runtime editors never create or change definitions.
    var annotationClasses: [NotebookAnnotationClass] { annotation_classes ?? audio_annotations?.classes ?? annotations?.classes ?? [] }
    var transcriptPolicy: NotebookAudioTranscriptPolicy {
        .init(trackAllowed: audio_transcript_allowed ?? true, trackRequired: audio_transcript_required ?? false,
              segmentAllowed: audio_segment_transcript_allowed ?? true, segmentRequired: audio_segment_transcript_required ?? false)
    }
}

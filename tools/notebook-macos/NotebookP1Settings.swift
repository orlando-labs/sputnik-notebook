import Foundation

struct NotebookParameterPreset: Codable, Identifiable {
    var id: String, title: String
    /// Exact scalar JSON, including Int64. Current session values never become defaults.
    var values: [String: String]
}
struct NotebookActionArgument: Codable, Identifiable {
    var id: String
    var name: String? = nil
    var input: String? = nil
    var value_json: String? = nil
}
struct NotebookChartSeries: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var stroke: String
}
/// Versioned, optional authored settings; no runtime data is saved here.
struct NotebookP1Settings: Codable {
    var unit: String? = nil
    var precision: Int? = nil
    var percentage: Bool? = nil
    var target: Double? = nil
    var baseline: Double? = nil
    var improvement: String? = nil
    var target_kind: String? = nil // cell, sheet, service, action
    var target_component: String? = nil
    var collapsed: Bool? = nil
    var extensions: String? = nil
    var arguments: [NotebookActionArgument]? = nil
    var preset_inputs: [String]? = nil
    var presets: [NotebookParameterPreset]? = nil
    var series: [NotebookChartSeries]? = nil
}

extension NotebookBoardComponent {
    var settings: NotebookP1Settings { p1 ?? NotebookP1Settings() }
    var ownsGrid: Bool { kind == "tabs" || kind == "group" || kind == "split" }
}

extension NotebookBoard {
    @discardableResult mutating func replaceComponent(_ value: NotebookBoardComponent) -> Bool {
        if let i = components.firstIndex(where: { $0.id == value.id }) { components[i] = value; return true }
        for i in components.indices {
            for j in components[i].panels?.indices ?? 0..<0 {
                var panel = components[i].panels![j]
                var grid = NotebookBoard(id: id, title: panel.title, sheet: sheet, columns: columns, components: panel.components, rows: panel.rows)
                if grid.replaceComponent(value) {
                    panel.components = grid.components; components[i].panels?[j] = panel; return true
                }
            }
        }
        return false
    }
}


extension NotebookBoardComponent {
    func actionSignature(inputs: [NotebookProjectInput], moduleSource: String) -> Data {
        let values = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0.value_json) })
        let arguments: [[String: String]] = (settings.arguments ?? []).map {
            ["name": $0.name ?? "", "input": $0.input ?? "", "value": $0.input.flatMap { values[$0] } ?? $0.value_json ?? ""]
        }
        let object: [String: Any] = ["module": module_id ?? "", "function": function ?? "", "source": moduleSource, "arguments": arguments]
        return (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? Data()
    }
}

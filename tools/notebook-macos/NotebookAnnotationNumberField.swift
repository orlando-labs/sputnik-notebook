import SwiftUI

/// Coordinate inputs accept either decimal separator and parse the complete
/// value. NumberFormatter can otherwise accept only a prefix in another locale.
struct NotebookAnnotationNumberField: View {
    let title: String
    @Binding var value: Double
    var integersOnly = false
    var validity: (Bool) -> Void = { _ in }
    @Environment(\.locale) private var locale
    @FocusState private var focused: Bool
    @State private var text = ""
    @State private var invalid = false

    private static let decimal = try! NSRegularExpression(pattern: #"^[+-]?(?:[0-9]+(?:[.,][0-9]*)?|[.,][0-9]+)(?:[eE][+-]?[0-9]+)?$"#)
    private static let integer = try! NSRegularExpression(pattern: #"^[+-]?[0-9]+$"#)
    static func parse(_ text: String, integersOnly: Bool = false) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 128,
              (integersOnly ? integer : decimal).firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil,
              let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")), value.isFinite,
              !integersOnly || value.rounded() == value else { return nil }
        return value
    }
    var body: some View {
        TextField(title, text: Binding(get: { text }, set: { candidate in
            text = candidate
            if let number = Self.parse(candidate, integersOnly: integersOnly) { invalid = false; validity(true); value = number }
            else { invalid = true; validity(false) }
        }))
        .focused($focused)
        .overlay { if invalid { RoundedRectangle(cornerRadius: 5).stroke(NotebookPalette.error, lineWidth: 1) } }
        .help(invalid ? (integersOnly ? "Enter a whole pixel coordinate." : "Enter a finite number; use a decimal point or comma.") : title)
        .onAppear { refresh() }
        .onChange(of: value) { _, _ in if !focused { refresh() } }
        .onChange(of: focused) { _, active in if !active && !invalid { refresh() } }
        .onSubmit { if !invalid { refresh() } }
        .onDisappear { validity(true) }
    }
    private func refresh() {
        text = value.formatted(.number.grouping(.never).precision(.fractionLength(0...(integersOnly ? 0 : 9))).locale(locale))
        invalid = false; validity(true)
    }
}

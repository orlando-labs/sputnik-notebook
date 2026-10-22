import SwiftUI

/// Page identity belongs in the header, without an instructional banner.
struct NotebookPageBadge: View {
    enum Kind {
        case board, sheet, module

        var title: String {
            switch self {
            case .board: return "Board"
            case .sheet: return "Sheet"
            case .module: return "Module"
            }
        }

        var symbol: String {
            switch self {
            case .board: return "square.grid.2x2"
            case .sheet: return "doc.text"
            case .module: return "shippingbox"
            }
        }
    }

    let kind: Kind
    var detail = ""

    var body: some View {
        Label(kind.title, systemImage: kind.symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(NotebookPalette.sputnik)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(NotebookPalette.sputnik.opacity(0.1), in: Capsule())
            .fixedSize()
            .help(detail.isEmpty ? kind.title : detail)
            .accessibilityLabel("Current view: \(kind.title)")
            .accessibilityIdentifier("notebook-page-kind")
    }
}

import SwiftUI

struct BoardColumnSpan: LayoutValueKey { static let defaultValue = 12 }

/// Both the designer and the running board use these same twelve-column
/// measurements. An incomplete row leaves its remaining columns empty.
struct NotebookBoardRowLayout: Layout {
    var height: Double? = nil
    var spacing: Double = 12

    static func cellWidth(_ span: Int, width: Double, spacing: Double = 12) -> Double {
        max(1, (width + spacing) * Double(span) / 12 - spacing)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 720
        let contentHeight = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: Self.cellWidth($0[BoardColumnSpan.self], width: width, spacing: spacing),
                                            height: height.map { CGFloat($0) })).height
        }.max() ?? 80
        return CGSize(width: width, height: height ?? contentHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for view in subviews {
            let width = Self.cellWidth(view[BoardColumnSpan.self], width: bounds.width, spacing: spacing)
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

extension NotebookBoardComponent {
    var horizontalAlignment: HorizontalAlignment {
        h_align == "center" ? .center : h_align == "trailing" ? .trailing : .leading
    }
    var cellAlignment: Alignment {
        Alignment(horizontal: horizontalAlignment,
                  vertical: v_align == "center" ? .center : v_align == "bottom" ? .bottom : .top)
    }
    var textAlignment: TextAlignment {
        h_align == "center" ? .center : h_align == "trailing" ? .trailing : .leading
    }
}

struct BoardGridGuides: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                for column in 1..<12 {
                    let x = geometry.size.width * Double(column) / 12
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                }
            }.stroke(NotebookPalette.rule.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

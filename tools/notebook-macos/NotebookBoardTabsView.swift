import SwiftUI

/// Tabs are layout containers. Switching panels only changes the visible grid;
/// all bindings continue to use the board's controller sheet and project inputs.
struct NotebookBoardTabsView: View {
    let component: NotebookBoardComponent
    var height: Double? = nil
    let content: (NotebookBoardPanel) -> AnyView
    @State private var selectedPanel: String?
    private let tabBarHeight: Double = 44

    var activePanel: NotebookBoardPanel? {
        (component.panels ?? []).first { $0.id == selectedPanel } ?? component.panels?.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabBar
            if let panel = activePanel {
                if let height {
                    ScrollView(.vertical) { panelContent(panel) }
                        .frame(height: max(1, height - tabBarHeight))
                } else {
                    panelContent(panel)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
            .background(NotebookPalette.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(NotebookPalette.rule, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityIdentifier("board-tabs-\(component.id)")
    }

    private var tabBar: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(component.panels ?? []) { panel in
                    let selected = activePanel?.id == panel.id
                    Button { selectedPanel = panel.id } label: {
                        Text(panel.title)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 16)
                            .frame(height: tabBarHeight - 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NotebookBoardTabStyle(selected: selected))
                    .accessibilityLabel(panel.title)
                    .accessibilityValue(selected ? "Selected" : "")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("board-tab-\(component.id)-\(panel.id)")
                }
            }.padding(.horizontal, 10).padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .frame(height: tabBarHeight)
        .background(alignment: .bottom) {
            NotebookPalette.sidebar.opacity(0.5)
                .overlay(alignment: .bottom) { NotebookPalette.rule.frame(height: 1) }
        }
    }

    private func panelContent(_ panel: NotebookBoardPanel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if panel.components.isEmpty {
                Text("Empty panel").font(.callout).foregroundStyle(NotebookPalette.muted)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                content(panel)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(14).id(panel.id)
            .accessibilityIdentifier("board-tab-panel-\(component.id)-\(panel.id)")
    }
}

private struct NotebookBoardTabStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)
        configuration.label
            .foregroundStyle(selected ? NotebookPalette.ink : NotebookPalette.slate)
            .background(selected ? NotebookPalette.canvas : NotebookPalette.card, in: shape)
            .overlay { shape.strokeBorder(NotebookPalette.rule, lineWidth: 1) }
            .overlay(alignment: .top) {
                if selected {
                    NotebookPalette.sputnik.frame(height: 2).padding(.horizontal, 6)
                }
            }
            .overlay(alignment: .bottom) {
                // Cover the tab's lower border and the strip's rule so that
                // the selected tab opens directly into its panel.
                if selected {
                    NotebookPalette.canvas.frame(height: 2).padding(.horizontal, 1)
                }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

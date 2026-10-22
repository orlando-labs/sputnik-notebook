import SwiftUI

struct NotebookSplitView: View {
    let component: NotebookBoardComponent
    var height: Double? = nil
    let content: (NotebookBoardPanel) -> AnyView
    var onSave: ((Double) -> Void)? = nil
    @State private var fraction: Double?
    @State private var dragStart: Double?
    private var ratio: Double { fraction ?? component.split_fraction ?? 0.5 }
    private var minimum: Double { component.split_min ?? 120 }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let horizontal = component.split_axis != "vertical"
                let length = (horizontal ? geometry.size.width : geometry.size.height) - 8
                if let panels = component.panels, panels.count == 2 {
                    if length < minimum * 2 {
                        ScrollView { VStack(spacing: 12) { panel(panels[0]).frame(minHeight: minimum); panel(panels[1]).frame(minHeight: minimum) } }
                    } else {
                        let first = max(minimum, min(length - minimum, length * ratio))
                        if horizontal {
                            HStack(spacing: 0) { panel(panels[0]).frame(width: first); divider(horizontal: true, length: length); panel(panels[1]).frame(maxWidth: .infinity) }
                        } else {
                            VStack(spacing: 0) { panel(panels[0]).frame(height: first); divider(horizontal: false, length: length); panel(panels[1]).frame(maxHeight: .infinity) }
                        }
                    }
                }
            }.frame(height: max(80, height ?? 420))
            if let onSave {
                HStack {
                    Button("Save divider position") { onSave(ratio) }.disabled(abs(ratio - (component.split_fraction ?? 0.5)) < 0.001)
                    Button("Reset divider") { fraction = component.split_fraction ?? 0.5 }
                }.controlSize(.small)
            }
        }.onChange(of: component.split_fraction) { _, value in fraction = value }
    }
    private func panel(_ value: NotebookBoardPanel) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: 8) { Text(value.title).font(.caption.bold()).foregroundStyle(NotebookPalette.muted); content(value) }.frame(maxWidth: .infinity, alignment: .leading) }.padding(6)
    }
    private func divider(horizontal: Bool, length: Double) -> some View {
        Rectangle().fill(NotebookPalette.rule).frame(width: horizontal ? 8 : nil, height: horizontal ? nil : 8)
            .overlay { Image(systemName: horizontal ? "ellipsis" : "ellipsis").font(.caption2).foregroundStyle(NotebookPalette.muted).rotationEffect(.degrees(horizontal ? 90 : 0)) }
            .contentShape(Rectangle())
            .gesture(DragGesture().onChanged { value in
                if dragStart == nil { dragStart = ratio }
                let delta = horizontal ? value.translation.width : value.translation.height
                fraction = min(min(0.9, 1 - minimum / length), max(max(0.1, minimum / length), (dragStart ?? ratio) + delta / length))
            }.onEnded { _ in dragStart = nil })
            .accessibilityLabel("Resize panels")
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.05 : -0.05
                fraction = min(min(0.9, 1 - minimum / length), max(max(0.1, minimum / length), ratio + delta))
            }
    }
}

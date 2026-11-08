import AppKit
import SwiftUI

private protocol NotebookFrameSizedHosting: AnyObject {
    func usePaneFrame()
}

extension NSHostingView: NotebookFrameSizedHosting {
    fileprivate func usePaneFrame() {
        if !sizingOptions.isEmpty { sizingOptions = [] }
    }
}

/// NavigationSplitView creates another hosting view for each column. Its
/// default minimum-size probes traverse the complete sheet on scroll geometry
/// changes, even though the split view already supplies the column's frame.
/// Attach only to the workspace pane; dialogs retain their content sizing.
struct NotebookPaneSizing: NSViewRepresentable {
    func makeNSView(context: Context) -> PaneSizingView { PaneSizingView() }
    func updateNSView(_ view: PaneSizingView, context: Context) { view.scheduleUpdate() }

    final class PaneSizingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleUpdate()
        }

        func scheduleUpdate() {
            DispatchQueue.main.async { [weak self] in
                var ancestor = self?.superview
                while let view = ancestor {
                    if let host = view as? NotebookFrameSizedHosting {
                        host.usePaneFrame()
                        return
                    }
                    ancestor = view.superview
                }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}

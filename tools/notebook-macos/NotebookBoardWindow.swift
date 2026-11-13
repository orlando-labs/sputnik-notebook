import AppKit
import Combine
import SwiftUI

final class NotebookBoardWindow: NSObject, NSWindowDelegate {
    private let model: NotebookModel
    private let preferences: NotebookPreferences
    private weak var workspace: NSWindow?
    private var observation: AnyCancellable?
    private(set) var window: NSWindow?

    init(model: NotebookModel, preferences: NotebookPreferences, workspace: NSWindow) {
        self.model = model
        self.preferences = preferences
        self.workspace = workspace
        super.init()
        observation = model.$boardWindowSheetID.map { $0 != nil }.removeDuplicates()
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.updateWindow() }
    }

    private func showWorkspace() {
        guard let workspace else { return }
        if workspace.isMiniaturized { workspace.deminiaturize(nil) }
        workspace.makeKeyAndOrderFront(nil)
    }

    private func updateWindow() {
        guard model.boardWindowSheetID != nil else {
            let previous = window
            let wasKey = previous?.isKeyWindow == true
            window = nil
            if previous != nil { model.boardWindowFocused = false }
            previous?.close()
            if wasKey { showWorkspace() }
            return
        }
        guard window == nil, let workspace else { return }
        let companion = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 740),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered, defer: false)
        companion.title = model.detachedBoard?.title ?? "Notebook Board"
        companion.minSize = NSSize(width: 620, height: 420)
        companion.isReleasedWhenClosed = false
        companion.delegate = self
        let view = NotebookDetachedBoardView(model: model, onOpenSheet: { [weak self] in self?.showWorkspace() },
                                            onTitle: { [weak companion] title in companion?.title = title })
        let content = NSHostingView(rootView: NotebookAppearanceView(preferences: preferences, content: view))
        content.sizingOptions = []
        companion.contentView = content
        let frameName = "SputnikNotebookBoard"
        if !companion.setFrameUsingName(frameName) {
            if let visible = workspace.screen?.visibleFrame {
                let x = max(visible.minX, min(workspace.frame.maxX + 12, visible.maxX - companion.frame.width))
                let y = max(visible.minY, min(workspace.frame.maxY, visible.maxY) - companion.frame.height)
                companion.setFrameOrigin(NSPoint(x: x, y: y))
            } else {
                companion.center()
            }
        }
        companion.setFrameAutosaveName(frameName)
        window = companion
        companion.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { model.canToggleBoardWindow }

    func windowDidBecomeKey(_ notification: Notification) { model.boardWindowFocused = true }
    func windowDidResignKey(_ notification: Notification) { model.boardWindowFocused = false }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        window = nil
        model.boardWindowFocused = false
        if model.boardWindowSheetID != nil { model.toggleBoardWindow() }
        showWorkspace()
    }
}

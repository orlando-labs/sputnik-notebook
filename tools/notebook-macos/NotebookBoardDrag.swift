import SwiftUI

/// A local designer drag carries identity, never a copy of the component.
/// The session keeps drops from another document/editor out of this draft.
struct NotebookBoardComponentDrag: Equatable {
    let session: UUID
    let board: String
    let component: String

    func canDrop(in draft: NotebookBoard, session: UUID, row: String) -> Bool {
        self.session == session && board == draft.id &&
        draft.components.first(where: { $0.id == component })?.row != row &&
        draft.canMoveComponent(component, to: row)
    }
}

struct NotebookBoardDragGeometry: Equatable {
    var rows: [String: CGRect] = [:]
    var viewport = CGRect.zero

    func row(at point: CGPoint) -> String? {
        guard viewport.contains(point) else { return nil }
        return rows.first { $0.value.contains(point) }?.key
    }
}

struct NotebookBoardDragGeometryKey: PreferenceKey {
    static var defaultValue = NotebookBoardDragGeometry()
    static func reduce(value: inout NotebookBoardDragGeometry, nextValue: () -> NotebookBoardDragGeometry) {
        let next = nextValue()
        value.rows.merge(next.rows) { _, new in new }
        if !next.viewport.isEmpty { value.viewport = next.viewport }
    }
}

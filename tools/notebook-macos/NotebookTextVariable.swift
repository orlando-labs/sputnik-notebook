import Foundation

struct NotebookTextVariable: Identifiable {
    let name: String
    let value: String
    let cellID: String
    let stale: Bool
    var cellNumber: String? = nil

    var id: String { name }
    var sourceLabel: String { cellNumber.map { "Cell \($0)" } ?? "Source cell" }
}

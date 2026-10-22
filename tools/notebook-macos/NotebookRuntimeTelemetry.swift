import Foundation

struct NotebookRuntimeTask: Decodable, Identifiable {
    let id: String, parent: String, cell: String, state: String, error: String, file: String
    let line: Int, elapsed_ms: UInt64
}
struct NotebookRuntimeTelemetry: Decodable {
    let revision: UInt64, dropped: UInt64, active: UInt64, total: UInt64, sampled_ms: UInt64
    let cpu_percent: Double?, resident_bytes: UInt64?
    let tasks: [NotebookRuntimeTask]
}

import Foundation
import SwiftUI

/// Book overrides travel with the document. App defaults are a separate store.
struct NotebookResourcePolicy: Codable, Equatable {
    var run_count: Int?
    var run_age_seconds: Int?
    var project_bytes: Int?
    var max_run_bytes: Int?
    var minimum_free_bytes: Int?
    var revision_count: Int?
    var run_seconds: Int?
    var total_run_seconds: Int?

    static let appDefaults = NotebookResourcePolicy(run_count: 100, run_age_seconds: 30 * 86400,
        project_bytes: 256 * 1024 * 1024, max_run_bytes: 32 * 1024 * 1024,
        minimum_free_bytes: 512 * 1024 * 1024, revision_count: 50)
    static let fields: [(String, String, WritableKeyPath<Self, Int?>, Int, Int)] = [
        ("runs", "Saved runs", \.run_count, 1, 1000),
        ("age", "Keep history (days)", \.run_age_seconds, 86400, 3650),
        ("storage", "History storage (MiB)", \.project_bytes, 1048576, 10240),
        ("result", "One run snapshot (MiB)", \.max_run_bytes, 1048576, 128),
        ("free", "Keep disk space free (MiB)", \.minimum_free_bytes, 1048576, 1048576),
        ("revisions", "Server revisions", \.revision_count, 1, 1000),
        ("run-time", "One run (seconds)", \.run_seconds, 1, 31536000),
        ("total-time", "Total run time per book (seconds)", \.total_run_seconds, 1, 31536000)
    ]
    var validationError: String? {
        for (_, title, key, scale, maximum) in Self.fields {
            if let value = self[keyPath: key], value < 1 || value > maximum * scale { return "\(title) must be positive and at most \(maximum)." }
        }
        return nil
    }
    func applying(to app: Self, restrictive: Bool = false) -> Self {
        var value = app
        for (id, _, key, _, _) in Self.fields {
            guard let book = self[keyPath: key] else { continue }
            if restrictive, let parent = app[keyPath: key] { value[keyPath: key] = id == "free" ? max(parent, book) : min(parent, book) }
            else { value[keyPath: key] = book }
        }
        return value
    }
    var json: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data("{}".utf8), as: UTF8.self) }
}

struct NotebookResourcePolicyForm: View {
    @Binding var policy: NotebookResourcePolicy
    var parent: NotebookResourcePolicy?
    var restrictive = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(NotebookResourcePolicy.fields, id: \.0) { id, title, key, scale, maximum in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if parent != nil || id == "run-time" || id == "total-time" {
                            Toggle(title, isOn: Binding(get: { policy[keyPath: key] != nil }, set: { enabled in
                                policy[keyPath: key] = enabled ? (parent?[keyPath: key] ?? NotebookResourcePolicy.appDefaults[keyPath: key] ?? 60) : nil
                            })).toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading)
                        } else { Text(title).frame(maxWidth: .infinity, alignment: .leading) }
                        if policy[keyPath: key] != nil {
                            TextField(title, value: Binding(get: { Double(policy[keyPath: key] ?? scale) / Double(scale) }, set: { value in
                                guard value.isFinite, value > 0, value <= Double(maximum) else { policy[keyPath: key] = Int.max; return }
                                policy[keyPath: key] = Int((value * Double(scale)).rounded())
                            }), format: .number)
                                .frame(width: 100).accessibilityIdentifier("resource-policy-" + id)
                        } else { Text(parent == nil ? "Unlimited" : "Use app setting").foregroundStyle(.secondary) }
                    }
                    if let parent {
                        let effective = policy.applying(to: parent, restrictive: restrictive)[keyPath: key]
                        Text("App + notebook: " + (effective.map { String(format: "%g", Double($0) / Double(scale)) } ?? "unlimited"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let message = policy.validationError { Text(message).foregroundStyle(.red).accessibilityIdentifier("resource-policy-validation") }
        }
    }
}

/// A local book's cumulative wall time persists across reopen/relaunch; monotonic
/// uptime meters the active run. The remote Core owns its own authoritative meter.
final class NotebookResourceUsage {
    private var file: URL?
    private(set) var spent: Double = 0
    private var started: TimeInterval?
    private var persisted: TimeInterval = 0
    private var fault: String?
    func open(project: String) {
        file = URL(fileURLWithPath: project).standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(".sputnik/resource-usage.json")
        spent = 0; started = nil; fault = nil
        guard let file, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            guard file.resolvingSymlinksInPath() == file else { throw NotebookFailure(message: "Execution usage storage contains a symlink.") }
            let attrs = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) < 4096 else { throw NotebookFailure(message: "Invalid execution usage storage.") }
            let value = try JSONDecoder().decode(Double.self, from: Data(contentsOf: file))
            guard value.isFinite && value >= 0 else { throw NotebookFailure(message: "Invalid execution usage value.") }
            spent = value
        } catch { fault = error.localizedDescription }
    }
    var current: Double { spent + (started.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0) }
    func begin() { started = ProcessInfo.processInfo.systemUptime; persisted = started! }
    func reason(_ policy: NotebookResourcePolicy) -> String? {
        if let fault { return "Execution usage is unavailable: " + fault }
        if let seconds = policy.total_run_seconds, current >= Double(seconds) { return "This notebook's total execution time budget is exhausted." }
        if let started, let seconds = policy.run_seconds, ProcessInfo.processInfo.systemUptime - started >= Double(seconds) { return "This run reached its execution time limit." }
        return nil
    }
    func checkpoint(finish: Bool = false) throws {
        guard let file else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard finish || now - persisted >= 1 else { return }
        // Do not follow a notebook-supplied symlink to another file/directory.
        let root = file.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        guard file.deletingLastPathComponent().resolvingSymlinksInPath().deletingLastPathComponent() == root,
              file.resolvingSymlinksInPath() == file else { throw NotebookFailure(message: "Execution usage storage contains a symlink.") }
        let value = current
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if finish { spent = value; started = nil }
        do {
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
            persisted = now; fault = nil
        } catch { fault = error.localizedDescription; throw error }
    }
}

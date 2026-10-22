import Foundation
import Combine
import CryptoKit

struct NotebookRunSource: Codable { let tab: String, cell: String, kind: String, source: String, formatting: String }
struct NotebookRunOutput: Codable, Identifiable {
    let id: String, result: String, error: String, pretty: String?, table: String?
    let ok: Bool, stale: Bool
    let elapsed: UInt64?
    let log: String
    let metrics: [String: String]
    let displays: [NotebookFigurePanel]
}
struct NotebookRunRecord: Codable, Identifiable {
    var version = 1
    let id: String
    var title: String
    let started: Date, ended: Date
    let tab: String, cell: String?, action: String
    let backend: String, epoch: String?, revision: String?
    let status: String, failure: String?
    let sources: [NotebookRunSource]
    let sourceHash: String
    let inputs: [String: String]
    let cellInputs: [String: [String: String]]
    let assets: [String: NotebookFigurePanel]
    let dependencies: [String]
    let outputs: [NotebookRunOutput]
    let omitted: Bool
    var acceptedData: [NotebookAcceptedData]? = nil
    var remoteDocument: String? = nil
    var provenanceNote: String? = nil
    var pinned = false
}
struct NotebookRunSummary: Identifiable {
    let id: String, title: String, started: Date, status: String, tab: String, backend: String
    let bytes: Int, pinned: Bool
}
struct NotebookRunStart {
    var id = UUID().uuidString.lowercased()
    var date = Date()
    var tab: String, cell: String?, action: String, backend: String
    var sources: [NotebookRunSource], inputs: [String: String], cellInputs: [String: [String: String]]
    var assets: [String: NotebookFigurePanel], dependencies: [String]
    var acceptedData: [NotebookAcceptedData] = []
    var cancelled = false
}

/// Run snapshots are separate from authored defaults and current runtime state.
/// Hidden project storage avoids recursively uploading history with remote revisions.
final class NotebookRunHistory: ObservableObject {
    @Published private(set) var runs: [NotebookRunSummary] = []
    @Published var error: String?
    private var directory: URL?
    static let maxRecord = 32 * 1024 * 1024
    static let maxTotal = 256 * 1024 * 1024
    static let maxUnpinned = 20
    static let maxPinned = 10
    private let encoder: JSONEncoder = { let v = JSONEncoder(); v.outputFormatting = [.sortedKeys]; return v }()
    private let decoder = JSONDecoder()

    func open(project: String) {
        runs = []; error = nil; directory = nil
        let root = URL(fileURLWithPath: project, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let folder = root.appendingPathComponent(".notebook-history", isDirectory: true)
        guard folder.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else {
            error = "History directory points outside this notebook."; return
        }
        directory = folder
        refresh()
    }
    private func file(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil, let directory else { throw failure("Run history is unavailable.") }
        let url = directory.appendingPathComponent(id + ".json")
        guard url.resolvingSymlinksInPath() == url else { throw failure("History symlinks are unsupported.") }
        return url
    }
    func load(_ id: String) throws -> NotebookRunRecord {
        let url = try file(id), size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, let count = size.fileSize, count <= Self.maxRecord else { throw failure("Invalid or oversized run snapshot.") }
        let record = try decoder.decode(NotebookRunRecord.self, from: Data(contentsOf: url))
        guard record.version == 1, record.id == id else { throw failure("Unsupported run snapshot.") }
        return record
    }
    func refresh() {
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { runs = []; return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "json" }
            guard files.count <= 256 else { throw failure("History contains too many files.") }
            var entries: [NotebookRunSummary] = []
            for url in files {
                let id = url.deletingPathExtension().lastPathComponent
                do {
                    let record = try load(id)
                    entries.append(.init(id: id, title: record.title, started: record.started, status: record.status,
                        tab: record.tab, backend: record.backend, bytes: (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0, pinned: record.pinned))
                } catch { self.error = "Some saved runs could not be read: " + error.localizedDescription }
            }
            runs = entries.sorted { $0.started > $1.started }
        } catch { self.error = error.localizedDescription }
    }
    func save(_ record: NotebookRunRecord) throws {
        guard let directory else { throw failure("History is unavailable.") }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw failure("History storage is not a directory.") }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let data = try encoder.encode(record)
        guard data.count <= Self.maxRecord else { throw failure("Run snapshot exceeds 32 MiB.") }
        let existing = runs.first { $0.id == record.id }
        if record.pinned && existing?.pinned != true && runs.filter(\.pinned).count >= Self.maxPinned {
            throw failure("At most ten runs can be pinned. Unpin a saved run first.")
        }
        let pinnedBytes = runs.filter { $0.pinned && $0.id != record.id }.reduce(0) { $0 + $1.bytes }
        guard pinnedBytes + data.count <= Self.maxTotal else { throw failure("Pinned runs leave insufficient history space.") }
        try data.write(to: file(record.id), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(record.id).path)
        refresh(); try enforceRetention()
    }
    private func enforceRetention() throws {
        var total = runs.reduce(0) { $0 + $1.bytes }
        var unpinned = runs.filter { !$0.pinned }.count
        for run in runs.reversed() where !run.pinned {
            if unpinned <= Self.maxUnpinned && total <= Self.maxTotal { break }
            try FileManager.default.removeItem(at: file(run.id)); unpinned -= 1; total -= run.bytes
        }
        refresh()
    }
    func remove(_ id: String) { do { try FileManager.default.removeItem(at: file(id)); refresh() } catch { self.error = error.localizedDescription } }
    func pin(_ id: String) { do { var value = try load(id); value.pinned.toggle(); try save(value) } catch { self.error = error.localizedDescription } }
    func rename(_ id: String, title: String) { do { var value = try load(id); value.title = String(title.prefix(256)); try save(value) } catch { self.error = error.localizedDescription } }
    func export(_ id: String, to url: URL) throws { try encoder.encode(load(id)).write(to: url, options: .atomic) }
    private func failure(_ text: String) -> NSError { NSError(domain: "NotebookHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

    func record(_ start: NotebookRunStart, state: NotebookSnapshot, failure: String? = nil, epoch: String? = nil, revision: String? = nil, remoteDocument: String? = nil, provenanceNote: String? = nil) {
        guard let tab = state.tabs.first(where: { $0.id == start.tab }) else { return }
        var remaining = 16 * 1024 * 1024, omitted = false
        func capture(_ panel: NotebookFigurePanel) -> NotebookFigurePanel? {
            guard panel.data.count <= remaining else { omitted = true; return nil }
            remaining -= panel.data.count; return panel
        }
        let outputs = tab.cells.filter { $0.kind == "code" }.map { cell in
            var displays = (cell.displays ?? []).compactMap(capture)
            displays += (cell.images ?? []).flatMap(\.images).compactMap(capture)
            for stream in cell.audio ?? [] where stream.replace && stream.valid {
                let panel = NotebookFigurePanel(mime: NotebookAudioPayload.mime, caption: stream.caption, width: 0, height: 0,
                    data: NotebookAudioPayload.encode(stream.wav(), format: "wav"), id: stream.id)
                if let stored = capture(panel) { displays.append(stored) }
            }
            let metrics = Dictionary(uniqueKeysWithValues: cell.locals.filter {
                $0.initialized && $0.role == "module_cell" && Double($0.text_value ?? $0.value)?.isFinite == true
            }.map { ($0.name, $0.text_value ?? $0.value) })
            return NotebookRunOutput(id: cell.id, result: cell.result, error: cell.error, pretty: cell.result_format?.pretty,
                table: cell.result_format?.table_json, ok: cell.ok, stale: cell.dirty, elapsed: cell.elapsed_ms,
                log: String(cell.output.map { "[\($0.stream)] \($0.text)" }.joined().prefix(262144)), metrics: metrics, displays: displays)
        }
        let selected = start.cell.map { id in outputs.filter { $0.id == id } } ?? outputs
        let failed = failure != nil || selected.contains { !$0.ok && !$0.stale }
        let status = start.cancelled ? "cancelled" : failed ? "failed" : "success"
        let sourceData = (try? encoder.encode(start.sources)) ?? Data()
        var assets: [String: NotebookFigurePanel] = [:]
        for (id, panel) in start.assets { if let saved = capture(panel) { assets[id] = saved } }
        var record = NotebookRunRecord(id: start.id, title: tab.title + " · " + start.date.formatted(date: .omitted, time: .standard),
            started: start.date, ended: Date(), tab: tab.id, cell: start.cell, action: start.action, backend: start.backend,
            epoch: epoch, revision: revision, status: status, failure: failure, sources: start.sources,
            sourceHash: SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined(), inputs: start.inputs,
            cellInputs: start.cellInputs, assets: assets, dependencies: start.dependencies, outputs: outputs, omitted: omitted)
        record.acceptedData = start.acceptedData
        record.remoteDocument = remoteDocument; record.provenanceNote = provenanceNote
        do { try save(record) } catch { self.error = error.localizedDescription }
    }
}


extension NotebookModel {
    func beginRunHistory(tab: NotebookTab, cell: String?, action: String) {
        guard let snapshot, snapshot.boards?.contains(where: { $0.sheet == String(tab.id.dropFirst(6)) && $0.allComponents.contains { ["run_history", "experiment_compare"].contains($0.kind) } }) == true else { return }
        let sources = snapshot.tabs.flatMap { tab in tab.cells.map { cell in
            NotebookRunSource(tab: tab.id, cell: cell.id, kind: cell.kind, source: source(for: cell, in: tab), formatting: formatting(for: cell, in: tab))
        } }
        var cells: [String: [String: String]] = [:]
        for tab in snapshot.tabs { for cell in tab.cells where cell.cell_inputs?.isEmpty == false {
            cells[cell.id] = Dictionary(uniqueKeysWithValues: cell.cell_inputs!.map { ($0.id, $0.value_json) })
        } }
        var assets: [String: NotebookFigurePanel] = [:]
        for input in snapshot.audio_inputs ?? [] { if let panel = input.panels.first { assets["audio:" + input.sheet + ":" + input.id] = panel } }
        for input in snapshot.image_inputs ?? [] { for (index, panel) in input.images.enumerated() { assets["image:" + input.sheet + ":" + input.id + ":" + String(index)] = panel } }
        pendingRunHistory[tab.id] = NotebookRunStart(tab: tab.id, cell: cell, action: action,
            backend: remote.isSelected ? remote.serverName : "Local", sources: sources,
            inputs: Dictionary(uniqueKeysWithValues: (snapshot.inputs ?? []).map { ($0.id, $0.value_json) }),
            cellInputs: cells, assets: assets, dependencies: (snapshot.dependencies ?? []).map(\.path), acceptedData: snapshot.accepted_data ?? [])
    }
    func finishRunHistory(tab: String, state: NotebookSnapshot, failure: String? = nil, remoteID: String? = nil, remoteDocument: String? = nil) {
        var pending = pendingRunHistory.removeValue(forKey: tab)
        if pending == nil, let current = state.tabs.first(where: { $0.id == tab }), remoteID != nil {
            beginRunHistory(tab: current, cell: nil, action: "remote_recovered")
            pending = pendingRunHistory.removeValue(forKey: tab)
            pending?.assets = [:] // the current input is not evidence of an older remote run's input
            pending?.sources = []
            pending?.acceptedData = []
        }
        guard var start = pending else { return }
        let remoteRun = remoteID.flatMap { id in remote.runs.first { $0.id == id } }
        if let remoteID {
            let bytes = Array(SHA256.hash(data: Data((start.backend + ":" + remoteID).utf8)).prefix(16))
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            start.id = String(hex.prefix(8)) + "-" + String(hex.dropFirst(8).prefix(4)) + "-" + String(hex.dropFirst(12).prefix(4)) + "-" + String(hex.dropFirst(16).prefix(4)) + "-" + String(hex.dropFirst(20))
            if runHistory.runs.contains(where: { $0.id == start.id }) { return }
        }
        if let document = remoteDocument, let json = try? JSONSerialization.jsonObject(with: Data(document.utf8)) as? [String: Any] {
            let sheets = json["sheets"] as? [[String: Any]] ?? []
            start.sources.removeAll { $0.tab.hasPrefix("sheet:") }
            for sheet in sheets { for cell in sheet["cells"] as? [[String: Any]] ?? [] {
                if let id = cell["id"] as? String {
                    start.sources.append(.init(tab: "sheet:" + (sheet["id"] as? String ?? ""), cell: id, kind: cell["kind"] as? String ?? "code", source: cell["source"] as? String ?? "", formatting: ""))
                }
            } }
            var inputs: [String: String] = [:]
            for input in json["inputs"] as? [[String: Any]] ?? [] {
                if let id = input["id"] as? String, let value = input["default"], let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) {
                    inputs[id] = String(decoding: bytes, as: UTF8.self)
                }
            }
            start.inputs = inputs
            var accepted: [NotebookAcceptedData] = []
            func componentData(_ components: [[String: Any]]) {
                for component in components {
                    for panel in component["panels"] as? [[String: Any]] ?? [] { componentData(panel["components"] as? [[String: Any]] ?? []) }
                    let type = component["kind"] as? String ?? ""
                    let kind = type == "table" ? "selection" : type == "audio_annotator" ? "audio_annotations" : "annotations"
                    guard type == "table" || type == "audio_annotator" || (["image", "image_carousel"].contains(type) && component["image_annotator"] as? Bool == true) else { continue }
                    let channel = component[kind == "selection" ? "selection_id" : "annotation_id"] as? String ?? (kind == "annotations" ? (component["id"] as? String ?? "") + "_labels" : "")
                    guard !channel.isEmpty, let bytes = try? JSONSerialization.data(withJSONObject: component[kind] ?? NSNull(), options: [.fragmentsAllowed, .sortedKeys]) else { continue }
                    accepted.append(.init(kind: kind, id: channel, json: String(decoding: bytes, as: UTF8.self)))
                }
            }
            for board in json["boards"] as? [[String: Any]] ?? [] { componentData(board["components"] as? [[String: Any]] ?? []) }
            start.acceptedData = accepted
            var local: [String: [String: String]] = [:]
            for sheet in sheets { for cell in sheet["cells"] as? [[String: Any]] ?? [] {
                guard let id = cell["id"] as? String, let ui = cell["cell_ui"] as? [String: Any] else { continue }
                var values: [String: String] = [:]
                for input in ui["inputs"] as? [[String: Any]] ?? [] {
                    if let key = input["id"] as? String {
                        if let exact = input["default_json"] as? String { values[key] = exact }
                        else if let value = input["default"], let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) { values[key] = String(decoding: bytes, as: UTF8.self) }
                    }
                }
                local[id] = values
            } }
            start.cellInputs = local
        }
        start.cancelled = start.cancelled || ["cancelled", "force-stopped", "interrupted"].contains(remoteRun?.state ?? "")
        runHistory.record(start, state: state, failure: failure ?? (remoteRun?.state == "failed" ? "Remote run failed" : nil), epoch: remoteRun?.epoch, revision: remoteRun?.revision, remoteDocument: remoteDocument, provenanceNote: remoteID != nil && !remote.frozenRunDocuments.contains(remoteID!) ? "This server does not provide frozen run inputs. Parameter provenance is incomplete; update the remote core." : nil)
    }
    func restoreRunParameters(_ record: NotebookRunRecord) {
        guard !busy, !remote.active, !remote.isSelected else { error = "Select local execution to restore saved scalar parameters."; return }
        var values = Dictionary(uniqueKeysWithValues: record.inputs.map { ("project:" + $0.key, $0.value) })
        for (cell, inputs) in record.cellInputs { for (key, value) in inputs { values["cell:" + cell + ":" + key] = value } }
        do { perform("restore_inputs", text: String(decoding: try JSONEncoder().encode(values), as: UTF8.self)) }
        catch { self.error = error.localizedDescription }
    }
}

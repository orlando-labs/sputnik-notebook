import AppKit
import Combine
import Foundation

struct NotebookOutput: Decodable {
    let stream: String; let text: String
    var source_file: String? = nil
    var source_line: Int? = nil
}
struct NotebookLocal: Decodable {
    let name: String, value: String, role: String, binding_kind: String
    let initialized: Bool, watched: Bool
    // Older bridge snapshots do not have a text representation yet. Keep
    // decoding those snapshots and use the debug value only as a fallback.
    let text_value: String?

    init(name: String, value: String, role: String, binding_kind: String,
         initialized: Bool, watched: Bool, text_value: String? = nil) {
        self.name = name
        self.value = value
        self.role = role
        self.binding_kind = binding_kind
        self.initialized = initialized
        self.watched = watched
        self.text_value = text_value
    }

    private enum CodingKeys: String, CodingKey {
        case name, value, role, binding_kind, initialized, watched, text_value
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        value = try values.decode(String.self, forKey: .value)
        role = try values.decode(String.self, forKey: .role)
        binding_kind = try values.decode(String.self, forKey: .binding_kind)
        initialized = try values.decode(Bool.self, forKey: .initialized)
        watched = try values.decode(Bool.self, forKey: .watched)
        text_value = try values.decodeIfPresent(String.self, forKey: .text_value)
    }
}
struct NotebookCell: Decodable, Identifiable {
    var cell_ui: NotebookCellUI? = nil
    var cell_inputs: [NotebookProjectInput]? = nil
    var canCollapseSource: Bool { kind == "code" && cell_ui?.post.isEmpty == false }
    var elapsed_ms: UInt64? = nil
    var stopwatches: [NotebookStopwatch]? = nil
    var result_format: NotebookResultFormat? = nil
    var displays: [NotebookFigurePanel]? = nil
    var progress: [NotebookProgress]? = nil
    var charts: [NotebookLiveChart]? = nil
    var images: [NotebookImageSeries]? = nil
    var audio: [NotebookAudioStream]? = nil
    var audio_controls: [NotebookAudioControl]? = nil
    let id: String, kind: String, source: String, formatting: String
    let watch: Bool, dirty: Bool, ok: Bool
    let result: String, error: String
    let output: [NotebookOutput], locals: [NotebookLocal]
}
struct NotebookResultFormat: Decodable {
    let pretty: String
    let is_container: Bool, truncated: Bool, pretty_truncated: Bool
    var table_json: String? = nil
}
struct NotebookCellPresentation {
    let cell: NotebookCell
    let stale: Bool, running: Bool
    let result: NotebookCellResult?
    let progress: [NotebookProgress]
    let figures: [NotebookFigurePanel]
    var hasResult: Bool { result != nil }
}
struct NotebookCellResult {
    let text: String
    let format: NotebookResultFormat?
    var previous = false
}
struct NotebookProgress: Decodable, Identifiable {
    let id: String, description: String
    let current: Double, total: Double
    let elapsed_ms: UInt64
    let done: Bool
}
struct NotebookStopwatch: Decodable, Identifiable {
    let id: String
    var elapsed_ms: UInt64
    let done: Bool
}
struct NotebookElapsed {
    let milliseconds: UInt64
    let running: Bool
}
struct NotebookChartPoint: Decodable, Equatable {
    let x: Double, y: Double
}
struct NotebookLiveChart: Decodable, Identifiable, Equatable {
    let id: String
    var points: [NotebookChartPoint]
    var total_points: UInt64
    var replace_chart: Bool

    func sampledPoints(maxCount: Int) -> [NotebookChartPoint] {
        guard points.count > maxCount, maxCount >= 4 else { return points }
        // Preserve extrema in each bucket so narrow loss charts retain spikes.
        let buckets = (maxCount - 2) / 2
        var sampled = [points[0]]
        for bucket in 0..<buckets {
            let start = 1 + bucket * (points.count - 2) / buckets
            let end = 1 + (bucket + 1) * (points.count - 2) / buckets
            var minimum = start, maximum = start
            for index in start..<end {
                if points[index].y < points[minimum].y { minimum = index }
                if points[index].y > points[maximum].y { maximum = index }
            }
            sampled.append(points[min(minimum, maximum)])
            if minimum != maximum { sampled.append(points[max(minimum, maximum)]) }
        }
        sampled.append(points[points.count - 1])
        return sampled
    }
}
struct NotebookImageSeries: Codable, Identifiable, Equatable {
    let id: String
    let caption: String
    let images: [NotebookFigurePanel]
}
struct NotebookImageInput: Decodable {
    let sheet: String, id: String, caption: String
    let selected: Int
    let images: [NotebookFigurePanel]
}
struct NotebookLiveCell: Decodable, Identifiable {
    var elapsed_ms: UInt64? = nil
    var timing_running: Bool? = nil
    var stopwatches: [NotebookStopwatch]? = nil
    var stopwatches_updated: Bool? = nil
    var displays_updated: Bool? = nil
    var progress_updated: Bool? = nil
    var charts_updated: Bool? = nil
    var charts_reset: Bool? = nil
    var images_updated: Bool? = nil
    var audio_updated: Bool? = nil
    var audio_reset: Bool? = nil
    var audio_controls_updated: Bool? = nil
    var output_updated: Bool? = nil
    var output: [NotebookOutput]? = nil
    let id: String
    var displays: [NotebookFigurePanel]
    var progress: [NotebookProgress]
    var charts: [NotebookLiveChart]
    var images: [NotebookImageSeries]? = nil
    var audio: [NotebookAudioStream]? = nil
    var audio_controls: [NotebookAudioControl]? = nil
}
private struct NotebookLiveSnapshot: Decodable {
    var telemetry: NotebookRuntimeTelemetry? = nil
    var telemetry_updated: Bool? = nil
    let tab: String?
    let executing_cell: String?
    let cells: [NotebookLiveCell]
}
struct NotebookCellLocation: Equatable {
    let tab: String, cell: String
}
struct NotebookCellNavigation: Equatable {
    let location: NotebookCellLocation
    let request = UUID()
}
struct NotebookTab: Decodable, Identifiable {
    var telemetry: NotebookRuntimeTelemetry? = nil
    let id: String, kind: String, title: String
    let modified: Bool, environment_stale: Bool, auto_import: Bool
    let status: String, environment_error: String
    let environment_output: [NotebookOutput]
    let selected_cell: String, cells: [NotebookCell]

    /// Positions include text cells and change when the sheet is reordered.
    /// Saved component bindings always retain the stable cell ID instead.
    func cellNumber(for cellID: String) -> String? {
        cells.firstIndex(where: { $0.id == cellID }).map { String(format: "%02d", $0 + 1) }
    }
    func cellLabel(for cellID: String) -> String {
        cellNumber(for: cellID).map { "Cell \($0)" } ?? "Source cell unavailable"
    }
}
struct NotebookDependency: Decodable, Identifiable {
    let path: String
    let auto_import: Bool
    var native: Bool? = nil
    var id: String { path }
}
struct NotebookSnapshot: Decodable {
    var retain_cell_results: Bool? = nil
    var image_inputs: [NotebookImageInput]? = nil
    var accepted_data: [NotebookAcceptedData]? = nil
    var audio_inputs: [NotebookAudioInput]? = nil
    var dependencies: [NotebookDependency]? = nil
    var inputs: [NotebookProjectInput]? = nil
    var boards: [NotebookBoard]? = nil
    var periodic_results: [NotebookPeriodicResult]? = nil
    let title: String, path: String, selected_tab: String
    let modified_count: Int, environment_generation: Int
    let tabs: [NotebookTab]
}

private struct SourceKey: Hashable { let tab: String; let cell: String }
private struct SourceDraft {
    let source: String
    // nil identifies executable source; empty string is an unformatted text block.
    let formatting: String?
}
private struct SourceEdit { let key: SourceKey; let draft: SourceDraft }
struct NotebookFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func normalizedWorkerGrants(_ text: String) throws -> String {
    guard !text.utf8.contains(0) else { throw NotebookFailure(message: "Worker grants cannot contain NUL characters.") }
    var error: UnsafeMutablePointer<CChar>?
    guard let result = sputnik_notebook_normalize_grants(text, &error) else {
        defer { sputnik_notebook_string_free(error) }
        throw NotebookFailure(message: error.map { String(cString: $0) } ?? "Invalid worker grants.")
    }
    defer { sputnik_notebook_string_free(result) }
    return String(cString: result)
}
private final class NotebookControl {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { sputnik_notebook_control_destroy(pointer) }
}

// The C++ host and all its Sessions have exactly one serial owner. Only
// immutable, decoded snapshots cross to AppKit's main thread; no runtime
// values, callbacks or borrowed Session pointers do.
private final class NotebookWorker {
    let executable: String?
    // Main-thread access only. Independent C++ lifetime, not a borrowed host.
    private var control: NotebookControl?
    var isolated: Bool { control != nil }
    private let settingsURL: URL
    private var settingsPath = ""
    private var localGrants: [String: String] = [:]
    init(executable: String?, settingsURL: URL) { self.executable = executable; self.settingsURL = settingsURL }
    func grants(tab: String, completion: @escaping (String) -> Void) {
        queue.async { let text = self.localGrants[tab] ?? ""; DispatchQueue.main.async { completion(text) } }
    }
    private func storedGrants() throws -> [String: [String: String]] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        return try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: settingsURL))
    }
    var phase: Int { Int(sputnik_notebook_control_phase(control?.pointer)) }
    func stop(force: Bool) -> Bool { sputnik_notebook_control_stop(control?.pointer, force ? 1 : 0) != 0 }
    func prepareExecution() { sputnik_notebook_control_prepare(control?.pointer) }
    func finishExecution() { sputnik_notebook_control_finish(control?.pointer) }
    private let liveQueue = DispatchQueue(label: "org.sputniklang.notebook.live", qos: .utility)
    func takeLive(_ completion: @escaping (NotebookLiveSnapshot?) -> Void) {
        let currentControl = control
        liveQueue.async {
            var snapshot: NotebookLiveSnapshot?
            if let json = sputnik_notebook_control_live(currentControl?.pointer) {
                snapshot = try? JSONDecoder().decode(NotebookLiveSnapshot.self, from: Data(String(cString: json).utf8))
                sputnik_notebook_string_free(json)
            }
            DispatchQueue.main.async { completion(snapshot) }
        }
    }
    let queue = DispatchQueue(label: "org.sputniklang.notebook.runtime", qos: .userInitiated)
    private var handle: OpaquePointer?
    private var paused = false
    private var external = false

    private func failure(_ error: UnsafeMutablePointer<CChar>?) -> NotebookFailure {
        defer { sputnik_notebook_string_free(error) }
        return NotebookFailure(message: error.map { String(cString: $0) } ?? "Notebook operation failed.")
    }

    private func snapshot() throws -> NotebookSnapshot {
        var error: UnsafeMutablePointer<CChar>?
        guard let json = sputnik_notebook_snapshot(handle, &error) else { throw failure(error) }
        defer { sputnik_notebook_string_free(json) }
        return try JSONDecoder().decode(NotebookSnapshot.self, from: Data(String(cString: json).utf8))
    }

    private func command(_ action: String, tab: String = "", cell: String = "", text: String = "") throws {
        guard ![action, tab, cell, text].contains(where: { $0.utf8.contains(0) }) else {
            throw NotebookFailure(message: "This editor cannot submit embedded NUL characters. The original file has not been overwritten.")
        }
        var error: UnsafeMutablePointer<CChar>?
        let result = cell.withCString { cellPointer in
            sputnik_notebook_command(handle, action, tab, cell.isEmpty ? nil : cellPointer, text, &error)
        }
        guard result != 0 else { throw failure(error) }
    }

    // Destruction runs on the same serial owner as all host commands.
    private func retireHost(completion: (() -> Void)? = nil) {
        sputnik_notebook_destroy(handle)
        handle = nil
        completion?()
    }

    func open(path: String, create: Bool, title: String,
              completion: @escaping (NotebookSnapshot?, String?) -> Void) {
        queue.async {
            var candidate: OpaquePointer?
            do {
                guard !path.utf8.contains(0), !title.utf8.contains(0) else {
                    throw NotebookFailure(message: "Project paths and titles cannot contain NUL characters.")
                }
                var error: UnsafeMutablePointer<CChar>?
                candidate = sputnik_notebook_open(path, create ? 1 : 0, title, &error)
                guard candidate != nil else { throw self.failure(error) }
                // Decode before replacing the current project, including on
                // malformed/unsupported source bytes or protocol failures.
                let previous = self.handle
                self.handle = candidate
                let initial: NotebookSnapshot
                do { initial = try self.snapshot() }
                catch { self.handle = previous; throw error }
                self.handle = previous
                // Every GUI execution uses the helper, including Finder opens.
                // Enabling transport is inert; only execution loads code.
                var candidateControl: NotebookControl?
                if let executable = self.executable {
                    guard let pointer = sputnik_notebook_enable_worker(candidate, executable, &error) else {
                        throw self.failure(error)
                    }
                    candidateControl = NotebookControl(pointer)
                } else { throw NotebookFailure(message: "Notebook worker executable is unavailable.") }
                let grants = try self.storedGrants()[initial.path] ?? [:]
                for tab in initial.tabs where grants[tab.id] != nil {
                    let text = try normalizedWorkerGrants(grants[tab.id]!)
                    guard sputnik_notebook_command(candidate, "worker_grants", tab.id, nil, text, &error) != 0 else { throw self.failure(error) }
                }
                for tab in initial.tabs where grants["@environment:" + tab.id] != nil {
                    let directory = grants["@environment:" + tab.id]!
                    guard sputnik_notebook_command(candidate, "worker_environment", tab.id, nil, directory, &error) != 0 else { throw self.failure(error) }
                }
                self.retireHost()
                self.handle = candidate
                candidate = nil
                self.paused = false
                self.settingsPath = initial.path
                self.localGrants = grants
                let nextControl = candidateControl
                DispatchQueue.main.async { self.control = nextControl; completion(initial, nil) }
            } catch {
                sputnik_notebook_destroy(candidate)
                let message = error.localizedDescription
                DispatchQueue.main.async { completion(nil, message) }
            }
        }
    }

    func execute(edits: [SourceEdit], action: String, tab: String, cell: String, text: String,
                 trustNative: Bool = false,
                 completion: @escaping (NotebookSnapshot?, String?) -> Void) {
        queue.async {
            var operationError: String?
            do {
                if trustNative { try self.command("trust_native", tab: tab) }
                for edit in edits {
                    if let formatting = edit.draft.formatting {
                        var content: [String: Any] = ["source": edit.draft.source]
                        if !formatting.isEmpty {
                            content["formatting"] = try JSONSerialization.jsonObject(with: Data(formatting.utf8))
                        }
                        let payload = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
                        try self.command("rich_source", tab: edit.key.tab, cell: edit.key.cell,
                                         text: String(decoding: payload, as: UTF8.self))
                    } else {
                        try self.command("source", tab: edit.key.tab, cell: edit.key.cell, text: edit.draft.source)
                    }
                }
                try self.command(action, tab: tab, cell: cell, text: text)
                if action == "worker_grants" || action == "worker_environment" {
                    let normalized = action == "worker_grants" ? try normalizedWorkerGrants(text) : text
                    let settingKey = action == "worker_grants" ? tab : "@environment:" + tab
                    self.localGrants[settingKey] = normalized
                    var saved = try self.storedGrants()
                    saved[self.settingsPath, default: [:]][settingKey] = normalized
                    do { try NotebookRemoteController.write(try JSONEncoder().encode(saved), to: self.settingsURL) }
                    catch { throw NotebookFailure(message: "Worker grants applied, but could not save settings: \(error.localizedDescription)") }
                }
            } catch { operationError = error.localizedDescription }
            var state: NotebookSnapshot?
            do { state = try self.snapshot() }
            catch { if operationError == nil { operationError = error.localizedDescription } }
            let result = state, message = operationError
            DispatchQueue.main.async { completion(result, message) }
        }
    }

    func setExternal(_ enabled: Bool) {
        queue.async {
            self.external = enabled
            var error: UnsafeMutablePointer<CChar>?
            _ = sputnik_notebook_external(self.handle, enabled ? 1 : 0, &error)
            sputnik_notebook_string_free(error)
        }
    }

    func export(edits: [SourceEdit], completion: @escaping (NotebookRemoteExport?, NotebookSnapshot?, String?) -> Void) {
        queue.async {
            do {
                for edit in edits {
                    if let formatting = edit.draft.formatting {
                        var value: [String: Any] = ["source": edit.draft.source]
                        if !formatting.isEmpty { value["formatting"] = try JSONSerialization.jsonObject(with: Data(formatting.utf8)) }
                        try self.command("rich_source", tab: edit.key.tab, cell: edit.key.cell,
                                         text: String(decoding: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
                    } else { try self.command("source", tab: edit.key.tab, cell: edit.key.cell, text: edit.draft.source) }
                }
                var error: UnsafeMutablePointer<CChar>?
                guard let json = sputnik_notebook_export(self.handle, &error) else { throw self.failure(error) }
                defer { sputnik_notebook_string_free(json) }
                guard let disk = sputnik_notebook_disk_export(self.handle, &error) else { throw self.failure(error) }
                defer { sputnik_notebook_string_free(disk) }
                let exported = NotebookRemoteExport(current: String(cString: json), disk: String(cString: disk)), state = try self.snapshot()
                DispatchQueue.main.async { completion(exported, state, nil) }
            } catch { let message = error.localizedDescription; DispatchQueue.main.async { completion(nil, nil, message) } }
        }
    }

    func restore(_ exported: String, completion: @escaping (NotebookSnapshot?, String?) -> Void) {
        queue.async {
            do {
                guard let value = try JSONSerialization.jsonObject(with: Data(exported.utf8)) as? [String: Any],
                      let document = value["document"] as? String, let modules = value["modules"] as? [String: String],
                      let parsed = try JSONSerialization.jsonObject(with: Data(document.utf8)) as? [String: Any] else {
                    throw NotebookFailure(message: "Invalid remote draft checkpoint.")
                }
                var error: UnsafeMutablePointer<CChar>?
                guard sputnik_notebook_restore_document(self.handle, document, &error) != 0 else { throw self.failure(error) }
                let initial = try self.snapshot()
                for module in parsed["modules"] as? [[String: Any]] ?? [] {
                    guard let id = module["id"] as? String, let path = module["path"] as? String,
                          let source = modules[path], let tab = initial.tabs.first(where: { $0.id == "module:" + id }), let cell = tab.cells.first else { continue }
                    try self.command("source", tab: tab.id, cell: cell.id, text: source)
                }
                let state = try self.snapshot()
                DispatchQueue.main.async { completion(state, nil) }
            } catch { let message = error.localizedDescription; DispatchQueue.main.async { completion(nil, message) } }
        }
    }

    func remoteResult(sheet: String, document: String, data: Data, stale: Bool,
                      completion: @escaping (NotebookSnapshot?, String?) -> Void) {
        queue.async {
            do {
                var error: UnsafeMutablePointer<CChar>?
                let ok = data.withUnsafeBytes { bytes in
                    sputnik_notebook_remote_result(self.handle, sheet, document, bytes.bindMemory(to: UInt8.self).baseAddress, data.count, stale ? 1 : 0, &error)
                }
                guard ok != 0 else { throw self.failure(error) }
                let state = try self.snapshot()
                DispatchQueue.main.async { completion(state, nil) }
            } catch { let message = error.localizedDescription; DispatchQueue.main.async { completion(nil, message) } }
        }
    }

    func remoteLive(_ data: Data, completion: @escaping (NotebookLiveSnapshot?, String?) -> Void) {
        liveQueue.async {
            do {
                var error: UnsafeMutablePointer<CChar>?
                let json = data.withUnsafeBytes { sputnik_notebook_remote_live($0.bindMemory(to: UInt8.self).baseAddress, data.count, &error) }
                guard let json else { throw self.failure(error) }
                defer { sputnik_notebook_string_free(json) }
                let state = try JSONDecoder().decode(NotebookLiveSnapshot.self, from: Data(String(cString: json).utf8))
                DispatchQueue.main.async { completion(state, nil) }
            } catch { let message = error.localizedDescription; DispatchQueue.main.async { completion(nil, message) } }
        }
    }

    func setPaused(_ value: Bool) {
        queue.async {
            self.paused = value
        }
    }

    func pendingWatch(_ completion: @escaping (String?, String?) -> Void) {
        queue.async {
            guard !self.external, !self.paused, self.handle != nil else {
                DispatchQueue.main.async { completion(nil, nil) }; return
            }
            var error: UnsafeMutablePointer<CChar>?
            let pending = sputnik_notebook_worker_pending(self.handle, &error)
            let owner = pending.map { String(cString: $0) }
            sputnik_notebook_string_free(pending)
            let message = error.map { self.failure($0).localizedDescription }
            DispatchQueue.main.async { completion(owner, message) }
        }
    }

    func close(completion: @escaping () -> Void) {
        queue.async {
            self.retireHost { DispatchQueue.main.async { self.control = nil; completion() } }
        }
    }
}

final class NotebookModel: ObservableObject {
    let audioSession = NotebookAudioSession()
    let runHistory = NotebookRunHistory()
    var pendingRunHistory: [String: NotebookRunStart] = [:]
    private let workerExecutable: String?
    let remote: NotebookRemoteController
    init(workerExecutable: String? = nil, remoteExecutable: String? = nil, remoteStorage: URL? = nil) {
        self.workerExecutable = workerExecutable ?? Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent("sputnik-notebook-worker").path
        self.remote = NotebookRemoteController(executable: remoteExecutable, storage: remoteStorage)
        remote.onError = { [weak self] in self?.error = $0 }
        remote.onExternal = { [weak self] enabled in
            guard let self else { return }
            self.livePollGeneration &+= 1; self.liveCells = [:]
            self.executingCells = [:]
            self.retainedResults = [:]; self.suppressedResults = []; self.observedResetEpochs = []
            self.remoteResultRuns = [:]; self.invalidatedResults = []
            self.worker.setExternal(enabled)
        }
        remote.onChange = { [weak self] in self?.remoteChanged() }
        remote.onResultReset = { [weak self] sheet in self?.discardResults(in: "sheet:" + sheet) }
        remote.focusedSheet = { [weak self] in
            guard let self, let tab = self.activeBoard.flatMap({ self.controller(for: $0) }) ?? self.activeTab, tab.kind == "sheet" else { return nil }
            return String(tab.id.dropFirst(6))
        }
        remote.exportSnapshot = { [weak self] in
            guard let self else { throw CancellationError() }
            let identity = self.documentIdentity
            let edits = self.drafts.map { SourceEdit(key: $0.key, draft: $0.value) }
            return try await withCheckedThrowingContinuation { continuation in
                self.worker.export(edits: edits) { exported, state, error in
                    guard self.documentIdentity == identity, !self.closing else { continuation.resume(throwing: CancellationError()); return }
                    if let state { self.accept(state) }
                    if let exported { continuation.resume(returning: exported) }
                    else { continuation.resume(throwing: NotebookRemoteFailure(status: 0, message: error ?? "Cannot export notebook.")) }
                }
            }
        }
        remote.restoreSnapshot = { [weak self] exported in
            guard let self else { throw CancellationError() }
            let identity = self.documentIdentity
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.worker.restore(exported) { state, error in
                    guard self.documentIdentity == identity, !self.closing else { continuation.resume(throwing: CancellationError()); return }
                    if let state { self.accept(state) }
                    if let error { continuation.resume(throwing: NotebookRemoteFailure(status: 0, message: error)) }
                    else { continuation.resume() }
                }
            }
        }
        remote.importResult = { [weak self] sheet, run, document, data, stale in
            guard let self else { throw CancellationError() }
            let identity = self.documentIdentity
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.worker.remoteResult(sheet: sheet, document: document, data: data, stale: stale) { state, error in
                    guard self.documentIdentity == identity, !self.closing else { continuation.resume(throwing: CancellationError()); return }
                    if let state {
                        let latest = self.remote.runs.last { $0.sheet == sheet }?.id == run
                        self.accept(state, freshResultsFor: latest ? ["sheet:" + sheet] : [])
                        self.finishRunHistory(tab: "sheet:" + sheet, state: state, remoteID: run, remoteDocument: document)
                        if self.liveTab == "sheet:" + sheet { self.liveCells = [:] }
                    }
                    if let error { continuation.resume(throwing: NotebookRemoteFailure(status: 0, message: error)) }
                    else { continuation.resume() }
                }
            }
        }
        remote.importCellInputs = { [weak self] values in
            guard let self else { throw CancellationError() }
            let identity = self.documentIdentity
            for tab in self.snapshot?.tabs ?? [] where tab.kind == "sheet" {
                for cell in tab.cells {
                    var edits: [String: String] = [:]
                    for input in cell.cell_inputs ?? [] {
                        if let value = values[cell.id + ":" + input.id], value != input.value_json { edits[input.id] = value }
                    }
                    guard !edits.isEmpty else { continue }
                    let text = String(decoding: try JSONEncoder().encode(edits), as: UTF8.self)
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        self.worker.execute(edits: [], action: "set_cell_inputs", tab: tab.id, cell: cell.id, text: text) { state, failure in
                            guard self.documentIdentity == identity, self.remote.isSelected else { continuation.resume(throwing: CancellationError()); return }
                            if let state { self.accept(state) }
                            if let failure { continuation.resume(throwing: NotebookRemoteFailure(status: 422, message: failure)) }
                            else { continuation.resume() }
                        }
                    }
                }
            }
        }
        remote.importLive = { [weak self] sheet, data in
            guard let self else { throw CancellationError() }
            let identity = self.documentIdentity, generation = self.livePollGeneration
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.worker.remoteLive(data) { state, error in
                    guard self.documentIdentity == identity, generation == self.livePollGeneration, !self.closing else { continuation.resume(throwing: CancellationError()); return }
                    if let state, self.remote.runs.contains(where: { $0.sheet == sheet && $0.active }) {
                        self.liveTab = "sheet:" + sheet
                        if state.telemetry_updated == true, let telemetry = state.telemetry { self.runtimeTelemetry["sheet:" + sheet] = telemetry; self.runtimeSampleDates["sheet:" + sheet] = Date() }
                        self.liveCells = Dictionary(uniqueKeysWithValues: state.cells.map { ($0.id, $0) })
                        self.liveReceived = Dictionary(uniqueKeysWithValues: state.cells.map { ($0.id, ProcessInfo.processInfo.systemUptime) })
                        for cell in state.cells where cell.audio_controls_updated == true { self.audioSession.apply(cell.audio_controls ?? [], tab: "sheet:" + sheet) }
                        self.updateExecutingCell(state.executing_cell, tab: "sheet:" + sheet)
                    }
                    if let error { continuation.resume(throwing: NotebookRemoteFailure(status: 0, message: error)) }
                    else { continuation.resume() }
                }
            }
        }
    }
    private func remoteChanged() {
        if remote.isSelected {
            periodicTimer?.invalidate(); periodicTimer = nil
            for key in periodicStates.keys { periodicStates[key]?.pause() }
            executionTimer?.invalidate(); executionTimer = nil
            if executingWorker && !remote.active { freezeLiveTiming() }
            executingWorker = remote.active
            let activeTabs = Set(remote.runs.filter(\.active).map { "sheet:" + $0.sheet })
            executingCells = executingCells.filter { activeTabs.contains($0.key) }
            for run in remote.runs where run.active { updateExecutingCell(run.executingCell, tab: "sheet:" + run.sheet) }
            let latestRuns = Dictionary(remote.runs.map { ($0.sheet, $0) }, uniquingKeysWith: { _, latest in latest })
            for run in latestRuns.values where remoteResultRuns[run.sheet] != run.id {
                remoteResultRuns[run.sheet] = run.id
                for cell in snapshot?.tabs.first(where: { $0.id == "sheet:" + run.sheet })?.cells ?? [] {
                    invalidatedResults.insert(SourceKey(tab: "sheet:" + run.sheet, cell: cell.id))
                }
            }
            for runtime in remote.runtimes {
                if let epoch = runtime["epoch"] as? String, let sheet = runtime["sheet_id"] as? String,
                   remote.resetEpochs.contains(epoch),
                   observedResetEpochs.insert(epoch).inserted { discardResults(in: "sheet:" + sheet) }
            }
            let state = remote.runs.last(where: { $0.active })?.state
            executionPhase = ["preparing": 1, "running": 2, "draining": 3, "stopping": 4, "terminating": 5][state ?? ""] ?? 0
        } else if !busy { executingWorker = false; executionPhase = 0 }
        objectWillChange.send()
    }
    var isolatedExecution: Bool { remote.isSelected || workerExecutable != nil || worker.isolated }
    @Published private(set) var actionSignatures: [String: Data] = [:]
    @Published private(set) var componentUpdatedAt: [String: Date] = [:]
    @Published private(set) var executingTargetID: String?
    @Published private(set) var executionStarted: Date?
    @Published private(set) var executingWorker = false
    @Published private(set) var workerLastContact: Date? = nil
    @Published private(set) var runtimeTelemetry: [String: NotebookRuntimeTelemetry] = [:]
    @Published private(set) var runtimeSampleDates: [String: Date] = [:]
    @Published private(set) var executionPhase = 0
    @Published private(set) var executingCells: [String: String] = [:]
    @Published private(set) var cellNavigation: NotebookCellNavigation?
    @Published private var selectedTabID: String?
    private var navigationRevision = 0
    private var executionTimer: Timer?
    @Published private(set) var liveCells: [String: NotebookLiveCell] = [:]
    private var liveTab = ""
    private var liveReceived: [String: TimeInterval] = [:]
    private var nativeTrusted = false
    private var livePollPending = false
    private var livePollGeneration = 0
    func liveCell(_ cell: NotebookCell, in tab: NotebookTab) -> NotebookLiveCell? {
        liveTab == tab.id ? liveCells[cell.id] : nil
    }
    private func pollLive() {
        guard !livePollPending else { return }
        livePollPending = true
        let generation = livePollGeneration
        worker.takeLive { [weak self] state in
            guard let self else { return }
            self.livePollPending = false
            guard generation == self.livePollGeneration, let state else { return }
            self.workerLastContact = Date()
            let owner = state.tab
            if let owner, !owner.isEmpty, owner != self.liveTab {
                self.liveTab = owner
                self.liveCells = [:]
            }
            if state.telemetry_updated == true, let telemetry = state.telemetry { self.runtimeTelemetry[owner ?? self.liveTab] = telemetry; self.runtimeSampleDates[owner ?? self.liveTab] = Date() }
            if self.executingWorker { self.updateExecutingCell(state.executing_cell, tab: owner ?? self.liveTab) }
            for var cell in state.cells {
                if cell.audio_controls_updated == true { self.audioSession.apply(cell.audio_controls ?? [], tab: owner ?? self.liveTab) }
                if let old = self.liveCells[cell.id] {
                    if cell.stopwatches_updated == false {
                        cell.stopwatches = old.stopwatches
                        cell.stopwatches_updated = old.stopwatches_updated
                    }
                    if cell.elapsed_ms == nil { cell.elapsed_ms = old.elapsed_ms; cell.timing_running = old.timing_running }
                    if cell.output_updated == false { cell.output = old.output; cell.output_updated = old.output_updated }
                    if cell.displays_updated == false { cell.displays = old.displays }
                    if cell.progress_updated == false { cell.progress = old.progress }
                    if cell.audio_updated == false { cell.audio = old.audio; cell.audio_updated = old.audio_updated }
                    else if cell.audio_reset != true {
                        cell.audio = NotebookAudioStream.merge(old.audio ?? [], cell.audio ?? [])
                    }
                    if cell.images_updated == false {
                        cell.images = old.images
                        cell.images_updated = old.images_updated
                    }
                    if cell.charts_updated == false {
                        cell.charts = old.charts
                        cell.charts_updated = old.charts_updated
                    } else if cell.charts_reset != true && !cell.charts.isEmpty {
                        cell.charts = self.mergeLiveCharts(old.charts, cell.charts)
                    }
                }
                self.liveCells[cell.id] = cell
                self.liveReceived[cell.id] = ProcessInfo.processInfo.systemUptime
            }
        }
    }
    func telemetry(in tab: NotebookTab) -> NotebookRuntimeTelemetry? {
        if let live = runtimeTelemetry[tab.id], live.sampled_ms > 0 { return live }
        if let saved = tab.telemetry, saved.sampled_ms > 0 { return saved }
        return nil
    }
    func output(for cell: NotebookCell, in tab: NotebookTab) -> [NotebookOutput] {
        if let live = liveCell(cell, in: tab), live.output_updated == true { return live.output ?? [] }
        return cell.output
    }
    func resourceSummary(in tab: NotebookTab) -> String {
        guard let telemetry = telemetry(in: tab) else { return "CPU / RAM / GPU: no telemetry" }
        let cpu = telemetry.cpu_percent.map { String(format: "%.1f%%", $0) } ?? "unavailable"
        let memory = telemetry.resident_bytes.map { ByteCountFormatter.string(fromByteCount: Int64(min($0, UInt64(Int64.max))), countStyle: .memory) } ?? "unavailable"
        let time = runtimeSampleDates[tab.id].map { " · " + $0.formatted(date: .omitted, time: .standard) } ?? " · last run"
        return "Worker CPU: " + cpu + " · RAM: " + memory + " · GPU: unavailable" + time
    }
    func audioInput(_ channel: String, sheet: String) -> NotebookAudioInput? {
        snapshot?.audio_inputs?.first { $0.id == channel && $0.sheet == sheet }
    }
    func editAudio(board: NotebookBoard, component: NotebookBoardComponent, data: Data, format: String, name: String, completion: @escaping (Bool) -> Void) {
        struct Edit: Encodable { let board: String, component: String, data: Data, format: String, name: String }
        do {
            let json = String(decoding: try JSONEncoder().encode(Edit(board: board.id, component: component.id, data: data, format: format, name: name)), as: UTF8.self)
            perform("audio_edit", text: json, completion: completion)
        } catch { self.error = error.localizedDescription; completion(false) }
    }
    func audioStreams(for cell: NotebookCell, in tab: NotebookTab) -> [NotebookAudioStream] {
        if let live = liveCell(cell, in: tab), live.audio_updated == true { return live.audio ?? [] }
        return cell.audio ?? []
    }
    private func mergeLiveCharts(_ previous: [NotebookLiveChart],
                                 _ updates: [NotebookLiveChart]) -> [NotebookLiveChart] {
        var charts = previous
        for update in updates {
            if let index = charts.firstIndex(where: { $0.id == update.id }) {
                if update.replace_chart {
                    charts[index] = update
                } else {
                    charts[index].points.append(contentsOf: update.points)
                    if charts[index].points.count > 65_536 {
                        charts[index].points.removeFirst(charts[index].points.count - 65_536)
                    }
                    charts[index].total_points = update.total_points
                    charts[index].replace_chart = true
                }
            } else {
                var initial = update
                initial.replace_chart = true
                charts.append(initial)
            }
        }
        return charts
    }
    var canEdit: Bool { !dependencyOperationActive && (!busy || executingWorker) }
    private func elapsed(_ milliseconds: UInt64, cellID: String, running: Bool) -> UInt64 {
        guard running, let received = liveReceived[cellID] else { return milliseconds }
        return milliseconds + UInt64(max(0, ProcessInfo.processInfo.systemUptime - received) * 1000)
    }
    func cellTiming(_ cell: NotebookCell, in tab: NotebookTab) -> NotebookElapsed? {
        if let live = liveCell(cell, in: tab), let milliseconds = live.elapsed_ms {
            let running = executingWorker && live.timing_running == true
            return NotebookElapsed(milliseconds: elapsed(milliseconds, cellID: cell.id, running: running), running: running)
        }
        return cell.elapsed_ms.map { NotebookElapsed(milliseconds: $0, running: false) }
    }
    func stopwatches(in tab: NotebookTab, channel: String) -> (items: [NotebookStopwatch], running: Bool, stale: Bool) {
        let cells = tab.cells.reversed()
        // A current measurement takes precedence over another cell's saved
        // channel, including the shared default channel during Run All.
        let ordered = cells.filter { liveCell($0, in: tab)?.stopwatches_updated == true }
            + cells.filter { liveCell($0, in: tab)?.stopwatches_updated != true }
        for cell in ordered {
            let live = liveCell(cell, in: tab)
            let source = live?.stopwatches_updated == true ? live?.stopwatches ?? [] : cell.stopwatches ?? []
            let timers = source.filter { channel.isEmpty || $0.id == channel }
            if !timers.isEmpty {
                let running = executingWorker && live != nil && timers.contains { !$0.done }
                let items = timers.map { timer in
                    NotebookStopwatch(id: timer.id, elapsed_ms: elapsed(timer.elapsed_ms, cellID: cell.id, running: running && !timer.done), done: timer.done)
                }
                return (items, running, !running && figureIsStale(for: cell, in: tab))
            }
        }
        return ([], false, false)
    }
    private func freezeLiveTiming() {
        for (id, var cell) in liveCells {
            if let milliseconds = cell.elapsed_ms { cell.elapsed_ms = elapsed(milliseconds, cellID: id, running: cell.timing_running == true) }
            cell.stopwatches = cell.stopwatches?.map { NotebookStopwatch(id: $0.id, elapsed_ms: elapsed($0.elapsed_ms, cellID: id, running: !$0.done), done: $0.done) }
            liveCells[id] = cell
            liveReceived[id] = ProcessInfo.processInfo.systemUptime
        }
    }
    var canNavigate: Bool { snapshot != nil && !closing && canEdit && editorFailures.isEmpty }
    private func updateExecutingCell(_ cell: String?, tab: String) {
        guard let cell, !tab.isEmpty else { return }
        executingCells[tab] = cell.isEmpty ? nil : cell
    }
    var executingCell: NotebookCellLocation? {
        let focused = activeBoard.flatMap { controller(for: $0) } ?? activeTab
        let tab = focused.flatMap { executingCells[$0.id] != nil ? $0.id : nil }
            ?? snapshot?.tabs.first(where: { executingCells[$0.id] != nil })?.id
        guard let tab, let cell = executingCells[tab],
              snapshot?.tabs.first(where: { $0.id == tab })?.cells.contains(where: { $0.id == cell }) == true else { return nil }
        return NotebookCellLocation(tab: tab, cell: cell)
    }
    var executingCellLabel: String? {
        guard let location = executingCell, let tab = snapshot?.tabs.first(where: { $0.id == location.tab }) else { return nil }
        return "\(tab.title) · \(tab.cellLabel(for: location.cell))"
    }
    func showExecutingCell() {
        guard canNavigate, let location = executingCell,
              let tab = snapshot?.tabs.first(where: { $0.id == location.tab }) else { return }
        selectTab(tab)
        selectedCellID = location.cell
        cellNavigation = NotebookCellNavigation(location: location)
    }
    private var currentRemoteRun: NotebookRemoteRun? {
        guard let sheet = remote.focusedSheet?() else { return nil }
        return remote.runs.last { $0.sheet == sheet && $0.active }
    }
    var executingCurrentWorker: Bool { remote.isSelected ? currentRemoteRun != nil : executingWorker }
    var canStop: Bool {
        if remote.isSelected { return remote.connected && currentRemoteRun.map { $0.state != "terminating" } == true }
        return executingWorker && executionPhase > 0 && executionPhase < 5
    }
    var canForceStop: Bool {
        if remote.isSelected { return remote.connected && currentRemoteRun != nil }
        return executingWorker && executionPhase > 0
    }
    var executionLabel: String {
        if remote.isSelected, let tab = activeBoard.flatMap({ controller(for: $0) }) ?? activeTab,
           remote.runtimes.contains(where: { $0["sheet_id"] as? String == String(tab.id.dropFirst(6)) && $0["needs_restart"] as? Bool == true }) {
            return "Restart required"
        }
        if remote.isSelected {
            return ["preparing": "Preparing worker", "running": "Running", "draining": "Waiting for child tasks",
                    "stopping": "Stopping…", "terminating": "Terminating worker…"][currentRemoteRun?.state ?? ""] ?? "Ready"
        }
        switch executionPhase {
        case 1: return "Preparing worker"
        case 2: return "Running"
        case 3: return "Waiting for child tasks"
        case 4: return "Stopping…"
        case 5: return "Terminating worker…"
        default: return "Ready"
        }
    }
    func stopExecution(force: Bool = false) {
        for key in pendingRunHistory.keys { pendingRunHistory[key]?.cancelled = true }
        if remote.isSelected {
            let tab = activeBoard.flatMap { controller(for: $0) } ?? activeTab
            if let tab { remote.stop(sheet: String(tab.id.dropFirst(6)), force: force) }
            return
        }
        guard executingWorker else { return }
        if let key = executingPeriodicKey { periodicStates[key]?.pause() }
        if !worker.stop(force: force) { error = "Execution has already finished, or the stop request could not be delivered." }
        executionPhase = worker.phase
    }
    private func trackExecution(_ active: Bool) {
        executionTimer?.invalidate(); executionTimer = nil
        if executingWorker && !active { freezeLiveTiming() }
        executingWorker = active; executionPhase = active ? 1 : 0
        guard active else { executingCells = [:]; worker.finishExecution(); return }
        worker.prepareExecution()
        livePollGeneration += 1
        liveCells = [:]
        executingCells = [:]
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.executionPhase = self.worker.phase
            self.pollLive()
        }
        executionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    @Published var snapshot: NotebookSnapshot?
    @Published var busy = false
    @Published var dependencyOperationActive = false
    func pauseForDependencyChanges() {
        for key in periodicStates.keys { periodicStates[key]?.pause() }
    }
    @Published var error: String?
    @Published var selectedCellID = ""
    @Published var selectedBoardID: String?
    @Published private(set) var periodicStates: [String: NotebookPeriodicState] = [:]
    var periodicBoardVisible: String?
    private var periodicTimer: Timer?
    private var watchTimer: Timer?
    private var watchPollPending = false
    private func scheduleWatchPolling() {
        guard watchTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.pollWatch() }
        watchTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private var canPollWatch: Bool {
        snapshot != nil && !busy && !dependencyOperationActive && !closing && !remote.isSelected &&
            editorFailures.isEmpty && !drafts.values.contains { $0.formatting == nil }
    }
    private func pollWatch() {
        guard canPollWatch, !watchPollPending else { return }
        watchPollPending = true
        let document = documentIdentity
        worker.pendingWatch { [weak self] owner, error in
            guard let self else { return }
            self.watchPollPending = false
            guard document == self.documentIdentity, self.canPollWatch else { return }
            if let error { self.error = error; return }
            if let tab = self.snapshot?.tabs.first(where: { $0.id == owner }) {
                self.perform("watch_run", tab: tab)
            }
        }
    }
    private var executingPeriodicKey: String?
    var boardEditorOpen = false
    @Published private(set) var documentIdentity = UUID()
    @Published private var draftVersion = 0
    var requestNew: (() -> Void)?
    var requestOpen: (() -> Void)?
    var requestDependency: (() -> Void)?
    var onChange: (() -> Void)?
    private var drafts: [SourceKey: SourceDraft] = [:]
    private var retainedResults: [SourceKey: NotebookCellResult] = [:]
    private var suppressedResults = Set<SourceKey>()
    private var observedResetEpochs = Set<String>()
    private var remoteResultRuns: [String: String] = [:]
    private var invalidatedResults = Set<SourceKey>()
    var retainCellResults: Bool { snapshot?.retain_cell_results ?? true }
    func setRetainCellResults(_ enabled: Bool, completion: ((Bool) -> Void)? = nil) {
        perform("retain_cell_results", text: enabled ? "on" : "off", completion: completion)
    }
    private func discardResults(in tabID: String) {
        retainedResults = retainedResults.filter { $0.key.tab != tabID }
        for cell in snapshot?.tabs.first(where: { $0.id == tabID })?.cells ?? [] {
            suppressedResults.insert(SourceKey(tab: tabID, cell: cell.id))
        }
        objectWillChange.send()
    }
    private func reconcileResults(_ state: NotebookSnapshot, freshTabs: Set<String>) {
        let keys = Set(state.tabs.flatMap { tab in tab.cells.map { SourceKey(tab: tab.id, cell: $0.id) } })
        retainedResults = retainedResults.filter { keys.contains($0.key) }
        suppressedResults.formIntersection(keys)
        invalidatedResults.formIntersection(keys)
        if !retainCellResults { retainedResults = [:] }
        for tab in state.tabs {
            for cell in tab.cells where cell.ok {
                let key = SourceKey(tab: tab.id, cell: cell.id)
                let hasResult = !cell.result.isEmpty && cell.result != "not evaluated"
                if freshTabs.contains(tab.id) && !cell.dirty && !tab.environment_stale {
                    suppressedResults.remove(key)
                    invalidatedResults.remove(key)
                    if !hasResult { retainedResults.removeValue(forKey: key) }
                }
                guard hasResult else { continue }
                if retainCellResults && !suppressedResults.contains(key) {
                    retainedResults[key] = NotebookCellResult(text: cell.result, format: cell.result_format)
                }
            }
        }
    }
    // A native rich editor can contain a buffer that the portable format
    // cannot represent. Keep it protected even before it becomes a draft.
    private var editorFailures: [SourceKey: String] = [:]
    private var closing = false
    private var closeCompletions: [() -> Void] = []
    private lazy var worker = NotebookWorker(executable: workerExecutable,
        settingsURL: remote.storage.appendingPathComponent("local-worker-grants.json"))

    @MainActor func workerSettings(for tab: NotebookTab) async throws -> NotebookWorkerSettings {
        if remote.isSelected {
            guard tab.kind == "sheet" else { throw NotebookFailure(message: "Remote worker settings require a sheet.") }
            return try await remote.workerSettings(sheet: String(tab.id.dropFirst(6)))
        }
        let text = await withCheckedContinuation { continuation in worker.grants(tab: tab.id) { continuation.resume(returning: $0) } }
        let directory = await withCheckedContinuation { continuation in worker.grants(tab: "@environment:" + tab.id) { continuation.resume(returning: $0) } }
        return NotebookWorkerSettings(environment_directory: directory, grants: text.isEmpty ? [] : text.components(separatedBy: "\n"), version: "", runtime_epoch: nil)
    }
    @MainActor func configureWorker(_ tab: NotebookTab, text: String, environmentDirectory: String? = nil, settings: NotebookWorkerSettings) async throws {
        let normalized = try normalizedWorkerGrants(text)
        let directory = environmentDirectory ?? settings.environment_directory ?? ""
        if remote.isSelected {
            guard tab.kind == "sheet" else { throw NotebookFailure(message: "Remote worker settings require a sheet.") }
            try await remote.configureWorker(sheet: String(tab.id.dropFirst(6)),
                grants: normalized.isEmpty ? [] : normalized.components(separatedBy: "\n"), environmentDirectory: directory, settings: settings)
        } else {
            let environmentSaved = await withCheckedContinuation { continuation in
                perform("worker_environment", tab: tab, text: directory) { continuation.resume(returning: $0) }
            }
            if !environmentSaved { throw NotebookFailure(message: error ?? "Could not update worker environment.") }
            let success = await withCheckedContinuation { continuation in
                perform("worker_grants", tab: tab, text: normalized) { continuation.resume(returning: $0) }
            }
            if !success { throw NotebookFailure(message: error ?? "Could not update worker settings.") }
            for board in snapshot?.boards ?? [] where "sheet:" + board.sheet == tab.id {
                for service in board.services { periodicStates[board.id + ":" + service.id]?.pause() }
            }
        }
    }

    var activeTab: NotebookTab? { snapshot?.tabs.first { $0.id == (selectedTabID ?? snapshot?.selected_tab) } }
    var activeBoard: NotebookBoard? { snapshot?.boards?.first { $0.id == selectedBoardID } }
    func controller(for board: NotebookBoard) -> NotebookTab? {
        snapshot?.tabs.first { $0.id == "sheet:" + board.sheet }
    }
    func liveChart(_ id: String, in tab: NotebookTab) -> NotebookLiveChart? {
        chartSource(id, in: tab)?.chart
    }
    func liveChartIsStale(_ id: String, in tab: NotebookTab) -> Bool {
        guard let source = chartSource(id, in: tab) else { return false }
        return source.live && executingWorker ? false : figureIsStale(for: source.cell, in: tab)
    }
    private func chartSource(_ id: String, in tab: NotebookTab) -> (chart: NotebookLiveChart, cell: NotebookCell, live: Bool)? {
        for cell in tab.cells.reversed() {
            if liveTab == tab.id, let live = liveCells[cell.id], live.charts_updated == true {
                if let chart = live.charts.first(where: { $0.id == id }) { return (chart, cell, true) }
                continue
            }
            if let chart = cell.charts?.first(where: { $0.id == id }) { return (chart, cell, false) }
        }
        return nil
    }
    func imageSeries(_ id: String, in tab: NotebookTab) -> NotebookImageSeries? {
        if let source = imageSource(id, in: tab) { return source.series }
        guard let input = imageInput(id, in: tab) else { return nil }
        return NotebookImageSeries(id: id, caption: input.caption, images: input.images)
    }
    private func imageInput(_ id: String, in tab: NotebookTab) -> NotebookImageInput? {
        snapshot?.image_inputs?.first { "sheet:" + $0.sheet == tab.id && $0.id == id }
    }
    func imageSelection(_ id: String, in tab: NotebookTab) -> Int { imageInput(id, in: tab)?.selected ?? 0 }
    func selectImage(_ index: Int, channel: String, tab: NotebookTab) {
        perform("image_select", tab: tab, text: String(index), commandCellID: channel)
    }
    func editImages(_ images: [NotebookFigurePanel], caption: String, selected: Int, board: NotebookBoard, component: NotebookBoardComponent,
                    completion: ((Bool) -> Void)? = nil) {
        struct Edit: Encodable {
            let board: String, component: String, caption: String, selected: Int, images: [NotebookFigurePanel]
        }
        do {
            let data = try JSONEncoder().encode(Edit(board: board.id, component: component.id, caption: caption,
                                                    selected: selected, images: images))
            perform("image_edit", text: String(decoding: data, as: UTF8.self)) { completion?($0) }
        } catch { self.error = error.localizedDescription; completion?(false) }
    }
    func imageSeriesIsStale(_ id: String, in tab: NotebookTab) -> Bool {
        guard let source = imageSource(id, in: tab) else { return false }
        return source.live && executingWorker ? false : figureIsStale(for: source.cell, in: tab)
    }
    private func imageSource(_ id: String, in tab: NotebookTab) -> (series: NotebookImageSeries, cell: NotebookCell, live: Bool)? {
        for cell in tab.cells.reversed() {
            if liveTab == tab.id, let live = liveCells[cell.id], live.images_updated == true {
                if let series = live.images?.first(where: { $0.id == id }) { return (series, cell, true) }
                continue
            }
            if let series = cell.images?.first(where: { $0.id == id }) { return (series, cell, false) }
        }
        return nil
    }
    func boardProgress(in tab: NotebookTab) -> [NotebookProgress] {
        var progress: [NotebookProgress] = []
        for cell in tab.cells {
            for item in liveCell(cell, in: tab)?.progress ?? cell.progress ?? [] {
                if let index = progress.firstIndex(where: { $0.id == item.id }) { progress[index] = item }
                else { progress.append(item) }
            }
        }
        return progress
    }
    func presentation(for cell: NotebookCell, in tab: NotebookTab) -> NotebookCellPresentation {
        let live = liveCell(cell, in: tab)
        let stale = figureIsStale(for: cell, in: tab)
        let pending = executingWorker && (executingTargetID == tab.id || executingCells[tab.id] != nil ||
            (remote.isSelected && remote.runs.contains { $0.active && "sheet:" + $0.sheet == tab.id }))
        let key = SourceKey(tab: tab.id, cell: cell.id)
        var result: NotebookCellResult?
        if !suppressedResults.contains(key) && !invalidatedResults.contains(key) && cell.ok && !cell.result.isEmpty && cell.result != "not evaluated" && !stale && !pending {
            result = NotebookCellResult(text: cell.result, format: cell.result_format)
        } else if retainCellResults, var previous = retainedResults[key] {
            previous.previous = true
            result = previous
        } else if retainCellResults && !suppressedResults.contains(key) && cell.ok && !cell.result.isEmpty && cell.result != "not evaluated" {
            result = NotebookCellResult(text: cell.result, format: cell.result_format, previous: true)
        }
        return NotebookCellPresentation(cell: cell, stale: stale,
            running: executingWorker && live != nil,
            result: result,
            progress: live?.progress ?? cell.progress ?? [],
            figures: (live?.displays.isEmpty == false ? live?.displays : cell.displays) ?? [])
    }
    /// Progress belongs to its publishing cell, not the first cell in the
    /// invocation. Only an unambiguous published source is safe to preselect.
    func suggestedProgressCell(in tab: NotebookTab) -> NotebookCell? {
        let providers = tab.cells.filter { $0.kind == "code" && !presentation(for: $0, in: tab).progress.isEmpty }
        return providers.count == 1 ? providers.first : nil
    }
    func selectBoard(_ board: NotebookBoard) {
        guard canNavigate else { return }
        navigationRevision &+= 1
        selectedBoardID = board.id
    }
    func setProjectInput(_ input: NotebookProjectInput, text: String) {
        do {
            perform("set_input", text: try NotebookProjectInput.valueJSON(text, type: input.type),
                    commandCellID: input.id)
        } catch { self.error = error.localizedDescription }
    }
    func deleteProjectInput(_ input: NotebookProjectInput, completion: @escaping (Bool) -> Void) {
        perform("delete_input", commandCellID: input.id, completion: completion)
    }
    var nextSheetTitle: String {
        let titles = snapshot?.tabs.filter { $0.kind == "sheet" }.map(\.title) ?? []
        return "Sheet \(NotebookDefaultName.nextNumber(prefix: "Sheet", titles: titles))"
    }
    var nextSheetIdentifier: String {
        let titles = snapshot?.tabs.filter { $0.kind == "sheet" }.map(\.title) ?? []
        var number = NotebookDefaultName.nextNumber(prefix: "Sheet", titles: titles)
        let ids = Set(snapshot?.tabs.map(\.id) ?? [])
        while ids.contains("sheet:sheet_\(number)") { number += 1 }
        return "sheet_\(number)"
    }
    func setProjectInputs(_ values: [String: String], completion: @escaping (Bool) -> Void) {
        do {
            let data = try JSONEncoder().encode(values)
            perform("set_inputs", text: String(decoding: data, as: UTF8.self), completion: completion)
        } catch { self.error = error.localizedDescription; completion(false) }
    }
    func setCellInputs(_ values: [String: String], cell: NotebookCell, tab: NotebookTab, completion: @escaping (Bool) -> Void) {
        do {
            let data = try JSONEncoder().encode(values)
            perform("set_cell_inputs", tab: tab, cell: cell, text: String(decoding: data, as: UTF8.self), completion: completion)
        } catch { self.error = error.localizedDescription; completion(false) }
    }
    func saveCellUI(_ ui: NotebookCellUI, cell: NotebookCell, tab: NotebookTab, completion: @escaping (Bool) -> Void) {
        do {
            let data = try JSONEncoder().encode(ui)
            perform("save_cell_ui", tab: tab, cell: cell, text: String(decoding: data, as: UTF8.self), completion: completion)
        } catch { self.error = error.localizedDescription; completion(false) }
    }
    func cellChart(_ channel: String, cell: NotebookCell, tab: NotebookTab) -> NotebookLiveChart? {
        if let live = liveCell(cell, in: tab), live.charts_updated == true { return live.charts.first { $0.id == channel } }
        return cell.charts?.first { $0.id == channel }
    }
    func cellImages(_ channel: String, cell: NotebookCell, tab: NotebookTab) -> NotebookImageSeries? {
        if let live = liveCell(cell, in: tab), live.images_updated == true { return live.images?.first { $0.id == channel } }
        return cell.images?.first { $0.id == channel }
    }
    func saveBoard(_ board: NotebookBoard, completion: @escaping (Bool) -> Void) {
        do {
            let json = String(decoding: try JSONEncoder().encode(board.rowLayout), as: UTF8.self)
            perform("save_board", text: json) { [weak self] success in
                if success { self?.selectedBoardID = board.id }
                completion(success)
            }
        } catch { self.error = error.localizedDescription; completion(false) }
    }

    func periodicState(board: NotebookBoard, component: NotebookBoardComponent) -> NotebookPeriodicState {
        periodicStates[board.id + ":" + component.id] ?? NotebookPeriodicState(settings: component.periodicSettings)
    }
    func startPeriodic(board: NotebookBoard, component: NotebookBoardComponent) {
        guard !busy, !closing else { return }
        if let message = component.periodicSettings.validationError { error = message; return }
        guard !(snapshot?.tabs.contains { $0.kind == "module" && isModified($0) } ?? false) else {
            error = "Save modified module tabs before starting Periodic Work."; return
        }
        guard authorizeExecution() else { return }
        let key = board.id + ":" + component.id
        var state = periodicState(board: board, component: component)
        state.start(at: ProcessInfo.processInfo.systemUptime)
        periodicStates[key] = state
        schedulePeriodic()
    }
    func pausePeriodic(board: NotebookBoard, component: NotebookBoardComponent) {
        let key = board.id + ":" + component.id
        periodicStates[key]?.pause()
        schedulePeriodic()
    }
    func runPeriodicOnce(board: NotebookBoard, component: NotebookBoardComponent) {
        guard !busy, !closing, component.periodicSettings.validationError == nil else { return }
        guard !(snapshot?.tabs.contains { $0.kind == "module" && isModified($0) } ?? false) else {
            error = "Save modified module tabs before running Periodic Work."; return
        }
        guard authorizeExecution() else { return }
        let key = board.id + ":" + component.id
        if periodicStates[key] == nil { periodicStates[key] = NotebookPeriodicState(settings: component.periodicSettings) }
        invokePeriodic(board: board, component: component, explicit: true)
    }
    func clearPeriodicHistory(board: NotebookBoard, component: NotebookBoardComponent) {
        periodicStates[board.id + ":" + component.id]?.history.removeAll()
    }
    private func reconcilePeriodic() {
        let components = (snapshot?.boards ?? []).flatMap { board in
            board.services.map { (board.id + ":" + $0.id, $0.periodicSettings) }
        }
        let settings = Dictionary(uniqueKeysWithValues: components)
        periodicStates = periodicStates.filter { settings[$0.key] != nil }
        for (key, state) in periodicStates where settings[key] != state.settings {
            var updated = state
            updated.pause(); updated.settings = settings[key]!
            updated.history = updated.history.filter { $0.ok ? updated.settings.storeValues : updated.settings.storeErrors }
            if updated.settings.retention == "none" { updated.history.removeAll() }
            else if updated.settings.retention == "tail" && updated.history.count > updated.settings.tailLimit {
                updated.history.removeFirst(updated.history.count - updated.settings.tailLimit)
            }
            updated.status = "Settings changed · Start to resume"
            periodicStates[key] = updated
        }
    }
    private func schedulePeriodic() {
        periodicTimer?.invalidate(); periodicTimer = nil
        guard !closing, periodicStates.values.contains(where: \.enabled) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let deadline = periodicStates.values.filter { $0.enabled && !$0.running }.compactMap(\.nextDeadline).min()
        let delay = max(0.01, min(0.25, (deadline ?? now + 0.25) - now))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.tickPeriodic() }
        RunLoop.main.add(timer, forMode: .common); periodicTimer = timer
    }
    private func tickPeriodic() {
        let now = ProcessInfo.processInfo.systemUptime
        let keys = periodicStates.keys.sorted {
            let left = periodicStates[$0]?.nextDeadline ?? .infinity
            let right = periodicStates[$1]?.nextDeadline ?? .infinity
            return left == right ? $0 < $1 : left < right
        }
        for key in keys {
            guard var state = periodicStates[key], state.enabled, !state.running,
                  let board = snapshot?.boards?.first(where: { key.hasPrefix($0.id + ":") }),
                  let component = board.services.first(where: { key == board.id + ":" + $0.id }) else { continue }
            if (state.settings.pauseWhenHidden && periodicBoardVisible != board.id) || boardEditorOpen {
                state.nextDeadline = nil; state.status = "Waiting for board"
                periodicStates[key] = state; continue
            }
            if state.nextDeadline == nil { state.nextDeadline = now + state.settings.period; state.status = "Waiting" }
            if snapshot?.tabs.contains(where: { $0.kind == "module" && isModified($0) }) == true {
                state.pause(); state.status = "Modules changed · Start after saving"
                periodicStates[key] = state; continue
            }
            guard let deadline = state.nextDeadline, deadline <= now else { periodicStates[key] = state; continue }
            if busy || drafts.values.contains(where: { $0.formatting == nil }) || !editorFailures.isEmpty {
                state.skipBusyTicks(at: now); periodicStates[key] = state; continue
            }
            periodicStates[key] = state
            invokePeriodic(board: board, component: component, explicit: state.needsExplicitRun)
            break
        }
        schedulePeriodic()
    }
    private func invokePeriodic(board: NotebookBoard, component: NotebookBoardComponent, explicit: Bool) {
        let key = board.id + ":" + component.id
        guard var state = periodicStates[key], !state.running, let tab = controller(for: board) else { return }
        state.running = true; state.needsExplicitRun = false; state.status = "Running"
        periodicStates[key] = state; executingPeriodicKey = key
        let start = ProcessInfo.processInfo.systemUptime, date = Date()
        perform(explicit ? "periodic_run" : "periodic_tick", tab: tab, text: board.id, commandCellID: component.id) { [weak self] success in
            guard let self else { return }
            self.executingPeriodicKey = nil
            guard var state = self.periodicStates[key] else { self.schedulePeriodic(); return }
            let result = self.snapshot?.periodic_results?.first { $0.id == key }
            let ok = success && result?.ok == true
            state.complete(start: start, end: ProcessInfo.processInfo.systemUptime, date: date, ok: ok,
                value: result?.result ?? "", error: success ? result?.error ?? "No execution result" : self.error ?? "Execution failed")
            // Configuration/module/worker failures require explicit recovery.
            if !success { state.pause(); state.status = "Execution failed · Start to retry" }
            self.periodicStates[key] = state
            self.schedulePeriodic()
        }
    }
    var selectedCell: NotebookCell? {
        activeTab?.cells.first { $0.id == selectedCellID } ?? activeTab?.cells.first
    }
    var hasUnsavedChanges: Bool { !drafts.isEmpty || !editorFailures.isEmpty || (snapshot?.modified_count ?? 0) != 0 }
    func isModified(_ tab: NotebookTab) -> Bool {
        tab.modified || drafts.keys.contains { $0.tab == tab.id } || editorFailures.keys.contains { $0.tab == tab.id }
    }
    func source(for cell: NotebookCell, in tab: NotebookTab) -> String {
        drafts[SourceKey(tab: tab.id, cell: cell.id)]?.source ?? cell.source
    }

    // Return the values that a text block may interpolate. Values are
    // collected in source order: a later successful module cell shadows an
    // earlier one, and a later stale/uninitialized provider must shadow it as
    // well so that an old value is never exposed as current by accident.
    func textVariables(before cell: NotebookCell,
                       in tab: NotebookTab) -> [NotebookTextVariable] {
        guard let targetIndex = tab.cells.firstIndex(where: { $0.id == cell.id }) else {
            return []
        }
        return textVariables(in: tab, beforeIndex: targetIndex)
    }

    /// Board-owned text is after the controller's code, rather than after a
    /// synthetic sheet cell. Both hosts use the same name/staleness resolver.
    func textVariables(in tab: NotebookTab) -> [NotebookTextVariable] {
        textVariables(in: tab, beforeIndex: tab.cells.count)
    }

    private func textVariables(in tab: NotebookTab, beforeIndex targetIndex: Int) -> [NotebookTextVariable] {
        var hasStalePredecessor = tab.environment_stale
        var variables: [String: NotebookTextVariable] = [:]

        for index in tab.cells.indices where index < targetIndex {
            let predecessor = tab.cells[index]
            guard predecessor.kind == "code" else { continue }
            let cellNumber = tab.cellNumber(for: predecessor.id)

            // Any code edit, failed evaluation, or dirty snapshot before the
            // text block can invalidate values from the runtime. Keep them
            // visible for the picker, but label every result stale.
            if predecessor.dirty || !predecessor.ok {
                hasStalePredecessor = true
            }
            let hasDraft = drafts.keys.contains {
                $0.tab == tab.id && $0.cell == predecessor.id
            }
            if hasDraft { hasStalePredecessor = true }

            // The bridge uses module_cell for notebook assignments. Imports,
            // reads, synthetic temporaries, and unknown roles are not user
            // bindings and must not leak into interpolation suggestions.
            for local in predecessor.locals where local.role == "module_cell" && !local.name.isEmpty {
                let value: String
                let localIsStale: Bool
                if local.initialized {
                    value = local.text_value ?? local.value
                    localIsStale = hasStalePredecessor
                } else {
                    value = local.text_value ?? "<unavailable>"
                    localIsStale = true
                }
                variables[local.name] = NotebookTextVariable(
                    name: local.name,
                    value: value,
                    cellID: predecessor.id,
                    stale: localIsStale,
                    cellNumber: cellNumber
                )
            }
        }

        return variables.values.sorted { $0.name < $1.name }
            .map { variable in
                guard hasStalePredecessor, !variable.stale else { return variable }
                return NotebookTextVariable(name: variable.name,
                                            value: variable.value,
                                            cellID: variable.cellID,
                                            stale: true,
                                            cellNumber: variable.cellNumber)
            }
    }

    func figureIsStale(for cell: NotebookCell, in tab: NotebookTab) -> Bool {
        guard !tab.environment_stale,
              let index = tab.cells.firstIndex(where: { $0.id == cell.id }) else { return true }
        // Until the edited source is compiled, the UI has no new dependency
        // graph. Conservatively stale retained figures after any code edit or
        // failure at/before their cell, just like text interpolation values.
        return tab.cells.prefix(index + 1).contains { predecessor in
            predecessor.kind == "code" &&
                (predecessor.dirty || !predecessor.ok ||
                 drafts[SourceKey(tab: tab.id, cell: predecessor.id)] != nil)
        }
    }

    func formatting(for cell: NotebookCell, in tab: NotebookTab) -> String {
        drafts[SourceKey(tab: tab.id, cell: cell.id)]?.formatting ?? cell.formatting
    }
    private func sameFormatting(_ left: String, _ right: String) -> Bool {
        func normalized(_ value: String) -> Data? {
            let plain = "{\"version\":1,\"runs\":[]}"
            guard let object = try? JSONSerialization.jsonObject(with: Data((value.isEmpty ? plain : value).utf8)) else { return nil }
            return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        return left == right || (normalized(left) != nil && normalized(left) == normalized(right))
    }
    private func pauseForCodeDrafts() {
        worker.setPaused(drafts.values.contains { $0.formatting == nil })
    }
    func editSource(_ source: String, cell: NotebookCell, tab: NotebookTab) {
        guard canEdit else { return }
        let key = SourceKey(tab: tab.id, cell: cell.id)
        // During execution the next host snapshot contains the submitted
        // buffer, not necessarily the snapshot currently displayed. Reverting
        // to that older displayed text is still a NEW edit that must survive.
        if !executingWorker && !remote.busy && source == cell.source { drafts.removeValue(forKey: key) }
        else { drafts[key] = SourceDraft(source: source, formatting: nil) }
        draftVersion &+= 1
        pauseForCodeDrafts()
        onChange?()
        remote.edited()
    }
    func editRichText(_ source: String, formatting: String, cell: NotebookCell, tab: NotebookTab) {
        guard canEdit, cell.kind == "text" else { return }
        let key = SourceKey(tab: tab.id, cell: cell.id)
        if !executingWorker && !remote.busy && source == cell.source && sameFormatting(formatting, cell.formatting) { drafts.removeValue(forKey: key) }
        else { drafts[key] = SourceDraft(source: source, formatting: formatting) }
        draftVersion &+= 1
        // Inert text edits must not suspend live code watchers.
        pauseForCodeDrafts()
        onChange?()
        remote.edited()
    }
    func reportEditorError(_ message: String?, cell: NotebookCell, tab: NotebookTab, document: UUID) {
        guard document == documentIdentity,
              snapshot?.tabs.first(where: { $0.id == tab.id })?.cells.contains(where: { $0.id == cell.id }) == true else { return }
        let key = SourceKey(tab: tab.id, cell: cell.id)
        guard editorFailures[key] != message else { return }
        editorFailures[key] = message
        draftVersion &+= 1
        onChange?()
    }
    func selectTab(_ tab: NotebookTab) {
        guard canNavigate else { return }
        navigationRevision &+= 1
        if executingWorker {
            selectedTabID = tab.id
            selectedCellID = tab.selected_cell.isEmpty ? tab.cells.first?.id ?? "" : tab.selected_cell
            selectedBoardID = nil
            return
        }
        perform("select", tab: tab) { [weak self] success in
            if success { self?.selectedBoardID = nil }
        }
    }
    func newProject() { requestNew?() }
    func openProject() { requestOpen?() }
    func clearError() { error = nil }

    private func accept(_ state: NotebookSnapshot, freshResultsFor: Set<String> = []) {
        let oldTab = activeTab?.id
        snapshot = state
        for tab in state.tabs where freshResultsFor.contains(tab.id) {
            if let telemetry = tab.telemetry, telemetry.sampled_ms > 0 { runtimeTelemetry[tab.id] = telemetry; runtimeSampleDates[tab.id] = Date() }
        }
        if !freshResultsFor.isEmpty && !remote.isSelected { workerLastContact = Date() }
        reconcileResults(state, freshTabs: freshResultsFor)
        for tab in state.tabs where freshResultsFor.contains(tab.id) {
            for cell in tab.cells { audioSession.apply(cell.audio_controls ?? [], tab: tab.id) }
        }
        if let selectedTabID, !state.tabs.contains(where: { $0.id == selectedTabID }) { self.selectedTabID = nil }
        reconcilePeriodic()
        schedulePeriodic()
        let liveKeys = Set(state.tabs.flatMap { tab in
            tab.cells.map { SourceKey(tab: tab.id, cell: $0.id) }
        })
        // A successful deletion has already consumed the submitted draft.
        // Keeping it would make every subsequent Save target a stale CellId.
        drafts = drafts.filter { liveKeys.contains($0.key) }
        editorFailures = editorFailures.filter { liveKeys.contains($0.key) }
        for tab in state.tabs {
            for cell in tab.cells {
                let key = SourceKey(tab: tab.id, cell: cell.id)
                if let draft = drafts[key], draft.source == cell.source,
                   draft.formatting.map({ sameFormatting($0, cell.formatting) }) ?? true {
                    drafts.removeValue(forKey: key)
                }
            }
        }
        if oldTab != activeTab?.id || !(activeTab?.cells.contains { $0.id == selectedCellID } ?? false) {
            selectedCellID = activeTab?.selected_cell ?? activeTab?.cells.first?.id ?? ""
        }
        onChange?()
    }

    func open(url: URL, create: Bool = false, completion: ((Bool) -> Void)? = nil) {
        guard !busy, !dependencyOperationActive else { completion?(false); return }
        periodicTimer?.invalidate(); periodicTimer = nil
        for key in periodicStates.keys { periodicStates[key]?.pause() }
        busy = true
        error = nil
        worker.open(path: url.path, create: create, title: url.deletingPathExtension().lastPathComponent) { [weak self] state, error in
            guard let self else { return }
            self.busy = false
            if let state {
                self.nativeTrusted = false
                self.livePollGeneration &+= 1
                self.liveCells = [:]
                self.executingCells = [:]; self.cellNavigation = nil; self.selectedTabID = nil
                self.drafts.removeAll()
                self.retainedResults = [:]; self.suppressedResults = []; self.observedResetEpochs = []
                self.remoteResultRuns = [:]; self.invalidatedResults = []
                self.editorFailures.removeAll()
                self.audioSession.close()
                self.runHistory.open(project: state.path); self.pendingRunHistory = [:]; self.workerLastContact = nil; self.runtimeTelemetry = [:]; self.runtimeSampleDates = [:]
                self.documentIdentity = UUID()
                self.selectedBoardID = nil
                self.periodicStates = [:]
                self.actionSignatures = [:]; self.componentUpdatedAt = [:]; self.executingTargetID = nil; self.executionStarted = nil
                self.periodicBoardVisible = nil
                self.accept(state)
                self.scheduleWatchPolling()
                self.remote.open(url)
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            }
            self.error = error
            self.onChange?()
            completion?(state != nil)
        }
    }

    private func authorizeExecution() -> Bool {
        if snapshot?.dependencies?.contains(where: { $0.native == true }) == true && !nativeTrusted {
            guard isolatedExecution else {
                error = "This project uses native packages. Open with isolated worker execution to enable Stop and Force Stop."
                return false
            }
            if CommandLine.arguments.contains("--trust-native") {
                nativeTrusted = true // explicit automated-test/launcher authorization
            } else {
                let alert = NSAlert()
                alert.messageText = "Trust this notebook's native packages?"
                alert.informativeText = "Run will load the prepared native libraries listed by this project and allow file reads. Native code has the same access as the app. Only continue if you trust these packages. Opening a notebook never loads them."
                alert.addButton(withTitle: "Trust and Run")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return false }
                nativeTrusted = true
            }
        }
        return true
    }

    func perform(_ action: String, tab: NotebookTab? = nil, cell: NotebookCell? = nil,
                 text: String = "", commandCellID: String? = nil, completion: ((Bool) -> Void)? = nil) {
        guard !dependencyOperationActive || ["restart_worker", "worker_environment", "worker_grants"].contains(action) else { completion?(false); return }
        guard !busy, snapshot != nil else { completion?(false); return }
        guard editorFailures.isEmpty else {
            let message = editorFailures.sorted { ($0.key.tab, $0.key.cell) < ($1.key.tab, $1.key.cell) }.first!.value
            error = "A text block has an unsaved editor buffer: \(message) Undo or correct that edit before saving or changing tabs."
            completion?(false)
            return
        }
        let target = tab ?? activeTab
        let targetCell = cell ?? (action == "select" ? nil : selectedCell)
        if remote.isSelected {
            if ["run", "run_all", "restart_worker"].contains(action) {
                guard let target, target.kind == "sheet" else { error = "Remote execution requires a sheet."; completion?(false); return }
                let sheet = String(target.id.dropFirst(6))
                if action == "restart_worker" { remote.restart(sheet: sheet); completion?(true) }
                else {
                    let id = action == "run_all" ? target.cells.first(where: { $0.kind == "code" })?.id : (commandCellID ?? targetCell?.id)
                    guard let id else { error = "This sheet has no code cell."; completion?(false); return }
                    beginRunHistory(tab: target, cell: action == "run_all" ? nil : id, action: action)
                    remote.run(sheet: sheet, cell: id, all: action == "run_all") { completion?($0) }
                }
                return
            }
            if action == "set_cell_inputs" {
                guard let target, target.kind == "sheet", let targetCell else { error = "Choose a sheet cell."; completion?(false); return }
                do {
                    let values = try JSONDecoder().decode([String: String].self, from: Data(text.utf8))
                    remote.setCellInputs(sheet: String(target.id.dropFirst(6)), cell: targetCell.id, values: values) { completion?($0) }
                } catch { self.error = error.localizedDescription; completion?(false) }
                return
            }
            if ["apply", "set_input", "set_inputs", "action_run", "periodic_run", "periodic_tick"].contains(action) {
                error = "This remote core does not support Apply, project inputs or Periodic Work yet."; completion?(false); return
            }
        }
        let edits = drafts.map { SourceEdit(key: $0.key, draft: $0.value) }.sorted {
            ($0.key.tab, $0.key.cell) < ($1.key.tab, $1.key.cell)
        }
        let explicitExecution = ["run", "run_all", "apply", "action_run", "periodic_run", "periodic_tick", "watch_run"].contains(action)
        let executes = explicitExecution || (isolatedExecution && ["set_input", "set_inputs", "set_cell_inputs"].contains(action))
        if explicitExecution && !authorizeExecution() { completion?(false); return }
        let actionComponent = action == "action_run" ? snapshot?.boards?.first { $0.id == text }?.allComponents.first { $0.id == commandCellID } : nil
        let actionSignature = actionComponent.map { component in
            component.actionSignature(inputs: snapshot?.inputs ?? [], moduleSource: snapshot?.tabs.first { $0.id == "module:" + (component.module_id ?? "") }?.cells.map(\.source).joined(separator: "\n") ?? "")
        }
        if ["run", "run_all", "apply"].contains(action), let target {
            beginRunHistory(tab: target, cell: action == "run" ? (commandCellID ?? targetCell?.id) : nil, action: action)
        }
        busy = true
        error = nil
        let navigation = navigationRevision
        if executes {
            executingTargetID = action == "action_run" || action.hasPrefix("periodic_") ? text + ":" + (commandCellID ?? "") : target?.id
            executionStarted = Date()
        }
        liveTab = action == "action_run" || action.hasPrefix("periodic_") ? "" : target?.id ?? ""
        trackExecution(isolatedExecution && executes)
        worker.execute(edits: edits, action: action, tab: target?.id ?? "",
                       cell: commandCellID ?? targetCell?.id ?? "", text: text,
                       trustNative: executes && nativeTrusted) { [weak self] state, error in
            guard let self else { return }
            self.busy = false
            self.pollLive()
            if self.remote.isSelected { self.remoteChanged() } else { self.trackExecution(false) }
            let previousState = self.snapshot
            if action == "set_cell_id", let target, let targetCell, let state,
               let renamed = state.tabs.first(where: { $0.id == target.id })?.cells,
               !renamed.contains(where: { $0.id == targetCell.id }), renamed.contains(where: { $0.id == text }) {
                let old = SourceKey(tab: target.id, cell: targetCell.id), new = SourceKey(tab: target.id, cell: text)
                self.drafts[new] = self.drafts.removeValue(forKey: old)
                self.retainedResults[new] = self.retainedResults.removeValue(forKey: old)
                if self.suppressedResults.remove(old) != nil { self.suppressedResults.insert(new) }
                if self.invalidatedResults.remove(old) != nil { self.invalidatedResults.insert(new) }
                self.componentUpdatedAt[target.id + ":" + text] = self.componentUpdatedAt.removeValue(forKey: target.id + ":" + targetCell.id)
                if self.selectedCellID == targetCell.id { self.selectedCellID = text }
            }
            if error == nil && ["restart_worker", "worker_grants", "worker_environment"].contains(action), let target { self.discardResults(in: target.id) }
            if state != nil && navigation == self.navigationRevision && ["select", "new_sheet", "new_module"].contains(action) {
                self.selectedTabID = nil
                if action == "new_sheet" || action == "new_module" { self.selectedBoardID = nil }
            }
            if let state {
                let fresh: Set<String> = !executes ? [] : ["set_input", "set_inputs", "set_cell_inputs"].contains(action)
                    ? Set(state.tabs.map(\.id)) : Set([target?.id].compactMap { $0 })
                self.accept(state, freshResultsFor: fresh)
            }
            if ["run", "run_all", "apply"].contains(action), let target, let state = state ?? self.snapshot {
                self.finishRunHistory(tab: target.id, state: state, failure: error)
            }
            if executes {
                if let target, let current = self.snapshot?.tabs.first(where: { $0.id == target.id }) {
                    for cell in current.cells where cell.ok && !cell.dirty {
                        let old = previousState?.tabs.first { $0.id == current.id }?.cells.first { $0.id == cell.id }
                        if action == "run_all" || (action == "run" && cell.id == (commandCellID ?? targetCell?.id)) || old?.dirty == true || old?.result != cell.result {
                            self.componentUpdatedAt[current.id + ":" + cell.id] = Date()
                        }
                    }
                }
                if let id = self.executingTargetID {
                    self.componentUpdatedAt[id] = Date()
                    if let actionSignature { self.actionSignatures[id] = actionSignature }
                }
                self.executingTargetID = nil
            }
            if error == nil {
                // An asynchronous decode started by the last timer tick may
                // finish after the committed snapshot. It must not resurrect
                // transient panels over that snapshot.
                self.livePollGeneration &+= 1
                self.liveCells = [:]
            }
            if ["add_cell", "add_text", "delete_cell", "move_up", "move_down"].contains(action) {
                self.selectedCellID = self.activeTab?.selected_cell ?? ""
            }
            self.error = error
            self.pauseForCodeDrafts()
            self.onChange?()
            if self.remote.isSelected { self.remote.edited() }
            completion?(error == nil)
        }
    }

    func cellIDValidationError(_ text: String, cell: NotebookCell) -> String? {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let id = UInt64(text), id > 0, id < UInt64.max else {
            return "Hard ID must be an integer from 1 to 18446744073709551614."
        }
        if snapshot?.tabs.flatMap(\.cells).contains(where: { $0.id != cell.id && UInt64($0.id) == id }) == true {
            return "Hard ID is already used by another cell."
        }
        return nil
    }

    func setCellID(_ text: String, cell: NotebookCell, tab: NotebookTab, completion: @escaping (Bool) -> Void) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = cellIDValidationError(value, cell: cell) {
            error = message; completion(false); return
        }
        perform("set_cell_id", tab: tab, cell: cell, text: String(UInt64(value)!), completion: completion)
    }

    func shutdown(completion: @escaping () -> Void) {
        audioSession.close()
        remote.detach()
        closeCompletions.append(completion)
        guard !closing else { return }
        closing = true
        watchTimer?.invalidate(); watchTimer = nil
        periodicTimer?.invalidate(); periodicTimer = nil
        for key in periodicStates.keys { periodicStates[key]?.pause() }
        self.livePollGeneration &+= 1
        busy = true
        worker.close { [weak self] in
            guard let self else { return }
            self.closing = false
            self.busy = false
            let completions = self.closeCompletions
            self.closeCompletions.removeAll()
            completions.forEach { $0() }
        }
    }
}

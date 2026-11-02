import SwiftUI

struct NotebookRunHistoryView: View {
    @ObservedObject var model: NotebookModel
    @ObservedObject var history: NotebookRunHistory
    let tab: NotebookTab
    var compare = false
    @State private var selected: String = ""
    @State private var baseline: String = ""
    @State private var record: NotebookRunRecord?
    @State private var other: NotebookRunRecord?
    @State private var details: NotebookRunRecord?
    @State private var title = ""
    @State private var restoreScope = "project"
    @State private var restoreVersion = ""
    @State private var reviewRunID = ""
    @State private var loadGeneration = 0
    private var runs: [NotebookRunSummary] { (model.remote.isSelected ? model.remote.historyRuns.map(\.historySummary) : history.runs).filter { $0.tab == tab.id } }
    private var changing: Bool { model.busy || (model.remote.isSelected && (model.remote.busy || model.remote.historyBusy || !model.remote.connected || model.remote.hasPending)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if compare {
                Picker("Baseline", selection: $baseline) { Text("Choose a run…").tag(""); ForEach(runs) { Text($0.title).tag($0.id) } }
            }
            Picker(compare ? "Candidate" : "Run", selection: $selected) {
                Text("Choose a run…").tag("")
                ForEach(runs) { Text(($0.pinned ? "📌 " : "") + $0.title + " · " + $0.status).tag($0.id) }
            }
            if model.remote.isSelected {
                HStack {
                    Button("Refresh server history") {
                        reviewRunID = ""
                        model.remote.loadHistory { success in if success { load() } }
                    }.disabled(changing || model.remote.historyBusy)
                    Button("Load older runs") { model.remote.loadHistory(older: true) }.disabled(changing || model.remote.historyBusy || !model.remote.historyHasMore)
                    if model.remote.historyBusy { ProgressView().controlSize(.small) }
                }
                if !model.remote.supportsHistory { Text("Update the remote core to manage retained server history.").font(.caption) }
            }
            if let record {
                if compare, let other { comparison(other, record) }
                else {
                    HStack {
                        TextField("Run title", text: $title).onSubmit { change(title: title) }
                        Button(record.pinned ? "Unpin" : "Pin") { change(pinned: !record.pinned) }
                        Button("Rename") { change(title: title) }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.disabled(changing)
                    Text("\(record.status) · \(record.backend) · \(record.started.formatted())").font(.caption).foregroundStyle(NotebookPalette.muted)
                    HStack {
                        Button("Inspect snapshot") { details = record }
                        Button("Restore scalar parameters") {
                            model.restoreRunParameters(record, scope: restoreScope, expectedVersion: model.remote.isSelected ? restoreVersion : nil)
                        }.disabled(changing || model.remote.active || (model.remote.isSelected && (!model.remote.canApplyProjectInputs || restoreVersion != model.remote.acceptedInputVersion)))
                        NotebookObjectMenu(title: "Run actions") {
                            Button("Export snapshot…") { export(record) }
                            Button("Delete run", role: .destructive) { change(remove: true) }.disabled(changing)
                        }
                    }
                    if model.remote.isSelected {
                        Picker("Restore scope", selection: $restoreScope) {
                            Text("Project parameters").tag("project")
                            ForEach(record.cellInputs.keys.sorted(), id: \.self) { Text("Cell \($0) parameters").tag($0) }
                        }
                        if restoreVersion != model.remote.acceptedInputVersion { Text("Accepted parameters changed. Reload the snapshot before restoring.").font(.caption).foregroundStyle(NotebookPalette.error) }
                    }
                    Text(model.remote.isSelected ? "Restore applies one scalar scope on the server. Watch cells may refresh; media assets and authored defaults are preserved." : "Restore changes local accepted scalar inputs without running code. Audio assets and sources remain visible in Inspect snapshot.")
                        .font(.caption).foregroundStyle(NotebookPalette.muted)
                }
            } else { Text("Explicit sheet and cell runs are saved here, including errors and Stop.").font(.callout).foregroundStyle(NotebookPalette.muted) }
            Text(model.remote.isSelected ? "Server retention and quotas apply · up to 10 pinned · current presentations are protected from deletion" : "Retention: 20 recent runs + up to 10 pinned · 256 MiB per notebook").font(.caption2).foregroundStyle(NotebookPalette.muted)
            if let error = model.remote.isSelected ? model.remote.historyError : history.error { Text(error).font(.caption).foregroundStyle(NotebookPalette.error) }
        }
        .onAppear { if model.remote.isSelected && !model.remote.historyLoaded { model.remote.loadHistory() }; choose(); load() }
        .onChange(of: selected) { _, _ in load() }
        .onChange(of: baseline) { _, _ in load() }
        .onChange(of: history.runs.map(\.id)) { _, _ in if selected.isEmpty { selected = runs.first?.id ?? "" }; load() }
        .onChange(of: model.remote.historyRuns.map { $0.id + ":" + $0.metadata.version }) { _, _ in choose(); load() }
        .onChange(of: model.remote.connected) { _, connected in if connected && !model.remote.historyLoaded { model.remote.loadHistory() } }
        .onChange(of: model.remote.busy) { _, busy in if !busy && model.remote.connected && !model.remote.historyLoaded { model.remote.loadHistory() } }
        .onChange(of: model.remote.isSelected) { _, _ in selected = ""; baseline = ""; choose(); load() }
        .sheet(item: $details) { record in NotebookRunSnapshotView(model: model, record: record).frame(minWidth: 780, minHeight: 620) }
    }
    @ViewBuilder private func comparison(_ baseline: NotebookRunRecord, _ candidate: NotebookRunRecord) -> some View {
        let first = metricValues(baseline), second = metricValues(candidate)
        let keys = Set(first.keys).union(second.keys).sorted()
        Text("\(baseline.status) → \(candidate.status) · \(baseline.sourceHash == candidate.sourceHash ? "Same sources" : "Sources changed")")
            .font(.caption).foregroundStyle(NotebookPalette.muted)
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow { Text("Parameter / metric").bold(); Text("Baseline").bold(); Text("Candidate").bold(); Text("Delta").bold() }
                ForEach(keys, id: \.self) { key in
                    GridRow {
                        Text(key); Text(first[key] ?? "—"); Text(second[key] ?? "—")
                        Text(delta(first[key], second[key]))
                    }.font(.system(.caption, design: .monospaced))
                }
            }.textSelection(.enabled)
        }.frame(maxHeight: 300)
        HStack { Button("Inspect baseline") { details = baseline }; Button("Inspect candidate") { details = candidate }; Button("Export comparison CSV…") { exportComparison(first, second, keys: keys) } }
    }
    private func metricValues(_ record: NotebookRunRecord) -> [String: String] {
        var values = Dictionary(uniqueKeysWithValues: record.inputs.map { ("Input · " + $0.key, $0.value) })
        for (cell, inputs) in record.cellInputs { for (key, value) in inputs { values["Cell \(number(cell, record)) · input · \(key)"] = value } }
        for output in record.outputs {
            let label = "Cell \(number(output.id, record))"
            for (key, value) in output.metrics { values[label + " · " + key] = value }
            if let elapsed = output.elapsed { values[label + " · elapsed_ms"] = String(elapsed) }
        }
        return values
    }
    private func number(_ id: String, _ record: NotebookRunRecord) -> String {
        record.sources.filter { $0.tab == record.tab }.firstIndex(where: { $0.cell == id }).map { String(format: "%02d", $0 + 1) } ?? "?"
    }
    private func delta(_ a: String?, _ b: String?) -> String {
        guard let a, let b else { return "—" }
        if let x = Double(a), let y = Double(b), x.isFinite, y.isFinite, (y - x).isFinite { return String(format: "%+.6g", y - x) }
        return a == b ? "=" : "changed"
    }
    private func load() {
        if model.remote.isSelected {
            loadGeneration += 1
            let generation = loadGeneration, selectedID = selected, baselineID = baseline
            record = nil; other = nil
            Task { @MainActor in
                do {
                    let candidate = selectedID.isEmpty ? nil : try await model.remote.historyRecord(selectedID)
                    let base = !compare || baselineID.isEmpty ? nil : try await model.remote.historyRecord(baselineID)
                    guard generation == loadGeneration, selected == selectedID, baseline == baselineID, model.remote.isSelected else { return }
                    record = candidate; other = base; title = candidate?.title ?? ""
                    if reviewRunID != selectedID { restoreVersion = model.remote.acceptedInputVersion; reviewRunID = selectedID }
                    if restoreScope != "project" && candidate?.cellInputs[restoreScope] == nil { restoreScope = "project" }
                } catch { if generation == loadGeneration { model.error = error.localizedDescription } }
            }
            return
        }
        record = selected.isEmpty ? nil : try? history.load(selected); title = record?.title ?? ""
        other = baseline.isEmpty ? nil : try? history.load(baseline)
    }
    private func choose() {
        if !runs.contains(where: { $0.id == selected }) { selected = runs.first?.id ?? "" }
        if compare && !runs.contains(where: { $0.id == baseline }) { baseline = runs.dropFirst().first?.id ?? "" }
    }
    private func change(title: String? = nil, pinned: Bool? = nil, remove: Bool = false) {
        guard let record else { return }
        if model.remote.isSelected {
            model.remote.changeHistory(record, title: title, pinned: pinned, remove: remove) { success in if success { choose(); load() } }
        } else {
            if remove { history.remove(record.id); choose() }
            else if title != nil { history.rename(record.id, title: title!) }
            else { history.pin(record.id) }
            load()
        }
    }
    private func export(_ record: NotebookRunRecord) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "run.json"
        if panel.runModal() == .OK, let url = panel.url { do {
            if model.remote.isSelected { try JSONEncoder().encode(record).write(to: url, options: .atomic) }
            else { try history.export(record.id, to: url) }
        } catch { model.error = error.localizedDescription } }
    }
    private func exportComparison(_ first: [String: String], _ second: [String: String], keys: [String]) {
        func csv(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let text = "Parameter,Baseline,Candidate,Delta\r\n" + keys.map { key in [key, first[key] ?? "", second[key] ?? "", delta(first[key], second[key])].map(csv).joined(separator: ",") }.joined(separator: "\r\n")
        let panel = NSSavePanel(); panel.nameFieldStringValue = "comparison.csv"
        if panel.runModal() == .OK, let url = panel.url { do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { history.error = error.localizedDescription } }
    }
}

private struct NotebookRunSnapshotView: View {
    @ObservedObject var model: NotebookModel
    let record: NotebookRunRecord
    @Environment(\.dismiss) private var dismiss
    @State private var audio = NotebookAudioSession()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(record.title).font(.title2); Spacer(); Button("Done") { dismiss() } }
            Text("\(record.status) · \(record.backend) · \(record.started.formatted())").font(.caption)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let note = record.provenanceNote { Text(note).foregroundStyle(NotebookPalette.sputnik) }
                    if let failure = record.failure { Text(failure).foregroundStyle(NotebookPalette.error) }
                    if record.omitted { Text("Some large media outputs were omitted from this snapshot to respect the 16 MiB media budget.").foregroundStyle(NotebookPalette.sputnik) }
                    DisclosureGroup("Sources and environment") {
                        Text("Source SHA-256: \(record.sourceHash)").font(.caption).textSelection(.enabled)
                        Text("Epoch: \(record.epoch ?? "unavailable") · revision: \(record.revision ?? "local")").font(.caption)
                        ForEach(Array(record.sources.enumerated()), id: \.offset) { index, source in
                            Text("\(source.tab.hasPrefix("module:") ? String(source.tab.dropFirst(7)) : "Cell \(index + 1)")\n\(source.source)")
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(record.dependencies, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    }
                    DisclosureGroup("Accepted inputs") {
                        ForEach(Array((record.acceptedData ?? []).enumerated()), id: \.offset) { _, data in
                            Text("\(data.kind) · \(data.id): \(data.json)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        ForEach(record.inputs.keys.sorted(), id: \.self) { key in Text("\(key): \(record.inputs[key]!)").font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        ForEach(record.assets.keys.sorted(), id: \.self) { key in
                            Text(key).font(.caption.bold()); media(record.assets[key]!, key: "input:" + key)
                        }
                    }
                    ForEach(Array(record.outputs.enumerated()), id: \.element.id) { index, cell in
                        GroupBox("Cell \(cellNumber(cell.id))\(cell.stale ? " · stale at capture" : "")") {
                            VStack(alignment: .leading, spacing: 10) {
                                if !cell.error.isEmpty { Text(cell.error).foregroundStyle(NotebookPalette.error) }
                                Text(cell.pretty ?? cell.result).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                ForEach(Array(cell.displays.enumerated()), id: \.offset) { i, panel in media(panel, key: cell.id + ":" + String(i)) }
                                if !cell.log.isEmpty { DisclosureGroup("Output") { Text(cell.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }.padding(20).onDisappear { audio.close() }
    }
    private func cellNumber(_ id: String) -> String {
        record.sources.filter { $0.tab == record.tab }.firstIndex(where: { $0.cell == id }).map { String(format: "%02d", $0 + 1) } ?? "?"
    }
    @ViewBuilder private func media(_ panel: NotebookFigurePanel, key: String) -> some View {
        if panel.mime == NotebookAudioPayload.mime { NotebookAudioView(controller: audio.controller(key), panel: panel) }
        else if panel.mime == "application/vnd.sputnik.table+json" { NotebookPublishedTableView(panel: panel, stale: false, height: 260) }
        else { NotebookFigureView(panels: [panel], stale: false).equatable() }
    }
}

import SwiftUI

enum NotebookCellDisplayKind: String { case result, progress, figure = "plot", table, audio }

/// Sheet output is an adapter to the same components placed in a board grid.
/// Empty output is hidden on sheets and remains an explicit slot on boards.
struct NotebookCellDisplay: View {
    @ObservedObject var model: NotebookModel
    let cell: NotebookCell
    let tab: NotebookTab
    let kind: NotebookCellDisplayKind
    var progressID: String = ""
    var tableID: String = ""
    var audioID: String = ""
    var showWaveform: Bool? = nil
    var excludedAudioIDs: Set<String> = []
    var excludedTableIDs: Set<String> = []
    var allowResultTable = true
    var showEmpty = false
    var viewportHeight: CGFloat? = nil
    var selectionBoard: NotebookBoard? = nil
    var selectionComponent: NotebookBoardComponent? = nil
    @State private var tableRepresentation = false
    @State private var table: NotebookTableSnapshot?

    var body: some View {
        Group {
            if let viewportHeight, kind != .figure && kind != .table {
                ScrollView { content }.frame(height: viewportHeight)
            } else { content }
        }
        .onAppear(perform: updateTable)
        .onChange(of: model.presentation(for: cell, in: tab).result?.format?.table_json) { updateTable() }
    }

    @ViewBuilder private var content: some View {
        let state = model.presentation(for: cell, in: tab)
        switch kind {
        case .result:
            if let result = state.result {
                if tableRepresentation, let table {
                    if result.previous { previousResultLabel }
                    NotebookTableView(table: table, stale: result.previous, height: viewportHeight)
                } else {
                    NotebookResultView(title: result.previous ? "PREVIOUS RUN RESULT" : "RESULT",
                    text: result.text,
                    pretty: result.format?.is_container == true ? result.format?.pretty : nil,
                    truncated: result.format?.truncated ?? false,
                    prettyTruncated: result.format?.pretty_truncated ?? false,
                    tint: result.previous ? NotebookPalette.sputnik : NotebookPalette.success)
                    .accessibilityIdentifier("notebook-output-result-\(cell.id)")
                }
                if table != nil {
                    Button(tableRepresentation ? "View result" : "View table") { tableRepresentation.toggle() }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(NotebookPalette.sputnik)
                }
            } else if showEmpty { waiting("Run the cell to publish a result") }
        case .progress:
            let items = state.progress.filter { progressID.isEmpty || $0.id == progressID }
            if !items.isEmpty {
                NotebookProgressView(items: items, running: state.running)
                    .accessibilityIdentifier("notebook-output-progress-\(cell.id)")
            } else if showEmpty {
                waiting(progressID.isEmpty ? "Waiting for progress from \(tab.cellLabel(for: cell.id))" : "Waiting for \(progressID) from \(tab.cellLabel(for: cell.id))")
            }
        case .figure:
            let figures = state.figures.filter { $0.mime != "application/vnd.sputnik.table+json" && $0.mime != NotebookAudioPayload.mime }
            if !figures.isEmpty {
                NotebookFigureView(panels: figures, stale: state.running ? false : state.stale).equatable()
            } else if showEmpty { waiting("Run the cell to publish a figure with notebook.show(…)") }
        case .audio:
            let published = state.figures.filter { $0.mime == NotebookAudioPayload.mime && (audioID.isEmpty || $0.id == audioID) && !excludedAudioIDs.contains($0.id ?? "") && (model.selectedAsset(selectionComponent) == nil || (try? NotebookAudioPayload.decode($0.data)).map { notebookAssetID($0.data) } == model.selectedAsset(selectionComponent)) }
            let streams = model.audioStreams(for: cell, in: tab).filter { (audioID.isEmpty || $0.id == audioID) && !excludedAudioIDs.contains($0.id) && model.selectedAsset(selectionComponent) == nil }
            if !streams.isEmpty {
                ForEach(streams) { stream in
                    NotebookAudioView(controller: model.audioSession.controller(tab.id + ":" + cell.id + ":" + stream.id),
                        stream: stream, showWaveform: showWaveform, stale: state.running ? false : state.stale)
                }
            }
            if !published.isEmpty {
                ForEach(Array(published.enumerated()), id: \.offset) { index, panel in
                    NotebookAudioView(controller: model.audioSession.controller(tab.id + ":" + cell.id + ":" + (panel.id ?? "audio-\(index)")),
                                      panel: panel, showWaveform: showWaveform, stale: state.running ? false : state.stale)
                }
            } else if showEmpty && streams.isEmpty { waiting("Publish audio with notebook.player(track)") }
        case .table:
            let published = state.figures.filter { $0.mime == "application/vnd.sputnik.table+json" && (tableID.isEmpty || $0.id == tableID) && !excludedTableIDs.contains($0.id ?? "") }
            if !published.isEmpty {
                ForEach(Array(published.enumerated()), id: \.offset) { index, panel in
                    NotebookPublishedTableView(panel: panel, stale: state.running ? false : state.stale, height: viewportHeight, selectionBinding: model.tableSelection(board: selectionBoard, component: selectionComponent))
                        .id(panel.id.flatMap { $0.isEmpty ? nil : $0 } ?? "table-\(index)")
                }
            } else if allowResultTable && tableID.isEmpty, let result = state.result, let table {
                if result.previous { previousResultLabel }
                NotebookTableView(table: table, stale: result.previous, height: viewportHeight, selectionBinding: model.tableSelection(board: selectionBoard, component: selectionComponent), sourceID: notebookAssetID(Data((result.format?.table_json ?? "").utf8)))
            } else if showEmpty { waiting("Publish a DataTableView with notebook.show(…)") }
        }
    }

    private func updateTable() {
        guard kind == .table || kind == .result else { return }
        table = NotebookTableSnapshot.decode(model.presentation(for: cell, in: tab).result?.format?.table_json ?? "")
    }

    private var previousResultLabel: some View {
        Label("Result from previous run", systemImage: "clock.arrow.circlepath")
            .font(.caption).foregroundStyle(NotebookPalette.sputnik)
    }

    private func waiting(_ text: String) -> some View {
        Label(text, systemImage: "clock").font(.callout).foregroundStyle(NotebookPalette.muted)
    }
}

enum NotebookTextCellMode { case design, run }

/// Editing always owns the source buffer. Run mode renders an independent
/// attributed snapshot and never writes substituted values back to the source.
struct NotebookTextCellView: View {
    let content: NotebookTextContent
    var mode: NotebookTextCellMode = .design
    var markdown = false
    var editable = true
    var variables: [NotebookTextVariable] = []
    var onChange: (String, String) -> Void = { _, _ in }
    var onFocus: () -> Void = {}
    var onError: (String?) -> Void = { _ in }
    @State private var choosingVariable = false
    @StateObject private var markdownController = RichTextEditorController(onChange: { _, _ in }, onFocus: {})

    var body: some View {
        if mode == .run {
            RichTextPreview(text: content.source, formatting: content.formatting,
                            variables: variables, markdown: markdown)
        } else if markdown {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Markdown").font(.caption).foregroundStyle(NotebookPalette.muted)
                    Spacer()
                    Button("Insert Variable…") { choosingVariable = true }.disabled(!editable)
                        .popover(isPresented: $choosingVariable) {
                            NotebookVariablePicker(variables: variables) { name in
                                markdownController.insertVariable(name)
                                choosingVariable = false
                            }
                        }
                }
                RichTextEditorRepresentable(text: content.source, formatting: "", editable: editable,
                    controller: markdownController, onChange: { text, _ in onChange(text, "") },
                    onFocus: onFocus, onError: onError)
                    .frame(minHeight: 120)
                    .accessibilityIdentifier("notebook-markdown-editor")
            }
        } else {
            RichTextEditor(text: content.source, formatting: content.formatting,
                editable: editable, variables: variables, onChange: onChange,
                onFocus: onFocus, onError: onError)
        }
    }
}

import SwiftUI

struct NotebookBoardView: View {
    @ObservedObject var model: NotebookModel
    let board: NotebookBoard
    var detached = false
    var onOpenSheet: () -> Void = {}
    let onDesign: () -> Void
    private var layout: NotebookBoard { board.rowLayout }

    var body: some View {
        let controller = model.controller(for: board)
        let needsApply = !model.remote.isSelected && controller?.environment_stale == true
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(board.title).font(.headline).lineLimit(1)
                NotebookPageBadge(kind: .board, detail: "Controller sheet: \(controller?.title ?? board.sheet)")
                if needsApply {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(NotebookPalette.sputnik)
                        .help("Modules changed. Apply Modules before running.")
                        .accessibilityLabel("Module environment changed")
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Design…", systemImage: "slider.horizontal.3", action: onDesign)
                    .disabled(model.busy)
                Button("Open Sheet", systemImage: "doc.text") {
                    if let controller {
                        model.selectTab(controller)
                        onOpenSheet()
                    }
                }.disabled(!model.canNavigate)
                NotebookBoardWindowButton(model: model)
                Button("Apply Modules", systemImage: "arrow.triangle.2.circlepath") {
                    if let controller { model.perform("apply", tab: controller) }
                }
                .help(model.remote.isSelected ? "Sync modules and restart the server worker to use a new environment" : "Build and apply the saved module environment to the controller sheet")
                .buttonStyle(.bordered)
                .disabled(!(controller.map { model.canApplyModules($0) } ?? false))
                .accessibilityIdentifier("board-apply-modules")
                Button("Run Sheet", systemImage: "play.fill") {
                    if let controller { model.perform("run_all", tab: controller) }
                }
                .buttonStyle(.borderedProminent).tint(NotebookPalette.sputnik)
                .disabled(needsApply || !(controller.map { model.canRun($0) } ?? false))
                .accessibilityIdentifier("board-run-sheet")
            }.padding(18)
            Divider()
            if let tab = controller, !model.executionIssues(in: tab).isEmpty {
                NotebookExecutionErrorsView(model: model, tab: tab, onNavigate: onOpenSheet).padding(18)
                Divider()
            }
            if board.components.isEmpty {
                ContentUnavailableView("An empty canvas", systemImage: "square.grid.2x2",
                                       description: Text("Choose Design to add inputs, text, figures and run buttons."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 18) {
                            if let tab = controller {
                                gridView(rows: layout.rows ?? [], components: layout.components, tab: tab)
                            } else { unavailable("Controller sheet unavailable") }
                            if !board.services.isEmpty {
                                Label("Services", systemImage: "gearshape.2").font(.headline)
                                ForEach(board.services) { component in
                                    NotebookPeriodicWorkView(model: model, board: board, component: component)
                                }
                            }
                        }
                        .frame(width: max(720, geometry.size.width - 48), alignment: .leading).padding(24)
                        .frame(minHeight: geometry.size.height, alignment: .topLeading)
                    }
                }
            }
        }.background(NotebookPalette.canvas).accessibilityIdentifier("notebook-board")
            .onAppear {
                if detached == (model.boardWindowSheetID != nil) { model.periodicBoardVisible = board.id }
            }
            .onDisappear {
                if detached == (model.boardWindowSheetID != nil) && model.periodicBoardVisible == board.id {
                    model.periodicBoardVisible = nil
                }
            }
    }

    private func gridView(rows: [NotebookBoardRow], components: [NotebookBoardComponent], tab: NotebookTab) -> AnyView {
        AnyView(VStack(spacing: 16) {
            ForEach(rows) { row in
                NotebookBoardRowLayout(height: row.height) {
                    ForEach(components.filter { !$0.isService && $0.row == row.id }) { component in
                        componentCard(component, tab: tab, height: row.height)
                            .id("\(model.documentIdentity):\(board.id):\(component.id)")
                            .layoutValue(key: BoardColumnSpan.self, value: component.columnSpan)
                    }
                }.clipped()
            }
        })
    }

    private func componentCard(_ component: NotebookBoardComponent, tab: NotebookTab, height: Double?) -> some View {
        VStack(alignment: component.horizontalAlignment, spacing: 12) {
            if component.kind != "live_chart" && component.kind != "group" { Text(component.title).font(.headline) }
            if component.kind == "group", let panel = component.panels?.first {
                NotebookGroupView(title: component.title, collapsed: component.settings.collapsed ?? false) {
                    gridView(rows: panel.rows, components: panel.components, tab: tab)
                }
            } else if component.kind == "split" {
                NotebookSplitView(component: component, height: height.map { max(80, $0 - 100) }, content: { panel in
                    gridView(rows: panel.rows, components: panel.components, tab: tab)
                }, onSave: model.busy || model.remote.active ? nil : { fraction in
                    var updated = component; updated.split_fraction = fraction; var next = board
                    if next.replaceComponent(updated) { model.saveBoard(next) { _ in } }
                })
            } else if component.kind == "tabs" {
                NotebookBoardTabsView(component: component, height: height.map { max(48, $0 - 72) }) { panel in
                    gridView(rows: panel.rows, components: panel.components, tab: tab)
                }.id(component.id)
            } else if component.kind == "rich_text" {
                NotebookTextCellView(content: component.text_content ?? NotebookTextContent(), mode: .run,
                    markdown: component.text_mode == "markdown", variables: model.textVariables(in: tab))
                    .accessibilityIdentifier("board-text-\(component.id)")
            } else if component.kind == "parameter_presets" {
                NotebookPresetView(model: model, board: board, component: component)
            } else if component.kind == "action" {
                NotebookActionButtonView(model: model, board: board, component: component)
            } else if component.kind == "execution_controls" {
                NotebookExecutionControlsView(model: model, board: board, component: component, tab: tab)
            } else if component.kind == "stopwatch" {
                NotebookStopwatchView(model: model, tab: tab, channel: component.stopwatch_id ?? "default")
            } else if component.kind == "task_monitor" {
                NotebookTaskMonitorView(model: model, tab: tab)
            } else if component.kind == "run_history" || component.kind == "experiment_compare" {
                NotebookRunHistoryView(model: model, history: model.runHistory, tab: tab, compare: component.kind == "experiment_compare")
            } else if component.kind == "status" {
                NotebookStatusView(model: model, board: board, component: component, tab: tab)
            } else if component.kind == "range_input" {
                if let input = model.snapshot?.inputs?.first(where: { $0.id == component.input && $0.type == "range" }) {
                    NotebookRangeInputView(model: model, input: input, control: component.control ?? NotebookInputControl())
                } else { unavailable("Choose a Range parameter in the designer") }
            } else if component.kind == "date_input" {
                if let input = model.snapshot?.inputs?.first(where: { $0.id == component.input }), TimeZone(identifier: component.date_time_zone ?? "UTC") != nil {
                    NotebookDateInputView(model: model, input: input, mode: component.date_mode ?? "date_time", zone: component.date_time_zone ?? "UTC")
                } else { unavailable("Choose a String input and a valid IANA time zone in the designer") }
            } else if component.kind == "audio_annotator" {
                NotebookAudioAnnotatorComponent(model: model, board: board, component: component, tab: tab)
            } else if component.kind == "audio_input" {
                NotebookAudioInputView(model: model, board: board, component: component)
            } else if component.kind == "file_input" {
                if model.remote.isSelected { unavailable("File input transfer requires local execution") }
                else if let input = model.snapshot?.inputs?.first(where: { $0.id == component.input && $0.type == "string" }) {
                    NotebookFileInputView(model: model, input: input, extensions: component.settings.extensions ?? "")
                } else { unavailable("Choose a String parameter in the designer") }
            } else if component.kind == "parameter_form" {
                NotebookParameterFormView(model: model, fields: component.fields ?? [], height: height.map { max(48, $0 - 72) })
            } else if component.kind == "input" {
                if let input = model.snapshot?.inputs?.first(where: { $0.id == component.input }) {
                    NotebookBoardInputView(model: model, input: input, control: component.control ?? NotebookInputControl()).id(input.id)
                } else { unavailable("Input unavailable") }
            } else if component.kind == "live_chart", component.settings.series?.isEmpty == false {
                NotebookMultiSeriesView(model: model, component: component, tab: tab, height: height.map { max(180, $0 - 36) })
            } else if component.kind == "live_chart" {
                let channel = component.chart_id ?? component.id
                let chart = model.liveChart(channel, in: tab) ??
                    NotebookLiveChart(id: channel, points: [], total_points: 0, replace_chart: true)
                NotebookLiveChartView(chart: chart, title: component.title, caption: component.caption ?? "",
                                      xLabel: component.x_label ?? "X",
                                      yLabel: component.y_label ?? "Y", stroke: component.stroke ?? "#d97706",
                                      yMin: component.y_min, yMax: component.y_max,
                                      xMin: component.x_min, xMax: component.x_max, running: model.executingWorker,
                                      cellHeight: component.v_align == "stretch" ? height.map { max(48, $0 - 36 - (model.liveChartIsStale(channel, in: tab) ? 28 : 0)) } : nil)
                    .equatable()
                if model.liveChartIsStale(channel, in: tab) {
                    Label("Previous samples · stale", systemImage: "clock")
                        .font(.caption).foregroundStyle(NotebookPalette.sputnik)
                }
            } else if component.kind == "image" || component.kind == "image_carousel" {
                let channel = component.image_id ?? component.id
                let stale = model.imageSeriesIsStale(channel, in: tab)
                NotebookImageView(series: model.selectedImageSeries(model.imageSeries(channel, in: tab) ?? NotebookImageSeries(id: channel, caption: "", images: []), component: component),
                                  carousel: component.kind == "image_carousel", mode: component.image_mode ?? "fit",
                                  caption: component.caption ?? "",
                                  cellHeight: height.map { max(48, $0 - 72 - (stale ? 28 : 0)) },
                                  selected: model.imageSelection(channel, in: tab),
                                  allowSave: component.image_allow_save ?? false, allowLoad: (component.image_allow_load ?? false) && model.selectedAsset(component) == nil,
                                  controlsDisabled: model.busy,
                                  onSelection: { if model.selectedAsset(component) == nil { model.selectImage($0, channel: channel, tab: tab) } },
                                  onEdit: { model.editImages($0, caption: $1, selected: $2, board: board, component: component) },
                                  annotationBinding: model.annotationBinding(board: board, component: component))
                    .id(component.id)
                if stale {
                    Label("Previous images · stale", systemImage: "clock").font(.caption).foregroundStyle(NotebookPalette.sputnik)
                }
            } else if let cell = tab.cells.first(where: { $0.id == component.cell && $0.kind == "code" }) {
                if let kind = NotebookCellDisplayKind(rawValue: component.kind) {
                    NotebookCellDisplay(model: model, cell: cell, tab: tab, kind: kind,
                        progressID: component.progress_id ?? "", tableID: component.table_id ?? "",
                        audioID: component.audio_id ?? "", showWaveform: component.show_waveform, showEmpty: true,
                        viewportHeight: height.map { max(48, $0 - 72) }, selectionBoard: board, selectionComponent: component)
                } else if component.kind == "metric" {
                    NotebookMetricView(model: model, component: component, tab: tab, cell: cell)
                } else if component.kind == "log" {
                    NotebookLogView(cell: cell, stale: model.figureIsStale(for: cell, in: tab), height: height.map { max(48, $0 - 126) }, sourceLabel: tab.cellLabel(for: cell.id), output: model.output(for: cell, in: tab), running: model.executingCurrentWorker && model.liveCell(cell, in: tab)?.output_updated == true)
                } else if component.kind == "artifacts" {
                    if model.remote.isSelected { unavailable("Remote artifact transfer is not available") }
                    else { NotebookArtifactBrowser(cell: cell, project: model.snapshot?.path ?? "", stale: model.figureIsStale(for: cell, in: tab), sourceLabel: tab.cellLabel(for: cell.id), updatedAt: model.componentUpdatedAt[tab.id + ":" + cell.id]) }
                } else if component.kind == "text" {
                    let binding = component.binding ?? ""
                    let local = cell.locals.first { $0.name == binding && $0.role == "module_cell" }
                    // A blocked cell's diagnostic result is the literal
                    // "error", not a published expression value.
                    let value = binding.isEmpty ? (cell.ok ? cell.result : nil) : (local?.initialized == true ? local?.text_value ?? local?.value : nil)
                    Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "Unavailable")
                        .font(.system(size: 26, weight: .medium, design: .rounded))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if model.figureIsStale(for: cell, in: tab) {
                        Label(value == nil ? "Requires evaluation" : "Previous value · stale", systemImage: "clock").font(.caption).foregroundStyle(NotebookPalette.sputnik)
                    }
                } else if component.kind == "run" {
                    Button(component.title, systemImage: "play.fill") { model.perform("run", tab: tab, cell: cell) }
                        .buttonStyle(.borderedProminent).disabled(model.busy || tab.environment_stale)
                    Text("Runs \(tab.cellLabel(for: cell.id)) explicitly").font(.caption).foregroundStyle(NotebookPalette.muted)
                }
                if !cell.error.isEmpty {
                    Text(cell.error).font(.caption).foregroundStyle(cell.dirty ? NotebookPalette.sputnik : NotebookPalette.error).textSelection(.enabled)
                }
            } else { unavailable("Source cell unavailable") }
        }
        .frame(maxWidth: component.h_align == nil || component.h_align == "stretch" ? .infinity : nil,
               maxHeight: component.v_align == "stretch" && height != nil ? .infinity : nil,
               alignment: component.cellAlignment)
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: component.cellAlignment)
        .multilineTextAlignment(component.textAlignment)
        .background(NotebookPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(NotebookPalette.rule))
    }
    private func unavailable(_ message: String) -> some View {
        Label(message, systemImage: "questionmark.circle").font(.callout).foregroundStyle(NotebookPalette.muted)
    }
}

struct NotebookBoardWindowButton: View {
    @ObservedObject var model: NotebookModel

    var body: some View {
        let detached = model.boardWindowSheetID != nil
        let title = detached ? "Attach Board" : "Detach Board"
        Button(title, systemImage: detached ? "arrow.down.left.square" : "arrow.up.right.square") {
            model.toggleBoardWindow()
        }
        .labelStyle(.iconOnly)
        .help(detached ? "Return the board to the notebook window" : "Open the board in a separate window")
        .disabled(!model.canToggleBoardWindow)
        .accessibilityIdentifier("board-window-toggle")
    }
}

struct NotebookDetachedBoardView: View {
    @ObservedObject var model: NotebookModel
    let onOpenSheet: () -> Void
    let onTitle: (String) -> Void
    @State private var boardToDesign: NotebookBoard?

    var body: some View {
        Group {
            if let board = model.detachedBoard {
                NotebookBoardView(model: model, board: board, detached: true, onOpenSheet: onOpenSheet) {
                    boardToDesign = board
                }.id(board.id)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text(model.boardWindowSheet?.title ?? "Board").font(.headline)
                        Spacer()
                        NotebookBoardWindowButton(model: model)
                    }.padding(18)
                    Divider()
                    ContentUnavailableView("No board for this sheet", systemImage: "square.grid.2x2")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(NotebookPalette.canvas)
        .foregroundStyle(NotebookPalette.ink)
        .tint(NotebookPalette.sputnik)
        .accessibilityIdentifier("detached-board-window")
        .alert("Notebook", isPresented: Binding(
            get: { model.error != nil && model.boardWindowFocused },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("OK", role: .cancel) { model.clearError() }
        } message: {
            Text(model.error ?? "")
        }
        .onChange(of: model.detachedBoard?.title, initial: true) { _, title in
            onTitle(title ?? "Notebook Board")
        }
        .sheet(item: $boardToDesign) { board in
            NotebookBoardEditor(model: model, board: board, document: model.documentIdentity)
        }
    }
}

struct NotebookGroupView<Content: View>: View {
    let title: String
    var collapsed = false
    @ViewBuilder var content: () -> Content
    @State private var expanded = true
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) { content().padding(.top, 12) } label: { Text(title).font(.headline) }
            .onAppear { expanded = !collapsed }
    }
}

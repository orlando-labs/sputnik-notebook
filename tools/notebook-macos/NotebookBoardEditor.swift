import SwiftUI

struct NotebookBoardEditor: View {
    @ObservedObject var model: NotebookModel
    @State var board: NotebookBoard
    let document: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var gridPath: [NotebookBoardGridPath] = []
    @State private var selectedRow: String?
    @State private var selectedComponent: String?
    @State private var insertionSpan = 6
    @State private var paletteCategory = NotebookComponentCategory.controls
    @State private var paletteQuery = ""
    @State private var undoBoards: [NotebookBoard] = []
    @State private var redoBoards: [NotebookBoard] = []
    @State private var observedBoard: NotebookBoard?
    @State private var restoringBoard = false
    @State private var lastUndo = Date.distantPast
    @State private var saveError: String?
    @State private var dragSession = UUID()
    @State private var draggedComponent: NotebookBoardComponentDrag?
    @State private var dropTargetRow: String?
    @State private var dragLocation: CGPoint?
    @State private var dragGeometry = NotebookBoardDragGeometry()
    @GestureState private var isDragging = false
    private var sheets: [NotebookTab] { model.snapshot?.tabs.filter { $0.kind == "sheet" } ?? [] }
    private var cells: [NotebookCell] { model.controller(for: board)?.cells.filter { $0.kind == "code" } ?? [] }
    private func cellLabel(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "Choose cell…" }
        return model.controller(for: board)?.cellLabel(for: id) ?? "Source cell unavailable"
    }
    private var grid: NotebookBoard {
        get { board.grid(at: gridPath) ?? board }
        nonmutating set { board.updateGrid(newValue, at: gridPath) }
    }
    private var rows: [NotebookBoardRow] { grid.rows ?? [] }
    private var freeColumns: Int { selectedRow.map { grid.availableColumns(in: $0) } ?? 0 }
    private var dropRejected: Bool { dropTargetRow.map { !canDrop(in: $0) } ?? false }
    private var heightError: String? {
        board.allRows.contains { $0.height.map { !$0.isFinite || $0 < 48 || $0 > 4096 } ?? false }
            ? "Row height must be between 48 and 4096 pt." : nil
    }
    private var periodicError: String? { board.services.compactMap { $0.periodicSettings.validationError }.first }
    private var bindingError: String? {
        if let error = board.inputBindingError(inputs: model.snapshot?.inputs ?? []) { return error }
        return board.allComponents.contains { $0.kind == "progress" && ($0.cell ?? "").isEmpty }
            ? "Choose the cell that publishes progress in the Object Inspector." : nil
    }
    private var dragMessage: String? {
        guard let row = dropTargetRow, let drag = draggedComponent,
              let component = grid.components.first(where: { $0.id == drag.component }) else { return nil }
        if component.row == row { return "Drag the component to another row" }
        if !canDrop(in: row) {
            return "Not enough space · \(component.columnSpan)/12 required · \(grid.availableColumns(in: row))/12 free"
        }
        return "Move \(component.title) to row \(rowNumber(row)) · \(component.columnSpan)/12 columns"
    }

    init(model: NotebookModel, board: NotebookBoard, document: UUID) {
        self.model = model; self.document = document
        let layout = board.rowLayout
        _board = State(initialValue: layout)
        _selectedRow = State(initialValue: layout.rows?.first?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            palette
            Divider()
            HStack(spacing: 0) {
                canvas
                Divider()
                ScrollView { inspector.padding(18) }
                    .frame(width: 300).background(NotebookPalette.card)
            }
            Divider()
            HStack(spacing: 12) {
                Text(heightError ?? periodicError ?? bindingError ?? dragMessage ?? "\(rows.count) rows · \(grid.components.count) components")
                    .font(.caption).foregroundStyle(heightError != nil || periodicError != nil || bindingError != nil || dropRejected
                        ? NotebookPalette.error : NotebookPalette.muted)
                Spacer()
                Button("Undo") { restore(undo: true) }.disabled(undoBoards.isEmpty)
                Button("Redo") { restore(undo: false) }.disabled(redoBoards.isEmpty)
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Board", action: save).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(NotebookPalette.sputnik)
                    .disabled(board.title.isEmpty || board.sheet.isEmpty || heightError != nil || periodicError != nil || bindingError != nil)
                    .accessibilityIdentifier("board-save")
            }.padding(16)
        }
        .frame(width: 1120, height: 740).background(NotebookPalette.canvas)
        .disabled(model.busy).interactiveDismissDisabled()
        .accessibilityIdentifier("notebook-board-designer")
        .onAppear { model.boardEditorOpen = true; observedBoard = board }
        .onChange(of: try? JSONEncoder().encode(board)) {
            if restoringBoard { restoringBoard = false }
            else if let previous = observedBoard {
                if Date().timeIntervalSince(lastUndo) > 0.5 { undoBoards.append(previous); if undoBoards.count > 100 { undoBoards.removeFirst() } }
                lastUndo = Date(); redoBoards = []
            }
            observedBoard = board
        }
        .onDisappear { model.boardEditorOpen = false; clearDrag() }
        .onChange(of: isDragging) { if !isDragging { clearDrag() } }
        .alert("Could not save board", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Board Designer").font(.title2.bold())
                Text("12 columns per row").font(.caption).foregroundStyle(NotebookPalette.muted)
            }
            NotebookPlotField(title: "Board title") {
                TextField("Board title", text: $board.title).textFieldStyle(.roundedBorder)
            }
            NotebookPlotField(title: "Controller sheet") {
                Picker("Controller sheet", selection: $board.sheet) {
                    ForEach(sheets) { Text($0.title).tag(String($0.id.dropFirst("sheet:".count))) }
                }.labelsHidden()
            }.frame(width: 220)
        }.padding(18)
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("COMPONENT PALETTE").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotebookPalette.muted)
                Spacer()
                if paletteCategory == .services {
                    Text("Nonvisual · belongs to the board").font(.caption).foregroundStyle(NotebookPalette.muted)
                } else {
                Text(selectedRow == nil ? "Add a row to place components" :
                     "Add to row \(rowNumber(selectedRow)) · \(freeColumns)/12 free")
                    .font(.caption).foregroundStyle(NotebookPalette.muted)
                Stepper("Width: \(insertionSpan)/12", value: $insertionSpan, in: 1...12)
                    .frame(width: 150).accessibilityIdentifier("board-insertion-span")
                }
            }
            HStack(spacing: 4) {
                ForEach(NotebookComponentCategory.allCases) { category in
                    Button { paletteCategory = category } label: {
                        Text(category.rawValue).font(.callout.weight(paletteCategory == category ? .semibold : .regular))
                            .foregroundStyle(paletteCategory == category ? NotebookPalette.category(category.rawValue) : NotebookPalette.ink)
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            .background(paletteCategory == category ? NotebookPalette.category(category.rawValue).opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).accessibilityIdentifier("board-category-\(category.rawValue.lowercased())")
                }
                Spacer()
                TextField("Search components…", text: $paletteQuery).textFieldStyle(.roundedBorder).frame(width: 240)
                    .accessibilityIdentifier("board-palette-search")
            }
            ScrollView(.horizontal) {
              HStack(spacing: 8) {
                ForEach(NotebookComponentTool.all.filter { paletteQuery.isEmpty ? $0.category == paletteCategory : ($0.title + " " + $0.detail + " " + $0.category.rawValue).localizedCaseInsensitiveContains(paletteQuery) }) { tool in
                    Button { add(tool) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tool.symbol).font(.system(size: 18)).frame(width: 22)
                                .foregroundStyle(NotebookPalette.category(tool.category.rawValue))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                                Text(tool.detail).font(.system(size: 10)).foregroundStyle(NotebookPalette.muted).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }.padding(8).frame(width: 148, height: 56)
                        .background(NotebookPalette.category(tool.category.rawValue).opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .background(NotebookPalette.card, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(NotebookPalette.category(tool.category.rawValue).opacity(0.35)))
                    }.buttonStyle(.plain)
                        .disabled(unavailableReason(tool) != nil)
                        .accessibilityIdentifier("board-palette-\(tool.id)")
                        .help(unavailableReason(tool) ?? (tool.category == .services ? "Add a nonvisual service to this board" : "Add \(tool.title) to the selected row, using \(insertionSpan) of 12 columns"))
                }
                Spacer(minLength: 0)
              }
            }
        }.padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var canvas: some View {
        VStack(spacing: 0) {
            if !gridPath.isEmpty {
                HStack(spacing: 12) {
                    Button("Back", systemImage: "chevron.left") { leavePanel() }
                        .accessibilityIdentifier("board-panel-back")
                    Text(grid.title).font(.headline).lineLimit(1)
                    Text("Panel grid · level \(gridPath.count)").font(.caption).foregroundStyle(NotebookPalette.muted)
                    Spacer()
                }.padding(.horizontal, 16).padding(.top, 12)
            }
            HStack {
                Label("Layout", systemImage: "square.grid.3x3").font(.headline)
                Text("Drag components between rows").font(.caption).foregroundStyle(NotebookPalette.muted)
                Spacer()
                Button("Add Row", systemImage: "plus") {
                    selectedRow = grid.appendRow(); selectedComponent = nil
                }.disabled(board.allRows.count >= 256).accessibilityIdentifier("board-add-row")
            }.padding(16)
            Divider()
            GeometryReader { geometry in
              ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 16) {
                    ForEach(rows) { row in designRow(row) }
                    serviceTray
                    if rows.isEmpty {
                        ContentUnavailableView("Add the first row", systemImage: "rectangle.split.3x1",
                                               description: Text("Each row has 12 columns. Choose its height and place components from the palette."))
                    }
                }.padding(16).frame(width: 800)
                    .frame(minHeight: geometry.size.height, alignment: .topLeading)
              }
              .coordinateSpace(name: "board-designer-canvas")
              .background(GeometryReader { viewport in
                  Color.clear.preference(key: NotebookBoardDragGeometryKey.self,
                      value: NotebookBoardDragGeometry(viewport: CGRect(origin: .zero, size: viewport.size)))
              })
              .onPreferenceChange(NotebookBoardDragGeometryKey.self) { value in
                  dragGeometry = value
                  if let dragLocation { dropTargetRow = value.row(at: dragLocation) }
              }
              .overlay(alignment: .topLeading) {
                  if let drag = draggedComponent, let point = dragLocation,
                     let component = grid.components.first(where: { $0.id == drag.component }) {
                      Label(component.title, systemImage: NotebookComponentTool.tool(for: component).symbol)
                          .font(.headline).padding(12)
                          .background(NotebookPalette.card, in: RoundedRectangle(cornerRadius: 6))
                          .overlay(RoundedRectangle(cornerRadius: 6).stroke(NotebookPalette.sputnik))
                          .shadow(radius: 8, y: 3).fixedSize()
                          .position(x: point.x + 24, y: point.y - 20)
                          .allowsHitTesting(false)
                  }
              }
            }
        }
    }

    @ViewBuilder private var serviceTray: some View {
        if !board.services.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Services · nonvisual", systemImage: "gearshape.2").font(.headline)
                ForEach(board.services) { component in
                    Button { selectedComponent = component.id } label: {
                        HStack {
                            Image(systemName: "timer").foregroundStyle(NotebookPalette.categoryServices)
                            Text(component.title).fontWeight(.semibold)
                            Text("\(component.module_id ?? "?").\(component.function ?? "?")()")
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(NotebookPalette.muted)
                            Spacer()
                        }.padding(12).background(NotebookPalette.card, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(NotebookPalette.categoryServices.opacity(selectedComponent == component.id ? 1 : 0.4)))
                    }.buttonStyle(.plain).accessibilityIdentifier("board-service-\(component.id)")
                }
            }.padding(14).background(NotebookPalette.editor, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func designRow(_ row: NotebookBoardRow) -> some View {
        let index = rows.firstIndex { $0.id == row.id } ?? 0
        let components = grid.components(in: row.id)
        let selected = selectedRow == row.id
        let targeted = dropTargetRow == row.id
        let border = targeted ? (canDrop(in: row.id) ? NotebookPalette.sputnik : NotebookPalette.error)
            : selected ? NotebookPalette.sputnik : NotebookPalette.rule
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { selectedRow = row.id; selectedComponent = nil } label: {
                    HStack {
                        Image(systemName: "rectangle.split.3x1")
                        Text("Row \(index + 1)").fontWeight(.semibold)
                        Text(row.height.map { "\($0.formatted(.number.precision(.fractionLength(0)))) pt" } ?? "Auto height")
                            .foregroundStyle(NotebookPalette.muted)
                        Text("· \(12 - grid.availableColumns(in: row.id))/12 columns")
                            .foregroundStyle(NotebookPalette.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("board-row-\(index + 1)")
                Button { moveRow(row.id, by: -1) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0).help("Move row up")
                Button { moveRow(row.id, by: 1) } label: { Image(systemName: "arrow.down") }
                    .disabled(index + 1 == rows.count).help("Move row down")
                Button(role: .destructive) {
                    grid.removeRow(row.id)
                    if selected { selectedRow = rows.first?.id; selectedComponent = nil }
                } label: { Image(systemName: "trash") }.help("Delete row and its components")
            }.font(.caption).padding(10).background(selected ? NotebookPalette.sputnik.opacity(0.12) : NotebookPalette.card)
            HStack(spacing: 0) {
                ForEach(1...12, id: \.self) { Text("\($0)").font(.system(size: 10, design: .monospaced)).frame(maxWidth: .infinity) }
            }.foregroundStyle(NotebookPalette.muted).padding(.vertical, 6)
            ZStack(alignment: .topLeading) {
                BoardGridGuides()
                if components.isEmpty {
                    Text("Select this row, then add a component from the palette")
                        .font(.caption).foregroundStyle(NotebookPalette.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedRow = row.id; selectedComponent = nil }
                } else {
                    NotebookBoardRowLayout(height: row.height.map { max(48, min(4096, $0.isFinite ? $0 : 120)) }) {
                        ForEach(components) { component in
                            componentPreview(component)
                                .layoutValue(key: BoardColumnSpan.self, value: component.columnSpan)
                        }
                    }
                }
            }.frame(height: components.isEmpty ? row.height.map { max(48, min(4096, $0.isFinite ? $0 : 120)) } ?? 100 : nil)
                .clipped().padding(10)
        }
        .background(NotebookPalette.editor, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .overlay(RoundedRectangle(cornerRadius: 6).fill(border.opacity(targeted ? 0.08 : 0)).allowsHitTesting(false))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(border, lineWidth: targeted ? 3 : selected ? 2 : 1).allowsHitTesting(false))
        .background(GeometryReader { geometry in
            Color.clear.preference(key: NotebookBoardDragGeometryKey.self,
                value: NotebookBoardDragGeometry(rows: [row.id: geometry.frame(in: .named("board-designer-canvas"))]))
        })
    }

    private func componentPreview(_ component: NotebookBoardComponent) -> some View {
        let tool = NotebookComponentTool.tool(for: component)
        let selected = component.id == selectedComponent
        let content = VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: component.horizontalAlignment, spacing: 10) {
                let heading = HStack(spacing: 5) {
                    Image(systemName: tool.symbol)
                        .foregroundStyle(NotebookPalette.category(tool.category.rawValue))
                    Text(component.title).fontWeight(.semibold).lineLimit(2)
                }.font(.system(size: 12))
                if component.kind == "rich_text" {
                    Button { selectedComponent = component.id; selectedRow = component.row } label: { heading }
                        .buttonStyle(.plain).simultaneousGesture(componentDrag(component))
                } else { heading }
                previewContent(component)
                Text("\(tool.title) · \(component.columnSpan)/12")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(NotebookPalette.muted)
            }
            .frame(maxWidth: component.h_align == nil || component.h_align == "stretch" ? .infinity : nil,
                   maxHeight: component.v_align == "stretch" ? .infinity : nil, alignment: component.cellAlignment)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: component.cellAlignment)
            .multilineTextAlignment(component.textAlignment)
            .background(NotebookPalette.category(tool.category.rawValue).opacity(selected ? 0.11 : 0.035))
            .background(NotebookPalette.card)
            .overlay(alignment: .leading) { NotebookPalette.category(tool.category.rawValue).frame(width: 3).allowsHitTesting(false) }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(NotebookPalette.category(tool.category.rawValue).opacity(selected ? 1 : 0.4), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        return Group {
            if component.kind == "rich_text" { content }
            else {
                Button { selectedComponent = component.id; selectedRow = component.row } label: { content }
                    .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: component.kind == "rich_text" ? .contain : .combine)
        .accessibilityLabel("\(component.title), \(component.columnSpan) columns")
        .accessibilityIdentifier("board-component-\(component.id)")
        .help("Drag to another row")
        .simultaneousGesture(componentDrag(component), including: component.kind == "rich_text" ? .none : .all)
    }

    private func componentDrag(_ component: NotebookBoardComponent) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("board-designer-canvas"))
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                guard !model.busy, model.documentIdentity == document else { return }
                if draggedComponent == nil {
                    draggedComponent = NotebookBoardComponentDrag(session: dragSession, board: board.id, component: component.id)
                    selectedComponent = component.id; selectedRow = component.row
                }
                dragLocation = value.location
                dropTargetRow = dragGeometry.row(at: value.location)
            }
            .onEnded { value in finishDrag(at: value.location) }
    }

    @ViewBuilder private func previewContent(_ component: NotebookBoardComponent) -> some View {
        switch component.kind {
        case "rich_text":
            NotebookTextCellView(content: component.text_content ?? NotebookTextContent(),
                markdown: component.text_mode == "markdown", variables: model.controller(for: board).map { model.textVariables(in: $0) } ?? [],
                onChange: { source, formatting in
                    componentBinding(component).wrappedValue.text_content = NotebookTextContent(source: source, formatting: formatting)
                }, onFocus: { selectedComponent = component.id; selectedRow = component.row })
                .accessibilityIdentifier("board-text-editor-\(component.id)")
        case "result":
            Label("\(cellLabel(component.cell)) · Inspect / Pretty", systemImage: "list.bullet.rectangle")
                .font(.callout).foregroundStyle(NotebookPalette.muted)
        case "stopwatch":
            Label("00:00.00", systemImage: "stopwatch").font(.system(.title2, design: .monospaced))
        case "progress":
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: 0.4)
                Text(component.progress_id.flatMap { $0.isEmpty ? nil : $0 } ?? "All progress channels of the cell")
                    .font(.caption).foregroundStyle(NotebookPalette.muted)
            }
        case "tabs":
            VStack(alignment: .leading, spacing: 8) {
                NotebookBoardTabsView(component: component) { panel in
                    AnyView(Text("\(panel.rows.count) rows · \(panel.components.count) components")
                        .font(.caption).foregroundStyle(NotebookPalette.muted)
                        .frame(maxWidth: .infinity, minHeight: 70))
                }.allowsHitTesting(false)
                Text("Select a panel in the inspector to edit its grid")
                    .font(.caption).foregroundStyle(NotebookPalette.muted)
            }
        case "group", "split":
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(component.panels ?? []) { panel in
                        Text(panel.title).font(.caption).lineLimit(1).padding(6)
                            .background(NotebookPalette.sputnik.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text("\(component.panels?.count ?? 0) panels · select a panel in the inspector to edit its grid")
                    .font(.caption).foregroundStyle(NotebookPalette.muted)
                    .frame(maxWidth: .infinity, minHeight: 70, alignment: .center)
                    .background(NotebookPalette.canvas.opacity(0.5))
            }
        case "input", "range_input":
            if let input = model.snapshot?.inputs?.first(where: { $0.id == component.input }) {
                NotebookInputControlView(input: input, control: component.control ?? NotebookInputControl(), text: .constant(input.editingText))
                    .allowsHitTesting(false)
            } else { Text("Choose input").foregroundStyle(NotebookPalette.muted) }
        case "parameter_form":
            VStack(alignment: .leading, spacing: 8) {
                ForEach((component.fields ?? []).prefix(4)) { field in
                    HStack {
                        Text(model.snapshot?.inputs?.first { $0.id == field.input }?.title ?? "Parameter unavailable")
                        Spacer()
                        Text(field.control.style).foregroundStyle(NotebookPalette.muted)
                    }.font(.caption)
                }
                Text("\(component.fields?.count ?? 0) parameters · Apply together").font(.caption).foregroundStyle(NotebookPalette.muted)
            }.padding(8)
        case "table":
            VStack(alignment: .leading, spacing: 6) {
                Label("\(cellLabel(component.cell)) · Data Table", systemImage: "tablecells")
                Text(component.table_id.flatMap { $0.isEmpty ? nil : $0 } ?? "All published tables")
                    .font(.caption).foregroundStyle(NotebookPalette.muted)
                Text("Sort · Filter · CSV · Markdown").font(.caption).foregroundStyle(NotebookPalette.muted)
            }.font(.callout)
        case "run":
            Label(component.title, systemImage: "play.fill").font(.caption.bold())
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(NotebookPalette.sputnik.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
        case "plot", "live_chart", "image", "image_carousel":
            ZStack {
                BoardGridGuides()
                Image(systemName: NotebookComponentTool.tool(for: component).symbol)
                    .font(.system(size: 38, weight: .light)).foregroundStyle(NotebookPalette.sputnik)
            }.frame(minHeight: 100, maxHeight: component.v_align == "stretch" ? .infinity : 140)
                .background(NotebookPalette.canvas.opacity(0.5))
        default:
            Text(component.binding.flatMap { $0.isEmpty ? nil : $0 } ?? "Cell result")
                .font(.system(size: 24, weight: .medium, design: .rounded)).lineLimit(2)
        }
    }

    @ViewBuilder private var inspector: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Object Inspector", systemImage: "slider.horizontal.3").font(.headline)
            if let id = selectedComponent, let component = board.services.first(where: { $0.id == id }) ?? grid.components.first(where: { $0.id == id }) {
                componentInspector(component)
            } else if let id = selectedRow, let row = rows.first(where: { $0.id == id }) {
                Text("Row \(rowNumber(id))").font(.title3.bold())
                Text("Components occupy up to 12 columns in reading order. Select a cell to edit its properties.")
                    .font(.callout).foregroundStyle(NotebookPalette.muted)
                Toggle("Explicit height", isOn: Binding(get: { rowBinding(row).wrappedValue.height != nil },
                                                       set: { rowBinding(row).wrappedValue.height = $0 ? 240 : nil }))
                    .accessibilityIdentifier("board-row-fixed-height")
                if row.height != nil {
                    NotebookPlotField(title: "Height (pt)") {
                        TextField("Height", value: rowBinding(row).height, format: .number)
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("board-row-height")
                    }
                    Text("48–4096 pt").font(.caption).foregroundStyle(NotebookPalette.muted)
                } else {
                    Text("Height follows the tallest component.").font(.caption).foregroundStyle(NotebookPalette.muted)
                }
                Text("\(grid.availableColumns(in: id)) of 12 columns available").font(.callout)
            } else {
                Text("Select a row or a component on the layout.").foregroundStyle(NotebookPalette.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func componentInspector(_ component: NotebookBoardComponent) -> some View {
        let item = componentBinding(component)
        let tool = NotebookComponentTool.tool(for: component)
        let editsInput = ["input", "range_input", "date_input", "file_input", "parameter_form"].contains(component.kind)
        let siblings = grid.components(in: component.row ?? "")
        let index = siblings.firstIndex { $0.id == component.id } ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            Label(tool.title, systemImage: tool.symbol)
                .font(.title3.bold())
            NotebookPlotField(title: "Component title") {
                TextField("Title", text: item.title).textFieldStyle(.roundedBorder)
            }
            Text(tool.detail).font(.system(size: 10)).foregroundStyle(NotebookPalette.muted)
            if editsInput {
                bindingInspector(component, item: item)
            }
            if ["table", "audio", "image", "image_carousel"].contains(component.kind) {
                NotebookPlotField(title: component.kind == "table" ? "Publish selection to channel" : "Follow selection channel") {
                    TextField("Optional", text: Binding(get: { item.wrappedValue.selection_id ?? "" }, set: { item.wrappedValue.selection_id = $0 }))
                }
                if component.kind == "table" {
                    NotebookPlotField(title: "Stable row key column") {
                        TextField("Unique column name", text: Binding(get: { item.wrappedValue.selection_key ?? "" }, set: { item.wrappedValue.selection_key = $0 }))
                    }
                    Text("Apply shares the typed row with linked images, audio and notebook.selection(channel). Sorting and filtering keep the same key.").font(.caption).foregroundStyle(NotebookPalette.muted)
                } else {
                    NotebookPlotField(title: "Row column containing asset_id") {
                        TextField("asset_id", text: Binding(get: { item.wrappedValue.selection_asset ?? "asset_id" }, set: { item.wrappedValue.selection_asset = $0 }))
                    }
                }
            }
            Divider()
            if component.ownsGrid {
                panelInspector(component, item: item)
                Divider()
            }
            if !component.isService {
            NotebookPlotField(title: "Row") {
                Picker("Row", selection: Binding(get: { item.wrappedValue.row ?? "" }, set: {
                    grid.moveComponent(component.id, to: $0)
                    selectedRow = grid.components.first { $0.id == component.id }?.row
                })) {
                    ForEach(Array(rows.enumerated()).filter {
                        grid.availableColumns(in: $0.element.id, excluding: component.id) >= component.columnSpan
                    }, id: \.element.id) { index, row in
                        Text("Row \(index + 1)").tag(row.id)
                    }
                }.labelsHidden()
            }
            Stepper("Width: \(component.columnSpan) / 12", value: Binding(
                get: { item.wrappedValue.columnSpan }, set: { item.wrappedValue.span = $0 }),
                in: 1...max(1, grid.availableColumns(in: component.row ?? "", excluding: component.id)))
                .accessibilityIdentifier("board-component-span")
            NotebookPlotField(title: "Horizontal alignment") {
                Picker("Horizontal alignment", selection: Binding(
                    get: { item.wrappedValue.h_align ?? "stretch" }, set: { item.wrappedValue.h_align = $0 })) {
                    Text("Left").tag("leading"); Text("Center").tag("center")
                    Text("Right").tag("trailing"); Text("Stretch").tag("stretch")
                }.labelsHidden()
            }
            NotebookPlotField(title: "Vertical alignment") {
                Picker("Vertical alignment", selection: Binding(
                    get: { item.wrappedValue.v_align ?? "top" }, set: { item.wrappedValue.v_align = $0 })) {
                    Text("Top").tag("top"); Text("Center").tag("center")
                    Text("Bottom").tag("bottom"); Text("Stretch").tag("stretch")
                }.labelsHidden()
            }
            HStack {
                Button("Move Left", systemImage: "arrow.left") { moveComponent(component.id, by: -1) }.disabled(index == 0)
                Button("Move Right", systemImage: "arrow.right") { moveComponent(component.id, by: 1) }.disabled(index + 1 == siblings.count)
            }.controlSize(.small)
            Divider()
            }
            if !component.ownsGrid && !editsInput { bindingInspector(component, item: item) }
            Divider()
            Button("Duplicate Component", systemImage: "plus.square.on.square") { duplicate(component) }
                .disabled(component.isService || board.allComponents.count >= 256)
            Button("Delete Component", systemImage: "trash", role: .destructive) {
                if component.isService { board.components.removeAll { $0.id == component.id } }
                else { grid.components.removeAll { $0.id == component.id } }
                selectedComponent = nil
            }
        }
    }

    @ViewBuilder private func bindingInspector(_ component: NotebookBoardComponent, item: Binding<NotebookBoardComponent>) -> some View {
        if component.isService {
            periodicInspector(component, item: item)
        } else if component.kind == "split" {
            Picker("Direction", selection: Binding(get: { item.wrappedValue.split_axis ?? "horizontal" }, set: { item.wrappedValue.split_axis = $0 })) { Text("Side by side").tag("horizontal"); Text("Stacked").tag("vertical") }
            Slider(value: Binding(get: { item.wrappedValue.split_fraction ?? 0.5 }, set: { item.wrappedValue.split_fraction = $0 }), in: 0.1...0.9).accessibilityLabel("Initial divider position")
            TextField("Minimum panel size", value: Binding(get: { item.wrappedValue.split_min ?? 120 }, set: { item.wrappedValue.split_min = $0 }), format: .number)
        } else if component.kind == "group" {
            NotebookP1Inspector(model: model, board: board, item: item)
        } else if component.kind == "range_input" {
            NotebookProjectInputPicker(model: model, allowedTypes: ["range"],
                selection: Binding(get: { item.wrappedValue.input ?? "" }, set: { item.wrappedValue.input = $0 }))
            if let input = model.snapshot?.inputs?.first(where: { $0.id == component.input && $0.type == "range" }) {
                NotebookInputControlEditor(input: input, control: Binding(
                    get: { item.wrappedValue.control ?? NotebookInputControl() }, set: { item.wrappedValue.control = $0 }))
                NotebookRangeInputView(model: model, input: input, control: component.control ?? NotebookInputControl())
            }
            Text("Read the Range value with notebook.input(\"\(component.input ?? "some_range")\").").font(.caption).foregroundStyle(NotebookPalette.muted)
        } else if component.kind == "date_input" {
            NotebookProjectInputPicker(model: model, allowedTypes: ["string"],
                selection: Binding(get: { item.wrappedValue.input ?? "" }, set: { item.wrappedValue.input = $0 }))
            Picker("Value", selection: Binding(get: { item.wrappedValue.date_mode ?? "date_time" }, set: { item.wrappedValue.date_mode = $0 })) { Text("Date and time").tag("date_time"); Text("Calendar date").tag("date") }
            TextField("IANA time zone", text: Binding(get: { item.wrappedValue.date_time_zone ?? "UTC" }, set: { item.wrappedValue.date_time_zone = $0 }))
        } else if component.kind == "audio_annotator" {
            Picker("Audio source", selection: Binding(get: { item.wrappedValue.audio_source ?? "file" }, set: { item.wrappedValue.audio_source = $0 })) {
                Text("Own file").tag("file"); Text("Audio Input channel").tag("input"); Text("Cell output").tag("cell")
            }
            NotebookPlotField(title: "Audio channel") { TextField("Channel", text: Binding(get: { item.wrappedValue.audio_id ?? component.id }, set: { item.wrappedValue.audio_id = $0 })) }
            if component.audio_source == "cell" {
                Picker("Source cell", selection: Binding(get: { item.wrappedValue.cell ?? "" }, set: { item.wrappedValue.cell = $0 })) {
                    Text("Choose cell…").tag(""); ForEach(cells) { Text(cellLabel($0.id)).tag($0.id) }
                }
            }
            NotebookPlotField(title: "Annotations channel") { TextField("Labels", text: Binding(get: { item.wrappedValue.annotation_id ?? component.id + "_labels" }, set: { item.wrappedValue.annotation_id = $0 })) }
            Picker("Initial view", selection: Binding(get: { item.wrappedValue.audio_view ?? "waveform" }, set: { item.wrappedValue.audio_view = $0 })) {
                Text("Waveform").tag("waveform"); Text("Spectrogram · plasma").tag("spectrogram")
            }
            Picker("FFT size", selection: Binding(get: { item.wrappedValue.audio_fft_size ?? 1024 }, set: { item.wrappedValue.audio_fft_size = $0 })) { ForEach([256, 512, 1024, 2048, 4096], id: \.self) { Text(String($0)).tag($0) } }
            NotebookAnnotationSettingsView(component: item)
            Text("Annotate a completed file or track. Apply saves classes, attributes, transcript and source-frame / Hz bounds. Read with notebook.audio_annotations(channel).").font(.caption).foregroundStyle(NotebookPalette.muted)
        } else if component.kind == "audio_input" {
            NotebookPlotField(title: "Audio input channel") {
                TextField("Channel", text: Binding(get: { item.wrappedValue.audio_id ?? item.wrappedValue.id }, set: { item.wrappedValue.audio_id = $0 }))
            }
            Toggle("Allow microphone recording", isOn: Binding(get: { item.wrappedValue.audio_recording ?? true }, set: { item.wrappedValue.audio_recording = $0 }))
            Text("Choose or record a draft in Run mode, then Apply. Code reads AudioTrack.from_input(channel).").font(.caption).foregroundStyle(NotebookPalette.muted)
        } else if ["parameter_presets", "file_input", "action", "execution_controls", "status"].contains(component.kind) {
            NotebookP1Inspector(model: model, board: board, item: item)
        } else if component.kind == "tabs" {
            panelInspector(component, item: item)
        } else if component.kind == "rich_text" {
            NotebookPlotField(title: "Text format") {
                Picker("Text format", selection: Binding(get: { item.wrappedValue.text_mode ?? "richtext" },
                    set: { item.wrappedValue.text_mode = $0 })) {
                    Text("Rich text").tag("richtext"); Text("Markdown").tag("markdown")
                }.labelsHidden()
            }
            Text("Edit the source on the canvas. Run mode renders {{name}} from published controller-sheet values.")
                .font(.caption).foregroundStyle(NotebookPalette.muted)
        } else if component.kind == "parameter_form" {
            formInspector(component, item: item)
        } else if component.kind == "input" {
            let config = component.control?.style == "json"
            NotebookProjectInputPicker(model: model, title: config ? "Config" : "Parameter", allowedTypes: config ? ["string"] : NotebookProjectInput.types, configJSON: config, configFormat: component.control?.configFormat ?? .json,
                selection: Binding(get: { item.wrappedValue.input ?? "" }, set: { item.wrappedValue.input = $0; if !config { item.wrappedValue.control = nil } }))
            if config {
                NotebookConfigSettings(format: Binding(get: { item.wrappedValue.control?.config_format }, set: { item.wrappedValue.control?.config_format = $0 }))
            } else if let input = model.snapshot?.inputs?.first(where: { $0.id == component.input }) {
                NotebookInputControlEditor(input: input, control: Binding(get: { item.wrappedValue.control ?? NotebookInputControl() }, set: { item.wrappedValue.control = $0 }))
            }
        } else if component.kind == "image" || component.kind == "image_carousel" {
            NotebookPlotField(title: "Channel ID") {
                TextField("ID used by publish_image / publish_images", text: Binding(
                    get: { item.wrappedValue.image_id ?? component.id }, set: { item.wrappedValue.image_id = $0 }))
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("board-image-channel")
            }
            NotebookPlotField(title: "Image sizing") {
                Picker("Image sizing", selection: Binding(
                    get: { item.wrappedValue.image_mode ?? "fit" }, set: { item.wrappedValue.image_mode = $0 })) {
                    Text("Fit").tag("fit"); Text("Fill").tag("fill"); Text("Auto height").tag("auto-height")
                }.labelsHidden().accessibilityIdentifier("board-image-mode")
            }
            NotebookPlotField(title: "Series caption (default)") {
                TextField("Caption", text: Binding(get: { item.wrappedValue.caption ?? "" }, set: { item.wrappedValue.caption = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
            Text("Fit shows the complete image. Fill crops to the viewport. Auto height follows the image's aspect ratio; use an auto-height row.")
                .font(.caption).foregroundStyle(NotebookPalette.muted)
            Divider()
            Toggle("Enable image annotations", isOn: Binding(get: { item.wrappedValue.image_annotator ?? false }, set: { item.wrappedValue.image_annotator = $0 }))
                .accessibilityIdentifier("board-image-annotator")
            if component.image_annotator == true {
                NotebookAnnotationSettingsView(component: item)
                NotebookPlotField(title: "Annotations channel") {
                    TextField("Labels", text: Binding(get: { item.wrappedValue.annotation_id ?? component.id + "_labels" }, set: { item.wrappedValue.annotation_id = $0 }))
                }
                Text("Points and rectangles use source pixels. notebook.annotations(channel) reads the accepted labels for the current image.").font(.caption).foregroundStyle(NotebookPalette.muted)
            }
            Toggle("Allow saving to a file", isOn: Binding(get: { item.wrappedValue.image_allow_save ?? false }, set: { item.wrappedValue.image_allow_save = $0 }))
                .accessibilityIdentifier("board-image-allow-save")
            Toggle("Allow loading and editing images", isOn: Binding(get: { item.wrappedValue.image_allow_load ?? false }, set: { item.wrappedValue.image_allow_load = $0 }))
                .accessibilityIdentifier("board-image-allow-load")
            Toggle("Allow reading from sheet code", isOn: Binding(get: { item.wrappedValue.image_allow_read ?? false }, set: { item.wrappedValue.image_allow_read = $0 }))
                .accessibilityIdentifier("board-image-allow-read")
            if component.image_allow_read == true {
                Text("read_image(\"\(component.image_id ?? component.id)\") reads the selected frame. read_images(…) reads the ordered series.")
                    .font(.caption).foregroundStyle(NotebookPalette.muted).textSelection(.enabled)
            }
        } else if component.kind == "live_chart" {
            NotebookP1Inspector(model: model, board: board, item: item)
            NotebookPlotField(title: "Caption") {
                TextField("Caption below the chart", text: Binding(
                    get: { item.wrappedValue.caption ?? "" }, set: { item.wrappedValue.caption = $0 }))
            }
            NotebookPlotField(title: "Channel ID") {
                TextField("ID used by publish_point", text: Binding(
                    get: { item.wrappedValue.chart_id ?? "" }, set: { item.wrappedValue.chart_id = $0 }))
            }
            NotebookPlotField(title: "X axis label") {
                TextField("X", text: Binding(get: { item.wrappedValue.x_label ?? "X" }, set: { item.wrappedValue.x_label = $0 }))
            }
            NotebookPlotField(title: "Y axis label") {
                TextField("Y", text: Binding(get: { item.wrappedValue.y_label ?? "Y" }, set: { item.wrappedValue.y_label = $0 }))
            }
            NotebookPlotField(title: "Line color (#rrggbb)") {
                TextField("#d97706", text: Binding(get: { item.wrappedValue.stroke ?? "#d97706" }, set: { item.wrappedValue.stroke = $0 }))
            }
            chartRange("X", low: item.x_min, high: item.x_max)
            chartRange("Y", low: item.y_min, high: item.y_max)
            Text("Empty limits follow incoming points. Code publishes to this channel.")
                .font(.caption).foregroundStyle(NotebookPalette.muted)
        } else if component.kind == "stopwatch" {
            NotebookPlotField(title: "Stopwatch ID") {
                TextField("default", text: Binding(get: { item.wrappedValue.stopwatch_id ?? "default" }, set: { item.wrappedValue.stopwatch_id = $0 }))
            }
            Text("from notebook.ui import Stopwatch\nStopwatch.measure(\"\(component.stopwatch_id ?? "default")\"):\n  # measured code")
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        } else {
            NotebookPlotField(title: "Cell") {
                Picker("Cell", selection: Binding(get: { item.wrappedValue.cell ?? "" }, set: { item.wrappedValue.cell = $0 })) {
                    Text("Choose cell…").tag("")
                    if let selected = component.cell, !selected.isEmpty, !cells.contains(where: { $0.id == selected }) {
                        Text("Source cell unavailable").tag(selected)
                    }
                    ForEach(cells) { cell in
                        Text("\(cellLabel(cell.id)) · ID \(cell.id) · \(cell.source.components(separatedBy: .newlines).first ?? "")").tag(cell.id)
                    }
                }.labelsHidden()
            }
            if component.kind == "metric" { NotebookP1Inspector(model: model, board: board, item: item) }
            if component.kind == "text" {
                NotebookPlotField(title: "Variable (empty = cell result)") {
                    TextField("Cell result", text: Binding(get: { item.wrappedValue.binding ?? "" }, set: { item.wrappedValue.binding = $0 }))
                }
            }
            if component.kind == "progress" {
                Text("Choose the code cell that publishes progress. Parameters in another cell do not publish the training cell's progress.")
                    .font(.caption).foregroundStyle(NotebookPalette.muted)
                NotebookPlotField(title: "Progress ID (empty = all cell channels)") {
                    TextField("All channels", text: Binding(get: { item.wrappedValue.progress_id ?? "" },
                        set: { item.wrappedValue.progress_id = $0 })).textFieldStyle(.roundedBorder)
                }
                if let cell = cells.first(where: { $0.id == component.cell }), let tab = model.controller(for: board) {
                    ForEach(model.presentation(for: cell, in: tab).progress) { progress in
                        Button(progress.id) { item.wrappedValue.progress_id = progress.id }.controlSize(.small)
                    }
                }
            }
            if component.kind == "audio" {
                NotebookPlotField(title: "Audio channel (empty = all)") {
                    TextField("All audio", text: Binding(get: { item.wrappedValue.audio_id ?? "" }, set: { item.wrappedValue.audio_id = $0 }))
                }
                Toggle("Show waveform", isOn: Binding(get: { item.wrappedValue.show_waveform ?? true }, set: { item.wrappedValue.show_waveform = $0 }))
                Text("Saved with the board. Overrides the published player's waveform setting.").font(.caption).foregroundStyle(NotebookPalette.muted)
            }
            if component.kind == "table" {
                Text("Publish DataTableView with notebook.show. An empty channel shows all tables published by the selected cell.")
                    .font(.caption).foregroundStyle(NotebookPalette.muted)
                NotebookPlotField(title: "Table channel (empty = all)") {
                    TextField("All tables", text: Binding(get: { item.wrappedValue.table_id ?? "" },
                        set: { item.wrappedValue.table_id = $0 })).textFieldStyle(.roundedBorder)
                }
                if let cell = cells.first(where: { $0.id == component.cell }), let tab = model.controller(for: board) {
                    ForEach(model.presentation(for: cell, in: tab).figures.filter { $0.mime == "application/vnd.sputnik.table+json" && $0.id?.isEmpty == false }, id: \.id) { panel in
                        Button(panel.caption.isEmpty ? panel.id! : panel.caption) { item.wrappedValue.table_id = panel.id }.controlSize(.small)
                    }
                }
            }
        }
    }

    private func formInspector(_ component: NotebookBoardComponent, item: Binding<NotebookBoardComponent>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fields share one draft and one Apply. Manual cells run with the board's Run button.")
                .font(.caption).foregroundStyle(NotebookPalette.muted)
            ForEach(Array((component.fields ?? []).enumerated()), id: \.element.id) { index, field in
                if let input = model.snapshot?.inputs?.first(where: { $0.id == field.input }) {
                    DisclosureGroup(input.title) {
                        NotebookInputControlEditor(input: input, control: Binding(get: {
                            item.wrappedValue.fields?.first { $0.input == field.input }?.control ?? NotebookInputControl()
                        }, set: { control in
                            if let position = item.wrappedValue.fields?.firstIndex(where: { $0.input == field.input }) {
                                item.wrappedValue.fields?[position].control = control
                            }
                        }))
                        HStack {
                            Button("Up") { item.wrappedValue.fields?.swapAt(index, index - 1) }.disabled(index == 0)
                            Button("Down") { item.wrappedValue.fields?.swapAt(index, index + 1) }.disabled(index + 1 >= (component.fields?.count ?? 0))
                            Button("Remove", role: .destructive) { item.wrappedValue.fields?.removeAll { $0.input == field.input } }
                        }.controlSize(.small)
                    }
                }
            }
            NotebookProjectInputPicker(model: model, title: "Add parameter",
                excludedIDs: (component.fields ?? []).map(\.input),
                selection: Binding(get: { "" }, set: { id in
                    guard !id.isEmpty, !(item.wrappedValue.fields ?? []).contains(where: { $0.input == id }) else { return }
                    if item.wrappedValue.fields == nil { item.wrappedValue.fields = [] }
                    item.wrappedValue.fields?.append(NotebookFormField(input: id, control: NotebookInputControl()))
                }))
                .disabled((component.fields?.count ?? 0) >= 128)
        }
    }

    private func periodicInspector(_ component: NotebookBoardComponent, item: Binding<NotebookBoardComponent>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NotebookPlotField(title: "Notebook module") {
                Picker("Notebook module", selection: Binding(get: { item.wrappedValue.module_id ?? "" }, set: { item.wrappedValue.module_id = $0 })) {
                    Text("Choose module…").tag("")
                    if let selected = component.module_id, !selected.isEmpty,
                       model.snapshot?.tabs.contains(where: { $0.id == "module:" + selected }) != true {
                        Text("\(selected) · unavailable").tag(selected)
                    }
                    ForEach(model.snapshot?.tabs.filter { $0.kind == "module" } ?? []) { tab in
                        Text(tab.title).tag(String(tab.id.dropFirst("module:".count)))
                    }
                }.labelsHidden().accessibilityIdentifier("board-periodic-module")
            }
            NotebookPlotField(title: "Exported function (no arguments)") {
                TextField("tick", text: Binding(get: { item.wrappedValue.function ?? "" }, set: { item.wrappedValue.function = $0 }))
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("board-periodic-function")
            }
            NotebookPlotField(title: "Period (seconds)") {
                TextField("60", value: Binding(get: { item.wrappedValue.period_seconds ?? 60 }, set: { item.wrappedValue.period_seconds = $0 }), format: .number)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("board-periodic-period")
            }
            Picker("Schedule", selection: Binding(get: { item.wrappedValue.timing ?? "fixed_delay" }, set: { item.wrappedValue.timing = $0 })) {
                Text("After completion").tag("fixed_delay")
                Text("Start to start · skip overlaps").tag("fixed_rate")
            }.accessibilityIdentifier("board-periodic-timing")
            Text(component.periodicSettings.timing == "fixed_rate" ?
                 "Starts follow the period from the previous start. Missed ticks are skipped; runs never overlap." :
                 "Wait the full period after work and its child tasks finish.")
                .font(.caption).foregroundStyle(NotebookPalette.muted)
            Divider()
            Picker("History", selection: Binding(get: { item.wrappedValue.retention ?? "tail" }, set: { item.wrappedValue.retention = $0 })) {
                Text("None").tag("none"); Text("All runs").tag("all"); Text("Last N runs").tag("tail")
            }.accessibilityIdentifier("board-periodic-retention")
            if component.periodicSettings.retention == "tail" {
                NotebookPlotField(title: "N") {
                    TextField("100", value: Binding(get: { item.wrappedValue.tail_limit ?? 100 }, set: { item.wrappedValue.tail_limit = $0 }), format: .number)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Toggle("Store returned values", isOn: Binding(get: { item.wrappedValue.store_values ?? true }, set: { item.wrappedValue.store_values = $0 }))
            Toggle("Store errors", isOn: Binding(get: { item.wrappedValue.store_errors ?? true }, set: { item.wrappedValue.store_errors = $0 }))
            Divider()
            Toggle("First run immediately", isOn: Binding(get: { item.wrappedValue.run_immediately ?? true }, set: { item.wrappedValue.run_immediately = $0 }))
            Toggle("Stop on error", isOn: Binding(get: { item.wrappedValue.stop_on_error ?? false }, set: { item.wrappedValue.stop_on_error = $0 }))
            Toggle("Pause while board is hidden", isOn: Binding(get: { item.wrappedValue.pause_when_hidden ?? true }, set: { item.wrappedValue.pause_when_hidden = $0 }))
            Text("Start explicitly on the board. History is kept for this session. Saving settings leaves the service stopped.")
                .font(.caption).foregroundStyle(NotebookPalette.muted)
            if let message = component.periodicSettings.validationError { Text(message).font(.caption).foregroundStyle(NotebookPalette.error) }
        }
    }

    private var canAddTabs: Bool {
        gridPath.count < 8 && board.allRows.count <= 254 && board.panelCount <= 126
    }

    private func panelInspector(_ component: NotebookBoardComponent, item: Binding<NotebookBoardComponent>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Panels").font(.headline)
            ForEach(Array((component.panels ?? []).enumerated()), id: \.element.id) { index, panel in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Panel title", text: Binding(get: {
                        item.wrappedValue.panels?.first { $0.id == panel.id }?.title ?? panel.title
                    }, set: { title in
                        if let i = item.wrappedValue.panels?.firstIndex(where: { $0.id == panel.id }) {
                            item.wrappedValue.panels?[i].title = title
                        }
                    })).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("board-panel-title-\(panel.id)")
                    HStack(spacing: 8) {
                        Button("Edit Grid", systemImage: "square.grid.3x3") { openPanel(component: component.id, panel: panel.id) }
                            .accessibilityIdentifier("board-edit-panel-\(panel.id)")
                        Spacer(minLength: 0)
                        Button { movePanel(panel.id, in: item, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0).help("Move panel earlier")
                        Button { movePanel(panel.id, in: item, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index + 1 == component.panels?.count).help("Move panel later")
                        Button(role: .destructive) {
                            item.wrappedValue.panels?.removeAll { $0.id == panel.id }
                        } label: { Image(systemName: "trash") }
                            .disabled((component.panels?.count ?? 0) <= 1).help("Delete panel and its grid")
                    }.controlSize(.small)
                    Text("\(panel.rows.count) rows · \(panel.components.count) components")
                        .font(.caption).foregroundStyle(NotebookPalette.muted)
                }.padding(10).background(NotebookPalette.canvas, in: RoundedRectangle(cornerRadius: 5))
            }
            if component.kind == "tabs" { Button("Add Panel", systemImage: "plus") {
                item.wrappedValue.panels?.append(.empty(title: "Tab \((item.wrappedValue.panels?.count ?? 0) + 1)"))
            }.disabled((component.panels?.count ?? 0) >= 32 || board.panelCount >= 128 || board.allRows.count >= 256)
                .accessibilityIdentifier("board-add-panel") }
        }
    }

    private func movePanel(_ id: String, in item: Binding<NotebookBoardComponent>, by offset: Int) {
        guard let index = item.wrappedValue.panels?.firstIndex(where: { $0.id == id }),
              item.wrappedValue.panels?.indices.contains(index + offset) == true else { return }
        item.wrappedValue.panels?.swapAt(index, index + offset)
    }
    private func openPanel(component: String, panel: String) {
        clearDrag()
        gridPath.append(NotebookBoardGridPath(component: component, panel: panel))
        selectedRow = rows.first?.id; selectedComponent = nil
    }
    private func leavePanel() {
        guard let parent = gridPath.popLast() else { return }
        clearDrag()
        selectedComponent = parent.component
        selectedRow = grid.components.first { $0.id == parent.component }?.row
    }

    private func chartRange(_ axis: String, low: Binding<Double?>, high: Binding<Double?>) -> some View {
        HStack {
            NotebookPlotField(title: "\(axis) minimum") { TextField("Automatic", value: low, format: .number) }
            NotebookPlotField(title: "\(axis) maximum") { TextField("Automatic", value: high, format: .number) }
        }.textFieldStyle(.roundedBorder)
    }
    private func rowBinding(_ row: NotebookBoardRow) -> Binding<NotebookBoardRow> {
        let path = gridPath
        return Binding(get: { board.grid(at: path)?.rows?.first { $0.id == row.id } ?? row }, set: { value in
            guard var target = board.grid(at: path), let index = target.rows?.firstIndex(where: { $0.id == row.id }) else { return }
            target.rows?[index] = value
            board.updateGrid(target, at: path)
        })
    }
    private func componentBinding(_ component: NotebookBoardComponent) -> Binding<NotebookBoardComponent> {
        if component.isService {
            return Binding(get: { board.components.first { $0.id == component.id } ?? component }, set: { value in
                if let index = board.components.firstIndex(where: { $0.id == component.id }) { board.components[index] = value }
            })
        }
        let path = gridPath
        return Binding(get: { board.grid(at: path)?.components.first { $0.id == component.id } ?? component }, set: { value in
            guard var target = board.grid(at: path), let index = target.components.firstIndex(where: { $0.id == component.id }) else { return }
            target.components[index] = value
            board.updateGrid(target, at: path)
        })
    }
    private func rowNumber(_ id: String?) -> Int { (rows.firstIndex { $0.id == id } ?? 0) + 1 }
    private func canDrop(in row: String) -> Bool {
        !model.busy && model.documentIdentity == document &&
        draggedComponent?.canDrop(in: grid, session: dragSession, row: row) == true
    }
    private func finishDrag(at point: CGPoint) {
        defer { clearDrag() }
        guard let drag = draggedComponent, let row = dragGeometry.row(at: point), canDrop(in: row) else { return }
        if grid.moveComponent(drag.component, to: row) {
            selectedComponent = drag.component; selectedRow = row
        }
    }
    private func clearDrag() {
        draggedComponent = nil; dropTargetRow = nil; dragLocation = nil
    }
    private func moveRow(_ id: String, by offset: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows.indices.contains(index + offset) else { return }
        grid.rows?.swapAt(index, index + offset)
    }
    private func moveComponent(_ id: String, by offset: Int) {
        guard let component = grid.components.first(where: { $0.id == id }) else { return }
        let siblings = grid.components(in: component.row ?? "")
        guard let index = siblings.firstIndex(where: { $0.id == id }), siblings.indices.contains(index + offset),
              let first = grid.components.firstIndex(where: { $0.id == id }),
              let second = grid.components.firstIndex(where: { $0.id == siblings[index + offset].id }) else { return }
        grid.components.swapAt(first, second)
    }
    private func unavailableReason(_ tool: NotebookComponentTool) -> String? {
        if board.allComponents.count >= 256 { return "The board has reached its 256-component limit." }
        if tool.category != .services {
            if selectedRow == nil { return "Add and select a row first." }
            if insertionSpan > freeColumns { return "Not enough space: \(insertionSpan) columns required, \(freeColumns) free. Reduce Width or add a row." }
        }
        if ["tabs", "group", "split"].contains(tool.id) && !canAddTabs { return "The board's panel, row or nesting limit has been reached." }
        if ["action", "periodic_work"].contains(tool.id) && model.snapshot?.tabs.contains(where: { $0.kind == "module" }) != true { return "Add a notebook module first." }
        if ["text", "metric", "log", "artifacts", "run", "result", "table", "plot", "progress"].contains(tool.id) && cells.isEmpty { return "Add a code cell to the controller sheet first." }
        return nil
    }
    private func add(_ tool: NotebookComponentTool) {
        if tool.category == .services {
            guard board.allComponents.count < 256 else { return }
            let id = NotebookBoard.newID("component")
            board.components.append(NotebookBoardComponent(id: id, kind: tool.id, title: tool.title,
                module_id: model.snapshot?.tabs.first(where: { $0.kind == "module" }).map { String($0.id.dropFirst("module:".count)) },
                function: "tick", period_seconds: 60, timing: "fixed_delay", retention: "tail", tail_limit: 100,
                store_values: true, store_errors: true, run_immediately: true, stop_on_error: false, pause_when_hidden: true))
            selectedComponent = id
            return
        }
        guard let row = selectedRow, insertionSpan <= freeColumns, board.allComponents.count < 256, !["tabs", "group", "split"].contains(tool.id) || canAddTabs else { return }
        let id = NotebookBoard.newID("component")
        let isImage = tool.componentKind == "image" || tool.componentKind == "image_carousel"
        let sourceCell = tool.id == "progress"
            ? model.controller(for: board).flatMap { model.suggestedProgressCell(in: $0) }?.id ?? ""
            : cells.first?.id ?? ""
        grid.components.append(NotebookBoardComponent(id: id, kind: tool.componentKind, title: tool.title,
            input: ["input", "config_editor", "range_input", "file_input", "date_input"].contains(tool.id) ? "" : nil,
            cell: ["input", "config_editor", "parameter_form", "parameter_presets", "file_input", "audio_input", "audio_annotator", "range_input", "date_input", "run_history", "experiment_compare", "task_monitor", "action", "status", "execution_controls", "stopwatch", "live_chart", "tabs", "group", "split", "rich_text"].contains(tool.id) || isImage ? nil : sourceCell, binding: nil,
            chart_id: tool.id == "live_chart" ? "chart_" + String(UUID().uuidString.lowercased().prefix(8)) : nil,
            image_id: isImage ? "images_" + String(UUID().uuidString.lowercased().prefix(8)) : nil,
            image_mode: isImage ? "fit" : nil,
            image_allow_load: tool.id == "image_annotator" ? true : nil,
            image_annotator: tool.id == "image_annotator" ? true : nil,
            x_label: tool.id == "live_chart" ? "X" : nil, y_label: tool.id == "live_chart" ? "Y" : nil,
            stroke: tool.id == "live_chart" ? "#d97706" : nil,
            row: row, span: insertionSpan, h_align: "stretch", v_align: tool.id == "live_chart" || tool.id == "tabs" ? "stretch" : "top",
            panels: tool.id == "split" ? [.empty(title: "Panel 1"), .empty(title: "Panel 2")] : tool.id == "tabs" ? [.empty(title: "Tab 1"), .empty(title: "Tab 2")] : tool.id == "group" ? [.empty(title: "Group")] : nil,
            module_id: tool.id == "action" ? model.snapshot?.tabs.first(where: { $0.kind == "module" }).map { String($0.id.dropFirst(7)) } : nil,
            function: tool.id == "action" ? "run" : nil,
            text_content: tool.id == "rich_text" ? NotebookTextContent(source: "Write text here.") : nil,
            text_mode: tool.id == "rich_text" ? "richtext" : nil,
            control: tool.id == "config_editor" ? NotebookInputControl(style: "json") : nil,
            fields: tool.id == "parameter_form" ? [] : nil))
        selectedComponent = id
    }
    private func restore(undo: Bool) {
        guard let previous = undo ? undoBoards.popLast() : redoBoards.popLast() else { return }
        if undo { redoBoards.append(board) } else { undoBoards.append(board) }
        restoringBoard = true; board = previous; observedBoard = previous
        gridPath = []; selectedRow = rows.first?.id; selectedComponent = nil
    }
    private func duplicate(_ component: NotebookBoardComponent) {
        guard board.allComponents.count < 256 else { return }
        var identities: [String: String] = [:]
        func clone(_ source: NotebookBoardComponent) -> NotebookBoardComponent {
            var value = source; value.id = NotebookBoard.newID("component"); identities[source.id] = value.id
            if var panels = value.panels {
                for i in panels.indices {
                    panels[i].id = NotebookBoard.newID("panel")
                    let rowIDs = Dictionary(uniqueKeysWithValues: panels[i].rows.map { ($0.id, NotebookBoard.newID("row")) })
                    panels[i].rows = panels[i].rows.map { NotebookBoardRow(id: rowIDs[$0.id]!, height: $0.height) }
                    panels[i].components = panels[i].components.map { source in var c = clone(source); c.row = source.row.flatMap { rowIDs[$0] }; return c }
                }
                value.panels = panels
            }
            return value
        }
        func remap(_ source: NotebookBoardComponent) -> NotebookBoardComponent {
            var result = source
            if let old = result.settings.target_component, let replacement = identities[old] { var settings = result.settings; settings.target_component = replacement; result.p1 = settings }
            if var panels = result.panels { for i in panels.indices { panels[i].components = panels[i].components.map(remap) }; result.panels = panels }
            return result
        }
        var copy = remap(clone(component)); copy.title += " copy"
        if grid.availableColumns(in: component.row ?? "") < copy.columnSpan { copy.row = grid.appendRow() }
        grid.components.append(copy); selectedComponent = copy.id; selectedRow = copy.row
    }
    private func save() {
        guard model.documentIdentity == document else { saveError = "Project changed. Close this editor."; return }
        model.saveBoard(board) { success in
            if success { dismiss() } else { saveError = model.error; model.clearError() }
        }
    }
}

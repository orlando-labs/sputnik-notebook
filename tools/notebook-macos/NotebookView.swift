import SwiftUI

struct NotebookView: View {
    @Environment(\.greekLetterSubstitutionEnabled) private var substituteGreekLetters
    @ObservedObject var model: NotebookModel

    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var collapsedCells = Set<String>()
    @State private var structurePrompt: StructurePrompt?
    @State private var pendingDelete: DeleteTarget?
    @State private var boardPrompt: NotebookBoard?
    @State private var componentCell: NotebookCell?
    @State private var exportCell: NotebookCell?
    @State private var showSheetImports = false
    @State private var cellIDTarget: CellIDTarget?
    @State private var manageInputs = false
    @State private var renameTarget: NotebookTab?
    @State private var deleteSheetTarget: NotebookTab?
    @State private var newMarkdown = false
    @State private var markdownName = ""
    @State private var sheetName = ""

    private var activeTab: NotebookTab? {
        model.activeTab
    }

    private var selectedCell: NotebookCell? {
        guard let tab = activeTab else { return nil }
        return tab.cells.first { $0.id == model.selectedCellID }
            ?? tab.cells.first { $0.id == tab.selected_cell }
            ?? tab.cells.first
    }

    private var isModule: Bool { activeTab?.kind == "module" }
    private var collapseEligibleCells: Set<String> {
        Set((model.snapshot?.tabs ?? []).flatMap { tab in
            tab.cells.filter { tab.kind == "module" || $0.canCollapseSource }.map { tab.id + ":" + $0.id }
        })
    }

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                notebookWorkspace(snapshot)
                    .id(model.documentIdentity)
            } else {
                welcomeView
            }
        }
        .onChange(of: collapseEligibleCells) { collapsedCells.formIntersection(collapseEligibleCells) }
        .onChange(of: model.documentIdentity) { collapsedCells.removeAll() }
        .onChange(of: model.cellNavigation) {
            if let location = model.cellNavigation?.location {
                collapsedCells.remove(location.tab + ":" + location.cell)
            }
        }
        .background(NotebookPalette.canvas)
        .foregroundStyle(NotebookPalette.ink)
        .tint(NotebookPalette.sputnik)
        .accentColor(NotebookPalette.sputnik)
        .frame(minWidth: 930, minHeight: 640)
        .alert("Notebook", isPresented: Binding(
            get: { model.error != nil && !model.boardWindowFocused },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("OK", role: .cancel) { model.clearError() }
        } message: {
            Text(model.error ?? "")
        }
        .confirmationDialog(
            "Delete this cell?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Cell", role: .destructive) {
                guard let target = pendingDelete else { return }
                model.perform("delete_cell", tab: target.tab, cell: target.cell)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("The cell and its source will be removed from this sheet.")
        }
        .sheet(item: $structurePrompt) { prompt in
            StructurePromptSheet(prompt: prompt) { name in
                if prompt.kind == .sheet {
                    model.perform("new_named_sheet", text: name, commandCellID: newSheetID())
                } else {
                    model.perform("new_module", text: name)
                }
                structurePrompt = nil
            } onCancel: {
                structurePrompt = nil
            }
        }
        .sheet(item: $cellIDTarget) { target in
            NotebookCellIDEditor(model: model, cell: target.cell, tab: target.tab)
        }
        .sheet(isPresented: $model.showDependencies) { NotebookDependenciesView(model: model) }
        .sheet(isPresented: $manageInputs) { NotebookProjectInputsView(model: model) }
        .sheet(isPresented: $newMarkdown) {
            VStack(alignment: .leading, spacing: 14) {
                Text("New Markdown Document").font(.headline)
                TextField("Document name", text: $markdownName).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { newMarkdown = false }.keyboardShortcut(.cancelAction)
                    Button("Create") {
                        model.createMarkdown(markdownName.trimmingCharacters(in: .whitespacesAndNewlines))
                        newMarkdown = false
                    }.keyboardShortcut(.defaultAction)
                        .disabled(markdownName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 420)
        }
        .sheet(item: $deleteSheetTarget) { tab in
            VStack(alignment: .leading, spacing: 14) {
                Text("Delete Sheet").font(.headline)
                Text("Delete “\(tab.title)” and its cells from this notebook?")
                if model.snapshot?.tabs.filter({ $0.kind == "sheet" }).count == 1 {
                    Text("A new blank sheet will replace this sheet.").foregroundStyle(NotebookPalette.muted)
                }
                if model.snapshot?.boards?.contains(where: { "sheet:" + $0.sheet == tab.id }) == true {
                    Text("Linked boards will use another sheet. Review their component bindings before running.")
                        .foregroundStyle(NotebookPalette.muted)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { deleteSheetTarget = nil }.keyboardShortcut(.cancelAction)
                    Button("Delete Sheet", role: .destructive) {
                        model.perform("delete_sheet", tab: tab, text: newSheetID())
                        deleteSheetTarget = nil
                    }.disabled(model.busy || model.executingCurrentWorker)
                }
            }.padding(24).frame(width: 420)
        }
        .sheet(item: $renameTarget) { tab in
            VStack(alignment: .leading, spacing: 16) {
                Text(tab.kind == "module" ? "Rename Module" : "Rename Sheet").font(.title2)
                TextField(tab.kind == "module" ? "Module name" : "Sheet name", text: $sheetName).textFieldStyle(.roundedBorder)
                if tab.kind == "module" {
                    Text("Spaces and hyphens become underscores. Renaming saves the current source with a matching filename. Update imports in other modules before running.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { renameTarget = nil }.keyboardShortcut(.cancelAction)
                    Button("Rename") {
                        model.perform(tab.kind == "module" ? "rename_module" : "rename_sheet", tab: tab,
                                      text: sheetName.trimmingCharacters(in: .whitespacesAndNewlines))
                        renameTarget = nil
                    }.disabled(sheetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sheetName.count > 200)
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 420)
        }
    }

    private func newSheetID() -> String {
        "sheet_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func notebookWorkspace(_ snapshot: NotebookSnapshot) -> some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            sidebar(snapshot)
                .navigationSplitViewColumnWidth(min: 220, ideal: 255, max: 310)
        } detail: {
            VStack(spacing: 0) {
                NotebookServerBar(model: model, remote: model.remote, sidebarVisibility: $sidebarVisibility)
                if let page = model.bookPage {
                    switch page {
                    case .markdown(let path): NotebookMarkdownPage(model: model, path: path).id(path)
                    case .attachments: NotebookAttachmentsPage(model: model)
                    }
                } else if let board = model.activeBoard {
                    NotebookBoardView(model: model, board: board) { boardPrompt = board }.id(board.id)
                } else if let tab = activeTab {
                    actionBar(snapshot)
                    Rectangle().fill(NotebookPalette.rule).frame(height: 1)
                    if tab.kind == "module" {
                        moduleContent(tab, snapshot: snapshot)
                    } else {
                        notebookContent(tab, snapshot: snapshot)
                    }
                } else {
                    missingTabView
                }
            }
            .background(NotebookPalette.canvas)
            .background(NotebookPaneSizing().frame(width: 0, height: 0))
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(snapshot.title)
        .disabled(model.boardEditorOpen && model.boardWindowSheetID != nil)
        .sheet(item: $boardPrompt) { board in
            NotebookBoardEditor(model: model, board: board, document: model.documentIdentity)
        }
        .sheet(item: $componentCell) { cell in
            if let tab = activeTab {
                NotebookCellComponentEditor(model: model, cell: cell, tab: tab)
            }
        }
        .sheet(item: $exportCell) { cell in
            if let tab = activeTab {
                NotebookCellExportsEditor(model: model, tab: tab, cell: cell)
            }
        }
        .sheet(isPresented: $showSheetImports) {
            if let tab = activeTab {
                NotebookSheetImportsEditor(model: model, tab: tab, tabs: snapshot.tabs)
            }
        }
    }

    private func sidebar(_ snapshot: NotebookSnapshot) -> some View {
        let modifiedTabCount = snapshot.tabs.filter { model.isModified($0) }.count +
            model.markdownDrafts.values.filter(\.modified).count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(NotebookPalette.sputnik.opacity(0.14))
                        .frame(width: 36, height: 36)
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NotebookPalette.sputnik)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(modifiedTabCount == 0 ? "All changes saved" : "\(modifiedTabCount) modified")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(modifiedTabCount == 0 ? NotebookPalette.muted : NotebookPalette.sputnik)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 23)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    tabSection(
                        "Sheets",
                        symbol: "plus",
                        actionLabel: "New sheet",
                        tabs: snapshot.tabs.filter { $0.kind == "sheet" }
                    ) {
                        structurePrompt = StructurePrompt(kind: .sheet, title: model.nextSheetTitle)
                    }

                    tabSection(
                        "Modules",
                        symbol: "plus",
                        actionLabel: "New module",
                        tabs: snapshot.tabs.filter { $0.kind == "module" }
                    ) {
                        structurePrompt = StructurePrompt(kind: .module)
                    }
                    bookFilesSection
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("BOARDS").font(.system(size: 10, weight: .bold)).foregroundStyle(NotebookPalette.muted)
                            Spacer()
                            Button {
                                let sheet = activeTab.flatMap { $0.kind == "sheet" ? $0 : nil }
                                    ?? snapshot.tabs.first { $0.kind == "sheet" }
                                if let sheet { boardPrompt = .empty(sheet: String(sheet.id.dropFirst("sheet:".count)), existing: snapshot.boards ?? []) }
                            } label: { Image(systemName: "plus") }
                                .help("New board").accessibilityLabel("New board").disabled(model.busy)
                        }.padding(.horizontal, 8)
                        ForEach(snapshot.boards ?? []) { board in
                            let selected = (model.detachedBoard?.id ?? model.selectedBoardID) == board.id
                            Button { model.selectBoard(board) } label: {
                                Label(board.title, systemImage: "square.grid.2x2")
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                                    .background(selected ? NotebookPalette.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay {
                                        if selected && NotebookPalette.currentPreset != .sputnik {
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(NotebookPalette.sidebarSelectionOutline, lineWidth: 1)
                                        }
                                    }
                            }.buttonStyle(.plain).disabled(!model.canNavigate)
                        }
                    }
                    Button { manageInputs = true } label: {
                        Label("Project Inputs (\(snapshot.inputs?.count ?? 0))", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }.buttonStyle(.plain).disabled(model.busy)
                        .accessibilityIdentifier("project-inputs-open")
                }
                .padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("DEPENDENCIES").font(.system(size: 10, weight: .bold)).foregroundStyle(NotebookPalette.muted)
                        Spacer()
                        Button { model.showDependencies = true } label: { Image(systemName: "shippingbox") }
                            .help("Manage dependencies").accessibilityLabel("Manage dependencies").disabled(model.busy || model.remote.busy)
                        Button { model.requestDependency?() } label: { Image(systemName: "plus") }
                            .help("Link package directory").accessibilityLabel("Link package directory").disabled(model.busy)
                    }
                    ForEach(snapshot.dependencies ?? []) { dependency in
                        Label(dependency.path, systemImage: "link")
                            .font(.system(size: 11)).lineLimit(3).help(dependency.path)
                            .contextMenu {
                                Button("Unlink (keep package files)") {
                                    model.perform("remove_dependency", text: dependency.path)
                                }.disabled(model.busy)
                            }
                    }
                    Text("External sources · explicit imports").font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.top, 16)
                .padding(.bottom, 22)
            }

            Spacer(minLength: 0)

            HStack(spacing: 7) {
                Image(systemName: "circle.grid.2x2")
                    .font(.system(size: 11, weight: .medium))
                Text("Environment · v\(snapshot.environment_generation)")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(NotebookPalette.muted)
            .padding(.horizontal, 19)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(NotebookPalette.rule).frame(height: 1)
            }
        }
        .background(NotebookPalette.sidebar)
    }

    private func tabSection(
        _ title: String,
        symbol: String,
        actionLabel: String,
        tabs: [NotebookTab],
        onAdd: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(NotebookPalette.muted)
                Spacer()
                Button(action: onAdd) {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NotebookPalette.ink)
                        .frame(width: 25, height: 25)
                        .background(NotebookPalette.card.opacity(0.75), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(actionLabel)
                .accessibilityLabel(actionLabel)
                .disabled(model.busy)
            }
            .padding(.horizontal, 8)

            if tabs.isEmpty {
                Text(title == "Sheets" ? "No sheets yet" : "No modules yet")
                    .font(.system(size: 12))
                    .foregroundStyle(NotebookPalette.muted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
            } else {
                ForEach(tabs) { tab in
                    sidebarRow(tab)
                }
            }
        }
    }

    private func sidebarRow(_ tab: NotebookTab) -> some View {
        let selected = model.bookPage == nil && model.activeBoard == nil && activeTab?.id == tab.id
        let modified = model.isModified(tab)
        return Button {
            model.selectTab(tab)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.kind == "module" ? "shippingbox" : "doc.text")
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? NotebookPalette.sputnik : NotebookPalette.muted)
                    .frame(width: 17)
                Text(tab.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(NotebookPalette.ink)
                    .lineLimit(1)
                Spacer(minLength: 2)

                if !model.executionIssues(in: tab).isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        .help("This page has a code error").accessibilityLabel("Code error")
                        .accessibilityIdentifier("page-error-\(tab.id)")
                }

                if model.executingCells[tab.id] != nil {
                    ProgressView().controlSize(.mini)
                        .help("This sheet is executing")
                        .accessibilityLabel("Running")
                }

                if tab.environment_stale {
                    Text("ENV")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(0.4)
                        .foregroundStyle(NotebookPalette.sputnik)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(NotebookPalette.sputnik.opacity(0.12), in: Capsule())
                        .help("This sheet needs the current module environment applied")
                }
                if modified {
                    Circle()
                        .fill(NotebookPalette.sputnik)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Modified")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(selected ? NotebookPalette.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(NotebookPalette.sidebarSelectionOutline, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!model.canNavigate)
        .contextMenu {
            if tab.kind == "sheet" {
                Button("Rename Sheet…") { sheetName = tab.title; renameTarget = tab }
                    .disabled(model.busy || model.executingCurrentWorker)
                Button("Delete Sheet…", role: .destructive) { deleteSheetTarget = tab }
                    .disabled(model.busy || model.executingCurrentWorker)
            } else {
                Button("Rename Module…") { sheetName = tab.title; renameTarget = tab }
                    .disabled(model.busy || model.executingCurrentWorker || model.remote.isSelected)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var bookFilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DOCUMENTATION").font(.system(size: 10, weight: .bold)).foregroundStyle(NotebookPalette.muted)
                Spacer()
                Button { markdownName = ""; newMarkdown = true } label: { Image(systemName: "plus") }
                    .help("New Markdown document").accessibilityLabel("New Markdown document")
                    .disabled(model.busy || !model.canNavigate)
            }.padding(.horizontal, 8)
            if model.markdownPaths.isEmpty {
                Text("No Markdown documents yet").font(.system(size: 12)).foregroundStyle(NotebookPalette.muted)
                    .padding(.horizontal, 9).padding(.vertical, 6)
            }
            ForEach(model.markdownPaths, id: \.self) { path in
                bookFileRow(String(path.dropFirst("docs/".count)), icon: "doc.text", page: .markdown(path))
                    .contextMenu { Button("Show in Finder") { model.revealBookFile(path) } }
            }
            bookFileRow("Attachments", icon: "folder", page: .attachments)
        }
    }

    private func bookFileRow(_ title: String, icon: String, page: NotebookBookPage) -> some View {
        let selected = model.bookPage == page
        return Button { model.selectBookPage(page) } label: {
            Label(title, systemImage: icon).font(.system(size: 13)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                .background(selected ? NotebookPalette.sidebarSelection : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).disabled(!model.canNavigate)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func actionBar(_ snapshot: NotebookSnapshot) -> some View {
        HStack(spacing: 10) {
            if let tab = activeTab {
                if tab.kind == "sheet" {
                    Button { sheetName = tab.title; renameTarget = tab } label: {
                        Label(tab.title, systemImage: "pencil")
                            .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    }.buttonStyle(.plain).help("Rename Sheet…").accessibilityLabel("Rename Sheet · " + tab.title)
                        .disabled(model.busy || model.executingCurrentWorker)
                } else {
                    Button { sheetName = tab.title; renameTarget = tab } label: {
                        Label(tab.title, systemImage: "pencil")
                            .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    }.buttonStyle(.plain).help("Rename Module…").accessibilityLabel("Rename Module · " + tab.title)
                        .disabled(model.busy || model.executingCurrentWorker || model.remote.isSelected)
                }
                NotebookPageBadge(kind: tab.kind == "module" ? .module : .sheet, detail: tab.status)
                if tab.kind == "sheet" {
                    if model.showsBoardWindowToggle { NotebookBoardWindowButton(model: model) }
                    Button { showSheetImports = true } label: {
                        Label("Imports", systemImage: "square.and.arrow.down")
                    }.disabled(model.busy)
                    if tab.cyclic_imports == true {
                        Label("Cyclic imports", systemImage: "arrow.trianglehead.clockwise.rotate.90")
                            .font(.caption).help(tab.status)
                    }
                }
            }

            Spacer(minLength: 10)

            if model.busy {
                ProgressView()
                    .controlSize(.small)
                    .help("Notebook work is in progress")
                    .padding(.trailing, 3)
            }

            Button {
                guard let tab = activeTab else { return }
                model.perform("save", tab: tab)
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .help("Save this tab · ⌘S")
            .disabled(model.busy || activeTab == nil || !(activeTab.map { model.isModified($0) } ?? false))
            .buttonStyle(.bordered)

            Button {
                runSelected()
            } label: {
                Label(isModule ? "Check Module" : "Run Selected", systemImage: isModule ? "checkmark.seal" : "play.fill")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .help(isModule ? "Check syntax, imports and compilation without executing code · ⌘Return" : "Run the selected cell · ⌘Return")
            .buttonStyle(.borderedProminent)
            .tint(NotebookPalette.sputnik)
            .disabled(!canRunSelected)

            if !isModule {
                Button {
                    guard let tab = activeTab else { return }
                    model.perform("run_all", tab: tab)
                } label: {
                    Label("Run All", systemImage: "forward.end.fill")
                }
                .help("Run every cell in this sheet")
                .buttonStyle(.bordered)
                .disabled(hasUnsupportedCell || !(activeTab.map { model.canRun($0) } ?? false))

                Button {
                    guard let tab = activeTab else { return }
                    model.perform("apply", tab: tab)
                } label: {
                    Label("Apply Modules", systemImage: "arrow.triangle.2.circlepath")
                }
                .help(model.remote.isSelected ? "Sync modules and restart the server worker to use a new environment" : "Build and apply the saved module environment to this sheet")
                .buttonStyle(.bordered)
                .disabled(!(activeTab.map { model.canApplyModules($0) } ?? false))
            }
        }
        .padding(.horizontal, 19)
        .padding(.vertical, 11)
        .background(NotebookPalette.topBar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notebook actions")
    }

    private var canRunSelected: Bool {
        guard let tab = activeTab, let cell = selectedCell else { return false }
        if tab.kind == "module" { return model.canCheckModule(tab) }
        return model.canRun(tab, cell: cell) && !hasUnsupportedCell
    }

    private var hasUnsupportedCell: Bool {
        guard let tab = activeTab, tab.kind == "sheet" else { return false }
        return tab.cells.contains { $0.kind != "code" && $0.kind != "text" }
    }

    private func runSelected() {
        guard let tab = activeTab, let cell = selectedCell, canRunSelected else { return }
        model.perform(tab.kind == "module" ? "check_module" : "run", tab: tab, cell: cell)
    }

    private func moduleContent(_ tab: NotebookTab, snapshot: NotebookSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            pageHeader(tab, snapshot: snapshot)
            if tab.status == "module check passed; code not executed", let cell = tab.cells.first,
               !cell.dirty, model.source(for: cell, in: tab).utf16.elementsEqual(cell.source.utf16) {
                noticeCard(symbol: "checkmark.circle.fill", title: "Module check passed",
                    message: "Syntax, imports and compilation checked. Module code was not executed.", tone: .green)
            }
            NotebookExecutionErrorsView(model: model, tab: tab)
            if tab.environment_stale || !tab.environment_error.isEmpty || !tab.environment_output.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        environmentNotice(tab)
                        environmentDetails(tab)
                    }
                }
                .frame(height: 100)
            }
            if let cell = tab.cells.first {
                codeCellCard(cell, index: 0, tab: tab)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(tab.id)
    }

    private func notebookContent(_ tab: NotebookTab, snapshot: NotebookSnapshot) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                pageHeader(tab, snapshot: snapshot)

                environmentNotice(tab)

                if hasUnsupportedCell {
                    let kinds = Array(Set(tab.cells.filter { $0.kind != "code" && $0.kind != "text" }.map(\.kind))).sorted().joined(separator: ", ")
                    noticeCard(
                        symbol: "lock.fill",
                        title: "Evaluation is paused",
                        message: "This sheet contains unsupported cell types (\(kinds)). The cells are preserved as read-only placeholders.",
                        tone: .slate
                    )
                }

                environmentDetails(tab)

                if tab.cells.isEmpty {
                    emptySheetCard(tab)
                } else {
                    ForEach(tab.cells.enumerated().map {
                        PositionedNotebookCell(position: $0.offset, cell: $0.element)
                    }) { item in
                        cellCard(item.cell, index: item.position, tab: tab)
                            .id(item.cell.id)
                    }
                }

                if tab.kind == "sheet" {
                    HStack(spacing: 12) {
                    Button {
                        model.perform("add_cell", tab: tab, cell: tab.cells.last)
                    } label: {
                        Label("Add code cell", systemImage: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(NotebookPalette.sputnik)
                    .background(NotebookPalette.card.opacity(0.58), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(NotebookPalette.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    .disabled(model.busy)
                    .help("Insert a new code cell after the last cell")
                    Button {
                        model.perform("add_text", tab: tab, cell: tab.cells.last)
                    } label: {
                        Label("Add text block", systemImage: "textformat")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(NotebookPalette.sputnik)
                    .background(NotebookPalette.card.opacity(0.58), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(NotebookPalette.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                    .disabled(model.busy)
                    .help("Insert a formatted, non-executable text block")
                    }
                }

            }
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .background(NotebookPalette.canvas)
        .onAppear { revealRequestedCell(in: tab, proxy: proxy) }
        .onChange(of: model.cellNavigation) { _, _ in revealRequestedCell(in: tab, proxy: proxy) }
        }
        .id(tab.id)
    }

    @ViewBuilder
    private func environmentNotice(_ tab: NotebookTab) -> some View {
        if tab.environment_stale {
            noticeCard(
                symbol: "arrow.triangle.2.circlepath",
                title: model.remote.isSelected ? "Results from an earlier server revision" : "Module environment changed",
                message: model.remote.isSelected ? "Run the current sources again. Restart Worker if the module environment changed." : "Apply the current modules to this sheet before running cells.",
                tone: .sputnik
            )
        }
    }

    @ViewBuilder
    private func environmentDetails(_ tab: NotebookTab) -> some View {
        if !tab.environment_error.isEmpty {
            NotebookExecutionErrorsView(model: model, tab: tab, environmentOnly: true)
            Button("Open Dependencies…") { model.showDependencies = true }
                .disabled(model.busy || model.remote.busy)
        }
        if !tab.environment_output.isEmpty {
            environmentOutputCard(tab.environment_output)
        }
    }

    private func revealRequestedCell(in tab: NotebookTab, proxy: ScrollViewProxy) {
        guard let request = model.cellNavigation, request.location.tab == tab.id else { return }
        collapsedCells.remove(tab.id + ":" + request.location.cell)
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(request.location.cell, anchor: .top) }
        }
    }

    private func pageHeader(_ tab: NotebookTab, snapshot: NotebookSnapshot) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Text(tab.title)
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .foregroundStyle(NotebookPalette.ink)
                    statusPill(tab)
                }
            }

            Spacer(minLength: 0)

            if tab.kind == "module" {
                Button {
                    model.perform("auto_import", tab: tab, text: tab.auto_import ? "off" : "on")
                } label: {
                    Label(
                        tab.auto_import ? "Auto-import on" : "Auto-import off",
                        systemImage: tab.auto_import ? "checkmark.circle.fill" : "circle"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .foregroundStyle(tab.auto_import ? NotebookPalette.sputnik : NotebookPalette.ink)
                    .background(NotebookPalette.card, in: Capsule())
                    .overlay(Capsule().stroke(NotebookPalette.rule, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
                .help("Choose whether this saved module is applied as an ambient sheet import")
                .accessibilityLabel(tab.auto_import ? "Disable module auto-import" : "Enable module auto-import")
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "circle.grid.2x2")
                    Text("ENV \(snapshot.environment_generation)")
                }
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(NotebookPalette.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(NotebookPalette.card, in: Capsule())
                .overlay(Capsule().stroke(NotebookPalette.rule, lineWidth: 1))
                .accessibilityLabel("Environment generation \(snapshot.environment_generation)")
            }
        }
        .padding(.bottom, 3)
    }

    @ViewBuilder
    private func statusPill(_ tab: NotebookTab) -> some View {
        if model.isModified(tab) {
            Text("MODIFIED")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(NotebookPalette.sputnik)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(NotebookPalette.sputnik.opacity(0.12), in: Capsule())
        } else if tab.environment_stale {
            Text("STALE ENV")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(NotebookPalette.sputnik)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(NotebookPalette.sputnik.opacity(0.12), in: Capsule())
        }
    }

    @ViewBuilder
    private func cellCard(_ cell: NotebookCell, index: Int, tab: NotebookTab) -> some View {
        if cell.kind == "text" { textBlockCard(cell, index: index, tab: tab) }
        else { codeCellCard(cell, index: index, tab: tab) }
    }

    private func textBlockCard(_ cell: NotebookCell, index: Int, tab: NotebookTab) -> some View {
        let selected = model.selectedCellID == cell.id
        let document = model.documentIdentity
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(tab.cellNumber(for: cell.id) ?? "?")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(NotebookPalette.muted)
                    .frame(minWidth: 25, minHeight: 25)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editCellID(cell, tab: tab) }
                    .help("Double-click to view, copy or edit this cell's Hard ID")
                    .accessibilityIdentifier("cell-number-\(cell.id)")
                    .accessibilityAction(named: "Edit Hard ID") { editCellID(cell, tab: tab) }
                Label("TEXT", systemImage: "textformat")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(NotebookPalette.muted)
                Spacer()
                iconAction("arrow.up", label: "Move text block up", disabled: model.busy || index == 0) {
                    model.perform("move_up", tab: tab, cell: cell)
                }
                iconAction("arrow.down", label: "Move text block down", disabled: model.busy || index == tab.cells.count - 1) {
                    model.perform("move_down", tab: tab, cell: cell)
                }
                iconAction("trash", label: "Delete text block", disabled: model.busy, role: .destructive) {
                    pendingDelete = DeleteTarget(tab: tab, cell: cell)
                }
            }
            NotebookTextCellView(content: NotebookTextContent(source: model.source(for: cell, in: tab),
                           formatting: model.formatting(for: cell, in: tab)),
                           editable: model.canEdit,
                           variables: model.textVariables(before: cell, in: tab),
                           onChange: { text, formatting in
                               model.editRichText(text, formatting: formatting, cell: cell, tab: tab)
                           },
                           onFocus: { model.selectedCellID = cell.id },
                           onError: { model.reportEditorError($0, cell: cell, tab: tab, document: document) })
        }
        .padding(10)
        .background(NotebookPalette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(selected ? NotebookPalette.sputnik.opacity(0.43) : NotebookPalette.rule, lineWidth: 1))
        .simultaneousGesture(TapGesture().onEnded { model.selectedCellID = cell.id })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text block \(index + 1)")
    }

    private func codeCellCard(_ cell: NotebookCell, index: Int, tab: NotebookTab) -> some View {
        let supported = cell.kind == "code"
        let selected = model.selectedCellID == cell.id || (model.selectedCellID.isEmpty && tab.selected_cell == cell.id)
        let collapseAllowed = tab.kind == "module" || cell.canCollapseSource
        let collapsed = collapseAllowed && collapsedCells.contains(cellKey(tab: tab, cell: cell))
        let modified = cell.dirty || model.source(for: cell, in: tab) != cell.source
        let running = model.executingCells[tab.id] == cell.id
        let navigation = model.cellNavigation
        let selection = navigation?.location == NotebookCellLocation(tab: tab.id, cell: cell.id) ? navigation?.selection : nil

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(tab.cellNumber(for: cell.id) ?? "?")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(NotebookPalette.muted)
                    .frame(width: 25, height: 25)
                    .background(NotebookPalette.canvas, in: Circle())
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editCellID(cell, tab: tab) }
                    .help("Double-click to view, copy or edit this cell's Hard ID")
                    .accessibilityIdentifier("cell-number-\(cell.id)")
                    .accessibilityAction(named: "Edit Hard ID") { editCellID(cell, tab: tab) }

                Text(supported ? (tab.kind == "module" ? "MODULE SOURCE" : "CODE") : cell.kind.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(supported ? NotebookPalette.muted : NotebookPalette.slate)

                if running {
                    ProgressView().controlSize(.mini)
                    stateBadge("RUNNING", tone: .sputnik)
                } else if tab.kind == "sheet", supported {
                    stateBadge(modified ? "STALE" : (cell.ok ? "CURRENT" : (cell.error.isEmpty ? "NOT RUN" : "ERROR")), tone: modified ? .sputnik : (cell.ok ? .green : (cell.error.isEmpty ? .slate : .red)))
                }

                Spacer(minLength: 4)

                NotebookCellTimer(model: model, cell: cell, tab: tab)

                if supported && tab.kind == "sheet" {
                    Button {
                        model.perform("watch", tab: tab, cell: cell, text: cell.watch ? "off" : "on")
                    } label: {
                        Label(cell.watch ? "Watch" : "Manual", systemImage: cell.watch ? "eye" : "hand.raised")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.busy)
                    .help(cell.watch ? "Turn off automatic watch evaluation" : "Turn on automatic watch evaluation")

                    iconAction("arrow.up", label: "Move cell up", disabled: model.busy || index == 0) {
                        model.perform("move_up", tab: tab, cell: cell)
                    }
                    iconAction("arrow.down", label: "Move cell down", disabled: model.busy || index == tab.cells.count - 1) {
                        model.perform("move_down", tab: tab, cell: cell)
                    }
                    iconAction("trash", label: "Delete cell", disabled: model.busy, role: .destructive) {
                        pendingDelete = DeleteTarget(tab: tab, cell: cell)
                    }
                }

                if supported && tab.kind == "sheet" {
                    iconAction("square.grid.2x2", label: "Components", disabled: model.busy) { componentCell = cell }
                        .accessibilityIdentifier("cell-components-\(cell.id)")
                    iconAction("square.and.arrow.up", label: "Exports", disabled: model.busy) { exportCell = cell }
                        .accessibilityIdentifier("cell-exports-\(cell.id)")
                    if running && model.executingWorker {
                        iconAction("stop.fill", label: "Stop", disabled: false) { model.stopExecution() }
                    } else if model.iterationReady(tab, cell: cell) {
                        Button("Run next iteration", systemImage: "arrow.clockwise") {
                            model.perform("run", tab: tab, cell: cell)
                        }.font(.caption).disabled(!model.canRun(tab, cell: cell))
                            .help("Cycle completed · ready for the next manual iteration")
                    } else {
                        iconAction("play.fill", label: "Run", disabled: !model.canRun(tab, cell: cell)) {
                            model.perform("run", tab: tab, cell: cell)
                        }
                    }
                }
                if supported && collapseAllowed {
                    NotebookSourceCollapseButton(collapsed: collapsed, cellID: cell.id) {
                        if collapsed { collapsedCells.remove(cellKey(tab: tab, cell: cell)) }
                        else { collapsedCells.insert(cellKey(tab: tab, cell: cell)) }
                    }.frame(width: 23, height: 23)
                }
            }

            if supported {
                NotebookCellComponentsView(model: model, cell: cell, tab: tab, components: cell.cell_ui?.pre ?? [])
                if collapsed {
                    Button {
                        collapsedCells.remove(cellKey(tab: tab, cell: cell))
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                            Text("\(model.source(for: cell, in: tab).components(separatedBy: .newlines).count) source lines hidden")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                        }
                        .foregroundStyle(NotebookPalette.muted)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .help("Show source code")
                    .accessibilityIdentifier("cell-source-collapsed-\(cell.id)")
                } else {
                    CodeEditor(
                        text: Binding(
                            get: { model.source(for: cell, in: tab) },
                            set: { model.editSource($0, cell: cell, tab: tab) }
                        ),
                        editable: model.canEdit,
                        substituteGreekLetters: substituteGreekLetters,
                        fillsHeight: tab.kind == "module",
                        errorRanges: model.source(for: cell, in: tab).utf16.elementsEqual(cell.source.utf16)
                            ? (cell.error_ranges ?? []) + model.sourceDiagnostics(for: cell, in: tab).compactMap(\.range) : [],
                        selectionRequest: selection,
                        onFocus: { model.selectedCellID = cell.id },
                        onRun: { model.selectedCellID = cell.id; runSelected() }
                    )
                    .frame(maxWidth: .infinity)
                    .background(NotebookPalette.editor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(NotebookPalette.rule, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Read-only placeholder", systemImage: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NotebookPalette.slate)
                    Text("This cell kind is preserved, but its execution semantics are not supported by this editor.")
                        .font(.system(size: 11))
                        .foregroundStyle(NotebookPalette.muted)
                    if !cell.source.isEmpty {
                        Text(cell.source)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(NotebookPalette.ink)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NotebookPalette.canvas.opacity(0.72), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            if supported {
                if tab.kind == "module" {
                    ViewThatFits(in: .vertical) {
                        codeCellOutput(cell, tab: tab, selected: selected)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView { codeCellOutput(cell, tab: tab, selected: selected) }
                    }
                    .frame(maxHeight: 150)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    codeCellOutput(cell, tab: tab, selected: selected)
                }
            }
        }
        .padding(10)
        .background(selected ? NotebookPalette.cardSelected : NotebookPalette.card,
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(running ? NotebookPalette.sputnik : (selected ? NotebookPalette.sputnik.opacity(0.43) : NotebookPalette.rule), lineWidth: running ? 2 : (selected ? 1.2 : 1))
        }
        .shadow(color: .black.opacity(selected ? 0.035 : 0.018), radius: 8, x: 0, y: 3)
        .simultaneousGesture(TapGesture().onEnded { model.selectedCellID = cell.id })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cell \(index + 1)")
        .onChange(of: collapseAllowed) {
            if !collapseAllowed { collapsedCells.remove(cellKey(tab: tab, cell: cell)) }
        }
    }

    private func codeCellOutput(_ cell: NotebookCell, tab: NotebookTab, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NotebookCellDisplay(model: model, cell: cell, tab: tab, kind: .progress)
            evaluationOutput(cell, tab: tab)
            NotebookCellDisplay(model: model, cell: cell, tab: tab, kind: .figure)
            let audioComponents = cell.cell_ui.map { ($0.pre + $0.post).filter { $0.kind == "audio" } } ?? []
            if !audioComponents.contains(where: { ($0.audio_id ?? "").isEmpty }) {
                NotebookCellDisplay(model: model, cell: cell, tab: tab, kind: .audio,
                    excludedAudioIDs: Set(audioComponents.compactMap(\.audio_id)))
            }
            let tableComponents = cell.cell_ui.map { ($0.pre + $0.post).filter { $0.kind == "table" } } ?? []
            if !tableComponents.contains(where: { ($0.table_id ?? "").isEmpty }) {
                NotebookCellDisplay(model: model, cell: cell, tab: tab, kind: .table,
                    excludedTableIDs: Set(tableComponents.compactMap(\.table_id)), allowResultTable: false)
            }
            NotebookCellComponentsView(model: model, cell: cell, tab: tab, components: cell.cell_ui?.post ?? [])
            if selected && !cell.locals.isEmpty {
                localsPanel(cell.locals)
            }
        }
    }

    private func editCellID(_ cell: NotebookCell, tab: NotebookTab) {
        guard !model.busy, tab.kind == "sheet", cell.kind == "code" || cell.kind == "text" else { return }
        model.selectedCellID = cell.id
        cellIDTarget = CellIDTarget(tab: tab, cell: cell)
    }

    private struct CellIDTarget: Identifiable {
        let tab: NotebookTab, cell: NotebookCell
        var id: String { tab.id + ":" + cell.id }
    }

    @ViewBuilder
    private func evaluationOutput(_ cell: NotebookCell, tab: NotebookTab) -> some View {
        let diagnostics = tab.kind == "module" ? [] : model.sourceDiagnostics(for: cell, in: tab)
        if !diagnostics.isEmpty {
            ForEach(Array(diagnostics.enumerated()), id: \.offset) { index, diagnostic in
                if let target = model.diagnosticSource(diagnostic, cell: cell, tab: tab) {
                    Button {
                        model.showSource(target.range, cell: target.cell, tab: target.tab)
                    } label: {
                        outputBlock(title: "Error · \(target.tab.kind == "module" ? target.tab.title + " · " : "")Line \(target.range.start_line + 1)", text: diagnostic.message,
                                    symbol: "exclamationmark.triangle.fill", tone: .red)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show line \(target.range.start_line + 1) in source")
                    .accessibilityIdentifier("cell-error-\(cell.id)-\(index)")
                } else {
                    outputBlock(title: "Error", text: diagnostic.message, symbol: "exclamationmark.triangle.fill", tone: .red)
                        .textSelection(.enabled)
                }
            }
        } else if tab.kind != "module", !cell.error.isEmpty {
            outputBlock(title: "Error", text: cell.error, symbol: "exclamationmark.triangle.fill", tone: .red)
                .textSelection(.enabled)
        }

        let events = model.output(for: cell, in: tab)
        ForEach(Array(events.indices), id: \.self) { index in
            let event = events[index]
            outputBlock(
                title: event.stream.uppercased(),
                text: event.text,
                symbol: event.stream.lowercased().contains("err") ? "exclamationmark.bubble" : "text.alignleft",
                tone: event.stream.lowercased().contains("err") ? .red : .slate
            )
            .textSelection(.enabled)
        }

        NotebookCellDisplay(model: model, cell: cell, tab: tab, kind: .result)
    }

    private func outputBlock(title: String, text: String, symbol: String, tone: BadgeTone) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(tone.color)
            Text(text)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(NotebookPalette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tone.color.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func localsPanel(_ locals: [NotebookLocal]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Locals", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotebookPalette.ink)
                Spacer()
                Text("\(locals.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(NotebookPalette.muted)
            }

            VStack(spacing: 0) {
                ForEach(Array(locals.indices), id: \.self) { index in
                    let local = locals[index]
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(local.name)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(NotebookPalette.ink)
                            .frame(minWidth: 92, alignment: .leading)
                        Text(local.value)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(NotebookPalette.slate)
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(local.role.isEmpty ? local.binding_kind : local.role)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(NotebookPalette.muted)
                        if local.watched {
                            Image(systemName: "eye.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(NotebookPalette.sputnik)
                                .help("Watched runtime value")
                        }
                    }
                    .padding(.vertical, 7)
                    if index < locals.count - 1 {
                        Rectangle().fill(NotebookPalette.rule.opacity(0.75)).frame(height: 1)
                    }
                }
            }
        }
        .padding(12)
        .background(NotebookPalette.canvas.opacity(0.75), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected cell locals")
    }

    private func noticeCard(symbol: String, title: String, message: String, tone: BadgeTone) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone.color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotebookPalette.ink)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(NotebookPalette.slate)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.color.opacity(0.075), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(tone.color.opacity(0.62)).frame(width: 3).padding(.vertical, 9)
        }
    }

    private func environmentOutputCard(_ output: [NotebookOutput]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Module output", systemImage: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotebookPalette.ink)
            ForEach(Array(output.indices), id: \.self) { index in
                let event = output[index]
                Text(event.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(event.stream.lowercased().contains("err") ? NotebookPalette.error : NotebookPalette.slate)
                    .textSelection(.enabled)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NotebookPalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(NotebookPalette.rule, lineWidth: 1))
    }

    private func emptySheetCard(_ tab: NotebookTab) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: "text.page")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(NotebookPalette.sputnik)
            Text("This sheet is empty")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(NotebookPalette.ink)
            Text("Add a code cell to start working in Sputnik.")
                .font(.system(size: 12))
                .foregroundStyle(NotebookPalette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(23)
        .background(NotebookPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NotebookPalette.rule, lineWidth: 1))
    }

    private var missingTabView: some View {
        VStack(spacing: 11) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(NotebookPalette.sputnik)
            Text("No tab selected")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(NotebookPalette.ink)
            Text("Choose a sheet or module from the sidebar.")
                .font(.system(size: 12))
                .foregroundStyle(NotebookPalette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcomeView: some View {
        NotebookWelcomeView(
            library: model.library,
            newProject: model.newProject,
            openProject: model.openProject,
            openLibraryProject: { model.open(url: $0) })
            .disabled(model.busy)
    }

    private func stateBadge(_ title: String, tone: BadgeTone) -> some View {
        Text(title)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .tracking(0.45)
            .foregroundStyle(tone.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(tone.color.opacity(0.10), in: Capsule())
    }

    @ViewBuilder
    private func iconAction(
        _ symbol: String,
        label: String,
        disabled: Bool,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        if let role {
            Button(role: role, action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 23, height: 23)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(role == .destructive ? NotebookPalette.error : NotebookPalette.muted)
            .disabled(disabled)
            .help(label)
            .accessibilityLabel(label)
        } else {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 23, height: 23)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(NotebookPalette.muted)
            .disabled(disabled)
            .help(label)
            .accessibilityLabel(label)
        }
    }

    private func cellKey(tab: NotebookTab, cell: NotebookCell) -> String {
        "\(tab.id):\(cell.id)"
    }
}

private struct PositionedNotebookCell: Identifiable {
    let position: Int
    let cell: NotebookCell
    var id: String { cell.id }
}


private enum BadgeTone {
    case sputnik, slate, red, green

    var color: Color {
        switch self {
        case .sputnik: NotebookPalette.sputnik
        case .slate: NotebookPalette.slate
        case .red: NotebookPalette.error
        case .green: NotebookPalette.success
        }
    }
}

private struct StructurePrompt: Identifiable {
    enum Kind { case sheet, module }
    let kind: Kind
    var title = ""
    var id: String { kind == .sheet ? "sheet" : "module" }
}

private struct DeleteTarget: Identifiable {
    let tab: NotebookTab
    let cell: NotebookCell
    var id: String { "\(tab.id):\(cell.id)" }
}

private struct StructurePromptSheet: View {
    let prompt: StructurePrompt
    let onCreate: (String) -> Void
    let onCancel: () -> Void
    @State private var identifier: String

    init(prompt: StructurePrompt, onCreate: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.prompt = prompt; self.onCreate = onCreate; self.onCancel = onCancel
        _identifier = State(initialValue: prompt.title)
    }

    private var kindName: String { prompt.kind == .sheet ? "sheet" : "module" }
    private var validName: Bool {
        if prompt.kind == .sheet {
            return !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && identifier.unicodeScalars.count <= 200
        }
        return identifier.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New \(kindName)")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(NotebookPalette.ink)
            TextField(prompt.kind == .sheet ? "Sheet name" : "Identifier", text: $identifier)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .onSubmit(create)
                .accessibilityLabel(prompt.kind == .sheet ? "New sheet name" : "New module identifier")

            if prompt.kind == .module {
                Label("Modules start outside the sheet environment. Save and apply them when you are ready.", systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(NotebookPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(NotebookPalette.sputnik)
                    .disabled(!validName)
            }
            .padding(.top, 4)
        }
        .padding(23)
        .frame(width: 390)
        .background(NotebookPalette.canvas)
    }

    private func create() {
        guard validName else { return }
        onCreate(identifier.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

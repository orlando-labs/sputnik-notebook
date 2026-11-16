import SwiftUI

extension NotebookPalette {
    static func package(_ id: String) -> Color {
        let colors: [NSColor] = [.systemTeal, .systemBlue, .systemPurple, .systemGreen, .systemPink, .systemIndigo]
        let index = id.utf8.reduce(0) { ($0 * 31 + Int($1)) % colors.count }
        return Color(nsColor: colors[index])
    }
}

struct NotebookPackagePropertyInspector: View {
    @ObservedObject var model: NotebookModel
    @Binding var component: NotebookBoardComponent

    var body: some View {
        if let (_, definition) = model.packageDefinition(for: component) {
            if definition.kind == .service {
                Toggle("Enabled", isOn: Binding(
                    get: { component.package_component?.enabled ?? true },
                    set: { component.package_component?.enabled = $0 }))
            }
            ForEach(definition.properties ?? []) { property in
                NotebookPlotField(title: property.title) {
                    editor(property)
                }
            }
        } else {
            Label("Install the provider in Dependencies to edit its properties.", systemImage: "shippingbox")
                .font(.caption).foregroundStyle(NotebookPalette.muted)
        }
    }

    @ViewBuilder private func editor(_ property: NotebookPackageProperty) -> some View {
        let value = Binding(
            get: { component.package_component.map { property.value(in: $0) } ?? "" },
            set: { component.package_component?.properties[property.id] = $0 })
        switch property.kind {
        case .integer, .text:
            TextField(property.title, text: value).labelsHidden().textFieldStyle(.roundedBorder)
        case .toggle:
            Toggle(property.title, isOn: Binding(get: { value.wrappedValue == "true" },
                                                 set: { value.wrappedValue = $0 ? "true" : "false" })).labelsHidden()
        case .input:
            Picker(property.title, selection: value) {
                Text("None").tag("")
                ForEach(model.snapshot?.inputs ?? []) { input in Text(input.title).tag(input.id) }
                if !value.wrappedValue.isEmpty, model.snapshot?.inputs?.contains(where: { $0.id == value.wrappedValue }) != true {
                    Text("Missing: \(value.wrappedValue)").tag(value.wrappedValue)
                }
            }.labelsHidden()
        case .module:
            let modules = model.snapshot?.tabs.filter { $0.kind == "module" } ?? []
            let fields = value.wrappedValue.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let module = fields.first.map(String.init) ?? ""
            let export = fields.dropFirst().first.map(String.init) ?? ""
            Picker("Module", selection: Binding(
                get: { module }, set: { value.wrappedValue = $0.isEmpty ? "" : "\($0):\(export)" })) {
                Text("Package default").tag("")
                ForEach(modules) { tab in Text(tab.title).tag(String(tab.id.dropFirst("module:".count))) }
                if !module.isEmpty, !modules.contains(where: { $0.id == "module:" + module }) { Text("Missing: \(module)").tag(module) }
            }.labelsHidden()
            if !module.isEmpty {
                TextField("Export name", text: Binding(
                    get: { export }, set: { value.wrappedValue = "\(module):\($0)" }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

struct NotebookPackageServiceView: View {
    @ObservedObject var runtime: NotebookPackageRuntime
    let board: NotebookBoard
    let component: NotebookBoardComponent
    let available: Bool

    var body: some View {
        let state = runtime.state(board: board, component: component)
        let disabled = component.package_component?.enabled == false
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(component.title, systemImage: "gearshape.2").font(.headline)
                Spacer()
                Text(state?.status ?? (disabled ? "Disabled" : available ? "Stopped" : "Package unavailable"))
                    .font(.caption).foregroundStyle(NotebookPalette.muted).textSelection(.enabled)
            }
            if let url = state?.url {
                HStack {
                    Text(url).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Button("Copy URL") { copy(url) }.controlSize(.small)
                    if let token = state?.token {
                        Button("Copy Token") { copy(token) }.controlSize(.small)
                    }
                    Spacer(minLength: 4)
                    Text("\(state?.requests ?? 0) requests").font(.caption).foregroundStyle(NotebookPalette.muted)
                }
            }
        }.padding(12)
            .background(NotebookPalette.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(NotebookPalette.package(component.package_component?.provider ?? "").opacity(0.5)))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct NotebookPackageBoardView: View {
    @ObservedObject var model: NotebookModel
    @ObservedObject var runtime: NotebookPackageRuntime
    let board: NotebookBoard
    let component: NotebookBoardComponent
    let height: Double?
    @State private var expanded = true

    var body: some View {
        let id = runtime.key(board, component)
        let provider = component.package_component?.provider ?? ""
        let tint = NotebookPalette.package(provider)
        let installed = model.packageDefinition(for: component)
        let child = runtime.childBoards[id]
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").foregroundStyle(tint)
                    Text(component.title).font(.headline)
                    Spacer()
                    Text(installed?.0.name ?? provider).font(.caption).foregroundStyle(NotebookPalette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                if let child, let embedded = child.board {
                    if let height {
                        ScrollView { content(child, board: embedded) }.frame(height: max(20, height - 46))
                    } else {
                        content(child, board: embedded)
                    }
                } else {
                    Text(runtime.childErrors[id] ?? "Loading board…")
                        .font(.caption).foregroundStyle(NotebookPalette.muted)
                }
            }
        }.padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NotebookPalette.card, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint, lineWidth: 1.5))
            .task(id: (installed?.0.digest ?? "") + (child == nil ? ":load" : ":ready")) {
                if child == nil { _ = await runtime.prepareChild(model: model, board: board, component: component) }
            }
    }

    private func content(_ child: NotebookPackageRuntime.EmbeddedBoard, board: NotebookBoard) -> some View {
        NotebookBoardView(model: child.model, board: board, embedded: true, onDesign: {})
    }
}

struct NotebookBoardSessionControls: View {
    @ObservedObject var model: NotebookModel
    @ObservedObject var runtime: NotebookPackageRuntime
    let board: NotebookBoard

    var body: some View {
        let active = runtime.sessions[board.id] != nil
        if !model.remote.isSelected && board.allComponents.contains(where: { $0.package_component != nil }) {
            if active {
                Button("Stop Board", systemImage: "stop.fill") { runtime.stop(model: model, board: board) }
                    .accessibilityIdentifier("board-stop")
            } else {
                Button("Start Board", systemImage: "play.fill", action: start)
                    .buttonStyle(.borderedProminent).tint(NotebookPalette.sputnik)
                    .disabled(model.busy || model.dependencyOperationActive)
                    .accessibilityIdentifier("board-start")
            }
        }
    }

    private func start() {
        let services = board.allComponents.filter { $0.package_component?.enabled == true }
        let alert = NSAlert()
        alert.messageText = "Start \(board.title)?"
        alert.informativeText = "Start the configured package components and their controllers on this Mac. Network services can listen only on loopback.\n\n"
            + services.map { component in
                let provider = component.package_component?.provider ?? ""
                let configuration = model.packageDefinition(for: component)?.1
                let port = configuration?.properties?.first { $0.id == configuration?.listen_port }
                let value = component.package_component.flatMap { port?.value(in: $0) }
                let target = value.map { $0 == "0" ? " · automatic loopback port" : " · 127.0.0.1:\($0)" } ?? ""
                return "\(component.title) (\(provider))\(target)"
            }.joined(separator: "\n")
        alert.addButton(withTitle: "Start Board")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { runtime.start(model: model, board: board) }
    }
}

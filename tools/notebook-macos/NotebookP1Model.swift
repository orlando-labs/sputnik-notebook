import Foundation

extension NotebookModel {
    func saveComponent(_ component: NotebookBoardComponent, board: NotebookBoard, completion: @escaping (Bool) -> Void) {
        guard var current = snapshot?.boards?.first(where: { $0.id == board.id }), current.replaceComponent(component) else {
            error = "Component is no longer available."; completion(false); return
        }
        saveBoard(current, completion: completion)
    }
    func runAction(board: NotebookBoard, component: NotebookBoardComponent) {
        perform("action_run", tab: controller(for: board), text: board.id, commandCellID: component.id)
    }
    func actionIsStale(board: NotebookBoard, component: NotebookBoardComponent) -> Bool {
        if remote.isSelected { return remote.invocationStale[board.id + ":" + component.id] == true || hasUnsavedChanges }
        let module = snapshot?.tabs.first { $0.id == "module:" + (component.module_id ?? "") }
        let source = module.map { tab in tab.cells.map { self.source(for: $0, in: tab) }.joined(separator: "\n") } ?? ""
        return actionSignatures[board.id + ":" + component.id] != component.actionSignature(inputs: snapshot?.inputs ?? [], moduleSource: source)
    }
    func targetKey(board: NotebookBoard, component: NotebookBoardComponent, tab: NotebookTab) -> String {
        ["service", "action"].contains(component.settings.target_kind ?? "") ? board.id + ":" + (component.settings.target_component ?? "") : tab.id
    }
    func targetStatus(board: NotebookBoard, component: NotebookBoardComponent, tab: NotebookTab) -> NotebookTargetStatus {
        let kind = component.settings.target_kind ?? (component.cell == nil ? "sheet" : "cell")
        if kind == "runtime" {
            let contact = remote.isSelected ? remote.lastContact : workerLastContact
            let when = contact.map { "Last contact: " + $0.formatted(date: .omitted, time: .standard) } ?? "No worker contact recorded yet"
            if remote.isSelected {
                let runtime = remote.runtimes.first { $0["sheet_id"] as? String == String(tab.id.dropFirst(6)) }
                let phase = runtime?["state"] as? String ?? (remote.active ? "running" : "idle")
                let epoch = runtime?["epoch"] as? String
                let detail = remote.serverName + " · " + phase + "\n" + when + (epoch.map { "\nEpoch: " + $0 } ?? "") + "\n" + resourceSummary(in: tab)
                if !remote.connected { return .init(title: "Disconnected", detail: detail, symbol: "network.slash", failed: true) }
                if runtime?["needs_restart"] as? Bool == true { return .init(title: "Restart required", detail: detail, symbol: "arrow.clockwise", stale: true) }
                if remote.conflict { return .init(title: "Revision conflict", detail: detail, symbol: "exclamationmark.triangle", stale: true) }
                return .init(title: remote.busy ? "Synchronizing" : "Connected", detail: detail, symbol: "network")
            }
            return .init(title: isolatedExecution ? executionLabel : "Local host", detail: "Local execution\n" + when + "\nEnvironment generation: " + String(snapshot?.environment_generation ?? 0) + "\n" + resourceSummary(in: tab), symbol: executingWorker ? "hourglass" : "desktopcomputer")
        }
        let key = targetKey(board: board, component: component, tab: tab)
        if executingTargetID == key || (remote.isSelected && ["sheet", "cell"].contains(kind) && executingCurrentWorker) {
            return NotebookTargetStatus(title: isolatedExecution ? executionLabel : "Running", detail: executionStarted.map { "Started \($0.formatted(date: .omitted, time: .standard))" } ?? "", symbol: "hourglass")
        }
        if kind == "service" {
            guard let source = board.allComponents.first(where: { $0.id == component.settings.target_component && $0.isService }) else { return .init(title: "Unavailable", detail: "Choose a service in the designer.", symbol: "questionmark.circle") }
            let state = periodicState(board: board, component: source)
            return .init(title: state.status, detail: "\(state.runs) runs · \(state.failures) errors · \(state.skipped) skipped", symbol: state.enabled ? "timer" : "pause.circle", failed: state.status == "Last run failed" || state.status == "Stopped after error")
        }
        if kind == "action" {
            guard board.allComponents.contains(where: { $0.kind == "action" && $0.id == component.settings.target_component }) else { return .init(title: "Unavailable", detail: "Choose an action in the designer.", symbol: "questionmark.circle") }
            guard let result = invocationResult(key) else { return .init(title: "Ready", detail: "Run the action explicitly.", symbol: "play.circle") }
            let source = board.allComponents.first { $0.id == component.settings.target_component }!
            let stale = actionIsStale(board: board, component: source)
            return .init(title: stale ? "Stale" : result.ok ? "Success" : "Error", detail: (stale ? "Arguments or module changed. Previous run: " : "") + (result.ok ? result.result : result.error), symbol: stale ? "clock" : result.ok ? "checkmark.circle" : "exclamationmark.circle", failed: !result.ok, stale: stale)
        }
        let cells = kind == "cell" ? tab.cells.filter { $0.id == component.cell } : tab.cells.filter { $0.kind == "code" }
        if cells.isEmpty { return .init(title: "Unavailable", detail: "Source cell unavailable", symbol: "questionmark.circle") }
        if !cells.contains(where: { $0.ok || !$0.error.isEmpty }) { return .init(title: "Ready", detail: "Run to publish the first result.", symbol: "play.circle") }
        if tab.environment_stale { return .init(title: "Stale", detail: "Apply saved module changes on the sheet.", symbol: "arrow.triangle.2.circlepath", stale: true) }
        if let failed = cells.first(where: { !$0.error.isEmpty && !$0.dirty }) { return .init(title: "Error", detail: failed.error, symbol: "exclamationmark.circle", failed: true) }
        if cells.contains(where: { $0.dirty }) { return .init(title: "Stale", detail: "Source or parameters changed. Run to refresh.", symbol: "clock", stale: true) }
        if cells.allSatisfy(\.ok) { return .init(title: "Success", detail: componentUpdatedAt[tab.id].map { "Updated \($0.formatted(date: .omitted, time: .standard))" } ?? "Last committed result", symbol: "checkmark.circle") }
        return .init(title: "Ready", detail: "Run to publish the first result.", symbol: "play.circle")
    }
}

import SwiftUI

struct NotebookTaskMonitorView: View {
    @ObservedObject var model: NotebookModel
    let tab: NotebookTab
    @State private var errorsOnly = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let telemetry = model.telemetry(in: tab) {
                HStack {
                    Text("\(telemetry.active) active · \(telemetry.total) registered").font(.caption)
                    Spacer(); Toggle("Errors only", isOn: $errorsOnly).toggleStyle(.checkbox)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(telemetry.tasks.filter { !errorsOnly || $0.state == "failed" }) { task in
                            let index = telemetry.tasks.firstIndex { $0.id == task.id } ?? 0
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Image(systemName: task.state == "failed" ? "exclamationmark.circle" : task.state == "succeeded" ? "checkmark.circle" : "circle.dotted")
                                    Text("Task \(index + 1) · \(task.state)")
                                    Spacer(); Text(String(format: "%.2f s", Double(task.elapsed_ms) / 1000)).monospacedDigit()
                                }.font(.caption)
                                if !task.error.isEmpty { Text(task.error).font(.caption).foregroundStyle(NotebookPalette.error).textSelection(.enabled) }
                                if !task.file.isEmpty {
                                    Text("\(tab.cellLabel(for: task.cell)) · line \(task.line)").font(.caption2).foregroundStyle(NotebookPalette.muted)
                                }
                            }.padding(.leading, CGFloat(depth(task, in: telemetry)) * 14)
                        }
                    }
                }.frame(maxHeight: 300)
                if telemetry.dropped > 0 { Text("\(telemetry.dropped) earlier task records omitted · bounded to 512 records").font(.caption).foregroundStyle(NotebookPalette.sputnik) }
                Text(model.resourceSummary(in: tab)).font(.caption2).foregroundStyle(NotebookPalette.muted)
            } else { Text("Run the sheet to inspect child tasks. This worker has not supplied task telemetry.").font(.callout).foregroundStyle(NotebookPalette.muted) }
        }
    }
    private func depth(_ task: NotebookRuntimeTask, in telemetry: NotebookRuntimeTelemetry) -> Int {
        var parent = task.parent, depth = 0
        while parent != "0" && depth < 12 {
            guard let next = telemetry.tasks.first(where: { $0.id == parent }) else { break }
            depth += 1; parent = next.parent
        }
        return depth
    }
}

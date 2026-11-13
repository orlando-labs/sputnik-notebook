import SwiftUI

struct NotebookExecutionErrorsView: View {
    @ObservedObject var model: NotebookModel
    let tab: NotebookTab
    var environmentOnly = false
    var onNavigate: () -> Void = {}

    var body: some View {
        let issues = environmentOnly && tab.environment_error.isEmpty ? [] : model.executionIssues(in: tab)
        if !issues.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(issues.enumerated()), id: \.offset) { index, issue in
                        if issue.location != nil {
                            Button {
                                model.showExecutionIssue(issue)
                                onNavigate()
                            } label: { card(issue) }
                                .buttonStyle(.plain)
                                .disabled(!model.canNavigate)
                                .help("Open the source of this error")
                                .accessibilityIdentifier("execution-error-\(tab.id)-\(index)")
                        } else { card(issue).textSelection(.enabled) }
                    }
                }
            }
            .frame(height: min(180, CGFloat(issues.count) * 90))
            .accessibilityIdentifier("execution-errors-\(tab.id)")
        }
    }

    private func card(_ issue: NotebookExecutionIssue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
            Text(issue.message).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(NotebookPalette.ink).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.red.opacity(0.25)))
        .contentShape(Rectangle())
    }
}

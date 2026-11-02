import AppKit

struct NotebookBuildInfo: Decodable {
    struct Source: Decodable {
        let version: String
        let build: String?
        let revision: String?
        let dirty: Bool?
        let compilerSHA256: String?

        var revisionDescription: String {
            let commit = revision ?? "unavailable (source archive)"
            switch dirty {
            case true: return "\(commit)\nUncommitted source changes"
            case false: return commit
            case nil: return "\(commit)\nSource state unavailable"
            }
        }
    }

    let schema: String
    let channel: String
    let buildID: String
    let notebook: Source
    let sputnik: Source

    // Use the snapshot linked into this executable, even after the source
    // checkout, bundled SDK or an adjacent development helper has changed.
    static let current = try! JSONDecoder().decode(
        NotebookBuildInfo.self, from: Data(NotebookBuildMetadata.json.utf8))

    var aboutText: String {
        let build = buildID.isEmpty ? channel : "\(channel) · \(buildID)"
        return """
        Build: \(build)

        Sputnik language / VM \(sputnik.version)
        \(sputnik.revisionDescription)

        Notebook commit
        \(notebook.revisionDescription)
        """
    }

    var aboutPanelOptions: [NSApplication.AboutPanelOptionKey: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return [
            .applicationName: "Sputnik Notebook",
            .applicationVersion: notebook.version,
            .version: notebook.build ?? "",
            .credits: NSAttributedString(string: aboutText, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ])
        ]
    }
}

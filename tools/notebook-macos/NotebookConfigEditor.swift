import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pure host operations: validation and formatting share the project parser
/// used by atomic input transactions. No notebook or worker is created.
enum NotebookConfigJSON {
    static let byteLimit = 65_536

    static func process(_ text: String, format: NotebookConfigFormat = .json, pretty: Bool = false) throws -> String {
        guard text.utf8.count <= byteLimit, !text.utf8.contains(0) else {
            throw failure("Config must fit 64 KiB and contain no NUL.")
        }
        var error: UnsafeMutablePointer<CChar>?
        let result = sputnik_notebook_config_document(text, format.rawValue, pretty ? 1 : 0, &error)
        defer { sputnik_notebook_string_free(result); sputnik_notebook_string_free(error) }
        guard let result else { throw failure(error.map { String(cString: $0) } ?? "Invalid \(format.title).") }
        return String(cString: result)
    }

    static func error(_ text: String, format: NotebookConfigFormat = .json) -> String? {
        do { _ = try process(text, format: format); return nil }
        catch { return error.localizedDescription }
    }

    static func read(_ url: URL, format: NotebookConfigFormat = .json) throws -> String {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw failure("Choose a regular config file.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while data.count <= byteLimit {
            guard let chunk = try file.read(upToCount: byteLimit + 1 - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= byteLimit else { throw failure("Config must fit 64 KiB.") }
        guard let text = String(data: data, encoding: .utf8) else { throw failure("Config must use UTF-8.") }
        return try process(text, format: format)
    }

    static func write(_ text: String, to url: URL, format: NotebookConfigFormat = .json) throws {
        let source = try process(text, format: format)
        try Data(source.utf8).write(to: url, options: .atomic)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "SputnikConfigJSON", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct NotebookConfigSettings: View {
    @Binding var format: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Format", selection: Binding(get: { format ?? "json" }, set: { format = $0 })) {
                ForEach(NotebookConfigFormat.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Text("Config content is always file text. Changing the format does not convert it. Read parsed values with notebook.config(…) or notebook.cell_config(…), passing format: :\(format ?? "json").")
                .font(.caption).foregroundStyle(NotebookPalette.muted)
        }
    }
}

/// The component stays compact regardless of the source length. Forms stage
/// the modal's result in their draft; standalone inputs supply atomic Apply.
struct NotebookConfigEditor: View {
    @Binding var text: String
    var title = "Config"
    var format: NotebookConfigFormat = .json
    var onApply: ((String, @escaping (String?) -> Void) -> Void)? = nil
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Label(format.title, systemImage: "curlybraces").font(.callout.weight(.medium))
                Text("\(text.utf8.count) bytes · \(text.components(separatedBy: .newlines).count) lines")
                    .font(.caption).foregroundStyle(NotebookPalette.muted).lineLimit(1)
                Spacer(minLength: 4)
                Button("Edit…") { editing = true }.accessibilityIdentifier("config-open")
            }
            if let error = NotebookConfigJSON.error(text, format: format) {
                Text(error).font(.caption).foregroundStyle(NotebookPalette.error).lineLimit(2)
            }
        }
        .sheet(isPresented: $editing) {
            NotebookConfigEditorSheet(source: text, title: title, format: format, applyTitle: onApply == nil ? "Use Config" : "Apply") { source, completed in
                if let onApply {
                    onApply(source) { error in
                        if error == nil { text = source }
                        completed(error)
                    }
                } else {
                    text = source; completed(nil)
                }
            }
        }
    }
}

struct NotebookConfigEditorSheet: View {
    let source: String
    let title: String
    let format: NotebookConfigFormat
    let applyTitle: String
    let onApply: (String, @escaping (String?) -> Void) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var fileError: String?
    @State private var applying = false
    private var validationError: String? { NotebookConfigJSON.error(text, format: format) }

    init(source: String, title: String, format: NotebookConfigFormat = .json, applyTitle: String, onApply: @escaping (String, @escaping (String?) -> Void) -> Void) {
        self.source = source; self.title = title; self.format = format; self.applyTitle = applyTitle; self.onApply = onApply
        _text = State(initialValue: source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold()).lineLimit(1)
            HStack {
                Text(format.title).font(.caption.weight(.semibold)).foregroundStyle(NotebookPalette.muted)
                Spacer()
                Button("Import…", action: importFile).accessibilityIdentifier("config-import")
                Button("Export…", action: exportFile).disabled(validationError != nil).accessibilityIdentifier("config-export")
                if format == .json {
                    Button("Format", action: formatJSON).disabled(validationError != nil).accessibilityIdentifier("config-format")
                }
            }.controlSize(.small)
            CodeEditor(text: $text, substituteGreekLetters: false, language: format == .yaml ? .yaml : format == .toml ? .toml : .json)
                .frame(height: 460)
                .accessibilityIdentifier("config-source")
            Group {
                if let error = fileError ?? validationError {
                    Text(error).font(.caption).foregroundStyle(NotebookPalette.error).textSelection(.enabled)
                        .accessibilityIdentifier("config-error")
                } else {
                    Text("Changes stay in this editor until you choose \(applyTitle).")
                        .font(.caption).foregroundStyle(NotebookPalette.muted)
                }
            }.frame(height: 30, alignment: .topLeading)
            Spacer(minLength: 0)
            HStack {
                Button("Reset") { text = source; fileError = nil }.disabled(text == source)
                    .accessibilityIdentifier("config-reset")
                Spacer()
                if applying { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("config-cancel")
                Button(applyTitle, action: apply).buttonStyle(.borderedProminent)
                    .disabled(text == source || validationError != nil).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("config-apply")
            }
        }
        .onChange(of: text) { fileError = nil }
        .padding(22).frame(width: 820, height: 680)
        .background(NotebookPalette.canvas).foregroundStyle(NotebookPalette.ink)
        .disabled(applying).interactiveDismissDisabled()
    }

    private func apply() {
        guard validationError == nil else { return }
        applying = true
        onApply(text) { error in
            applying = false
            if let error { fileError = error } else { dismiss() }
        }
    }

    private func formatJSON() {
        do { text = try NotebookConfigJSON.process(text, pretty: true); fileError = nil }
        catch { fileError = error.localizedDescription }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = format.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { text = try NotebookConfigJSON.read(url, format: format); fileError = nil }
        catch { fileError = error.localizedDescription }
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = format.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.nameFieldStringValue = "config." + format.rawValue
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try NotebookConfigJSON.write(text, to: url, format: format); fileError = nil }
        catch { fileError = error.localizedDescription }
    }
}

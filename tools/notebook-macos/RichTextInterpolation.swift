import AppKit
import SwiftUI

/// Substitution is deliberately not an Sputnik evaluator. Only published names
/// from the host's published-name snapshot can be read, never expressions.
enum RichTextInterpolation {
    private static let token = try! NSRegularExpression(pattern: #"\{\{([^{}\r\n]+)\}\}"#)

    static func render(_ source: NSAttributedString, variables: [NotebookTextVariable]) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        let values = Dictionary(variables.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        let text = source.string as NSString
        for match in token.matches(in: source.string, range: NSRange(location: 0, length: source.length)).reversed() {
            let name = text.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let variable = values[name]
            var attrs = source.attributes(at: match.range.location, effectiveRange: nil)
            let replacement: String
            if let variable {
                // Preserve table/paragraph ownership even for multiline values.
                let display = variable.value.replacingOccurrences(of: "\r\n", with: "\u{2028}")
                    .replacingOccurrences(of: "\n", with: "\u{2028}").replacingOccurrences(of: "\r", with: "\u{2028}")
                let bounded = String(display.prefix(4096)) + (display.count > 4096 ? "…" : "")
                replacement = variable.stale ? "[\(name): stale — \(bounded)]" : bounded
            } else {
                replacement = "[\(name): unavailable]"
            }
            if variable == nil || variable?.stale == true {
                attrs[.foregroundColor] = NotebookPalette.nativeAccent
                attrs[.backgroundColor] = NotebookPalette.nativeAccent.withAlphaComponent(0.08)
            }
            result.replaceCharacters(in: match.range, with: NSAttributedString(string: replacement, attributes: attrs))
        }
        return result
    }

    static func matching(_ variables: [NotebookTextVariable], query: String) -> [NotebookTextVariable] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? variables : variables.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

struct NotebookVariablePicker: View {
    let variables: [NotebookTextVariable]
    let insert: (String) -> Void
    @State private var query = ""
    @FocusState private var searching: Bool

    private var matches: [NotebookTextVariable] { RichTextInterpolation.matching(variables, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Insert notebook variable").font(.headline)
            TextField("Search variables…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
                .accessibilityIdentifier("notebook-variable-search")
                .onSubmit { if let first = matches.first { insert(first.name) } }
            if matches.isEmpty {
                Text(variables.isEmpty ? "Run a code cell above this block to publish variables." : "No matching variables.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(matches) { variable in
                            Button { insert(variable.name) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(variable.name).font(.system(.body, design: .monospaced).weight(.semibold))
                                        Spacer()
                                        Text(variable.stale ? "Stale · \(variable.sourceLabel)" : variable.sourceLabel)
                                            .font(.caption).foregroundStyle(variable.stale ? NotebookPalette.sputnik : NotebookPalette.muted)
                                    }
                                    Text(variable.value).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .padding(7).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Insert variable \(variable.name)")
                        }
                    }
                }.frame(maxHeight: 240)
            }
            Text("Inserts {{name}} at the caret. Preview shows its value.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(width: 360)
        .onAppear { searching = true }
    }
}

/// Read-only rendering stays separate from the editing buffer and Undo stack.
struct RichTextPreview: NSViewRepresentable {
    let text: String
    let formatting: String
    let variables: [NotebookTextVariable]
    var markdown = false

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = RichTextScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = NotebookPalette.nativeEditor
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 120))
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 13, height: 11)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        view.setAccessibilityIdentifier("notebook-text-preview")
        scroll.documentView = view
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let decoded = markdown ? NotebookMarkdown.render(text) :
            ((try? RichTextCodec.decode(text: text, formatting: formatting)) ?? NSAttributedString(string: text))
        let rendered = RichTextInterpolation.render(decoded, variables: variables)
        if !view.attributedString().isEqual(to: rendered) { view.textStorage?.setAttributedString(rendered) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = max(48, proposal.width ?? 640)
        guard let view = nsView.documentView as? NSTextView else { return CGSize(width: width, height: 120) }
        let naturalHeight = RichTextLayout.height(view.attributedString(), width: width)
        return CGSize(width: width, height: proposal.height.map { min(naturalHeight, max(0, $0)) } ?? naturalHeight)
    }
}

/// Parse source before interpolation so values containing Markdown punctuation
/// stay literal. Foundation supplies the parser; portable rich-text supplies the
/// same fonts/colors used by sheet text cells.
enum NotebookMarkdown {
    static func render(_ source: String) -> NSAttributedString {
        guard let parsed = try? AttributedString(markdown: source) else {
            return NSAttributedString(string: source, attributes: RichTextCodec.attributes(style: .body, bold: false, italic: false, underline: false))
        }
        let output = NSMutableAttributedString(string: "")
        var previousBlock: Int?
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            let newBlock = block != previousBlock
            if newBlock && output.length > 0 { output.append(NSAttributedString(string: "\n")) }
            var style = RichTextCodec.Style.body
            var prefix = ""
            for component in components {
                switch component.kind {
                case .header(let level): style = level == 1 ? .heading1 : level == 2 ? .heading2 : .heading3
                case .codeBlock: style = .code
                case .listItem(let ordinal):
                    let ordered = components.contains { $0.kind == .orderedList }
                    if newBlock { prefix = ordered ? "\(ordinal). " : "• " }
                default: break
                }
            }
            let inline = run.inlinePresentationIntent ?? []
            if inline.contains(.code) { style = .code }
            var attributes = RichTextCodec.attributes(style: style,
                bold: inline.contains(.stronglyEmphasized), italic: inline.contains(.emphasized), underline: false)
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            output.append(NSAttributedString(string: prefix + String(parsed[run.range].characters), attributes: attributes))
            previousBlock = block
        }
        return output
    }
}

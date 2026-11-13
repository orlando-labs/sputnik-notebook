import AppKit
import SwiftUI

enum NotebookEditorLanguage {
    case sputnik, markdown, json, yaml, toml
    var configTitle: String { self == .yaml ? "YAML" : self == .toml ? "TOML" : "JSON" }
    var isConfig: Bool { self != .sputnik && self != .markdown }
}

/// A small AppKit-backed source editor. Keeping NSTextView alive across SwiftUI
/// snapshots preserves its native selection and undo history while the text is
/// unchanged.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool = true
    var substituteGreekLetters: Bool = true
    var language: NotebookEditorLanguage = .sputnik
    var fillsHeight = false
    var errorRanges: [NotebookSourceRange] = []
    var selectionRequest: NotebookSourceSelection?
    var onFocus: () -> Void = {}
    var onRun: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NotebookPalette.nativeEditor
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = FocusTrackingTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 100))
        context.coordinator.install(textView)
        textView.string = text
        textView.isRichText = false
        textView.isEditable = editable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = NotebookPalette.nativeInk
        textView.insertionPointColor = NotebookPalette.nativeCaret
        textView.selectedTextAttributes = [.backgroundColor: NotebookPalette.nativeTextSelectionBackground,
                                           .foregroundColor: NotebookPalette.nativeTextSelectionForeground]
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.typingAttributes = Self.editorTypingAttributes
        if let storage = textView.textStorage {
            applySyntax(to: storage)
        }
        textView.showsLineNumbers = !language.isConfig
        textView.updateDecorations(errorRanges)
        textView.setAccessibilityLabel(editorLabel)
        scrollView.documentView = textView
        context.coordinator.revealSelection(in: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? FocusTrackingTextView else { return }

        textView.isEditable = editable
        textView.setAccessibilityLabel(editorLabel)
        textView.onFocus = onFocus

        // Runtime snapshots arrive frequently. Assign only when the source
        // itself changed so the normal snapshot path never disturbs selection
        // or the user's undo stack.
        if textView.string != text {
            context.coordinator.replaceExternalSource(text, in: textView)
        } else {
            context.coordinator.flushPendingSource(in: textView)
        }
        textView.updateDecorations(textView.string.utf16.elementsEqual(text.utf16) ? errorRanges : [])
        context.coordinator.revealSelection(in: textView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = max(240, proposal.width ?? 640)
        if language.isConfig { return CGSize(width: width, height: max(150, proposal.height ?? 220)) }
        if fillsHeight, let height = proposal.height { return CGSize(width: width, height: max(96, height)) }
        let inset = (nsView.documentView as? NSTextView)?.textContainerInset.width ?? 40
        let usableWidth = max(160, width - 2 * inset - 10)
        let approximateCharacterWidth: CGFloat = 7.7
        let sourceLines = text.components(separatedBy: .newlines)
        let visualLineCount = sourceLines.reduce(0) { count, line in
            let wrapped = max(1, Int(ceil(CGFloat(line.count) * approximateCharacterWidth / usableWidth)))
            return count + wrapped
        }
        let height = min(320, max(96, CGFloat(visualLineCount) * 19 + 30))
        return CGSize(width: width, height: height)
    }

    private var editorLabel: String {
        if language == .markdown { return "Markdown source" }
        if language.isConfig { return "\(language.configTitle) config editor" }
        return editable ? "Sputnik source editor" : "Read-only Sputnik source"
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        private(set) var isApplyingExternalSource = false
        private(set) var isApplyingSyntax = false
        private var isSubstitutingGreekLetter = false
        private var pendingExternalSource: String?
        private var revealedSelection: UUID?

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        func install(_ textView: FocusTrackingTextView) {
            textView.delegate = self
            textView.onFocus = parent.onFocus
            textView.onUndoRedo = { [weak self, weak textView] in
                guard let textView else { return }
                self?.sourceDidChange(in: textView)
            }
            textView.onLayout = { [weak self, weak textView] in
                guard let textView else { return }
                self?.revealSelection(in: textView)
            }
        }

        func revealSelection(in textView: FocusTrackingTextView) {
            guard let request = parent.selectionRequest, request.id != revealedSelection else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, self.parent.selectionRequest?.id == request.id,
                      self.revealedSelection != request.id,
                      textView.window != nil,
                      (textView.enclosingScrollView?.contentSize.height ?? 0) > 0,
                      textView.string.utf16.elementsEqual(request.source.utf16),
                      textView.revealSourceRange(request.range) else { return }
                self.revealedSelection = request.id
            }
        }

        func replaceExternalSource(_ source: String, in textView: NSTextView) {
            // AppKit owns an IME's marked range. Replacing text while it is
            // marked discards the composition, so wait for the next SwiftUI
            // update after the composition commits.
            if textView.hasMarkedText() {
                pendingExternalSource = source
                return
            }
            pendingExternalSource = nil

            let oldSelection = textView.selectedRange()
            let newLength = (source as NSString).length
            let undoManager = textView.undoManager
            guard let storage = textView.textStorage else { return }
            if parent.language.isConfig {
                // Format, Import and Reset are ordinary undoable draft edits.
                textView.breakUndoCoalescing()
                let range = NSRange(location: 0, length: storage.length)
                if textView.shouldChangeText(in: range, replacementString: source) {
                    storage.replaceCharacters(in: range, with: source)
                    textView.didChangeText()
                }
                textView.setSelectedRange(NSRange(location: min(oldSelection.location, newLength), length: 0))
                highlight(textView)
                return
            }
            undoManager?.disableUndoRegistration()
            isApplyingExternalSource = true
            storage.beginEditing()
            storage.replaceCharacters(
                in: NSRange(location: 0, length: storage.length),
                with: NSAttributedString(string: source,
                                          attributes: CodeEditor.editorTypingAttributes))
            storage.endEditing()
            isApplyingExternalSource = false
            undoManager?.enableUndoRegistration()

            let location = min(max(0, oldSelection.location), newLength)
            let available = max(0, newLength - location)
            let length = min(max(0, oldSelection.length), available)
            textView.setSelectedRange(NSRange(location: location, length: length))
            highlight(textView)
        }

        func flushPendingSource(in textView: NSTextView) {
            guard let pending = pendingExternalSource, !textView.hasMarkedText() else { return }
            pendingExternalSource = nil
            guard pending == parent.text else { return }
            guard pending != textView.string else {
                return
            }
            replaceExternalSource(pending, in: textView)
        }

        private func highlight(_ textView: NSTextView) {
            guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
            let undoManager = textView.undoManager
            undoManager?.disableUndoRegistration()
            isApplyingSyntax = true
            parent.applySyntax(to: storage)
            isApplyingSyntax = false
            undoManager?.enableUndoRegistration()
            textView.typingAttributes = CodeEditor.editorTypingAttributes
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            sourceDidChange(in: textView)
        }

        private func sourceDidChange(in textView: NSTextView) {
            guard !isApplyingExternalSource, !isApplyingSyntax else { return }
            (textView as? FocusTrackingTextView)?.updateDecorations([])
            if parent.text != textView.string {
                parent.text = textView.string
            }
            // Do not touch attributes belonging to an active IME composition.
            // The next non-marked textDidChange recolors the complete source.
            if !textView.hasMarkedText() {
                highlight(textView)
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            flushPendingSource(in: textView)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            guard parent.editable, parent.language == .sputnik, parent.substituteGreekLetters,
                  !isSubstitutingGreekLetter, !isApplyingExternalSource, !isApplyingSyntax,
                  !textView.hasMarkedText(),
                  textView.undoManager?.isUndoing != true,
                  textView.undoManager?.isRedoing != true,
                  let insertedText = replacementString,
                  let replacement = SputnikGreekLetters.replacement(in: textView.string,
                      range: affectedCharRange, insertedText: insertedText) else { return true }

            // Submit one normal AppKit edit so selection, bindings and Undo /
            // Redo all see the same replacement, including its delimiter.
            isSubstitutingGreekLetter = true
            textView.breakUndoCoalescing()
            textView.insertText(replacement.text, replacementRange: replacement.range)
            isSubstitutingGreekLetter = false
            return false
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                textView.insertText("  ", replacementRange: textView.selectedRange())
                return true
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:)),
               textView.window?.currentEvent?.modifierFlags.contains(.command) == true {
                parent.onRun()
                return true
            }

            if parent.language == .sputnik, commandSelector == #selector(NSResponder.insertNewline(_:)),
               parent.editable, !textView.hasMarkedText() {
                let source = textView.string as NSString
                let selection = textView.selectedRange()
                guard selection.location != NSNotFound, NSMaxRange(selection) <= source.length else { return false }
                let lineStart = source.lineRange(for: NSRange(location: selection.location, length: 0)).location
                let prefix = source.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
                let indentation = String(prefix.prefix { $0 == " " || $0 == "\t" })
                let step = indentation.contains("\t") ? "\t" : "  "
                // Tokenize the prefix so colons/brackets in comments and
                // strings cannot open a block, even in unfinished code.
                let tokens = SputnikSyntax.tokens(in: source.substring(to: selection.location))
                    .filter { $0.category != .comment }
                let last = tokens.last(where: { $0.range.location >= lineStart })
                var brackets: [SputnikSyntaxToken] = []
                for token in tokens where token.category != .string {
                    if ["(", "[", "{"].contains(token.text) { brackets.append(token) }
                    else if [")", "]", "}"].contains(token.text), !brackets.isEmpty { brackets.removeLast() }
                }
                var nextIndent = indentation
                if last?.text == ":", brackets.isEmpty { nextIndent += step }
                else if let opener = brackets.last {
                    let start = source.lineRange(for: NSRange(location: opener.range.location, length: 0)).location
                    let line = source.substring(with: NSRange(location: start, length: opener.range.location - start))
                    let base = String(line.prefix { $0 == " " || $0 == "\t" })
                    if nextIndent.count <= base.count { nextIndent = base + step }
                }
                var insertion = "\n" + nextIndent
                var tailLength = 0
                let closing = ["(": ")", "[": "]", "{": "}"]
                if let last, let end = closing[last.text], NSMaxRange(selection) < source.length,
                   source.substring(from: NSMaxRange(selection)).hasPrefix(end) {
                    let tail = "\n" + indentation
                    insertion += tail
                    tailLength = (tail as NSString).length
                }
                textView.insertText(insertion, replacementRange: selection)
                textView.setSelectedRange(NSRange(location: max(0, textView.selectedRange().location - tailLength), length: 0))
                return true
            }

            if parent.language != .sputnik, commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let source = textView.string as NSString
                let start = source.lineRange(for: NSRange(location: textView.selectedRange().location, length: 0)).location
                let prefix = source.substring(with: NSRange(location: start, length: textView.selectedRange().location - start))
                let indentation = String(prefix.prefix { $0 == " " || $0 == "\t" })
                let previous = prefix.trimmingCharacters(in: .whitespaces).last
                let indentMore = parent.language == .json ? previous == "{" || previous == "[" : parent.language == .yaml && previous == ":"
                textView.insertText("\n" + indentation + (indentMore ? "  " : ""), replacementRange: textView.selectedRange())
                return true
            }

            return false
        }
    }

    fileprivate static let editorFont = NSFont.monospacedSystemFont(ofSize: 13,
                                                                     weight: .regular)
    fileprivate static let editorColor = NotebookPalette.nativeInk
    fileprivate static let editorTypingAttributes: [NSAttributedString.Key: Any] = [
        .font: editorFont,
        .foregroundColor: editorColor,
    ]

    private func applySyntax(to storage: NSTextStorage) {
        if language == .markdown {
            let source = storage.string
            storage.setAttributes(Self.editorTypingAttributes, range: NSRange(location: 0, length: storage.length))
            for token in NotebookMarkdownSyntax.tokens(in: source) {
                storage.addAttribute(.foregroundColor, value: SputnikSyntax.color(for: token.category), range: token.range)
            }
        } else if language.isConfig {
            let source = storage.string as NSString
            storage.setAttributes(Self.editorTypingAttributes, range: NSRange(location: 0, length: source.length))
            // Lexical highlighting also works with an unfinished document.
            let pattern = language == .json
                ? #""(?:[^"\\]|\\.)*"|-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|\b(?:true|false|null)\b"#
                : #""(?:[^"\\]|\\.)*"|'[^']*'|#[^\n]*|-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|\b(?:true|false|null)\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            for token in regex.matches(in: storage.string, range: NSRange(location: 0, length: source.length)) {
                let text = source.substring(with: token.range)
                let category: SputnikSyntaxCategory = text.first == "#" ? .comment : text.first == "\"" || text.first == "'" ? .string : ["true", "false", "null"].contains(text) ? .keyword : .number
                storage.addAttribute(.foregroundColor, value: SputnikSyntax.color(for: category), range: token.range)
            }
        } else {
            SputnikSyntax.apply(to: storage, font: Self.editorFont, baseColor: Self.editorColor)
        }
    }
}

enum NotebookMarkdownSyntax {
    private static let inlineRules: [(NSRegularExpression, SputnikSyntaxCategory)] = [
        (#"`+[^`]+?`+"#, .string),
        (#"(?<!\\)(?:\$\$[^$]+?\$\$|\$[^$]+?\$|\\\(.+?\\\))"#, .variable),
        (#"!?\[[^\]\r\n]+\]\([^\r\n)]+\)"#, .className),
        (#"(?<!\\)(?:\*\*[^*]+\*\*|__[^_]+__|\*[^*]+\*|(?<!\w)_[^_]+_(?!\w)|~~[^~]+~~)"#, .keyword)
    ].compactMap { pattern, kind in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, kind) }
    }
    private static let block = try? NSRegularExpression(pattern: #"^ {0,3}(?:#{1,6}(?:\s|$).*|>+|[-+*](?=\s)|\d{1,9}[.)](?=\s)|[-*_]{3,}\s*$|\|)"#)
    private static let fence = try? NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})(.*)$"#)

    static func tokens(in source: String) -> [SputnikSyntaxToken] {
        let text = source as NSString
        guard text.length <= 262144 else { return [] }
        var tokens: [SputnikSyntaxToken] = []
        var openFence: String?
        var displayMath: String?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines]) { line, range, _, stop in
            if tokens.count >= 20000 { stop.pointee = true; return }
            guard let line else { return }
            let lineRange = NSRange(location: 0, length: range.length)
            func add(_ selection: NSRange, _ kind: SputnikSyntaxCategory) {
                tokens.append(.init(range: NSRange(location: range.location + selection.location, length: selection.length), category: kind))
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let closer = displayMath {
                add(lineRange, .variable)
                if trimmed.contains(closer) { displayMath = nil }
                return
            }
            if let match = fence?.firstMatch(in: line, range: lineRange) {
                let value = line as NSString
                let mark = value.substring(with: match.range(at: 1))
                let suffix = value.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
                if let opened = openFence {
                    if mark.first == opened.first && mark.count >= opened.count && suffix.isEmpty { openFence = nil }
                } else { openFence = mark }
                add(lineRange, .comment)
                return
            }
            if openFence != nil { add(lineRange, .string); return }
            for (start, end) in [("$$", "$$"), ("\\[", "\\]")] where trimmed.hasPrefix(start) {
                if !trimmed.dropFirst(start.count).contains(end) { displayMath = end }
                add(lineRange, .variable)
                return
            }
            if let match = block?.firstMatch(in: line, range: lineRange) { add(match.range, .keyword) }
            guard lineRange.length <= 16384 else { return }
            var occupied: [NSRange] = []
            for (rule, kind) in inlineRules {
                for match in rule.matches(in: line, range: lineRange) where !occupied.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                    occupied.append(match.range)
                    add(match.range, kind)
                }
            }
        }
        return tokens
    }
}

class FocusTrackingTextView: NSTextView {
    var onFocus: () -> Void = {}
    var onUndoRedo: () -> Void = {}
    var onLayout: () -> Void = {}
    var showsLineNumbers = false
    private static let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let gutterLeadingPadding: CGFloat = 6
    private static let gutterTrailingPadding: CGFloat = 8
    private var decoratedSource: String?
    private var sourceLines = NotebookSourceLines("")
    private var errorRanges: [NotebookSourceRange] = []
    private var errorLines = IndexSet()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onLayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onLayout()
    }

    @discardableResult
    func revealSourceRange(_ range: NotebookSourceRange) -> Bool {
        guard !hasMarkedText(),
              let selection = NotebookSourceLines(string).selection(for: range, in: string as NSString) else { return false }
        window?.makeFirstResponder(self)
        setSelectedRange(selection)
        if let layoutManager, let textContainer {
            layoutManager.ensureLayout(for: textContainer)
            sizeToFit()
        }
        scrollRangeToVisible(selection)
        return true
    }

    func updateDecorations(_ ranges: [NotebookSourceRange]) {
        guard showsLineNumbers, let layoutManager, let textStorage else { return }
        let source = string
        let sourceChanged = decoratedSource?.utf16.elementsEqual(source.utf16) != true
        guard sourceChanged || errorRanges != ranges else { return }
        if sourceChanged {
            decoratedSource = source
            sourceLines = NotebookSourceLines(source)
            let digits = String(sourceLines.lines.count).count
            let width = (String(repeating: "0", count: digits) as NSString).size(withAttributes: [.font: Self.gutterFont]).width
            textContainerInset = NSSize(width: ceil(width) + Self.gutterLeadingPadding + Self.gutterTrailingPadding,
                                        height: textContainerInset.height)
        }
        if !errorRanges.isEmpty {
            let all = NSRange(location: 0, length: textStorage.length)
            for key: NSAttributedString.Key in [.backgroundColor, .underlineColor, .underlineStyle] {
                layoutManager.removeTemporaryAttribute(key, forCharacterRange: all)
            }
        }
        errorRanges = ranges
        errorLines = IndexSet()
        for range in ranges {
            guard let decoration = sourceLines.decoration(for: range, in: source as NSString) else { continue }
            errorLines.insert(integersIn: decoration.rows)
            if let characters = decoration.characters {
                layoutManager.addTemporaryAttributes([
                    .backgroundColor: NSColor.systemRed.withAlphaComponent(0.21),
                    .underlineColor: NSColor.systemRed,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ], forCharacterRange: characters)
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if showsLineNumbers, let layoutManager, let textContainer {
            let origin = textContainerOrigin
            let visible = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
            // Include the text layout even when only the gutter needs repainting.
            let rows = NSRect(x: 0, y: visible.minY, width: textContainer.containerSize.width, height: visible.height)
            let glyphs = layoutManager.glyphRange(forBoundingRect: rows, in: textContainer)
            func drawLine(_ offset: Int, in rect: NSRect) {
                let line = sourceLines.line(at: offset)
                let y = rect.minY + origin.y
                if errorLines.contains(line) {
                    NSColor.systemRed.withAlphaComponent(0.10).setFill()
                    NSRect(x: 0, y: y, width: bounds.width, height: rect.height).fill()
                }
                guard sourceLines.lines[line].lowerBound == offset else { return }
                let label = String(line + 1) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: Self.gutterFont,
                    .foregroundColor: errorLines.contains(line) ? NSColor.systemRed : NotebookPalette.nativeMuted
                ]
                let size = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: origin.x - Self.gutterTrailingPadding - size.width,
                                       y: y + (rect.height - size.height) / 2),
                           withAttributes: attributes)
            }
            if glyphs.length > 0 {
                layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, fragment, _ in
                    drawLine(layoutManager.characterIndexForGlyph(at: fragment.location), in: rect)
                }
            }
            if layoutManager.extraLineFragmentTextContainer === textContainer,
               rows.intersects(layoutManager.extraLineFragmentRect) {
                drawLine(sourceLines.lines.last!.upperBound, in: layoutManager.extraLineFragmentRect)
            }
            NotebookPalette.nativeRule.setFill()
            NSRect(x: origin.x, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        }
        super.draw(dirtyRect)
    }

    // AppKit can restore the buffer without sending textDidChange on undo.
    // Publish the restored source before the next Save or runtime snapshot.
    @objc func undo(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { return }
        undoManager?.undo()
        onUndoRedo()
    }

    @objc func redo(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { return }
        undoManager?.redo()
        onUndoRedo()
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder { onFocus() }
        return didBecomeFirstResponder
    }
}

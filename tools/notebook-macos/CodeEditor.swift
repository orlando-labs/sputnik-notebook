import AppKit
import SwiftUI

enum NotebookEditorLanguage {
    case sputnik, json, yaml, toml
    var configTitle: String { self == .yaml ? "YAML" : self == .toml ? "TOML" : "JSON" }
}

/// A small AppKit-backed source editor. Keeping NSTextView alive across SwiftUI
/// snapshots preserves its native selection and undo history while the text is
/// unchanged.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool = true
    var substituteGreekLetters: Bool = true
    var language: NotebookEditorLanguage = .sputnik
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
        textView.insertionPointColor = NotebookPalette.nativeAccent
        textView.selectedTextAttributes = [.backgroundColor: NotebookPalette.nativeFoxglove.withAlphaComponent(0.35),
                                           .foregroundColor: NotebookPalette.nativeInk]
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
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
        textView.setAccessibilityLabel(language != .sputnik ? "\(language.configTitle) config editor" : editable ? "Sputnik source editor" : "Read-only Sputnik source")
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        textView.isEditable = editable
        textView.setAccessibilityLabel(language != .sputnik ? "\(language.configTitle) config editor" : editable ? "Sputnik source editor" : "Read-only Sputnik source")
        (textView as? FocusTrackingTextView)?.onFocus = onFocus

        // Runtime snapshots arrive frequently. Assign only when the source
        // itself changed so the normal snapshot path never disturbs selection
        // or the user's undo stack.
        if textView.string != text {
            context.coordinator.replaceExternalSource(text, in: textView)
        } else {
            context.coordinator.flushPendingSource(in: textView)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = max(240, proposal.width ?? 640)
        if language != .sputnik { return CGSize(width: width, height: max(150, proposal.height ?? 220)) }
        let usableWidth = max(160, width - 44)
        let approximateCharacterWidth: CGFloat = 7.7
        let sourceLines = text.components(separatedBy: .newlines)
        let visualLineCount = sourceLines.reduce(0) { count, line in
            let wrapped = max(1, Int(ceil(CGFloat(line.count) * approximateCharacterWidth / usableWidth)))
            return count + wrapped
        }
        let height = min(320, max(96, CGFloat(visualLineCount) * 19 + 30))
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        private(set) var isApplyingExternalSource = false
        private(set) var isApplyingSyntax = false
        private var isSubstitutingGreekLetter = false
        private var pendingExternalSource: String?

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
            if parent.language != .sputnik {
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
        if language != .sputnik {
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

class FocusTrackingTextView: NSTextView {
    var onFocus: () -> Void = {}
    var onUndoRedo: () -> Void = {}

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

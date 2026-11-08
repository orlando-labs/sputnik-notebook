import AppKit
import Foundation
import SwiftUI

private struct SyntaxTestError: Error, CustomStringConvertible {
    let description: String
}

@main
private enum NotebookMacOSSyntaxTests {
    static func main() throws {
        try unicodeRangesAndNumbers()
        try sequencingAndScopedExitKeywords()
        try commentsDoNotEatCode()
        try stringsWinOverKeywordsAndComments()
        try relativeImportStrings()
        try templateLoopControls()
        try regexpTagsAndSymmetricOperator()
        try macroSplicesUseSputnikHashRules()
        try applyingColorPreservesText()
        try editorDiagnosticRanges()
        try editorCoordinatorPreservesSelectionUndoAndIME()
        try greekLetterTokenReplacement()
        try editorGreekLetterReplacement()
        try editorSmartIndentation()
        print("notebook macOS syntax tests passed")
    }

    private static func regexpTagsAndSymmetricOperator() throws {
        for source in [#"r"\d+#{"я"}"mi ~= text"#, #"text ~= r'#{'я'}\d+'im"#,
                       #"rx'#{'я'}\d+'im ~= text"#] {
            let tokens = SputnikSyntax.tokens(in: source)
            _ = try token("~=", in: tokens, category: .operator)
            require(tokens.filter { $0.category == .string }.count == 1,
                    "regexp interpolation quotes and modifiers belong to the tagged string")
            require(!tokens.contains { $0.category == .comment },
                    "regexp interpolation is not a comment")
        }
        for spelling in ["=~", "!~"] {
            require(!SputnikSyntax.tokens(in: "text " + spelling + " pattern").contains {
                $0.category == .operator && $0.text == spelling
            }, "removed regexp operators must not be recognized")
        }
    }

    private static func templateLoopControls() throws {
        let source = "html\"\"\"\n  %for item with_index i in items:\n    #{item}\n  %# omitted\n  %%for literal\n  \"\"\""
        let tokens = SputnikSyntax.tokens(in: source)
        _ = try token("for", in: tokens, category: .keyword)
        _ = try token("in", in: tokens, category: .keyword)
        _ = try token("%# omitted", in: tokens, category: .comment)
        _ = try token("template", in: SputnikSyntax.tokens(in: "template \"./page.html.sv\""), category: .identifier)
        _ = try token("@template", in: SputnikSyntax.tokens(in: "@template(\"value\")"), category: .variable)
        for plain in ["\"\"\"\n  %for item in items:\n  \"\"\"",
                      "r\"\"\"\n  %for item in items:\n  \"\"\""] {
            require(!SputnikSyntax.tokens(in: plain).contains { $0.category == .keyword },
                    "ordinary and regexp blocks keep percent lines literal")
        }
    }

    private static func unicodeRangesAndNumbers() throws {
        let source = "π = 0x2A + 1.5e+2\nЖар = true\n"
        let tokens = SputnikSyntax.tokens(in: source)
        let pi = try token("π", in: tokens, category: .identifier)
        require(pi.range == NSRange(location: 0, length: 1),
                "Greek identifier must use its UTF-16 range")
        _ = try token("0x2A", in: tokens, category: .number)
        _ = try token("1.5e+2", in: tokens, category: .number)
        _ = try token("Жар", in: tokens, category: .className)
        _ = try token("true", in: tokens, category: .constant)

        let astralSource = "😀 + π = 1"
        let astralTokens = SputnikSyntax.tokens(in: astralSource)
        let astralPi = try token("π", in: astralTokens, category: .identifier)
        require(astralPi.range == NSRange(location: 5, length: 1),
                "an astral scalar before a token must count as two UTF-16 units")

        let incomplete = SputnikSyntax.tokens(in: "value = \"unterminated if # true")
        let literal = try token("\"unterminated if # true", in: incomplete, category: .string)
        require(literal.range.location == 8,
                "an incomplete string should still begin at its delimiter")
        require(!incomplete.contains { $0.category == .keyword || $0.category == .comment },
                "incomplete strings must not leak keyword/comment highlighting")
    }

    private static func sequencingAndScopedExitKeywords() throws {
        let sources: [(String, [String])] = [
            ("load() then normalize($_) then save($_)", ["then", "then"]),
            ("Model.rollback then break if invalid?", ["then", "break"]),
            ("Model.transaction(): break :cancelled", ["break"]),
            ("items.map |x|: prepare(x) then next x if skip?(x)", ["then", "next"]),
            ("items.map |x|: next x", ["next"]),
            ("items.map |x|: next", ["next"]),
            ("next if ready?", ["next"]),
            ("next :skipped", ["next"]),
            ("items.map |x|: next :skipped", ["next"]),
            ("ready() then next :skipped", ["then", "next"]),
            ("ready() then next", ["then", "next"]),
            ("(if ready? then start() else wait()) then finish()", ["then", "then"]),
            ("if ready? then (prepare() then run()) else fallback()", ["then", "then"]),
            ("obj.then() then obj.next()", ["then"]),
            ("next = 1 then print(next)", ["then"]),
            ("f(next) then next", ["then", "next"]),
            ("π = load() then normalize($_)", ["then"]),
            ("α then β", ["then"]),
            ("этап then следующий", ["then"]),
        ]
        for (source, expected) in sources {
            let controls = SputnikSyntax.tokens(in: source).filter {
                $0.category == .keyword && ["then", "next", "break"].contains($0.text)
            }
            require(controls.map(\.text) == expected,
                    "Control keywords must follow their expression context: " + source)
            for control in controls {
                require((source as NSString).substring(with: control.range) == control.text,
                        "Control keyword ranges must retain UTF-16 source offsets")
            }
        }
        for source in [
            "then = 1",
            "next = 1",
            "next(1)",
            "fn(then, next)",
            "symbols = [:then, :next]",
            "def then(): null",
            "def next(): null",
            "then? = false",
            "next! = false",
            "labels = {then: 1, next: 2}",
            "obj.then next",
            "foo_then next",
            "message = \"then next break\"",
            "# then next break",
        ] {
            let tokens = SputnikSyntax.tokens(in: source)
            require(!tokens.contains {
                $0.category == .keyword && ["then", "next", "break"].contains($0.text)
            }, "Names, strings and comments must preserve their original role: " + source)
        }
    }

    private static func commentsDoNotEatCode() throws {
        let source = "value = 1\n# if true\nvalue = 2 #{outside}\ncall#method\n"
        let tokens = SputnikSyntax.tokens(in: source)
        let comment = try token("# if true", in: tokens, category: .comment)
        require(comment.text == "# if true", "comment should end at the physical newline")
        require(!tokens.contains { $0.category == .keyword && $0.text == "if" },
                "keywords inside comments must not be highlighted")
        require(!tokens.contains { $0.category == .comment && $0.text.contains("outside") == false && $0.text.contains("value") },
                "a preceding identifier must keep #method out of comment mode")
    }

    private static func stringsWinOverKeywordsAndComments() throws {
        let source = "single = 'if # false \\'quote\\''\n" +
            "double = \"if # true \\\"quote\\\"\"\n" +
            "raw = r\"if #{not_interpolated} # not a comment\"\n" +
            "block = \"\"\"\n  if true\n\"\"\"\n"
        let tokens = SputnikSyntax.tokens(in: source)
        require(tokens.filter { $0.category == .string }.count == 4,
                "single, double, raw, and triple strings should each be one token")
        require(tokens.filter { $0.category == .keyword }.isEmpty,
                "keywords inside strings must not leak into the token stream")
        let raw = try token("r\"if #{not_interpolated} # not a comment\"",
                            in: tokens, category: .string)
        require(raw.text.hasPrefix("r\""), "raw string tag should be part of the literal token")
    }

    private static func macroSplicesUseSputnikHashRules() throws {
        let source = "macro def inc(x):\n  #{x} + true\nplain = 1 #{outside_macro}\n"
        let tokens = SputnikSyntax.tokens(in: source)
        let splice = try token("#{", in: tokens, category: .punctuation)
        require(splice.range.location == (source as NSString).range(of: "#{x}").location,
                "macro splice should be visible at its source location")
        let outside = try token("#{outside_macro}", in: tokens, category: .comment)
        require(outside.text == "#{outside_macro}",
                "outside a macro body #{ keeps its comment reading")
    }

    private static func relativeImportStrings() throws {
        let tokens = SputnikSyntax.tokens(in: "import \"../backend/models\" as models\nfrom \"./helpers.s\" import Item\n")
        _ = try token("import", in: tokens, category: .keyword)
        _ = try token("\"../backend/models\"", in: tokens, category: .string)
        _ = try token("\"./helpers.s\"", in: tokens, category: .string)
    }

    private static func applyingColorPreservesText() throws {
        let source = "answer = 42\n# note\n"
        let storage = NSTextStorage(string: source)
        SputnikSyntax.apply(to: storage)
        require(storage.string == source,
                "syntax coloring must not mutate the editor source")
        require(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil,
                "syntax coloring should install a foreground color")
    }

    private static func editorCoordinatorPreservesSelectionUndoAndIME() throws {
        // NSTextView lazily touches AppKit's application services even though
        // this test never opens a window. Keep that application prohibited so
        // the tokenizer and NSTextStorage tests remain headless.
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        var source = "answer = 42\n"
        let binding = Binding<String>(
            get: { source },
            set: { source = $0 }
        )
        let editor = CodeEditor(text: binding)
        let coordinator = editor.makeCoordinator()
        let textView = UndoTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        coordinator.install(textView)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.string = source
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        coordinator.replaceExternalSource("answer = 43\n", in: textView)
        require(textView.string == "answer = 43\n",
                "external source replacement should update the text view")
        require(textView.selectedRange() == NSRange(location: 4, length: 0),
                "external source replacement should preserve the selection")

        textView.setSelectedRange(NSRange(location: 10, length: 0))
        textView.insertText("!", replacementRange: textView.selectedRange())
        require(textView.string == "answer = 4!3\n",
                "the real text view should accept an edit")
        textView.undoManager?.undo()
        require(textView.string == "answer = 43\n",
                "syntax attributes must not consume the user's undo edit")

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: NSRange(location: 0, length: 0))
        if textView.hasMarkedText() {
            coordinator.replaceExternalSource("runtime = true\n", in: textView)
            require(textView.string.hasPrefix("かな"),
                    "external snapshots must not replace active marked IME text")
            textView.unmarkText()
        }
    }

    private static func editorDiagnosticRanges() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let source = "😀π\r\ninvalid\n"
        let range = NotebookSourceRange(start_line: 0, start_column: 1, end_line: 0, end_column: 2, whole_line: false)
        let lines = NotebookSourceLines(source)
        let decorated = lines.decoration(for: range, in: source as NSString)
        require(lines.lines == [0..<3, 5..<12, 13..<13], "CRLF and trailing empty source lines must count once")
        require(decorated?.characters == NSRange(location: 2, length: 1), "diagnostics count Unicode scalars")
        let eof = NotebookSourceRange(start_line: 2, start_column: 0, end_line: 2, end_column: 1, whole_line: false)
        require(lines.decoration(for: eof, in: source as NSString)?.rows == 2...2, "end of file can mark an empty row")
        let view = FocusTrackingTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        view.showsLineNumbers = true
        view.string = source
        view.updateDecorations([range])
        let layout = view.layoutManager!
        require(layout.temporaryAttribute(.underlineStyle, atCharacterIndex: 2, effectiveRange: nil) != nil,
                "the exact error range must be underlined")
        require(layout.temporaryAttribute(.underlineStyle, atCharacterIndex: 0, effectiveRange: nil) == nil,
                "characters outside the error must not be underlined")
        view.updateDecorations([])
        require(layout.temporaryAttribute(.underlineStyle, atCharacterIndex: 2, effectiveRange: nil) == nil,
                "stale error styling must be removed")
        require(view.revealSourceRange(range) && view.selectedRange() == NSRange(location: 2, length: 1),
                "error navigation must select the diagnostic's Unicode scalar range")
        require(view.revealSourceRange(eof) && view.selectedRange() == NSRange(location: 13, length: 0),
                "end of file diagnostics must navigate to the final empty line")
        let invalid = NotebookSourceRange(start_line: 100, start_column: 0, end_line: 100, end_column: 1, whole_line: false)
        require(!view.revealSourceRange(invalid) && view.selectedRange() == NSRange(location: 13, length: 0),
                "invalid diagnostics must preserve selection")
    }

    private static func greekLetterTokenReplacement() throws {
        func completed(_ source: String, with delimiter: String = " ") -> String {
            guard let edit = SputnikGreekLetters.replacement(in: source,
                range: NSRange(location: (source as NSString).length, length: 0),
                insertedText: delimiter) else { return source + delimiter }
            return (source as NSString).replacingCharacters(in: edit.range, with: edit.text)
        }
        let names = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega".split(separator: " ").map(String.init)
        let symbols = Array("αβγδεζηθικλμνξοπρστυφχψω").map(String.init)
        for (name, symbol) in zip(names, symbols) {
            require(completed(name) == symbol + " ", "Every lowercase Greek name should be supported")
            require(completed(name.capitalized) == symbol.uppercased() + " ", "Title case should produce uppercase Greek")
            require(completed(name.uppercased()) == symbol.uppercased() + " ", "Uppercase names should produce uppercase Greek")
        }
        for delimiter in [" ", "\n", "\r\n", "\t", "  ", "=", ",", ":", "}", ")", "]", "+", "."] {
            require(completed("alpha", with: delimiter) == "α" + delimiter,
                    "Replacement should preserve its whitespace or punctuation trigger")
        }
        require(completed("{\"alpha\": alpha", with: "}") == "{\"alpha\": α}",
                "A string map key must keep its spelling while the value is replaced")
        require(completed("{alpha", with: ":") == "{α:", "A bare map key is an identifier")
        require(completed("{α: alpha", with: "}") == "{α: α}", "A bare map value is an identifier")
        for source in ["\"alpha", "'alpha", "r\"alpha", "\"\"\"alpha", "# alpha", "value = 1 # alpha",
                       "alpha_value", "alpha1", "alphabeta", "alphaЖ", "Жalpha", "αalpha", "aLpHa"] {
            require(completed(source) == source + " ", "Strings, comments and longer names must be preserved: " + source)
        }
        for delimiter in ["_", "1", "x", "?", "!", "\"", "'", " + beta", "\nalpha\n"] {
            require(completed("alpha", with: delimiter) == "alpha" + delimiter,
                    "Postfixes, quotes and bulk pasted code must not trigger replacement")
        }
        for source in ["alpha?", "alpha!", "@alpha", "@@Alpha!", "😀 Ж = alpha"] {
            let expected = source.replacingOccurrences(of: "alpha", with: "α")
                .replacingOccurrences(of: "Alpha", with: "Α") + " "
            require(completed(source) == expected, "Suffixes, sigils and UTF-16 offsets must be preserved")
        }
        require(SputnikGreekLetters.replacement(in: "alpha_value", range: NSRange(location: 5, length: 0),
                                               insertedText: " ") == nil,
                "Inserting whitespace inside an existing name must not replace part of that name")
    }

    private static func editorSmartIndentation() throws {
        var source = ""
        let coordinator = CodeEditor(text: Binding(get: { source }, set: { source = $0 }), substituteGreekLetters: false).makeCoordinator()
        let view = UndoTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 120))
        coordinator.install(view)
        view.isRichText = false; view.allowsUndo = true
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; window.makeFirstResponder(view)
        func newline(_ initial: String, _ expected: String, at caret: Int? = nil, length: Int = 0, selected: Int? = nil) {
            source = initial
            coordinator.replaceExternalSource(initial, in: view)
            view.setSelectedRange(NSRange(location: caret ?? (initial as NSString).length, length: length))
            view.breakUndoCoalescing(); view.undoManager?.removeAllActions()
            require(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))), "Enter uses editor indentation")
            require(view.string == expected && source == expected, "Smart Enter: \(initial.debugDescription) produced \(view.string.debugDescription)")
            require(view.selectedRange().location == (selected ?? (expected as NSString).length), "Caret follows indentation")
            view.undo(nil)
            require(view.string == initial && source == initial, "One Undo restores the complete Enter edit")
            view.redo(nil)
            require(view.string == expected && source == expected, "Redo restores the complete indented newline")
        }
        newline("  value = 42", "  value = 42\n  ")
        newline("  if ready:", "  if ready:\n    ")
        newline("  if ready: # comment", "  if ready: # comment\n    ")
        newline("  # comment:", "  # comment:\n  ")
        newline("  text = \"colon:\"", "  text = \"colon:\"\n  ")
        newline("  text = \"(\"", "  text = \"(\"\n  ")
        newline("  call(", "  call(\n    ")
        newline("  call(\n    value,", "  call(\n    value,\n    ")
        newline("  call()", "  call(\n    \n  )", at: 7, selected: 12)
        newline("  x = 123", "  x = \n  3", at: 6, length: 2, selected: 9)
        newline("\tif ready:", "\tif ready:\n\t\t")
        newline("  π = 42\r\n  x", "  π = 42\r\n  x\n  ")
    }

    private static func editorGreekLetterReplacement() throws {
        var source = ""
        let editor = CodeEditor(text: Binding(get: { source }, set: { source = $0 }))
        let coordinator = editor.makeCoordinator()
        let textView = UndoTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        coordinator.install(textView)
        textView.isRichText = false
        textView.allowsUndo = true
        let window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = textView
        window.makeFirstResponder(textView)

        func reset(_ value: String) {
            source = value
            coordinator.replaceExternalSource(value, in: textView)
            textView.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
            textView.breakUndoCoalescing()
            textView.undoManager?.removeAllActions()
        }
        func insert(_ value: String) {
            textView.insertText(value, replacementRange: textView.selectedRange())
        }

        reset("alpha")
        require(textView.string == "alpha", "External source must never be converted")
        insert(" ")
        require(textView.string == "α " && source == "α ", "AppKit and the source binding should receive the same replacement")
        require(textView.selectedRange() == NSRange(location: 2, length: 0), "The caret should follow the preserved space")
        textView.undo(nil)
        require(textView.string == "alpha" && source == "alpha", "Undo should restore the English name; view=\(textView.string.debugDescription), source=\(source.debugDescription)")
        textView.redo(nil)
        require(textView.string == "α " && source == "α ", "Redo should restore the Greek name and delimiter")
        textView.deleteBackward(nil)
        insert("_1")
        require(source == "α_1", "Deleting the inserted space should allow a Greek identifier with a postfix")

        reset("")
        for character in "alpha_1" { insert(String(character)) }
        insert(" ")
        require(source == "alpha_1 ", "Typing an English identifier with a postfix should preserve it")
        reset("{\"alpha\": alpha")
        insert("}")
        require(source == "{\"alpha\": α}", "Typing map punctuation must preserve literal keys")
        reset("{alpha")
        insert(":")
        insert(" ")
        for character in "alpha" { insert(String(character)) }
        insert("}")
        require(source == "{α: α}", "Typing bare map keys and values must replace both identifiers")

        reset("alpha")
        _ = coordinator.textView(textView, doCommandBy: #selector(NSResponder.insertTab(_:)))
        require(source == "α  ", "Tab should replace the name and preserve editor indentation")
        reset("alpha")
        textView.insertNewline(nil)
        require(source == "α\n", "Enter should replace the name and preserve the newline")

        coordinator.parent.substituteGreekLetters = false
        reset("alpha")
        insert(" ")
        require(source == "alpha ", "Disabling the option should immediately preserve English names")
        coordinator.parent.substituteGreekLetters = true
        reset("beta")
        insert(" ")
        require(source == "β ", "Re-enabling the option should immediately resume replacement")

        reset("")
        insert("alpha beta\n")
        require(source == "alpha beta\n", "Pasting a code block should keep its spelling")
        reset("alpha")
        textView.setMarkedText("alpha", selectedRange: NSRange(location: 5, length: 0),
                               replacementRange: NSRange(location: 0, length: 5))
        if textView.hasMarkedText() {
            require(coordinator.textView(textView, shouldChangeTextIn: NSRange(location: 5, length: 0),
                                         replacementString: " "), "Active IME composition must not be rewritten")
            textView.unmarkText()
        }
    }

    private static func token(_ text: String,
                              in tokens: [SputnikSyntaxToken],
                              category: SputnikSyntaxCategory) throws -> SputnikSyntaxToken {
        guard let token = tokens.first(where: { $0.text == text && $0.category == category }) else {
            throw SyntaxTestError(description: "missing " + category.rawValue + " token: " + text)
        }
        return token
    }

    private static func require(_ condition: @autoclosure () -> Bool,
                                _ message: String) {
        precondition(condition(), message)
    }
}

private final class UndoTextView: FocusTrackingTextView {
    private let stableUndoManager = UndoManager()

    override var undoManager: UndoManager? {
        stableUndoManager
    }
}

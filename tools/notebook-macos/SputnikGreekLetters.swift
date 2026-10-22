import Foundation

/// Plans a replacement only for the identifier just completed by a keystroke.
/// Opening a file, pasting code and syntax highlighting never rewrite source.
enum SputnikGreekLetters {
    private static let lowercase: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        "epsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ",
        "nu": "ν", "xi": "ξ", "omicron": "ο", "pi": "π",
        "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ",
        "phi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
    ]
    // Quotes can begin tagged strings; ? and ! can extend method names.
    // Neither they nor identifier characters should trigger a replacement.
    private static let punctuation = Set("()[]{}.,:;+-*/%=<>&|^~#")

    static func replacement(in source: String, range: NSRange,
                            insertedText: String) -> (range: NSRange, text: String)? {
        // Tab is inserted as two spaces by CodeEditor. Bulk source insertions
        // retain their spelling, as do names extended with identifier postfixes.
        let completesToken = [" ", "\n", "\r", "\r\n", "\t", "  "].contains(insertedText)
            || (insertedText.count == 1 && insertedText.first.map { punctuation.contains($0) } == true)
        guard completesToken,
              range.location != NSNotFound, range.location > 0,
              range.location <= (source as NSString).length,
              range.length <= (source as NSString).length - range.location else { return nil }

        let tokens = SputnikSyntax.tokens(in: source)
        guard let endIndex = tokens.lastIndex(where: { NSMaxRange($0.range) == range.location }) else { return nil }
        var token = tokens[endIndex]
        // The styling scanner emits predicate/bang suffixes as operators for
        // ordinary identifiers, but includes them in @instance variables.
        if token.text == "?" || token.text == "!" {
            guard endIndex > 0 else { return nil }
            let name = tokens[endIndex - 1]
            guard NSMaxRange(name.range) == token.range.location else { return nil }
            token = SputnikSyntaxToken(range: NSUnionRange(name.range, token.range),
                                       category: name.category, text: name.text + token.text)
        }
        guard [.identifier, .className, .variable].contains(token.category) else { return nil }

        let prefix = String(token.text.prefix(while: { $0 == "@" }))
        var name = String(token.text.dropFirst(prefix.count))
        let suffix = name.last == "?" || name.last == "!" ? String(name.removeLast()) : ""
        guard let symbol = lowercase[name.lowercased()] else { return nil }
        let replacement: String
        if name == name.lowercased() {
            replacement = symbol
        } else if name == name.capitalized || name == name.uppercased() {
            replacement = symbol.uppercased()
        } else {
            return nil
        }
        return (NSRange(location: token.range.location,
                        length: token.range.length + range.length),
                prefix + replacement + suffix + insertedText)
    }
}

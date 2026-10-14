import Foundation

/// Built-in spoken punctuation commands for Clean-mode dictation.
///
/// "question mark" / "exclamation mark" become `?` / `!`, including common
/// multilingual aliases. English "comma", "period" / "full stop", "colon",
/// "semicolon", "new line", and "new paragraph" become `,` `.` `:` `;` and a
/// line or paragraph break. Prefixing a phrase with a literal marker
/// (`literal question mark`) keeps the words. User text snippets of the same
/// trigger still win because snippet expansion runs first. Snippet expansions
/// that themselves contain a command phrase are also converted.
public enum SpokenPunctuation: Sendable {
    public static let commands: [(phrase: String, mark: String)] = {
        let pairs: [(String, String)] = [
            ("punto de interrogación", "?"),
            ("ponto de interrogação", "?"),
            ("signo de interrogación", "?"),
            ("signo de interrogacion", "?"),
            ("ponto de interrogacao", "?"),
            ("point d'interrogation", "?"),
            ("point d’interrogation", "?"),
            ("point d interrogation", "?"),
            ("exclamation point", "!"),
            ("exclamation mark", "!"),
            ("punto de exclamación", "!"),
            ("ponto de exclamação", "!"),
            ("signo de exclamación", "!"),
            ("signo de exclamacion", "!"),
            ("ponto de exclamacao", "!"),
            ("point d'exclamation", "!"),
            ("point d’exclamation", "!"),
            ("point d exclamation", "!"),
            ("question mark", "?"),
            ("znak zapytania", "?"),
            ("ausrufezeichen", "!"),
            ("fragezeichen", "?"),
            ("wykrzyknik", "!"),
            ("疑問符", "？"),
            ("感嘆符", "！"),
            ("感叹号", "！"),
            ("问号", "？"),
            ("問號", "？"),
            ("感嘆號", "！"),
            ("new paragraph", "\n\n"),
            ("semi colon", ";"),
            ("full stop", "."),
            ("semicolon", ";"),
            ("new line", "\n"),
            ("period", "."),
            ("colon", ":"),
            ("comma", ","),
        ]
        return pairs.sorted { $0.0.count > $1.0.count }
    }()

    public static let literalPrefixes: [String] = [
        "dosłownie", "doslownie", "wörtlich", "wortlich", "littéral", "litteral",
        "literal",
    ].sorted { $0.count > $1.count }

    /// English commands that are also everyday words: "a period of time",
    /// "a new line of products", "add a comma". These stay words when they are
    /// used as a noun, which the next two sets detect from the neighbouring word.
    /// "question mark" and the other commands are rarely ordinary prose.
    private static let nounLikePhrases: Set<String> = [
        "comma", "period", "full stop", "colon", "semicolon", "semi colon",
        "new line", "new paragraph",
    ]

    /// A determiner or possessive right before the phrase makes it a noun
    /// ("the colon", "our new line"). Words such as "one", "next" or "last"
    /// are left out on purpose: "number one period" is a command.
    private static let nounDeterminers: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those",
        "my", "your", "his", "her", "its", "our", "their",
    ]

    /// Nouns that "period" completes ("time period", "grace period").
    private static let periodCompounds: Set<String> = ["time", "trial", "grace", "waiting"]

    /// Precompiled so Clean-mode dictation stays in the sub-millisecond budget.
    /// Group 1 is the spoken phrase so restore keeps the user's casing.
    private static let literalRegexes: [NSRegularExpression] = {
        var rules: [NSRegularExpression] = []
        for (phrase, _) in commands {
            let capturedPhrase = capturedPhrasePattern(for: phrase)
            for prefix in literalPrefixes {
                let prefixPattern = NSRegularExpression.escapedPattern(for: prefix)
                    .replacingOccurrences(of: " ", with: "\\s+")
                let pattern = "(?i)(?<![\\p{L}\\p{N}])\(prefixPattern)\\s+\(capturedPhrase)"
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                rules.append(regex)
            }
        }
        return rules
    }()

    private struct ReplaceRule {
        let regex: NSRegularExpression
        let phrase: String
        let mark: String
    }

    /// Group 1 is the spoken phrase, so the noun check can read its neighbours.
    /// A spoken mark replaces the engine's punctuation on both sides of it. A
    /// spoken break keeps a full stop the engine wrote before it.
    private static let replaceRules: [ReplaceRule] = {
        commands.compactMap { phrase, mark in
            let precedingPunctuation = mark.hasPrefix("\n") ? "," : "[.,;:]"
            let pattern =
                "(?i)(?:[ \\t]*\(precedingPunctuation))?[ \\t]*\(boundedPhrasePattern(for: phrase))(?:[ \\t]*[.,!?。？！]+)?"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return ReplaceRule(regex: regex, phrase: phrase, mark: mark)
        }
    }()

    public static func apply(to text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        var protected: [String: String] = [:]

        if containsLiteralPrefix(text) {
            for regex in literalRegexes {
                let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
                for match in matches.reversed() {
                    guard let range = Range(match.range, in: result) else { continue }
                    let phraseText: String
                    if match.numberOfRanges > 1, let phraseRange = Range(match.range(at: 1), in: result) {
                        phraseText = String(result[phraseRange])
                    } else {
                        continue
                    }
                    let token = "\u{E000}\(protected.count)\u{E001}"
                    protected[token] = phraseText
                    result.replaceSubrange(range, with: token)
                }
            }
        }

        for rule in replaceRules {
            let matches = rule.regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result),
                    let phraseRange = Range(match.range(at: 1), in: result)
                else { continue }
                if nounLikePhrases.contains(rule.phrase),
                    isUsedAsNoun(rule.phrase, at: phraseRange, in: result)
                {
                    // Protect it like a literal phrase so a shorter command
                    // ("colon" inside "a semi colon") cannot convert it later.
                    let token = "\u{E000}\(protected.count)\u{E001}"
                    protected[token] = String(result[phraseRange])
                    result.replaceSubrange(phraseRange, with: token)
                    continue
                }
                var rest = String(result[range.upperBound...])
                // A full stop or break the speaker asked for starts a new sentence.
                if rule.mark == "." || rule.mark.hasPrefix("\n") {
                    rest = capitalizingFirstLetter(of: rest)
                }
                result = String(result[..<range.lowerBound]) + rule.mark + rest
            }
        }

        for (token, original) in protected {
            result = result.replacingOccurrences(of: token, with: original)
        }
        return result
    }

    private static func isUsedAsNoun(
        _ phrase: String,
        at range: Range<String.Index>,
        in text: String
    ) -> Bool {
        if let previous = wordBefore(range.lowerBound, in: text) {
            if nounDeterminers.contains(previous) { return true }
            if phrase == "period", periodCompounds.contains(previous) { return true }
        }
        return wordAfter(range.upperBound, in: text) == "of"
    }

    /// The word separated from `index` by spaces only, lowercased.
    private static func wordBefore(_ index: String.Index, in text: String) -> String? {
        let before = text[..<index].reversed().drop { $0 == " " || $0 == "\t" }
        let word = before.prefix { $0.isLetter }
        return word.isEmpty ? nil : String(word.reversed()).lowercased()
    }

    /// The word separated from `index` by spaces only, lowercased.
    private static func wordAfter(_ index: String.Index, in text: String) -> String? {
        let after = text[index...]
        let spaces = after.prefix { $0 == " " || $0 == "\t" }
        guard !spaces.isEmpty else { return nil }
        let word = after.dropFirst(spaces.count).prefix { $0.isLetter }
        return word.isEmpty ? nil : word.lowercased()
    }

    /// Leaves words with deliberate inner capitals ("iPhone", "macOS") alone.
    private static func capitalizingFirstLetter(of text: String) -> String {
        guard let index = text.firstIndex(where: { !$0.isWhitespace }),
            text[index].isLowercase
        else { return text }
        let word = text[index...].prefix { !$0.isWhitespace }
        guard !word.dropFirst().contains(where: \.isUppercase) else { return text }
        return text.replacingCharacters(in: index...index, with: text[index].uppercased())
    }

    private static func containsLiteralPrefix(_ text: String) -> Bool {
        literalPrefixes.contains { prefix in
            text.range(of: prefix, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private static func escapedPhrase(_ phrase: String) -> String {
        NSRegularExpression.escapedPattern(for: phrase)
            .replacingOccurrences(of: " ", with: "\\s+")
    }

    private static func capturedPhrasePattern(for phrase: String) -> String {
        "(\(escapedPhrase(phrase)))(?![\\p{L}\\p{N}])"
    }

    private static func boundedPhrasePattern(for phrase: String) -> String {
        guard phrase.contains(where: \.isASCII) else {
            return capturedPhrasePattern(for: phrase)
        }
        return "(?<![\\p{L}\\p{N}])\(capturedPhrasePattern(for: phrase))"
    }
}

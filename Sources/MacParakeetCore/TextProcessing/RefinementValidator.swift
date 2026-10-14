import Foundation

/// Judges whether AI-formatter (LLM) output is a safe replacement for the
/// deterministic baseline transcript. Pure and deterministic: it never rewrites
/// text, only accepts the refinement or rejects it in favor of the baseline.
/// Scope is light cleanup/formatting, not intentional rewrites (Transforms).
///
/// The checks are deliberately narrow and accept-biased: they catch gross
/// corruption (runaway length, degenerate loops, dropped content) and never
/// second-guess legitimate light or structural edits.
public enum RefinementValidator {
    public enum Decision: Equatable, Sendable {
        case accept
        case reject(Reason)
    }

    /// Raw values are the `reason=` token in the `<lane>_ai_formatter_rejected` log line.
    public enum Reason: String, Equatable, Sendable {
        /// The refinement is blank.
        case empty
        /// The refinement is implausibly longer than the input.
        case lengthRunaway
        /// A short word n-gram repeats back-to-back more than the speaker did.
        case repetitionLoop
        /// Too few of the input's content words survived.
        case lowContentOverlap
    }

    public struct Limits: Sendable, Equatable {
        /// Reject if `refined.count > original.count * maxLengthGrowth + lengthSlack`.
        public var maxLengthGrowth: Double
        public var lengthSlack: Int
        /// Fraction of the original's content words that must survive.
        public var minContentOverlap: Double
        /// The overlap check only runs when the original has more content words than this.
        public var overlapMinContentWords: Int
        /// Reject when a 3- or 4-word phrase repeats back-to-back at least this many times.
        public var maxConsecutiveNGramRepeats: Int

        public init(
            maxLengthGrowth: Double,
            lengthSlack: Int,
            minContentOverlap: Double,
            overlapMinContentWords: Int,
            maxConsecutiveNGramRepeats: Int
        ) {
            self.maxLengthGrowth = maxLengthGrowth
            self.lengthSlack = lengthSlack
            self.minContentOverlap = minContentOverlap
            self.overlapMinContentWords = overlapMinContentWords
            self.maxConsecutiveNGramRepeats = maxConsecutiveNGramRepeats
        }

        // Starting values from plans/active/2026-06-21-refinement-validator.md,
        // calibrated against RefinementValidatorTests. Tune from field data.
        public static let dictation = Limits(
            maxLengthGrowth: 1.8, lengthSlack: 80,
            minContentOverlap: 0.5, overlapMinContentWords: 6,
            maxConsecutiveNGramRepeats: 3)
        public static let transcription = Limits(
            maxLengthGrowth: 2.0, lengthSlack: 200,
            minContentOverlap: 0.5, overlapMinContentWords: 8,
            maxConsecutiveNGramRepeats: 3)
    }

    /// Runs the four checks in order; the first failure wins.
    public static func validate(refined: String, original: String, limits: Limits) -> Decision {
        guard refined.contains(where: { !$0.isWhitespace }) else {
            return .reject(.empty)
        }

        let maxLength = Int(Double(original.count) * limits.maxLengthGrowth) + limits.lengthSlack
        if refined.count > maxLength {
            return .reject(.lengthRunaway)
        }

        let refinedWords = words(in: refined)
        let originalWords = words(in: original)

        // A loop is measured against what was said: a speaker who repeated
        // themselves ("no no no no no") must not have faithful cleanup rejected.
        // The input's longest run of any phrase of the same length is the bar.
        for n in repetitionNGramSizes {
            let run = longestBackToBackRun(ofLength: n, in: refinedWords)
            if run >= limits.maxConsecutiveNGramRepeats,
                run > longestBackToBackRun(ofLength: n, in: originalWords)
            {
                return .reject(.repetitionLoop)
            }
        }

        let originalContent = contentWords(originalWords)
        if originalContent.count > limits.overlapMinContentWords {
            let surviving = originalContent.intersection(contentWords(refinedWords)).count
            if Double(surviving) / Double(originalContent.count) < limits.minContentOverlap {
                return .reject(.lowContentOverlap)
            }
        }

        return .accept
    }

    // MARK: - Shared tokenizer

    private static let repetitionNGramSizes = [3, 4]

    /// Words shared by the repetition and overlap checks: lowercased, split on
    /// whitespace, and stripped of every character that is not a letter or
    /// digit, so "team,", "team" and "**team**" compare equal, as do "don't"
    /// and "don’t", and a segment of an unspaced script with a comma inserted.
    static func words(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .compactMap { token in
                let scalars = token.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
                return scalars.isEmpty ? nil : String(String.UnicodeScalarView(scalars))
            }
    }

    /// Fillers and function words the formatter may legitimately drop or
    /// swap; changing them must not read as lost content.
    private static let stopWords: Set<String> = [
        "um", "uh", "umm", "uhh",
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with", "as",
        "is", "are", "was", "were", "be", "been", "it", "its", "this", "that",
        "i", "you", "he", "she", "we", "they", "my", "your", "upon",
    ]

    private static func contentWords(_ words: [String]) -> Set<String> {
        Set(words.filter { !stopWords.contains($0) })
    }

    /// Longest chain of one `n`-word phrase recurring back-to-back: each
    /// occurrence starts no later than the previous one ends, so nothing else
    /// is said between them. "the team the team the team the team" has the
    /// 3-word phrase "the team the" at word 0, 2 and 4: a run of 3. The same
    /// phrase spread across a transcript, or recurring speaker labels, stays at 1.
    static func longestBackToBackRun(ofLength n: Int, in words: [String]) -> Int {
        guard n > 0, words.count >= n else { return 0 }
        var lastSeen: [ArraySlice<String>: (start: Int, run: Int)] = [:]
        var longest = 0
        for start in 0...(words.count - n) {
            let phrase = words[start..<(start + n)]
            var run = 1
            if let previous = lastSeen[phrase], start - previous.start <= n {
                run = previous.run + 1
            }
            lastSeen[phrase] = (start, run)
            longest = max(longest, run)
        }
        return longest
    }
}

import XCTest
@testable import MacParakeetCore

final class SpokenPunctuationTests: XCTestCase {
    private let pipeline = TextProcessingPipeline()

    func testEnglishQuestionAndExclamationMarks() {
        XCTAssertEqual(
            pipeline.process(text: "are you coming question mark.", customWords: [], snippets: []).text,
            "Are you coming?"
        )
        XCTAssertEqual(
            pipeline.process(text: "Are you coming question mark?", customWords: [], snippets: []).text,
            "Are you coming?"
        )
        XCTAssertEqual(
            pipeline.process(text: "ship it exclamation mark", customWords: [], snippets: []).text,
            "Ship it!"
        )
        XCTAssertEqual(
            pipeline.process(text: "ship it exclamation point", customWords: [], snippets: []).text,
            "Ship it!"
        )
    }

    func testLiteralPrefixKeepsTheSpokenPhrase() {
        XCTAssertEqual(
            pipeline.process(text: "say literal question mark please", customWords: [], snippets: []).text,
            "Say question mark please"
        )
        XCTAssertEqual(
            SpokenPunctuation.apply(to: "wörtlich Fragezeichen"),
            "Fragezeichen"
        )
    }

    func testMultilingualSpokenPunctuation() {
        XCTAssertEqual(SpokenPunctuation.apply(to: "fertig fragezeichen"), "fertig?")
        XCTAssertEqual(SpokenPunctuation.apply(to: "vamos signo de interrogación"), "vamos?")
        XCTAssertEqual(SpokenPunctuation.apply(to: "c'est fait point d'exclamation"), "c'est fait!")
        XCTAssertEqual(SpokenPunctuation.apply(to: "pronto ponto de interrogação"), "pronto?")
        XCTAssertEqual(SpokenPunctuation.apply(to: "koniec znak zapytania"), "koniec?")
        XCTAssertEqual(SpokenPunctuation.apply(to: "你好问号"), "你好？")
        XCTAssertEqual(SpokenPunctuation.apply(to: "完成感叹号"), "完成！")
        XCTAssertEqual(SpokenPunctuation.apply(to: "请问号码是多少"), "请问号码是多少")
    }

    func testUserSnippetOverridesBuiltInSpokenPunctuation() {
        let snippets = [
            TextSnippet(trigger: "question mark", expansion: "[Q]")
        ]
        let result = pipeline.process(
            text: "use the question mark",
            customWords: [],
            snippets: snippets
        )
        XCTAssertEqual(result.text, "Use the [Q]")
    }

    func testSpokenPunctuationCanBeDisabled() {
        let result = pipeline.process(
            text: "are you coming question mark",
            customWords: [],
            snippets: [],
            spokenPunctuationEnabled: false
        )
        XCTAssertEqual(result.text, "Are you coming question mark")
    }

    func testPrecedingCommaIsConsumed() {
        XCTAssertEqual(
            SpokenPunctuation.apply(to: "hello, question mark"),
            "hello?"
        )
    }

    func testTrailingEnginePunctuationIsConsumed() {
        XCTAssertEqual(SpokenPunctuation.apply(to: "hello question mark."), "hello?")
        XCTAssertEqual(SpokenPunctuation.apply(to: "hello question mark!"), "hello?")
    }

    // MARK: - English punctuation and break commands

    private func clean(
        _ text: String,
        snippets: [TextSnippet] = [],
        insertionStyle: DictationInsertionStyle = .sentence,
        spokenPunctuationEnabled: Bool = true
    ) -> String {
        pipeline.process(
            text: text,
            customWords: [],
            snippets: snippets,
            insertionStyle: insertionStyle,
            spokenPunctuationEnabled: spokenPunctuationEnabled
        ).text
    }

    func testCommaAndPeriodAreTyped() {
        XCTAssertEqual(clean("send it comma thanks period"), "Send it, thanks.")
        XCTAssertEqual(clean("send it, comma, thanks."), "Send it, thanks.")
        XCTAssertEqual(clean("send it comma thanks full stop"), "Send it, thanks.")
        XCTAssertEqual(clean("number one period"), "Number one.")
        XCTAssertEqual(clean("take the next one period"), "Take the next one.")
    }

    func testEngineCommaAfterACommandIsConsumed() {
        // Parakeet leaves the command as a word and often adds its own comma after it.
        XCTAssertEqual(clean("Send it comma thanks period, then more."), "Send it, thanks. Then more.")
        XCTAssertEqual(clean("Hello, comma, world."), "Hello, world.")
    }

    func testColonAndSemicolonAreTyped() {
        XCTAssertEqual(clean("note colon call him semicolon then email"), "Note: call him; then email")
        XCTAssertEqual(clean("note colon call him semi colon then email"), "Note: call him; then email")
    }

    func testNewLineAndNewParagraphInsertBreaks() {
        XCTAssertEqual(clean("first line new line second line"), "First line\nSecond line")
        XCTAssertEqual(clean("first line new paragraph second line"), "First line\n\nSecond line")
        XCTAssertEqual(clean("First line, new line, second line."), "First line\nSecond line.")
        XCTAssertEqual(clean("Thanks. New paragraph. See you soon."), "Thanks.\n\nSee you soon.")
    }

    func testCommandFullStopStartsANewSentence() {
        XCTAssertEqual(clean("thanks period see you"), "Thanks. See you")
        XCTAssertEqual(clean("one comma two period three"), "One, two. Three")
        XCTAssertEqual(clean("thanks period iPhone is great"), "Thanks. iPhone is great")
    }

    func testEnginePunctuationBeforeAMarkIsReplaced() {
        XCTAssertEqual(clean("Thanks. Period."), "Thanks.")
        XCTAssertEqual(clean("Hello. Comma world"), "Hello, world")
        XCTAssertEqual(SpokenPunctuation.apply(to: "hello. question mark"), "hello?")
    }

    func testInlineStyleTreatsACommandPeriodLikeAnEnginePeriod() {
        XCTAssertEqual(
            clean("send it comma thanks period", insertionStyle: .inline),
            clean("Send it, thanks.", insertionStyle: .inline)
        )
        XCTAssertEqual(clean("send it comma thanks period", insertionStyle: .inline), "send it, thanks")
        XCTAssertEqual(clean("thanks period see you", insertionStyle: .inline), "thanks. See you")
    }

    func testOrdinaryProseIsLeftAlone() {
        let sentences = [
            "It was a period of time",
            "Over that period we measured",
            "The time period was short",
            "The colon is in the abdomen",
            "Add a comma here",
            "Their semicolon use is odd",
            "A new line of products",
            "The new paragraph is better",
            "The car came to a full stop.",
            "A semi colon is here",
            "Period of review starts Monday",
            "Our trial period ends",
            "The grace period ends",
            "A waiting period applies",
        ]
        for sentence in sentences {
            XCTAssertEqual(clean(sentence), sentence)
        }
    }

    func testLiteralPrefixKeepsNewWords() {
        XCTAssertEqual(clean("type literal comma here"), "Type comma here")
        XCTAssertEqual(clean("type literal new paragraph here"), "Type new paragraph here")
    }

    func testUserSnippetStillWinsForNewWords() {
        let snippets = [
            TextSnippet(trigger: "comma", expansion: "[C]"),
            TextSnippet(trigger: "new paragraph", expansion: "[P]"),
        ]
        XCTAssertEqual(clean("one comma two new paragraph three", snippets: snippets), "One [C] two [P] three")
    }

    func testVoiceReturnTriggerBeatsNewLine() {
        let snippets = [
            TextSnippet(trigger: "new line", expansion: "new line", action: .returnKey)
        ]
        // Step 3 strips a trailing Voice Return trigger before spoken punctuation runs.
        let trailing = pipeline.process(text: "send it new line", customWords: [], snippets: snippets)
        XCTAssertEqual(trailing.text, "Send it")
        XCTAssertEqual(trailing.postPasteAction, .returnKey)

        // Step 3 only matches at the end, so a mid-text "new line" is still a break.
        let midText = pipeline.process(text: "first new line second", customWords: [], snippets: snippets)
        XCTAssertEqual(midText.text, "First\nSecond")
        XCTAssertNil(midText.postPasteAction)
    }

    func testSpokenPunctuationToggleDisablesNewWords() {
        XCTAssertEqual(
            clean(
                "a comma b period c full stop d colon e semicolon f new line g new paragraph h",
                spokenPunctuationEnabled: false
            ),
            "A comma b period c full stop d colon e semicolon f new line g new paragraph h"
        )
    }

    func testRawModeLeavesNewWordsUntouched() async {
        let raw = await TextRefinementService().refine(
            rawText: "send it comma thanks period new line bye",
            mode: .raw,
            customWords: [],
            snippets: []
        )
        XCTAssertNil(raw.text, "Raw mode pastes the engine text as is")
        XCTAssertEqual(raw.path, .raw)
        // File, URL, and meeting transcripts pass spokenPunctuationEnabled: false,
        // which testSpokenPunctuationToggleDisablesNewWords covers.
    }
}

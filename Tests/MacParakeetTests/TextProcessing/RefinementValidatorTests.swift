import XCTest
@testable import MacParakeetCore

final class RefinementValidatorTests: XCTestCase {
    private let lanes: [(name: String, limits: RefinementValidator.Limits)] = [
        ("dictation", .dictation),
        ("transcription", .transcription),
    ]

    // MARK: - Accept (false-reject guardrails)

    func testAcceptsLightCleanup() {
        assertAccepted(
            refined: "So the Kubernetes cluster is down.",
            original: "um so the kubernetes cluster is down"
        )
    }

    func testAcceptsStructuralFormatting() {
        let original =
            "okay three things for the launch first the pricing page needs the new tiers "
            + "second support wants the refund policy linked from checkout "
            + "third engineering will freeze the release branch on thursday"
        let refined = """
            ## Launch

            Three things for the launch:

            - **Pricing:** the pricing page needs the new tiers.
            - **Support:** support wants the refund policy linked from checkout.
            - **Engineering:** engineering will freeze the release branch on Thursday.
            """

        assertAccepted(refined: refined, original: original)
    }

    func testAcceptsFillerRemoval() {
        assertAccepted(
            refined: "I think we should move the standup to ten because the build finishes later now",
            original: "um i think uh we should move the standup to ten because uh the build finishes later now"
        )
    }

    func testAcceptsFunctionWordRephrase() {
        assertAccepted(
            refined: "We agreed upon a plan, and I will send a summary to the team on review of this budget.",
            original: "we agreed on the plan and i will send the summary to the team upon review of the budget"
        )
    }

    func testAcceptsTechnicalPhraseTidy() {
        assertAccepted(
            refined:
                "Yesterday we noticed the Kubernetes cluster kept restarting after the deploy, "
                + "and the alerts fired twice.",
            original:
                "so yesterday we noticed the kubernetes thing kept restarting after the deploy "
                + "and the alerts fired twice"
        )
    }

    func testAcceptsDispersedRepetition() {
        let clauses = [
            "pursuant to the supplier agreement the invoices are due in thirty days",
            "the warehouse confirmed the pallets arrived on monday",
            "pursuant to the revised schedule the audit moves to november",
            "finance asked for the receipts before the quarter closes",
            "pursuant to the earlier memo travel needs a director sign off",
            "nobody objected when the vote was called",
            "pursuant to the bylaws the minutes go out within a week",
            "the next session covers hiring",
            "pursuant to the same bylaws the chair rotates in january",
        ]
        let original = clauses.joined(separator: " ")
        let refined = clauses.map { $0.prefix(1).uppercased() + $0.dropFirst() + "." }.joined(separator: " ")

        assertAccepted(refined: refined, original: original)
    }

    func testAcceptsSpeakerLabels() {
        let original =
            "John: can everyone see my screen Sarah: yes we can see it "
            + "John: great let us start with the roadmap Sarah: sounds good "
            + "John: the first item is the database migration"
        let refined = """
            **John:** Can everyone see my screen?

            **Sarah:** Yes, we can see it.

            **John:** Great, let us start with the roadmap.

            **Sarah:** Sounds good.

            **John:** The first item is the database migration.
            """

        assertAccepted(refined: refined, original: original)
    }

    func testAcceptsRepetitionThatWasSpoken() {
        // The speaker repeated themselves; cleanup that keeps it is not a loop.
        assertAccepted(
            refined: "No, no, no, no, no, no. That is not what I meant.",
            original: "no no no no no no that is not what i meant"
        )
    }

    func testAcceptsPunctuationAddedInsideUnspacedSegments() {
        // Scripts without spaces arrive as one token per segment; a comma the
        // formatter adds inside a segment must not make the segment a new word.
        let segments = [
            "今日は会議です", "資料を共有します", "予算は来週決めます", "担当は田中さんです", "締め切りは金曜日です",
            "質問はありますか", "次回は月曜日です", "議事録を送ります", "顧客の要望を確認します", "以上で終わります",
        ]
        let original = segments.joined(separator: " ")
        let refined = segments.map { String($0.prefix(2)) + "、" + String($0.dropFirst(2)) + "。" }
            .joined(separator: " ")

        assertAccepted(refined: refined, original: original)
    }

    // MARK: - Reject

    func testRejectsLengthRunaway() {
        let original =
            "the quarterly numbers came in below forecast because the enterprise renewals slipped "
            + "into next month and marketing spend ran ahead of plan so we should revisit the hiring "
            + "freeze before the board meets and ask sales for a revised pipeline by the end of the week"
        let refined =
            Array(repeating: original, count: 3).joined(separator: " ")
            + " I hope this summary helps. Let me know if you would like me to expand on any of these points."

        assertRejected(.lengthRunaway, refined: refined, original: original)
    }

    func testRejectsBackToBackRepetition() {
        let original = "we should ask the team about the rollout"

        assertRejected(.repetitionLoop, refined: "the team the team the team the team", original: original)
        assertRejected(.repetitionLoop, refined: "the team, the team, the team, the team,", original: original)
        // A 4-word loop: only the 4-word scan sees it.
        assertRejected(
            .repetitionLoop,
            refined: "We are ahead of the plan ahead of the plan ahead of the plan.",
            original: "we are ahead of the plan"
        )
        assertRejected(
            .repetitionLoop,
            refined: "We should ask the team, the team, the team, the team about the rollout.",
            original: original
        )
    }

    func testRejectsRepetitionLongerThanWasSpoken() {
        let original = "no no no no no no that is not what i meant"
        let refined = Array(repeating: "no", count: 30).joined(separator: " ") + " that is not what I meant"

        assertRejected(.repetitionLoop, refined: refined, original: original)
    }

    func testRejectsLowContentOverlap() {
        let original =
            "the quarterly numbers came in below forecast because the enterprise renewals slipped "
            + "into next month and marketing spend ran ahead of plan"

        // Replaced: none of what was said survives.
        assertRejected(
            .lowContentOverlap,
            refined: "Thanks for sharing. Here is a short poem about autumn leaves falling by a quiet river.",
            original: original
        )
        // Dropped: only the opening clause survives.
        assertRejected(
            .lowContentOverlap,
            refined: "The quarterly numbers came in below forecast.",
            original: original
        )
    }

    func testRejectsEmpty() {
        assertRejected(.empty, refined: "", original: "hello world")
        assertRejected(.empty, refined: " \n\t ", original: "hello world")
    }

    // MARK: - Edges

    func testShortInputSingleSubstitutionNotRejectedByOverlap() {
        assertAccepted(refined: "Ship the Kubernetes cluster Friday.", original: "ship the kubernetes thing friday")
        // Below the content-word floor the overlap check does not run at all.
        assertAccepted(refined: "Phone mother tonight.", original: "call mom tonight")
    }

    func testFirstFailingCheckWins() {
        // Looping output that is also far too long reports the length check, which runs first.
        let original = "we should ask the team about the rollout"
        let refined = Array(repeating: "the team", count: 200).joined(separator: " ")

        assertRejected(.lengthRunaway, refined: refined, original: original)
    }

    func testValidatorIsPure() {
        let original =
            "the quarterly numbers came in below forecast because the enterprise renewals slipped "
            + "into next month and marketing spend ran ahead of plan"
        let good =
            "The quarterly numbers came in below forecast because the enterprise renewals slipped "
            + "into next month, and marketing spend ran ahead of plan."
        let bad = "Here is a short poem about autumn leaves."

        for (_, limits) in lanes {
            let accepted = RefinementValidator.validate(refined: good, original: original, limits: limits)
            XCTAssertEqual(accepted, .accept)
            XCTAssertEqual(RefinementValidator.validate(refined: good, original: original, limits: limits), accepted)

            let rejected = RefinementValidator.validate(refined: bad, original: original, limits: limits)
            XCTAssertEqual(rejected, .reject(.lowContentOverlap))
            XCTAssertEqual(RefinementValidator.validate(refined: bad, original: original, limits: limits), rejected)
        }
    }

    func testReasonRawValuesAreStableLogTokens() {
        XCTAssertEqual(RefinementValidator.Reason.empty.rawValue, "empty")
        XCTAssertEqual(RefinementValidator.Reason.lengthRunaway.rawValue, "lengthRunaway")
        XCTAssertEqual(RefinementValidator.Reason.repetitionLoop.rawValue, "repetitionLoop")
        XCTAssertEqual(RefinementValidator.Reason.lowContentOverlap.rawValue, "lowContentOverlap")
    }

    // MARK: - Helpers

    private func assertAccepted(
        refined: String,
        original: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (name, limits) in lanes {
            XCTAssertEqual(
                RefinementValidator.validate(refined: refined, original: original, limits: limits),
                .accept,
                "\(name) limits",
                file: file,
                line: line
            )
        }
    }

    private func assertRejected(
        _ reason: RefinementValidator.Reason,
        refined: String,
        original: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (name, limits) in lanes {
            XCTAssertEqual(
                RefinementValidator.validate(refined: refined, original: original, limits: limits),
                .reject(reason),
                "\(name) limits",
                file: file,
                line: line
            )
        }
    }
}

@testable import MeetingTranscriber
import XCTest

/// Window state, analogous to `LiveCaptionsStateTests`: pure logic on the
/// observable object, no window.
@MainActor
final class LiveMinutesStateTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC") ?? .gmt

    func testInitialStateIsIdleAndEmpty() {
        let state = LiveMinutesState()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.utterances.isEmpty)
        XCTAssertTrue(state.summary.isEmpty)
        XCTAssertNil(state.lastUpdated)
        XCTAssertFalse(state.isUpdating)
        XCTAssertFalse(state.lastUpdateFailed)
        XCTAssertTrue(state.transcriptVisible)
        XCTAssertNil(state.draftMarkdown)
        XCTAssertNil(state.lastUpdatedText())
    }

    func testBeginStartsRecordingAndDropsThePreviousMeeting() {
        let state = LiveMinutesState()
        state.begin()
        state.append(LiveMinutesTestData.utterance("old"))
        state.apply(.summary(LiveMinutesSummary(topics: ["Old"], decisions: [], tasks: [], openQuestions: []), at: Date()))

        state.begin()

        XCTAssertEqual(state.phase, .recording)
        XCTAssertTrue(state.utterances.isEmpty)
        XCTAssertTrue(state.summary.isEmpty)
        XCTAssertNil(state.lastUpdated)
    }

    func testTranscriptVisibilityIsAViewChoiceThatSurvivesTheNextMeeting() {
        let state = LiveMinutesState()
        state.transcriptVisible = false
        state.begin()
        XCTAssertFalse(state.transcriptVisible)
    }

    func testAppendKeepsArrivalOrderAndCapsLength() {
        let state = LiveMinutesState()
        state.begin()
        for index in 0 ..< (LiveMinutesState.maxUtterancesKept + 3) {
            state.append(LiveMinutesTestData.utterance("u\(index)"))
        }
        XCTAssertEqual(state.utterances.count, LiveMinutesState.maxUtterancesKept)
        XCTAssertEqual(state.utterances.first?.text, "u3", "the oldest lines drop first")
        XCTAssertEqual(state.utterances.last?.text, "u\(LiveMinutesState.maxUtterancesKept + 2)")
    }

    func testUpdatingFlagFollowsEvents() {
        let state = LiveMinutesState()
        state.apply(.updating(true))
        XCTAssertTrue(state.isUpdating)
        state.apply(.updating(false))
        XCTAssertFalse(state.isUpdating)
    }

    func testSummaryEventReplacesSummaryAndStampsTime() {
        let state = LiveMinutesState()
        let summary = LiveMinutesSummary(topics: ["Budget"], decisions: [], tasks: [], openQuestions: [])
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)

        state.apply(.summary(summary, at: stamp))

        XCTAssertEqual(state.summary, summary)
        XCTAssertEqual(state.lastUpdated, stamp)
        XCTAssertEqual(state.lastUpdatedText(timeZone: utc), "22:13:20")
        XCTAssertTrue(state.hasSummary)
    }

    func testFailureKeepsTheSummaryAndIsClearedByTheNextSuccess() {
        let state = LiveMinutesState()
        let summary = LiveMinutesSummary(topics: ["Kept"], decisions: [], tasks: [], openQuestions: [])
        state.apply(.summary(summary, at: Date()))

        state.apply(.failed(.invalidReply))
        XCTAssertTrue(state.lastUpdateFailed)
        XCTAssertEqual(state.summary, summary)

        state.apply(.summary(summary, at: Date()))
        XCTAssertFalse(state.lastUpdateFailed)
    }

    func testEndKeepsTranscriptAndSummaryForTheFinalDraft() {
        let state = LiveMinutesState()
        state.begin()
        state.append(LiveMinutesTestData.utterance("hello"))
        state.apply(.updating(true))
        let final = LiveMinutesSummary(topics: ["Final"], decisions: [], tasks: [], openQuestions: [])

        state.end(finalSummary: final, at: Date())

        XCTAssertEqual(state.phase, .ended)
        XCTAssertFalse(state.isUpdating)
        XCTAssertEqual(state.summary, final)
        XCTAssertEqual(state.utterances.count, 1)
        XCTAssertTrue(state.draftMarkdown?.contains("- Final") == true)
    }

    func testClearResetsEverythingButTheViewChoice() {
        let state = LiveMinutesState()
        state.begin()
        state.append(LiveMinutesTestData.utterance("x"))
        state.clear()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertTrue(state.utterances.isEmpty)
    }

    // MARK: - Editing

    func testModelSummaryFillsTheEditors() {
        let state = LiveMinutesState()
        let summary = LiveMinutesSummary(
            topics: ["A", "B"], decisions: [], tasks: [.init(task: "Ship", owner: "Anna", due: "Mon")], openQuestions: ["Q"],
        )
        state.apply(.summary(summary, at: Date()))
        XCTAssertEqual(state.text(for: .topics), "A\nB")
        XCTAssertEqual(state.text(for: .tasks), "Ship | Anna | Mon")
        XCTAssertEqual(state.text(for: .openQuestions), "Q")
        XCTAssertEqual(state.text(for: .decisions), "")
    }

    func testTypingKeepsTheTextVerbatimAndDerivesTheSummary() {
        let state = LiveMinutesState()
        var forwarded: [LiveMinutesSummary] = []
        state.onUserEdit = { forwarded.append($0) }

        state.setText("- First\n\n  \nSecond\n", for: .topics)

        XCTAssertEqual(state.text(for: .topics), "- First\n\n  \nSecond\n", "the editor text is not reshaped while typing")
        XCTAssertEqual(state.summary.topics, ["First", "Second"])
        XCTAssertEqual(forwarded.last?.topics, ["First", "Second"])
        XCTAssertEqual(state.userEditCount, 1)
    }

    func testEditingOneSectionLeavesTheOthersAlone() {
        let state = LiveMinutesState()
        state.apply(.summary(LiveMinutesSummary(topics: ["T"], decisions: ["D"], tasks: [], openQuestions: []), at: Date()))
        state.setText("D edited", for: .decisions)
        XCTAssertEqual(state.summary.topics, ["T"])
        XCTAssertEqual(state.summary.decisions, ["D edited"])
    }

    func testTaskLinesParseOwnerAndDue() {
        let state = LiveMinutesState()
        state.setText("Plan | Anna | Friday\nReview |  | Mon\nCall Bo", for: .tasks)
        XCTAssertEqual(state.summary.tasks, [
            .init(task: "Plan", owner: "Anna", due: "Friday"),
            .init(task: "Review", owner: nil, due: "Mon"),
            .init(task: "Call Bo", owner: nil, due: nil),
        ])
    }

    func testReplyBuiltBeforeAnEditNeverOverwritesTheTypedText() {
        let state = LiveMinutesState()
        state.apply(.updating(true))
        state.setText("Typed", for: .topics)

        state.apply(.summary(LiveMinutesSummary(topics: ["From model"], decisions: [], tasks: [], openQuestions: []), at: Date()))

        XCTAssertEqual(state.text(for: .topics), "Typed")
        XCTAssertEqual(state.summary.topics, ["Typed"])
    }

    func testReplyAfterAnEditIsAcceptedOnceTheNextRequestStarted() {
        let state = LiveMinutesState()
        state.setText("Typed", for: .topics)
        state.apply(.updating(true))
        state.apply(.summary(LiveMinutesSummary(topics: ["Typed", "Extended"], decisions: [], tasks: [], openQuestions: []), at: Date()))
        XCTAssertEqual(state.text(for: .topics), "Typed\nExtended")
    }

    func testEndKeepsTheEditorsWhenTheUserTypedDuringTheFinalUpdate() {
        let state = LiveMinutesState()
        state.begin()
        state.setText("Typed", for: .topics)
        state.end(
            finalSummary: LiveMinutesSummary(topics: ["Model"], decisions: [], tasks: [], openQuestions: []),
            at: Date(),
            keepingEdits: true,
        )
        XCTAssertEqual(state.phase, .ended)
        XCTAssertEqual(state.text(for: .topics), "Typed")
    }

    func testDraftMarkdownReflectsEdits() {
        let state = LiveMinutesState()
        state.setText("Edited topic", for: .topics)
        XCTAssertTrue(state.draftMarkdown?.contains("- Edited topic") == true)
    }
}

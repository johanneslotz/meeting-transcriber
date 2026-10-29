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
}

@testable import MeetingTranscriber
import XCTest

/// The path from finalized captions to the window state, with a fake LLM:
/// gating, ordering, the end-of-meeting final draft, and a clean start for the
/// next meeting.
@MainActor
final class LiveMinutesCoordinatorTests: XCTestCase {
    private func makeSettings(enabled: Bool = true) throws -> AppSettings {
        let name = "live-minutes-coord-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let settings = AppSettings(defaults: defaults)
        settings.liveMinutesEnabled = enabled
        settings.liveTranscriptionEnabled = true
        settings.whisperLanguage = "de"
        return settings
    }

    private func makeCoordinator(
        settings: AppSettings,
        llm: FakeLiveMinutesLLM,
        captions: LiveCaptionsState,
    ) -> LiveMinutesCoordinator {
        let coordinator = LiveMinutesCoordinator(
            state: LiveMinutesState(),
            settings: settings,
            makeClient: { _ in llm },
            endGraceSeconds: 0,
        )
        coordinator.attach(to: captions)
        return coordinator
    }

    private func waitUntilEnded(_ state: LiveMinutesState) async {
        for _ in 0 ..< 500 where state.phase != .ended {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testDisabledSettingStartsNothing() throws {
        let captions = LiveCaptionsState()
        let coordinator = try makeCoordinator(settings: makeSettings(enabled: false), llm: FakeLiveMinutesLLM(), captions: captions)

        coordinator.recordingChanged(isRecording: true)
        captions.applyFinalized("hello", channel: .mic)

        XCTAssertFalse(coordinator.isRunning)
        XCTAssertEqual(coordinator.state.phase, .idle)
        XCTAssertTrue(coordinator.state.utterances.isEmpty)
    }

    func testLiveTranscriptionOffStartsNothing() throws {
        let settings = try makeSettings()
        settings.liveTranscriptionEnabled = false
        let coordinator = makeCoordinator(settings: settings, llm: FakeLiveMinutesLLM(), captions: LiveCaptionsState())
        coordinator.recordingChanged(isRecording: true)
        XCTAssertFalse(coordinator.isRunning, "without captions there is no source for the minutes")
    }

    func testFinalizedCaptionsReachTheWindowStateInOrderWithSpeakerLabels() throws {
        let captions = LiveCaptionsState()
        let coordinator = try makeCoordinator(settings: makeSettings(), llm: FakeLiveMinutesLLM(), captions: captions)

        coordinator.recordingChanged(isRecording: true)
        captions.applyFinalized("first", channel: .mic, speaker: "Anna")
        captions.applyFinalized("second", channel: .app, speaker: "Remote")

        XCTAssertTrue(coordinator.isRunning)
        XCTAssertEqual(coordinator.state.phase, .recording)
        XCTAssertEqual(coordinator.state.utterances.map(\.text), ["first", "second"])
        XCTAssertEqual(coordinator.state.utterances.map(\.speaker), ["Anna", "Remote"])
    }

    func testPartialCaptionsAreNotMinuted() throws {
        let captions = LiveCaptionsState()
        let coordinator = try makeCoordinator(settings: makeSettings(), llm: FakeLiveMinutesLLM(), captions: captions)
        coordinator.recordingChanged(isRecording: true)
        captions.applyPartial("half a sent", channel: .mic)
        XCTAssertTrue(coordinator.state.utterances.isEmpty)
    }

    func testEndOfRecordingProducesTheFinalDraftFromTheLastUpdate() async throws {
        let captions = LiveCaptionsState()
        let llm = FakeLiveMinutesLLM(replies: [.success(LiveMinutesTestData.json(decisions: ["Ship it"]))])
        let coordinator = try makeCoordinator(settings: makeSettings(), llm: llm, captions: captions)
        coordinator.recordingChanged(isRecording: true)
        captions.applyFinalized("we ship it", channel: .mic, speaker: "Anna")

        coordinator.recordingChanged(isRecording: false)
        await waitUntilEnded(coordinator.state)

        XCTAssertEqual(coordinator.state.phase, .ended)
        XCTAssertEqual(coordinator.state.summary.decisions, ["Ship it"])
        XCTAssertFalse(coordinator.isRunning)
        let requests = await llm.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].user.contains("Anna: we ship it"))
        XCTAssertNotNil(coordinator.state.draftMarkdown)
    }

    func testNextMeetingStartsClean() async throws {
        let captions = LiveCaptionsState()
        let coordinator = try makeCoordinator(settings: makeSettings(), llm: FakeLiveMinutesLLM(), captions: captions)
        coordinator.recordingChanged(isRecording: true)
        captions.applyFinalized("meeting one", channel: .mic)
        coordinator.recordingChanged(isRecording: false)
        await waitUntilEnded(coordinator.state)

        coordinator.recordingChanged(isRecording: true)

        XCTAssertEqual(coordinator.state.phase, .recording)
        XCTAssertTrue(coordinator.state.utterances.isEmpty)
        XCTAssertTrue(coordinator.state.summary.isEmpty)
    }

    func testMissingEndpointReportsFailureInsteadOfCrashing() throws {
        let coordinator = try LiveMinutesCoordinator(
            state: LiveMinutesState(), settings: makeSettings(), makeClient: { _ in nil }, endGraceSeconds: 0,
        )
        coordinator.recordingChanged(isRecording: true)
        XCTAssertFalse(coordinator.isRunning)
        XCTAssertTrue(coordinator.state.lastUpdateFailed)
    }

    func testLateUtteranceDuringTheGracePeriodIsStillMinuted() async throws {
        let captions = LiveCaptionsState()
        let llm = FakeLiveMinutesLLM()
        let coordinator = try LiveMinutesCoordinator(
            state: LiveMinutesState(),
            settings: makeSettings(),
            makeClient: { _ in llm },
            endGraceSeconds: 0.3,
        )
        coordinator.attach(to: captions)
        coordinator.recordingChanged(isRecording: true)
        coordinator.recordingChanged(isRecording: false)

        captions.applyFinalized("flushed tail", channel: .mic)
        await waitUntilEnded(coordinator.state)

        XCTAssertEqual(coordinator.state.utterances.map(\.text), ["flushed tail"])
        let requests = await llm.requests
        XCTAssertEqual(requests.count, 1, "the tail utterance is part of the final update")
    }
}

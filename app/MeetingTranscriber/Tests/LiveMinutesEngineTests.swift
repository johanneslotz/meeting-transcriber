@testable import MeetingTranscriber
import XCTest

/// The rolling-summary engine against a scripted LLM: scheduling and debounce,
/// cancellation, state hand-over between updates, failure fallback, bounded
/// context. No network, no timers: the clock and the sleep are injected.
final class LiveMinutesEngineTests: XCTestCase {
    private func makeEngine(
        client: any LiveMinutesLLMClient,
        configuration: LiveMinutesEngine.Configuration = .init(),
        clock: ManualClock = ManualClock(),
        sleep: @escaping LiveMinutesEngine.Sleep = { _ in try await Task.sleep(for: .seconds(3600)) },
        events: EventLog = EventLog(),
    ) -> LiveMinutesEngine {
        LiveMinutesEngine(
            client: client,
            configuration: configuration,
            systemPrompt: { "SYSTEM" },
            now: { clock.now },
            sleep: sleep,
            onEvent: { await events.append($0) },
        )
    }

    private actor EventLog {
        private(set) var events: [LiveMinutesEngine.Event] = []
        func append(_ event: LiveMinutesEngine.Event) {
            events.append(event)
        }
    }

    // MARK: - State hand-over

    func testUpdateSendsStateAndNewUtterancesAndReplacesSummary() async {
        let reply = LiveMinutesTestData.json(topics: ["Budget"], decisions: ["Ship in May"])
        let llm = FakeLiveMinutesLLM(replies: [.success(reply)])
        let engine = makeEngine(client: llm)
        await engine.ingest(LiveMinutesTestData.utterance("We need a budget", speaker: "Anna"))

        let outcome = await engine.requestUpdate(force: true)

        XCTAssertEqual(outcome, .updated)
        let summary = await engine.summary
        XCTAssertEqual(summary.topics, ["Budget"])
        XCTAssertEqual(summary.decisions, ["Ship in May"])
        let pending = await engine.pending
        XCTAssertTrue(pending.isEmpty, "a successful update consumes the utterances it covered")
        let requests = await llm.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].system, "SYSTEM")
        XCTAssertTrue(requests[0].user.contains("Anna: We need a budget"))
        XCTAssertTrue(requests[0].user.contains("CURRENT STATE:"))
    }

    func testSecondUpdateSendsPreviousStateAndOnlyTheNewUtterances() async {
        let llm = FakeLiveMinutesLLM(replies: [
            .success(LiveMinutesTestData.json(topics: ["First topic"])),
            .success(LiveMinutesTestData.json(topics: ["First topic", "Second topic"])),
        ])
        let engine = makeEngine(client: llm)
        await engine.ingest(LiveMinutesTestData.utterance("alpha utterance"))
        await engine.requestUpdate(force: true)
        await engine.ingest(LiveMinutesTestData.utterance("bravo utterance"))
        await engine.requestUpdate(force: true)

        let requests = await llm.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].user.contains("First topic"), "the old state travels with the next update")
        XCTAssertTrue(requests[1].user.contains("bravo utterance"))
        XCTAssertFalse(requests[1].user.contains("alpha utterance"), "covered utterances are never resent")
        let topics = await engine.summary.topics
        XCTAssertEqual(topics, ["First topic", "Second topic"])
    }

    func testNothingPendingMakesNoRequest() async {
        let llm = FakeLiveMinutesLLM()
        let engine = makeEngine(client: llm)
        let outcome = await engine.requestUpdate(force: true)
        XCTAssertEqual(outcome, .skippedNothingNew)
        let requests = await llm.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testBlankUtterancesAreIgnored() async {
        let engine = makeEngine(client: FakeLiveMinutesLLM())
        await engine.ingest(LiveMinutesTestData.utterance("   \n"))
        let pending = await engine.pending
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Failure fallback

    func testUnparseableReplyKeepsOldStateAndPendingUtterances() async {
        let llm = FakeLiveMinutesLLM(replies: [
            .success(LiveMinutesTestData.json(topics: ["Kept"])),
            .success("Sorry, I cannot produce JSON right now."),
        ])
        let events = EventLog()
        let engine = makeEngine(client: llm, events: events)
        await engine.ingest(LiveMinutesTestData.utterance("one"))
        await engine.requestUpdate(force: true)
        await engine.ingest(LiveMinutesTestData.utterance("two"))

        let outcome = await engine.requestUpdate(force: true)

        XCTAssertEqual(outcome, .failed(.invalidReply))
        let topics = await engine.summary.topics
        XCTAssertEqual(topics, ["Kept"])
        let pending = await engine.pending
        XCTAssertEqual(pending.map(\.text), ["two"], "the utterance is retried with the next update")
        let logged = await events.events
        XCTAssertTrue(logged.contains(.failed(.invalidReply)))
        XCTAssertEqual(logged.last, .updating(false), "the updating indicator is always cleared")
    }

    func testReplyThatEmptiesANonEmptyStateIsRejected() async {
        let llm = FakeLiveMinutesLLM(replies: [
            .success(LiveMinutesTestData.json(topics: ["Kept"])),
            .success(LiveMinutesTestData.json()),
        ])
        let engine = makeEngine(client: llm)
        await engine.ingest(LiveMinutesTestData.utterance("one"))
        await engine.requestUpdate(force: true)
        await engine.ingest(LiveMinutesTestData.utterance("two"))

        let outcome = await engine.requestUpdate(force: true)

        XCTAssertEqual(outcome, .failed(.invalidReply))
        let topics = await engine.summary.topics
        XCTAssertEqual(topics, ["Kept"])
    }

    func testTransportErrorKeepsStateAndPending() async {
        let llm = FakeLiveMinutesLLM(replies: [.failure(URLError(.cannotConnectToHost))])
        let engine = makeEngine(client: llm)
        await engine.ingest(LiveMinutesTestData.utterance("one"))

        let outcome = await engine.requestUpdate(force: true)

        XCTAssertEqual(outcome, .failed(.request))
        let summary = await engine.summary
        XCTAssertTrue(summary.isEmpty)
        let pending = await engine.pending
        XCTAssertEqual(pending.count, 1)
    }

    // MARK: - Debounce, busy, cancellation

    func testCountTriggeredUpdateIsDebouncedByMinimumGap() async {
        let clock = ManualClock()
        var configuration = LiveMinutesEngine.Configuration()
        configuration.minSecondsBetweenUpdates = 20
        let engine = makeEngine(client: FakeLiveMinutesLLM(), configuration: configuration, clock: clock)

        await engine.ingest(LiveMinutesTestData.utterance("one"))
        let first = await engine.requestUpdate()
        XCTAssertEqual(first, .updated, "no earlier attempt, so the gap does not apply")

        await engine.ingest(LiveMinutesTestData.utterance("two"))
        clock.advance(by: 5)
        let tooSoon = await engine.requestUpdate()
        XCTAssertEqual(tooSoon, .skippedTooSoon)

        clock.advance(by: 20)
        let later = await engine.requestUpdate()
        XCTAssertEqual(later, .updated)
    }

    func testForcedUpdateIgnoresTheMinimumGap() async {
        let engine = makeEngine(client: FakeLiveMinutesLLM())
        await engine.ingest(LiveMinutesTestData.utterance("one"))
        await engine.requestUpdate(force: true)
        await engine.ingest(LiveMinutesTestData.utterance("two"))
        let outcome = await engine.requestUpdate(force: true)
        XCTAssertEqual(outcome, .updated)
    }

    func testUpdateWhilePreviousIsRunningIsSkippedNotQueued() async {
        let gate = AsyncGate()
        let llm = FakeLiveMinutesLLM(gate: gate)
        let engine = makeEngine(client: llm)
        await engine.ingest(LiveMinutesTestData.utterance("one"))

        let first = Task { await engine.requestUpdate(force: true) }
        await llm.waitForRequests(1)
        await engine.ingest(LiveMinutesTestData.utterance("two"))
        let second = await engine.requestUpdate(force: true)
        XCTAssertEqual(second, .skippedBusy)

        await gate.open()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .updated)
        let requests = await llm.requests
        XCTAssertEqual(requests.count, 1, "the skipped trigger made no request")
        let pending = await engine.pending
        XCTAssertEqual(pending.map(\.text), ["two"], "the utterance that arrived meanwhile stays for the next update")
    }

    func testStopCancelsRunningUpdateAndDiscardsItsReply() async {
        let gate = AsyncGate()
        let llm = FakeLiveMinutesLLM(replies: [.success(LiveMinutesTestData.json(topics: ["Late"]))], gate: gate)
        let events = EventLog()
        let engine = makeEngine(client: llm, events: events)
        await engine.ingest(LiveMinutesTestData.utterance("one"))

        let running = Task { await engine.requestUpdate(force: true) }
        await llm.waitForRequests(1)
        await engine.stop()
        await gate.open()

        let outcome = await running.value
        XCTAssertEqual(outcome, .cancelled)
        let summary = await engine.summary
        XCTAssertTrue(summary.isEmpty, "a cancelled update must not publish")
        let pending = await engine.pending
        XCTAssertEqual(pending.count, 1)
        let logged = await events.events
        XCTAssertEqual(logged.last, .updating(false))
        XCTAssertFalse(logged.contains { if case .summary = $0 { true } else { false } })
    }

    // MARK: - Triggers

    func testUtteranceCountTriggersAnUpdateWhileRunning() async {
        var configuration = LiveMinutesEngine.Configuration()
        configuration.utteranceTrigger = 3
        configuration.minSecondsBetweenUpdates = 0
        let llm = FakeLiveMinutesLLM()
        let engine = makeEngine(client: llm, configuration: configuration)
        await engine.start()

        await engine.ingest(LiveMinutesTestData.utterance("one"))
        await engine.ingest(LiveMinutesTestData.utterance("two"))
        await engine.ingest(LiveMinutesTestData.utterance("three"))
        await llm.waitForRequests(1)
        await engine.waitForIdle()
        await engine.stop()

        let requests = await llm.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].user.contains("three"))
    }

    func testNoCountTriggerBeforeStart() async {
        var configuration = LiveMinutesEngine.Configuration()
        configuration.utteranceTrigger = 1
        let llm = FakeLiveMinutesLLM()
        let engine = makeEngine(client: llm, configuration: configuration)
        await engine.ingest(LiveMinutesTestData.utterance("one"))
        await engine.waitForIdle()
        let requests = await llm.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testTimerRequestsTheConfiguredIntervalAndTriggersAnUpdate() async {
        var configuration = LiveMinutesEngine.Configuration()
        configuration.intervalSeconds = 45
        configuration.utteranceTrigger = 100
        let ticks = TickSource()
        let llm = FakeLiveMinutesLLM()
        let engine = makeEngine(client: llm, configuration: configuration, sleep: { await ticks.wait(interval: $0) })
        await engine.ingest(LiveMinutesTestData.utterance("one"))
        await engine.start()

        await ticks.fire()
        await llm.waitForRequests(1)
        await engine.waitForIdle()
        await engine.stop()

        let intervals = await ticks.requestedIntervals
        XCTAssertEqual(intervals.first, 45)
        let summary = await engine.summary
        XCTAssertEqual(summary.topics, ["Fallback topic"])
    }

    // MARK: - Finish

    func testFinishFoldsInPendingUtterancesWithOneLastUpdate() async {
        let llm = FakeLiveMinutesLLM(replies: [.success(LiveMinutesTestData.json(decisions: ["Final decision"]))])
        let engine = makeEngine(client: llm)
        await engine.start()
        await engine.ingest(LiveMinutesTestData.utterance("closing words"))

        let final = await engine.finish()

        XCTAssertEqual(final.decisions, ["Final decision"])
        let requests = await llm.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testFinishWaitsForARunningUpdate() async {
        let gate = AsyncGate()
        let llm = FakeLiveMinutesLLM(replies: [.success(LiveMinutesTestData.json(topics: ["From running"]))], gate: gate)
        let engine = makeEngine(client: llm)
        await engine.ingest(LiveMinutesTestData.utterance("one"))
        let running = Task { await engine.requestUpdate(force: true) }
        await llm.waitForRequests(1)

        let finishing = Task { await engine.finish() }
        await gate.open()
        _ = await running.value
        let final = await finishing.value

        XCTAssertEqual(final.topics, ["From running"])
        let requests = await llm.requests
        XCTAssertEqual(requests.count, 1, "nothing was left pending, so no extra request")
    }

    // MARK: - Bounded context

    func testRequestContextIsBoundedAndKeepsTheNewestUtterances() async {
        var configuration = LiveMinutesEngine.Configuration()
        configuration.maxContextCharacters = 1000
        let llm = FakeLiveMinutesLLM()
        let engine = makeEngine(client: llm, configuration: configuration)
        for index in 0 ..< 60 {
            await engine.ingest(LiveMinutesTestData.utterance("utterance \(index) " + String(repeating: "x", count: 120), at: Double(index)))
        }

        await engine.requestUpdate(force: true)

        let user = await llm.requests[0].user
        XCTAssertLessThan(user.count, 1000 + 600, "budget plus fixed framing and the state JSON")
        XCTAssertTrue(user.contains("utterance 59 "))
        XCTAssertFalse(user.contains("utterance 0 "))
        XCTAssertTrue(user.contains("earlier utterances were left out"))
        let pending = await engine.pending
        XCTAssertTrue(pending.isEmpty, "omitted utterances are accounted for, not resent forever")
    }

    func testPendingQueueIsCappedWhileTheEndpointIsDown() async {
        var configuration = LiveMinutesEngine.Configuration()
        configuration.maxPendingUtterances = 5
        let engine = makeEngine(client: FakeLiveMinutesLLM(), configuration: configuration)
        for index in 0 ..< 12 {
            await engine.ingest(LiveMinutesTestData.utterance("u\(index)"))
        }
        let pending = await engine.pending
        XCTAssertEqual(pending.map(\.text), ["u7", "u8", "u9", "u10", "u11"])
    }

    func testBoundedBatchAlwaysKeepsTheNewestUtteranceEvenOverBudget() {
        let utterances = [
            LiveMinutesTestData.utterance("old", at: 0),
            LiveMinutesTestData.utterance(String(repeating: "y", count: 500), at: 1),
        ]
        let (batch, omitted) = LiveMinutesEngine.boundedBatch(utterances, budget: 50)
        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(omitted, 1)
        XCTAssertEqual(batch[0].text.first, "y")
    }

    func testOversizedSingleUtteranceIsTruncatedOnIngest() async {
        var configuration = LiveMinutesEngine.Configuration()
        configuration.maxContextCharacters = 400
        let engine = makeEngine(client: FakeLiveMinutesLLM(), configuration: configuration)
        await engine.ingest(LiveMinutesTestData.utterance(String(repeating: "z", count: 5000)))
        let pending = await engine.pending
        XCTAssertEqual(pending.first?.text.count, 100)
    }
}

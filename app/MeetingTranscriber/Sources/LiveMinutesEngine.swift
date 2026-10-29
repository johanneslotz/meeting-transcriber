import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LiveMinutes")

/// The one operation the engine needs from an LLM: a system prompt and a user
/// message in, the model's reply out. A seam so tests drive the engine with a
/// fake and the app plugs in `OpenAIProtocolGenerator.complete`.
protocol LiveMinutesLLMClient: Sendable {
    func complete(system: String, user: String) async throws -> String
}

/// Keeps the structured running summary of a meeting and refreshes it from a
/// bounded slice of new utterances.
///
/// **Update cycle.** An update sends only the current state (JSON) plus the
/// utterances that arrived since the last successful update, newest first up
/// to `maxContextCharacters`, and replaces the state with the validated reply.
/// Older utterances that do not fit are summarised as a count, never resent.
///
/// **Triggers.** A timer every `intervalSeconds`, or `utteranceTrigger` pending
/// utterances, whichever comes first. The count trigger is debounced by
/// `minSecondsBetweenUpdates` so a burst of short utterances cannot flood the
/// endpoint; the timer is not.
///
/// **One request at a time.** A trigger that finds an update running is
/// skipped, not queued: the utterances stay pending and ride along with the
/// next one. `stop()` cancels the running request and discards its reply.
///
/// Every update emits `.updating(false)` as its last event, whatever the outcome.
///
/// **Failure keeps the old state.** A transport error or an unparseable reply
/// leaves the summary and the pending utterances untouched, so the next update
/// retries with everything that is still pending (bounded by
/// `maxPendingUtterances`).
///
/// **Memory only.** Nothing here touches disk, and the log carries counts, never
/// content. One engine serves one meeting; the next meeting builds a new one.
actor LiveMinutesEngine {
    struct Configuration: Equatable {
        var intervalSeconds: TimeInterval = 90
        var utteranceTrigger = 12
        var minSecondsBetweenUpdates: TimeInterval = 20
        var maxContextCharacters = 6000
        var maxPendingUtterances = 400
        var limits = LiveMinutesSummary.Limits()
    }

    enum Failure: Equatable {
        case request
        case invalidReply
    }

    enum Outcome: Equatable {
        case updated
        case skippedBusy
        case skippedNothingNew
        case skippedTooSoon
        case failed(Failure)
        case cancelled
    }

    enum Event: Equatable {
        case updating(Bool)
        case summary(LiveMinutesSummary, at: Date)
        case failed(Failure)
    }

    typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    typealias EventHandler = @Sendable (Event) async -> Void

    private let client: any LiveMinutesLLMClient
    private let configuration: Configuration
    private let systemPrompt: @Sendable () -> String
    private let now: @Sendable () -> Date
    private let sleep: Sleep
    private let onEvent: EventHandler

    private(set) var summary: LiveMinutesSummary = .empty
    private(set) var pending: [LiveMinutesUtterance] = []

    private var running = false
    private var generation = 0
    private var lastAttempt: Date?
    private var inFlight: Task<Outcome, Never>?
    private var timer: Task<Void, Never>?
    private var triggerQueued = false

    init(
        client: any LiveMinutesLLMClient,
        configuration: Configuration = Configuration(),
        systemPrompt: @escaping @Sendable () -> String,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping Sleep = { seconds in try await Task.sleep(for: .seconds(seconds)) },
        onEvent: @escaping EventHandler = { _ in },
    ) {
        self.client = client
        self.configuration = configuration
        self.systemPrompt = systemPrompt
        self.now = now
        self.sleep = sleep
        self.onEvent = onEvent
    }

    // MARK: - Lifecycle

    /// Arm the timer. Idempotent.
    func start() {
        guard !running else { return }
        running = true
        let interval = configuration.intervalSeconds
        let sleep = sleep
        timer = Task {
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                await self.tick()
            }
        }
    }

    /// Stop timing, cancel a running request and discard its reply. The
    /// summary and the pending utterances stay readable.
    func stop() {
        running = false
        generation += 1
        timer?.cancel()
        timer = nil
        inFlight?.cancel()
    }

    /// End of meeting: stop timing, let a running update finish, fold in
    /// whatever is still pending with one last update, and return the result.
    func finish() async -> LiveMinutesSummary {
        running = false
        timer?.cancel()
        timer = nil
        if let run = inFlight { _ = await run.value }
        if !pending.isEmpty { _ = await requestUpdate(force: true) }
        return summary
    }

    /// Suspends until the running update, if any, has finished.
    func waitForIdle() async {
        if let run = inFlight { _ = await run.value }
    }

    // MARK: - Input

    /// Add a finalized utterance; may trigger an update by count.
    func ingest(_ utterance: LiveMinutesUtterance) {
        let text = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let capped = String(text.prefix(configuration.maxContextCharacters / 4))
        pending.append(LiveMinutesUtterance(
            id: utterance.id, speaker: utterance.speaker, text: capped, timestamp: utterance.timestamp,
        ))
        let overflow = pending.count - configuration.maxPendingUtterances
        if overflow > 0 { pending.removeFirst(overflow) }

        guard running, !triggerQueued, inFlight == nil, pending.count >= configuration.utteranceTrigger else { return }
        triggerQueued = true
        Task { await self.runTriggeredUpdate() }
    }

    // MARK: - Updating

    /// Run one update now unless one is running, nothing is pending, or (when
    /// not `force`) the last attempt was too recent.
    @discardableResult
    func requestUpdate(force: Bool = false) async -> Outcome {
        if inFlight != nil { return .skippedBusy }
        guard !pending.isEmpty else { return .skippedNothingNew }
        if !force, let lastAttempt, now().timeIntervalSince(lastAttempt) < configuration.minSecondsBetweenUpdates {
            return .skippedTooSoon
        }
        let run = Task { await self.performUpdate() }
        inFlight = run
        let outcome = await run.value
        inFlight = nil
        return outcome
    }

    private func tick() async {
        guard running else { return }
        _ = await requestUpdate(force: true)
    }

    private func runTriggeredUpdate() async {
        triggerQueued = false
        guard running else { return }
        _ = await requestUpdate()
    }

    private func performUpdate() async -> Outcome {
        let startedIn = generation
        lastAttempt = now()
        let snapshot = pending
        let (batch, omitted) = Self.boundedBatch(snapshot, budget: configuration.maxContextCharacters)
        let user = LiveMinutesPrompt.userMessage(state: summary, utterances: batch, omitted: omitted)
        let system = systemPrompt()

        await onEvent(.updating(true))
        let reply: String
        do {
            reply = try await client.complete(system: system, user: user)
        } catch {
            guard !Task.isCancelled, startedIn == generation else {
                await onEvent(.updating(false))
                return .cancelled
            }
            logger.warning("live minutes update failed (request), keeping previous summary")
            await onEvent(.failed(.request))
            await onEvent(.updating(false))
            return .failed(.request)
        }
        guard !Task.isCancelled, startedIn == generation else {
            await onEvent(.updating(false))
            return .cancelled
        }

        let parsed: LiveMinutesSummary
        do {
            parsed = try LiveMinutesSummary.parse(reply, limits: configuration.limits)
            // A reply that empties a non-empty state is a dropped section, not an update.
            if parsed.isEmpty, !summary.isEmpty { throw LiveMinutesSummary.ParseError.invalidStructure }
        } catch {
            logger.warning("live minutes update failed (reply), keeping previous summary")
            await onEvent(.failed(.invalidReply))
            await onEvent(.updating(false))
            return .failed(.invalidReply)
        }

        summary = parsed
        let consumed = Set(snapshot.map(\.id))
        pending.removeAll { consumed.contains($0.id) }
        logger.info("live minutes updated (\(batch.count, privacy: .public) utterances, \(omitted, privacy: .public) omitted)")
        await onEvent(.summary(parsed, at: now()))
        await onEvent(.updating(false))
        return .updated
    }

    /// Newest utterances first until `budget` characters are used, returned in
    /// chronological order with the number that did not fit. Always keeps at
    /// least the newest one.
    static func boundedBatch(_ utterances: [LiveMinutesUtterance], budget: Int) -> (batch: [LiveMinutesUtterance], omitted: Int) {
        var used = 0
        var kept: [LiveMinutesUtterance] = []
        for utterance in utterances.reversed() {
            let cost = LiveMinutesPrompt.render(utterance).count + 1
            if !kept.isEmpty, used + cost > budget { break }
            used += cost
            kept.append(utterance)
        }
        return (kept.reversed(), utterances.count - kept.count)
    }
}

import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "LiveMinutes")

/// Production client: the app's OpenAI-compatible generator, bounded for a
/// request that has to fit between two updates.
struct OpenAILiveMinutesClient: LiveMinutesLLMClient {
    let generator: OpenAIProtocolGenerator

    func complete(system: String, user: String) async throws -> String {
        try await generator.complete(system: system, user: user)
    }
}

/// Connects the live caption stream to a `LiveMinutesEngine` and the window's
/// `LiveMinutesState`, one engine per meeting.
///
/// **Source.** Subscribes to `LiveCaptionsState.onFinalized`, so Live Minutes
/// sees exactly the finalized utterances the caption overlay sees. It adds no
/// ASR pass and holds no reference to the recorder: a later live-only mode only
/// has to call `begin()` / `end()` itself instead of following `isRecording`.
///
/// **Ordering.** Utterances go through one `AsyncStream` consumed by a single
/// task, so the engine sees them in capture order and always after `start()`.
///
/// **Lifetime.** `recordingChanged(isRecording:)` is called by the app scene on
/// each recording start and stop. The gate is evaluated when a meeting begins;
/// changing the settings mid-meeting takes effect with the next one.
@MainActor
final class LiveMinutesCoordinator {
    typealias ClientFactory = @MainActor (AppSettings) -> (any LiveMinutesLLMClient)?

    let state: LiveMinutesState
    private let settings: AppSettings
    private let makeClient: ClientFactory
    private let now: @Sendable () -> Date
    private let endGraceSeconds: TimeInterval

    private struct Session {
        let engine: LiveMinutesEngine
        let input: AsyncStream<LiveMinutesUtterance>.Continuation
        let consumer: Task<Void, Never>
    }

    private var session: Session?
    private var endTask: Task<Void, Never>?

    init(
        state: LiveMinutesState,
        settings: AppSettings,
        makeClient: @escaping ClientFactory = LiveMinutesCoordinator.makeDefaultClient,
        now: @escaping @Sendable () -> Date = { Date() },
        endGraceSeconds: TimeInterval = 1.5,
    ) {
        self.endGraceSeconds = endGraceSeconds
        self.state = state
        self.settings = settings
        self.makeClient = makeClient
        self.now = now
    }

    static func makeDefaultClient(settings: AppSettings) -> (any LiveMinutesLLMClient)? {
        guard let endpoint = URL(string: settings.liveMinutesResolvedEndpoint) else { return nil }
        return OpenAILiveMinutesClient(generator: OpenAIProtocolGenerator(
            endpoint: endpoint,
            model: settings.liveMinutesResolvedModel,
            language: settings.protocolLanguage,
            apiKey: settings.liveMinutesAPIKey,
            timeoutSeconds: 60,
            maxTotalSeconds: 120,
            maxOutputTokens: 2000,
        ))
    }

    /// Route finalized caption lines here. Replaces any earlier handler.
    func attach(to captions: LiveCaptionsState) {
        captions.onFinalized = { [weak self] line in
            self?.receive(line)
        }
    }

    /// Whether the settings allow Live Minutes for a recording right now.
    var isEnabledForRecording: Bool {
        LiveMinutesGate.isActive(
            minutesEnabled: settings.liveMinutesEnabled,
            captionsAvailable: LiveCaptionsGate.captionsAvailable(
                liveEnabled: settings.liveTranscriptionEnabled,
                engineLanguage: settings.activeEngineLanguageOrNil,
                engineSupportsLive: settings.transcriptionEngine.supportsLiveTranscription,
            ),
            isRecording: true,
        )
    }

    /// Whether a meeting is being minuted at the moment.
    var isRunning: Bool {
        session != nil
    }

    func recordingChanged(isRecording: Bool) {
        if isRecording {
            guard isEnabledForRecording else { return }
            begin()
        } else {
            end()
        }
    }

    // MARK: - Meeting lifecycle

    func begin() {
        retirePreviousMeeting()
        state.begin()
        guard let client = makeClient(settings) else {
            state.apply(.failed(.request))
            return
        }
        var configuration = LiveMinutesEngine.Configuration()
        configuration.intervalSeconds = settings.liveMinutesIntervalSeconds
        let language = settings.protocolLanguage
        let state = state
        let engine = LiveMinutesEngine(
            client: client,
            configuration: configuration,
            systemPrompt: { LiveMinutesPrompt.systemPrompt(language: language) },
            onEvent: { event in await state.apply(event) },
        )
        let (stream, input) = AsyncStream.makeStream(of: LiveMinutesUtterance.self)
        let consumer = Task {
            await engine.start()
            for await utterance in stream {
                await engine.ingest(utterance)
            }
        }
        session = Session(engine: engine, input: input, consumer: consumer)
    }

    /// The recording stopped. Utterances keep being accepted for a short grace
    /// period, because the caption pipeline commits the tail utterance when it
    /// is flushed at stop time, which can land after the recording flag flips.
    /// Then the engine folds in what is pending with one last update.
    func end() {
        guard session != nil, endTask == nil else { return }
        endTask = Task { [state, now, endGraceSeconds] in
            try? await Task.sleep(for: .seconds(endGraceSeconds))
            guard !Task.isCancelled, let finished = session else { return }
            session = nil
            finished.input.finish()
            await finished.consumer.value
            let summary = await finished.engine.finish()
            await finished.engine.stop()
            // Cancelled by the next meeting: its state is not ours to overwrite.
            guard !Task.isCancelled else { return }
            state.end(finalSummary: summary, at: now())
        }
    }

    /// A new meeting starts while the previous one is still finishing its last
    /// update: cancel that update, its result is no longer wanted.
    private func retirePreviousMeeting() {
        endTask?.cancel()
        endTask = nil
        if let running = session {
            session = nil
            running.input.finish()
            Task { await running.engine.stop() }
        }
    }

    private func receive(_ line: LiveCaptionLine) {
        guard let session else { return }
        let utterance = LiveMinutesUtterance(speaker: line.speaker, text: line.text, timestamp: now())
        state.append(utterance)
        session.input.yield(utterance)
    }
}

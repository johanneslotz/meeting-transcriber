import Foundation
import Observation

/// Observable, memory-only state behind the Live Minutes window: the running
/// transcript, the rolling summary and the status around it.
///
/// Nothing in here is persisted. The state is cleared when the next meeting
/// begins; until then the finished meeting's transcript and final draft stay
/// readable so the user can copy or save the draft.
///
/// `transcriptVisible` is a per-window viewing choice, not meeting data, so it
/// survives `clear()`.
@Observable
@MainActor
final class LiveMinutesState {
    enum Phase: Equatable {
        case idle
        case recording
        case ended
    }

    /// Cap on the transcript kept for display. The engine has its own bounds;
    /// this one only keeps a very long meeting from growing the view model.
    static let maxUtterancesKept = 5000

    private(set) var phase: Phase = .idle
    private(set) var utterances: [LiveMinutesUtterance] = []
    private(set) var summary: LiveMinutesSummary = .empty
    private(set) var lastUpdated: Date?
    private(set) var isUpdating = false
    /// The most recent update failed; the summary shown is the one before it.
    private(set) var lastUpdateFailed = false

    /// Hides the live transcript pane so the summary can be read without the
    /// scrolling text. Display only: utterances keep arriving while hidden.
    var transcriptVisible = true

    /// A new meeting starts: drop the previous meeting's content.
    func begin() {
        clear()
        phase = .recording
    }

    func append(_ utterance: LiveMinutesUtterance) {
        utterances.append(utterance)
        let overflow = utterances.count - Self.maxUtterancesKept
        if overflow > 0 { utterances.removeFirst(overflow) }
    }

    func apply(_ event: LiveMinutesEngine.Event) {
        switch event {
        case let .updating(active):
            isUpdating = active

        case let .summary(newSummary, date):
            summary = newSummary
            lastUpdated = date
            lastUpdateFailed = false

        case .failed:
            lastUpdateFailed = true
        }
    }

    /// The meeting ended; `finalSummary` is the engine's last state.
    func end(finalSummary: LiveMinutesSummary, at date: Date) {
        if finalSummary != summary || lastUpdated == nil {
            summary = finalSummary
            lastUpdated = date
        }
        isUpdating = false
        phase = .ended
    }

    func clear() {
        phase = .idle
        utterances.removeAll()
        summary = .empty
        lastUpdated = nil
        isUpdating = false
        lastUpdateFailed = false
    }

    var hasSummary: Bool {
        !summary.isEmpty
    }

    /// The draft as Markdown, for copy and save; nil until there is something.
    var draftMarkdown: String? {
        hasSummary ? summary.markdown() : nil
    }

    /// `HH:mm:ss` of the last successful update, or nil before the first one.
    func lastUpdatedText(timeZone: TimeZone = .autoupdatingCurrent) -> String? {
        guard let lastUpdated else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: lastUpdated)
    }
}

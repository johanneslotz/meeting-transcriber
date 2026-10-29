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
    /// The text shown in each section editor. Kept apart from `summary` so the
    /// editor never reshapes what the user is typing: the summary is derived
    /// from it on every edit, and it is rebuilt from the summary only when a
    /// new summary arrives from the model.
    private(set) var sectionTexts: [LiveMinutesSection: String] = [:]
    private(set) var lastUpdated: Date?
    private(set) var isUpdating = false
    /// The most recent update failed; the summary shown is the one before it.
    private(set) var lastUpdateFailed = false

    /// Number of user edits so far. Lets the end-of-meeting step tell whether
    /// the user typed while the final update ran.
    private(set) var userEditCount = 0
    private var editCountAtRequestStart = 0

    /// Called after each user edit with the summary derived from the editors.
    /// Set by the coordinator to hand the edit to the engine.
    @ObservationIgnored var onUserEdit: (@MainActor (LiveMinutesSummary) -> Void)?

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
            if active { editCountAtRequestStart = userEditCount }
            isUpdating = active

        case let .summary(newSummary, date):
            // The user typed after this request started and the edit has not
            // reached the engine yet: the reply is built on older text, and
            // the typed text wins.
            guard userEditCount == editCountAtRequestStart else { return }
            setSummary(newSummary)
            lastUpdated = date
            lastUpdateFailed = false

        case .failed:
            lastUpdateFailed = true
        }
    }

    /// The meeting ended; `finalSummary` is the engine's last state. With
    /// `keepingEdits` (the user typed while the final update ran) the editors
    /// are left as the user has them rather than replaced under the cursor.
    func end(finalSummary: LiveMinutesSummary, at date: Date, keepingEdits: Bool = false) {
        if !keepingEdits, finalSummary != summary || lastUpdated == nil {
            setSummary(finalSummary)
            lastUpdated = date
        }
        isUpdating = false
        phase = .ended
    }

    func clear() {
        phase = .idle
        utterances.removeAll()
        setSummary(.empty)
        lastUpdated = nil
        isUpdating = false
        lastUpdateFailed = false
    }

    /// The text of one section editor.
    func text(for section: LiveMinutesSection) -> String {
        sectionTexts[section] ?? ""
    }

    /// The user changed one section: keep the typed text as is, derive the
    /// summary from it and hand it on.
    func setText(_ text: String, for section: LiveMinutesSection) {
        userEditCount += 1
        sectionTexts[section] = text
        summary = summary.replacing(section, withEditorText: text)
        onUserEdit?(summary)
    }

    private func setSummary(_ newSummary: LiveMinutesSummary) {
        summary = newSummary
        sectionTexts = Dictionary(uniqueKeysWithValues: LiveMinutesSection.allCases.map {
            ($0, newSummary.editorText(for: $0))
        })
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

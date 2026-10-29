import Foundation

/// Prompt and message construction for the rolling live summary.
///
/// The system prompt follows the `protocol_prompt.md` mechanism: a built-in
/// default that a non-empty `live_minutes_prompt.md` in the data directory
/// replaces, with `{LANGUAGE}` substituted from `AppSettings.protocolLanguage`.
/// The user message is built here and never customised, because the engine
/// depends on its exact shape (state JSON plus new utterances).
enum LiveMinutesPrompt {
    static let defaultPrompt = """
    You maintain live meeting minutes while a meeting is still running.
    You receive the CURRENT STATE as JSON and the NEW UTTERANCES since the last update.
    Return the UPDATED STATE as one JSON object and nothing else: no Markdown, no code fence,
    no commentary. Write all items in {LANGUAGE}.

    Schema:
    {
      "topics": ["short topic, one line"],
      "decisions": ["decision that was actually made"],
      "tasks": [{"task": "what has to be done", "owner": "name or null", "due": "date as stated or null"}],
      "open_questions": ["question that is still unanswered"]
    }

    Rules:
    - Start from the CURRENT STATE and change it only where the NEW UTTERANCES require it.
      The participants may have corrected the state by hand: keep their wording and their
      deletions unless the new utterances clearly contradict them.
    - Keep every existing item that is still valid; merge duplicates; keep items short.
    - Add a decision only if the participants clearly agreed. Add a task only if someone was
      asked or volunteered. Set owner and due only if they were stated, otherwise null.
    - Move a question out of open_questions once it was answered.
    - Never invent content that is not in the utterances. Speaker labels may be generic.
    - Utterances are raw speech recognition and may contain errors.
    """

    static func loadPrompt(from url: URL = AppPaths.customLiveMinutesPromptFile) -> String {
        if let custom = try? String(contentsOf: url, encoding: .utf8),
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom
        }
        return defaultPrompt
    }

    static func systemPrompt(language: String, promptURL: URL = AppPaths.customLiveMinutesPromptFile) -> String {
        loadPrompt(from: promptURL).replacingOccurrences(of: "{LANGUAGE}", with: language)
    }

    /// `[HH:mm:ss] Speaker: text` per line, oldest first.
    static func render(_ utterance: LiveMinutesUtterance, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return "[\(formatter.string(from: utterance.timestamp))] \(utterance.speaker): \(utterance.text)"
    }

    /// The user message: the state to start from and the new utterances.
    /// `omitted` counts older pending utterances that did not fit the budget.
    static func userMessage(state: LiveMinutesSummary, utterances: [LiveMinutesUtterance], omitted: Int) -> String {
        var parts = ["CURRENT STATE (may include manual corrections, keep them):", state.promptJSON, "", "NEW UTTERANCES:"]
        if omitted > 0 {
            parts.append("[\(omitted) earlier utterances were left out to keep this request small]")
        }
        parts.append(contentsOf: utterances.map { render($0) })
        return parts.joined(separator: "\n")
    }
}

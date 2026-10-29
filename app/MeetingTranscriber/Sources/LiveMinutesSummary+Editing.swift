import Foundation

/// The four editable parts of the summary, in display order.
enum LiveMinutesSection: String, CaseIterable, Identifiable {
    case topics
    case decisions
    case tasks
    case openQuestions

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .topics: "Topics"
        case .decisions: "Decisions"
        case .tasks: "Tasks"
        case .openQuestions: "Open questions"
        }
    }
}

/// Text form of the summary for in-window editing: one item per line, and
/// tasks as `Task | Owner | Due` with owner and due optional.
///
/// Parsing is forgiving and lossless for what was typed: bullets
/// (`-`, `*`, `•`) and blank lines are dropped, nothing else is rewritten.
/// Sanitizing (de-duplication, caps) is left to the engine, so the editor text
/// itself is never reshaped under the cursor.
extension LiveMinutesSummary {
    func editorText(for section: LiveMinutesSection) -> String {
        switch section {
        case .topics: topics.joined(separator: "\n")
        case .decisions: decisions.joined(separator: "\n")
        case .tasks: tasks.map(\.editorLine).joined(separator: "\n")
        case .openQuestions: openQuestions.joined(separator: "\n")
        }
    }

    /// This summary with one section replaced by what the user typed.
    func replacing(_ section: LiveMinutesSection, withEditorText text: String) -> LiveMinutesSummary {
        var copy = self
        switch section {
        case .topics: copy.topics = Self.items(in: text)
        case .decisions: copy.decisions = Self.items(in: text)
        case .tasks: copy.tasks = Self.items(in: text).compactMap(ActionItem.init(editorLine:))
        case .openQuestions: copy.openQuestions = Self.items(in: text)
        }
        return copy
    }

    static func items(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            for bullet in ["- ", "* ", "\u{2022} "] where line.hasPrefix(bullet) {
                line = String(line.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            return line.isEmpty ? nil : line
        }
    }
}

extension LiveMinutesSummary.ActionItem {
    /// `Task`, `Task | Owner`, `Task | Owner | Due` or `Task |  | Due`.
    var editorLine: String {
        guard owner != nil || due != nil else { return task }
        var parts = [task, owner ?? ""]
        if let due { parts.append(due) }
        return parts.joined(separator: " | ")
    }

    /// Inverse of `editorLine`; nil when the task text is empty.
    init?(editorLine: String) {
        let parts = editorLine
            .split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let task = parts.first, !task.isEmpty else { return nil }
        let owner = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        let due = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        self.init(task: task, owner: owner, due: due)
    }
}

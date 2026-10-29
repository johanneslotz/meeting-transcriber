import Foundation

/// One utterance handed to the live minutes engine: a finalized live caption
/// with the speaker label resolved at commit time and the wall-clock time it
/// was finalized. Value type, so it crosses from the main actor into the
/// engine actor without sharing state.
struct LiveMinutesUtterance: Hashable, Identifiable {
    let id: UUID
    let speaker: String
    let text: String
    let timestamp: Date

    init(id: UUID = UUID(), speaker: String, text: String, timestamp: Date) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
    }
}

/// The structured running state the engine keeps and the LLM replaces on each
/// update: topics, decisions, tasks and open questions.
///
/// The JSON shape is the contract with `LiveMinutesPrompt.defaultPrompt`. The
/// decoder is tolerant about absent keys (a model may omit an empty section)
/// but not about structure: a payload that is not an object, or that carries
/// none of the four sections, is a parse failure, so a chatty non-answer can
/// never blank the state.
struct LiveMinutesSummary: Codable, Equatable {
    struct ActionItem: Codable, Equatable {
        var task: String
        var owner: String?
        var due: String?
    }

    var topics: [String]
    var decisions: [String]
    var tasks: [ActionItem]
    var openQuestions: [String]

    static let empty = Self(topics: [], decisions: [], tasks: [], openQuestions: [])

    enum CodingKeys: String, CodingKey {
        case topics
        case decisions
        case tasks
        case openQuestions = "open_questions"
    }

    init(topics: [String], decisions: [String], tasks: [ActionItem], openQuestions: [String]) {
        self.topics = topics
        self.decisions = decisions
        self.tasks = tasks
        self.openQuestions = openQuestions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let topics = try container.decodeIfPresent([String].self, forKey: .topics)
        let decisions = try container.decodeIfPresent([String].self, forKey: .decisions)
        let tasks = try container.decodeIfPresent([ActionItem].self, forKey: .tasks)
        let questions = try container.decodeIfPresent([String].self, forKey: .openQuestions)
        guard topics != nil || decisions != nil || tasks != nil || questions != nil else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "none of the four summary sections is present",
            ))
        }
        self.init(
            topics: topics ?? [],
            decisions: decisions ?? [],
            tasks: tasks ?? [],
            openQuestions: questions ?? [],
        )
    }

    var isEmpty: Bool {
        topics.isEmpty && decisions.isEmpty && tasks.isEmpty && openQuestions.isEmpty
    }

    // MARK: - Parsing

    enum ParseError: Error, Equatable {
        case noJSONObject
        case invalidStructure
    }

    /// Parse an LLM reply into a summary. Accepts a bare JSON object or one
    /// wrapped in a code fence or a sentence of prose, by taking the outermost
    /// `{ ... }`. The result is sanitized with `limits`.
    static func parse(_ reply: String, limits: Limits = .init()) throws -> Self {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else {
            throw ParseError.noJSONObject
        }
        let data = Data(reply[start ... end].utf8)
        do {
            return try JSONDecoder().decode(Self.self, from: data).sanitized(limits: limits)
        } catch {
            throw ParseError.invalidStructure
        }
    }

    // MARK: - Bounds

    /// Caps that keep the state, and with it every request, bounded. A model
    /// that keeps appending would otherwise grow the prompt without limit.
    struct Limits: Equatable {
        var maxItemsPerSection = 40
        var maxItemLength = 280
    }

    /// Trim, drop empties, de-duplicate case-insensitively, cut over-long items
    /// and keep the newest `maxItemsPerSection` entries of each section.
    func sanitized(limits: Limits = .init()) -> Self {
        func clean(_ items: [String]) -> [String] {
            var seen = Set<String>()
            let kept = items.compactMap { raw -> String? in
                let trimmed = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limits.maxItemLength))
                guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
                return trimmed
            }
            return Array(kept.suffix(limits.maxItemsPerSection))
        }
        func field(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(limits.maxItemLength))
        }
        var seenTasks = Set<String>()
        let cleanTasks = tasks.compactMap { item -> ActionItem? in
            guard let text = clean([item.task]).first,
                  seenTasks.insert(text.lowercased()).inserted else { return nil }
            return ActionItem(task: text, owner: field(item.owner), due: field(item.due))
        }
        return Self(
            topics: clean(topics),
            decisions: clean(decisions),
            tasks: Array(cleanTasks.suffix(limits.maxItemsPerSection)),
            openQuestions: clean(openQuestions),
        )
    }

    // MARK: - Serialization

    /// Compact, key-sorted JSON for the prompt (stable bytes for a given state).
    var promptJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// Markdown rendering of the draft, for copy and save. Headings are fixed
    /// English like the rest of the UI; the items keep the protocol language.
    func markdown(title: String = "Live Minutes (automatic draft)") -> String {
        var lines = ["# \(title)", ""]
        func section(_ heading: String, _ items: [String]) {
            lines.append("## \(heading)")
            lines.append(contentsOf: items.isEmpty ? ["- (none)"] : items.map { "- \($0)" })
            lines.append("")
        }
        section("Topics", topics)
        section("Decisions", decisions)
        section("Tasks", tasks.map(\.displayLine))
        section("Open questions", openQuestions)
        return lines.joined(separator: "\n")
    }
}

extension LiveMinutesSummary.ActionItem {
    /// `Task (Owner, due Date)` with the parenthesis only for what was stated.
    var displayLine: String {
        var details: [String] = []
        if let owner { details.append(owner) }
        if let due { details.append("due \(due)") }
        return details.isEmpty ? task : "\(task) (\(details.joined(separator: ", ")))"
    }
}

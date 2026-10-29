import Foundation
@testable import MeetingTranscriber

enum LiveMinutesTestData {
    static func json(
        topics: [String] = [],
        decisions: [String] = [],
        tasks: [(task: String, owner: String?, due: String?)] = [],
        questions: [String] = [],
    ) -> String {
        func array(_ items: [String]) -> String {
            "[" + items.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        }
        let taskItems = tasks.map { item -> String in
            let owner = item.owner.map { "\"\($0)\"" } ?? "null"
            let due = item.due.map { "\"\($0)\"" } ?? "null"
            return "{\"task\":\"\(item.task)\",\"owner\":\(owner),\"due\":\(due)}"
        }
        return "{\"topics\":\(array(topics)),\"decisions\":\(array(decisions)),"
            + "\"tasks\":[\(taskItems.joined(separator: ","))],\"open_questions\":\(array(questions))}"
    }

    static func utterance(_ text: String, speaker: String = "Me", at seconds: TimeInterval = 0) -> LiveMinutesUtterance {
        LiveMinutesUtterance(
            speaker: speaker,
            text: text,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
        )
    }
}

@testable import MeetingTranscriber
import XCTest

final class LiveMinutesSummaryTests: XCTestCase {
    func testParsesBareJSON() throws {
        let reply = LiveMinutesTestData.json(
            topics: ["Budget"],
            decisions: ["Ship in May"],
            tasks: [(task: "Draft plan", owner: "Anna", due: "Friday")],
            questions: ["Who pays?"],
        )
        let summary = try LiveMinutesSummary.parse(reply)
        XCTAssertEqual(summary.topics, ["Budget"])
        XCTAssertEqual(summary.decisions, ["Ship in May"])
        XCTAssertEqual(summary.tasks, [.init(task: "Draft plan", owner: "Anna", due: "Friday")])
        XCTAssertEqual(summary.openQuestions, ["Who pays?"])
    }

    func testParsesJSONInsideCodeFenceAndProse() throws {
        let reply = "Here you go:\n```json\n" + LiveMinutesTestData.json(topics: ["A"]) + "\n```\nDone."
        XCTAssertEqual(try LiveMinutesSummary.parse(reply).topics, ["A"])
    }

    func testMissingSectionsDecodeAsEmpty() throws {
        let summary = try LiveMinutesSummary.parse(#"{"topics":["Only topics"]}"#)
        XCTAssertEqual(summary.topics, ["Only topics"])
        XCTAssertTrue(summary.decisions.isEmpty)
        XCTAssertTrue(summary.tasks.isEmpty)
        XCTAssertTrue(summary.openQuestions.isEmpty)
    }

    func testRejectsReplyWithoutJSONObject() {
        XCTAssertThrowsError(try LiveMinutesSummary.parse("I could not do that.")) {
            XCTAssertEqual($0 as? LiveMinutesSummary.ParseError, .noJSONObject)
        }
    }

    func testRejectsObjectWithNoneOfTheSections() {
        XCTAssertThrowsError(try LiveMinutesSummary.parse(#"{"answer":"done"}"#)) {
            XCTAssertEqual($0 as? LiveMinutesSummary.ParseError, .invalidStructure)
        }
    }

    func testRejectsWrongTypes() {
        XCTAssertThrowsError(try LiveMinutesSummary.parse(#"{"topics":"not a list"}"#)) {
            XCTAssertEqual($0 as? LiveMinutesSummary.ParseError, .invalidStructure)
        }
    }

    func testSanitizeTrimsDedupesAndDropsEmpties() {
        let raw = LiveMinutesSummary(
            topics: ["  Budget ", "budget", "", "Hiring"],
            decisions: [],
            tasks: [.init(task: " Send notes ", owner: " ", due: nil), .init(task: "send notes", owner: "Bo", due: nil)],
            openQuestions: [],
        )
        let clean = raw.sanitized()
        XCTAssertEqual(clean.topics, ["Budget", "Hiring"])
        XCTAssertEqual(clean.tasks, [.init(task: "Send notes", owner: nil, due: nil)])
    }

    func testSanitizeCapsLengthAndKeepsNewestItems() {
        let limits = LiveMinutesSummary.Limits(maxItemsPerSection: 2, maxItemLength: 5)
        let clean = LiveMinutesSummary(
            topics: ["one", "two", "three-long-text"], decisions: [], tasks: [], openQuestions: [],
        ).sanitized(limits: limits)
        XCTAssertEqual(clean.topics, ["two", "three"])
    }

    func testDisplayLineShowsOnlyStatedDetails() {
        XCTAssertEqual(LiveMinutesSummary.ActionItem(task: "Ship", owner: nil, due: nil).displayLine, "Ship")
        XCTAssertEqual(LiveMinutesSummary.ActionItem(task: "Ship", owner: "Anna", due: nil).displayLine, "Ship (Anna)")
        XCTAssertEqual(
            LiveMinutesSummary.ActionItem(task: "Ship", owner: "Anna", due: "Mon").displayLine,
            "Ship (Anna, due Mon)",
        )
    }

    func testPromptJSONRoundTripsAndIsStable() throws {
        let summary = LiveMinutesSummary(
            topics: ["B", "A"], decisions: ["D"], tasks: [.init(task: "T", owner: "O", due: nil)], openQuestions: ["Q"],
        )
        XCTAssertEqual(summary.promptJSON, summary.promptJSON)
        XCTAssertEqual(try LiveMinutesSummary.parse(summary.promptJSON), summary)
    }

    func testMarkdownListsEverySectionAndMarksEmptyOnes() {
        let markdown = LiveMinutesSummary(topics: ["A"], decisions: [], tasks: [], openQuestions: []).markdown()
        XCTAssertTrue(markdown.contains("## Topics\n- A"))
        XCTAssertTrue(markdown.contains("## Decisions\n- (none)"))
        XCTAssertTrue(markdown.contains("## Tasks"))
        XCTAssertTrue(markdown.contains("## Open questions"))
    }

    func testPromptSubstitutesLanguageAndPrefersCustomFile() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-\(UUID().uuidString).md")
        XCTAssertTrue(LiveMinutesPrompt.systemPrompt(language: "German", promptURL: missing).contains("in German"))

        let custom = FileManager.default.temporaryDirectory.appendingPathComponent("lm-\(UUID().uuidString).md")
        addTeardownBlock { try? FileManager.default.removeItem(at: custom) }
        try "Custom prompt in {LANGUAGE}".write(to: custom, atomically: true, encoding: .utf8)
        XCTAssertEqual(LiveMinutesPrompt.systemPrompt(language: "French", promptURL: custom), "Custom prompt in French")
    }

    func testEmptyCustomPromptFallsBackToDefault() throws {
        let custom = FileManager.default.temporaryDirectory.appendingPathComponent("lm-\(UUID().uuidString).md")
        addTeardownBlock { try? FileManager.default.removeItem(at: custom) }
        try "  \n".write(to: custom, atomically: true, encoding: .utf8)
        XCTAssertEqual(LiveMinutesPrompt.loadPrompt(from: custom), LiveMinutesPrompt.defaultPrompt)
    }
}

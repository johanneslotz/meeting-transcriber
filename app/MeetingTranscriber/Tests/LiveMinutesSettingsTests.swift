import AppKit
@testable import MeetingTranscriber
import XCTest

final class LiveMinutesSettingsTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let name = "live-minutes-settings-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    func testDefaults() throws {
        let settings = try AppSettings(defaults: makeDefaults())
        XCTAssertFalse(settings.liveMinutesEnabled, "off: it sends meeting text to an LLM")
        XCTAssertTrue(settings.liveMinutesAutoOpen)
        XCTAssertEqual(settings.liveMinutesIntervalSeconds, 90)
        XCTAssertFalse(settings.liveMinutesVisibleInScreenSharing, "hidden from screen sharing by default")
        XCTAssertEqual(settings.liveMinutesEndpoint, "")
        XCTAssertEqual(settings.liveMinutesModel, "")
    }

    func testEveryChoicePersistsAcrossInstances() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.liveMinutesEnabled = true
        settings.liveMinutesAutoOpen = false
        settings.liveMinutesIntervalSeconds = 120
        settings.liveMinutesVisibleInScreenSharing = true
        settings.liveMinutesEndpoint = "http://localhost:1234/v1"
        settings.liveMinutesModel = "small-model"

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertTrue(reloaded.liveMinutesEnabled)
        XCTAssertFalse(reloaded.liveMinutesAutoOpen)
        XCTAssertEqual(reloaded.liveMinutesIntervalSeconds, 120)
        XCTAssertTrue(reloaded.liveMinutesVisibleInScreenSharing)
        XCTAssertEqual(reloaded.liveMinutesEndpoint, "http://localhost:1234/v1")
        XCTAssertEqual(reloaded.liveMinutesModel, "small-model")
    }

    func testIntervalIsClampedToThirtyToThreeHundredSecondsOnWriteAndRead() throws {
        let defaults = try makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.liveMinutesIntervalSeconds = 5
        XCTAssertEqual(settings.liveMinutesIntervalSeconds, 30)
        settings.liveMinutesIntervalSeconds = 9999
        XCTAssertEqual(settings.liveMinutesIntervalSeconds, 300)

        defaults.set(1.0, forKey: "liveMinutesIntervalSeconds")
        XCTAssertEqual(AppSettings(defaults: defaults).liveMinutesIntervalSeconds, 30)
    }

    // MARK: - Endpoint resolution

    func testEmptyFieldsFallBackToTheProtocolProviderSettings() throws {
        let settings = try AppSettings(defaults: makeDefaults())
        settings.openAIEndpoint = "http://localhost:11434/v1"
        settings.openAIModel = "llama3.1"
        XCTAssertEqual(settings.liveMinutesResolvedEndpoint, "http://localhost:11434/v1")
        XCTAssertEqual(settings.liveMinutesResolvedModel, "llama3.1")
        XCTAssertTrue(settings.liveMinutesUsesProtocolEndpoint)
    }

    func testOwnFieldsOverrideAndWhitespaceOnlyCountsAsEmpty() throws {
        let settings = try AppSettings(defaults: makeDefaults())
        settings.liveMinutesEndpoint = "http://127.0.0.1:8080/v1"
        settings.liveMinutesModel = "tiny"
        XCTAssertEqual(settings.liveMinutesResolvedEndpoint, "http://127.0.0.1:8080/v1")
        XCTAssertEqual(settings.liveMinutesResolvedModel, "tiny")
        XCTAssertFalse(settings.liveMinutesUsesProtocolEndpoint)

        settings.liveMinutesEndpoint = "   "
        XCTAssertEqual(settings.liveMinutesResolvedEndpoint, settings.openAIEndpoint)
    }

    func testProtocolAPIKeyIsNeverSentToADifferentEndpoint() throws {
        let account = "LiveMinutesSettingsTests-openAIAPIKey-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { KeychainHelper.delete(key: account) }
        let settings = try AppSettings(defaults: makeDefaults(), apiKeyAccount: account)
        settings.openAIAPIKey = "secret"
        XCTAssertEqual(settings.liveMinutesAPIKey, "secret")
        settings.liveMinutesEndpoint = "https://other.example.com/v1"
        XCTAssertNil(settings.liveMinutesAPIKey)
    }

    func testEndpointPolicyRecognisesThisMachineOnly() {
        for local in ["http://localhost:11434/v1", "http://127.0.0.1:1234/v1", "http://127.1.2.3/v1", "http://[::1]:8080/v1"] {
            XCTAssertTrue(LiveMinutesEndpointPolicy.isLocal(local), local)
        }
        for remote in [
            "https://api.openai.com/v1", "http://192.168.1.20:11434/v1", "http://mac-mini.local:1234/v1",
            "http://localhost.evil.example/v1", "http://127.0.0.1.evil.example/v1", "not a url", "",
        ] {
            XCTAssertFalse(LiveMinutesEndpointPolicy.isLocal(remote), remote)
        }
    }

    // MARK: - Gate

    func testGateRunsOnlyWhenEnabledWithCaptionsWhileRecording() {
        XCTAssertTrue(LiveMinutesGate.isActive(minutesEnabled: true, captionsAvailable: true, isRecording: true))
        XCTAssertFalse(LiveMinutesGate.isActive(minutesEnabled: false, captionsAvailable: true, isRecording: true))
        XCTAssertFalse(LiveMinutesGate.isActive(minutesEnabled: true, captionsAvailable: false, isRecording: true))
        XCTAssertFalse(LiveMinutesGate.isActive(minutesEnabled: true, captionsAvailable: true, isRecording: false))
    }

    func testAutoOpenNeedsBothActiveAndTheSetting() {
        XCTAssertTrue(LiveMinutesGate.shouldAutoOpen(active: true, autoOpen: true))
        XCTAssertFalse(LiveMinutesGate.shouldAutoOpen(active: true, autoOpen: false))
        XCTAssertFalse(LiveMinutesGate.shouldAutoOpen(active: false, autoOpen: true))
    }

    func testSharingTypeMapsTheSetting() {
        XCTAssertEqual(LiveMinutesGate.sharingType(visibleInScreenSharing: false), .none)
        XCTAssertEqual(LiveMinutesGate.sharingType(visibleInScreenSharing: true), .readOnly)
    }
}

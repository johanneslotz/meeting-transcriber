@testable import MeetingTranscriber
import ViewInspector
import XCTest

/// Wiring of the settings section: one test per control, as the GUI testing
/// rules ask, plus the two conditional pieces (disabled state, remote warning).
@MainActor
final class LiveMinutesSettingsSectionTests: XCTestCase {
    private func makeSettings() throws -> AppSettings {
        let name = "live-minutes-section-\(getpid())-\(UUID().uuidString)"
        addTeardownBlock { DefaultsSuite.remove(name) }
        return try AppSettings(defaults: XCTUnwrap(UserDefaults(suiteName: name)))
    }

    func testEnabledToggleWritesBack() throws {
        let settings = try makeSettings()
        let view = LiveMinutesSettingsSection(settings: settings)
        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.liveMinutesEnabledToggle)
            .find(ViewType.Toggle.self)
            .tap()
        XCTAssertTrue(settings.liveMinutesEnabled)
    }

    func testSharingToggleWritesBack() throws {
        let settings = try makeSettings()
        settings.liveMinutesEnabled = true
        let view = LiveMinutesSettingsSection(settings: settings)
        try view.inspect()
            .find(viewWithAccessibilityIdentifier: A11yID.liveMinutesSharingToggle)
            .find(ViewType.Toggle.self)
            .tap()
        XCTAssertTrue(settings.liveMinutesVisibleInScreenSharing)
    }

    func testDependentControlsAreDisabledWhileTheFeatureIsOff() throws {
        let settings = try makeSettings()
        let view = LiveMinutesSettingsSection(settings: settings)
        for id in [A11yID.liveMinutesAutoOpenToggle, A11yID.liveMinutesIntervalStepper, A11yID.liveMinutesSharingToggle] {
            let control = try view.inspect().find(viewWithAccessibilityIdentifier: id)
            XCTAssertTrue(control.isDisabled(), id)
        }
    }

    func testRemoteWarningAppearsOnlyForANonLocalEndpoint() throws {
        let settings = try makeSettings()
        settings.liveMinutesEnabled = true
        settings.liveMinutesEndpoint = "http://localhost:11434/v1"
        XCTAssertThrowsError(
            try LiveMinutesSettingsSection(settings: settings).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.liveMinutesRemoteWarning),
            "a local endpoint shows no warning",
        )

        settings.liveMinutesEndpoint = "https://api.example.com/v1"
        XCTAssertNoThrow(
            try LiveMinutesSettingsSection(settings: settings).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.liveMinutesRemoteWarning),
        )
    }

    func testNoWarningWhileTheFeatureIsOff() throws {
        let settings = try makeSettings()
        settings.liveMinutesEndpoint = "https://api.example.com/v1"
        XCTAssertThrowsError(
            try LiveMinutesSettingsSection(settings: settings).inspect()
                .find(viewWithAccessibilityIdentifier: A11yID.liveMinutesRemoteWarning),
        )
    }
}

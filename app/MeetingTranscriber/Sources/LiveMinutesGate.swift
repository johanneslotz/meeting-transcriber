import AppKit

/// Pure decisions for Live Minutes, shared by the coordinator and the app
/// scene so both agree, and unit-testable without a window.
enum LiveMinutesGate {
    /// Live Minutes runs while recording, when the user enabled it and live
    /// captions are available as its source (`LiveCaptionsGate.captionsAvailable`).
    static func isActive(minutesEnabled: Bool, captionsAvailable: Bool, isRecording: Bool) -> Bool {
        minutesEnabled && captionsAvailable && isRecording
    }

    /// Whether the window opens by itself when a recording starts.
    static func shouldAutoOpen(active: Bool, autoOpen: Bool) -> Bool {
        active && autoOpen
    }

    /// `.none` keeps the window out of screen shares and captures; `.readOnly`
    /// lets participants see it. The default setting maps to `.none`.
    static func sharingType(visibleInScreenSharing: Bool) -> NSWindow.SharingType {
        visibleInScreenSharing ? .readOnly : .none
    }
}

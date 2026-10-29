import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A regular, resizable window that hosts `LiveMinutesView`.
///
/// Separate from the click-through caption bar: this one is meant to be read
/// and moved, so it is an ordinary titled `NSWindow`. Its `sharingType` decides
/// whether screen shares and captures can see it: `.none` by default, set from
/// `AppSettings.liveMinutesVisibleInScreenSharing`, and re-applied live when
/// the setting changes.
///
/// The window is created on first `show()` and kept; closing it only hides it,
/// so the content (which lives in `LiveMinutesState`) is there when it is
/// reopened. Nothing is written to disk unless the user chooses a destination
/// in the save panel.
@MainActor
final class LiveMinutesWindowController {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("live-minutes")

    private(set) var window: NSWindow?
    private let state: LiveMinutesState
    private var sharingType: NSWindow.SharingType

    init(state: LiveMinutesState, sharingType: NSWindow.SharingType = .none) {
        self.state = state
        self.sharingType = sharingType
    }

    var isVisible: Bool {
        window?.isVisible == true
    }

    /// Show the window. `activating: false` (auto-open at recording start)
    /// puts it on screen without taking focus from the meeting app.
    func show(activating: Bool) {
        let window = ensureWindow()
        if activating {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
    }

    func hide() {
        window?.orderOut(nil)
    }

    /// Change what screen sharing can see, effective immediately.
    func apply(sharingType: NSWindow.SharingType) {
        self.sharingType = sharingType
        window?.sharingType = sharingType
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let view = LiveMinutesView(
            state: state,
            onCopyDraft: { [weak self] in self?.copyDraft() },
            onSaveDraft: { [weak self] in self?.saveDraft() },
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
        )
        window.title = "Live Minutes"
        window.titlebarAppearsTransparent = true
        window.identifier = Self.windowIdentifier
        window.isReleasedWhenClosed = false
        window.sharingType = sharingType
        window.contentView = NSHostingView(rootView: view)
        window.center()
        self.window = window
        return window
    }

    // MARK: - Draft export

    private func copyDraft() {
        guard let markdown = state.draftMarkdown else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    private func saveDraft() {
        guard let markdown = state.draftMarkdown, let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "live_minutes_draft_\(Self.stamp()).md"
        if let markdownType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdownType]
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(markdown.utf8).write(to: url, options: .atomic)
            } catch {
                NSSound.beep()
            }
        }
    }

    private static func stamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter.string(from: date)
    }
}

import SwiftUI

/// Settings → Transcribe → Live Minutes. A form `Section`, hosted by
/// `TranscriptionSettingsView` below the live transcription section it depends on.
struct LiveMinutesSettingsSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section("Live Minutes (PoC)") {
            enabledToggle
            autoOpenToggle
            intervalStepper
            sharingToggle
            endpointFields
            remoteEndpointWarning
            LiveMinutesPromptControls()
                .disabled(!settings.liveMinutesEnabled)
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier(A11yID.liveMinutesSection)
        .recordOnlyDisabled(settings.recordOnly)
    }

    private var enabledToggle: some View {
        Toggle("Show live minutes during recording", isOn: $settings.liveMinutesEnabled)
            .accessibilityIdentifier(A11yID.liveMinutesEnabledToggle)
    }

    private var autoOpenToggle: some View {
        Toggle("Open window when a recording starts", isOn: $settings.liveMinutesAutoOpen)
            .disabled(!settings.liveMinutesEnabled)
            .accessibilityIdentifier(A11yID.liveMinutesAutoOpenToggle)
    }

    private var intervalStepper: some View {
        Stepper(
            "Update every \(Int(settings.liveMinutesIntervalSeconds)) s",
            value: $settings.liveMinutesIntervalSeconds,
            in: 30 ... 300,
            step: 10,
        )
        .disabled(!settings.liveMinutesEnabled)
        .accessibilityIdentifier(A11yID.liveMinutesIntervalStepper)
    }

    private var sharingToggle: some View {
        Toggle("Visible in screen sharing", isOn: $settings.liveMinutesVisibleInScreenSharing)
            .disabled(!settings.liveMinutesEnabled)
            .accessibilityIdentifier(A11yID.liveMinutesSharingToggle)
    }

    private var endpointFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Endpoint", text: $settings.liveMinutesEndpoint, prompt: Text(settings.openAIEndpoint))
                .accessibilityIdentifier(A11yID.liveMinutesEndpointField)
            TextField("Model", text: $settings.liveMinutesModel, prompt: Text(settings.openAIModel))
                .accessibilityIdentifier(A11yID.liveMinutesModelField)
        }
        .textFieldStyle(.roundedBorder)
        .disabled(!settings.liveMinutesEnabled)
    }

    @ViewBuilder private var remoteEndpointWarning: some View {
        if settings.liveMinutesEnabled, !settings.liveMinutesEndpointIsLocal {
            Label(
                "This endpoint is not on this Mac. Meeting text is sent to it while the meeting is running.",
                systemImage: "exclamationmark.triangle.fill",
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(A11yID.liveMinutesRemoteWarning)
        }
    }

    private var footnote: String {
        "Needs live transcription above. A rolling summary of topics, decisions, tasks and open questions "
            + "is drafted from the live captions. Empty endpoint and model fields use the protocol provider's "
            + "OpenAI-compatible settings. The window and summary stay in memory only. The window is hidden "
            + "from screen sharing unless you allow it."
    }
}

/// Edit / import / reset of `live_minutes_prompt.md`, the same controls the
/// protocol prompt has in Settings → Output. A non-empty file replaces the
/// built-in prompt; deleting it restores the default.
private struct LiveMinutesPromptControls: View {
    @State private var hasCustomPrompt = false
    @State private var showResetConfirmation = false

    private var url: URL {
        AppPaths.customLiveMinutesPromptFile
    }

    var body: some View {
        HStack {
            Button("Edit Prompt") {
                openCustomPrompt()
                refresh()
            }
            .accessibilityIdentifier(A11yID.liveMinutesPromptEditButton)

            Button("Import Prompt") {
                importCustomPrompt()
                refresh()
            }
            .accessibilityIdentifier(A11yID.liveMinutesPromptImportButton)

            Button("Reset to Default") {
                showResetConfirmation = true
            }
            .disabled(!hasCustomPrompt)
            .accessibilityIdentifier(A11yID.liveMinutesPromptResetButton)
            .confirmationDialog(
                "Reset the live minutes prompt to the built-in default?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible,
            ) {
                Button("Reset", role: .destructive) {
                    try? FileManager.default.removeItem(at: url)
                    refresh()
                }
            }

            Spacer()

            if hasCustomPrompt {
                Label("Custom prompt active", systemImage: "doc.text.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
            } else {
                Label("Using default prompt", systemImage: "doc.text")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        hasCustomPrompt = FileManager.default.fileExists(atPath: url.path)
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
    }

    /// Seeds the file with the built-in prompt on first use, so the user edits
    /// the real text instead of starting from an empty page.
    private func openCustomPrompt() {
        if !FileManager.default.fileExists(atPath: url.path) {
            ensureDirectory()
            try? LiveMinutesPrompt.defaultPrompt.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }

    private func importCustomPrompt() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .init(filenameExtension: "md")].compactMap(\.self)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a prompt file to import"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        ensureDirectory()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: source)
        } else {
            try? FileManager.default.copyItem(at: source, to: url)
        }
    }
}

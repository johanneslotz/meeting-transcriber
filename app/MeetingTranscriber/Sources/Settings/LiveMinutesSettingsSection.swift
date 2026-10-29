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

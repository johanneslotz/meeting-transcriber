import SwiftUI

/// Content of the Live Minutes window: the live transcript (can be hidden) and
/// the rolling summary, labelled as an automatic draft.
///
/// The summary reads like a document page (white sheet, centred column,
/// headings, no boxes around the editors) and the transcript sits beside it as
/// quiet secondary text, so the page is what the eye lands on.
///
/// Split into small named properties so no single `body` approaches the
/// 300 ms type-check budget.
struct LiveMinutesView: View {
    @Bindable var state: LiveMinutesState
    /// Save/copy actions are injected: the view holds no AppKit panel code, and
    /// nothing is written unless the user picks a destination.
    var onCopyDraft: () -> Void = {}
    var onSaveDraft: () -> Void = {}

    private static let pageWidth: CGFloat = 680

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                if state.transcriptVisible {
                    transcriptPane
                        .frame(minWidth: 220, idealWidth: 300)
                }
                summaryPane
                    .frame(minWidth: 320, idealWidth: 460)
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $state.transcriptVisible) {
                Label("Transcript", systemImage: "sidebar.left")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Show or hide the live transcript")
            .accessibilityIdentifier(A11yID.liveMinutesTranscriptToggle)
            Spacer()
            statusLabel
            updateButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var updateButton: some View {
        Button {
            state.requestUpdate()
        } label: {
            Label("Update", systemImage: "arrow.clockwise")
        }
        .controlSize(.small)
        .disabled(!state.canRequestUpdate)
        .help("Update the minutes now with everything said since the last update")
        .accessibilityIdentifier(A11yID.liveMinutesUpdateButton)
    }

    private var statusLabel: some View {
        HStack(spacing: 6) {
            if state.isUpdating {
                ProgressView().controlSize(.small)
                Text("Updating")
                    .accessibilityIdentifier(A11yID.liveMinutesUpdatingIndicator)
            }
            Text(lastUpdatedLabel)
                .accessibilityIdentifier(A11yID.liveMinutesLastUpdated)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var lastUpdatedLabel: String {
        guard let text = state.lastUpdatedText() else { return "No summary yet" }
        return "Last updated \(text)"
    }

    // MARK: - Transcript

    private var transcriptPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(state.utterances) { utterance in
                        transcriptRow(utterance).id(utterance.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: state.utterances.last?.id) { _, last in
                guard let last else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier(A11yID.liveMinutesTranscript)
    }

    private func transcriptRow(_ utterance: LiveMinutesUtterance) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(utterance.speaker)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(utterance.text)
                .font(.callout)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Summary

    private var summaryPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                documentTitle
                ForEach(LiveMinutesSection.allCases) { section in
                    sectionEditor(section)
                }
                if state.lastUpdateFailed { failureNote }
                if state.phase == .ended { draftActions }
                editHint
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: Self.pageWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier(A11yID.liveMinutesSummary)
    }

    private var documentTitle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Meeting minutes")
                .font(.system(size: 28, weight: .bold))
            draftBanner
        }
    }

    private var draftBanner: some View {
        Label(
            state.phase == .ended ? "Final automatic draft, not a protocol" : "Automatic draft, may contain errors",
            systemImage: "sparkles",
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .accessibilityIdentifier(A11yID.liveMinutesDraftBanner)
    }

    private var editHint: some View {
        Text(
            "You can edit the draft. Your changes are kept and sent with the next update. "
                + "One item per line; tasks as: Task | Owner | Due.",
        )
        .font(.caption)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(A11yID.liveMinutesEditHint)
    }

    private func sectionEditor(_ section: LiveMinutesSection) -> some View {
        let text = Binding(
            get: { state.text(for: section) },
            set: { state.setText($0, for: section) },
        )
        return VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
                .font(.system(size: 18, weight: .semibold))
            growingEditor(text: text)
                .accessibilityIdentifier(A11yID.liveMinutesEditor(section))
        }
    }

    /// A borderless editor that grows with its content, so the page scrolls as
    /// one document instead of each section scrolling inside its own box. The
    /// invisible `Text` measures the content; `TextEditor` has no intrinsic height.
    private func growingEditor(text: Binding<String>) -> some View {
        Text(text.wrappedValue + "\n")
            .font(.body)
            .lineSpacing(3)
            .opacity(0)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .overlay {
                TextEditor(text: text)
                    .font(.body)
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
            }
    }

    private var failureNote: some View {
        Label("The last update failed. Showing the previous summary.", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .accessibilityIdentifier(A11yID.liveMinutesFailureNote)
    }

    private var draftActions: some View {
        HStack {
            Button("Copy draft", action: onCopyDraft)
                .accessibilityIdentifier(A11yID.liveMinutesCopyDraft)
            Button("Save draft\u{2026}", action: onSaveDraft)
                .accessibilityIdentifier(A11yID.liveMinutesSaveDraft)
        }
        .disabled(!state.hasSummary)
    }
}

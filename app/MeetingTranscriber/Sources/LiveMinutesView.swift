import SwiftUI

/// Content of the Live Minutes window: the live transcript (can be hidden) and
/// the rolling summary, labelled as an automatic draft.
///
/// Split into small named properties so no single `body` approaches the
/// 300 ms type-check budget.
struct LiveMinutesView: View {
    @Bindable var state: LiveMinutesState
    /// Save/copy actions are injected: the view holds no AppKit panel code, and
    /// nothing is written unless the user picks a destination.
    var onCopyDraft: () -> Void = {}
    var onSaveDraft: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                if state.transcriptVisible {
                    transcriptPane
                        .frame(minWidth: 220, idealWidth: 320)
                }
                summaryPane
                    .frame(minWidth: 260, idealWidth: 360)
            }
        }
        .frame(minWidth: 520, minHeight: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Toggle("Show transcript", isOn: $state.transcriptVisible)
                .toggleStyle(.switch)
                .accessibilityIdentifier(A11yID.liveMinutesTranscriptToggle)
            Spacer()
            statusLabel
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusLabel: some View {
        HStack(spacing: 6) {
            if state.isUpdating {
                ProgressView().controlSize(.small)
                Text("Updating")
                    .accessibilityIdentifier(A11yID.liveMinutesUpdatingIndicator)
            }
            Text(lastUpdatedLabel)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(A11yID.liveMinutesLastUpdated)
        }
        .font(.caption)
    }

    private var lastUpdatedLabel: String {
        guard let text = state.lastUpdatedText() else { return "No summary yet" }
        return "Last updated \(text)"
    }

    // MARK: - Transcript

    private var transcriptPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(state.utterances) { utterance in
                        transcriptRow(utterance).id(utterance.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: state.utterances.last?.id) { _, last in
                guard let last else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
        .accessibilityIdentifier(A11yID.liveMinutesTranscript)
    }

    private func transcriptRow(_ utterance: LiveMinutesUtterance) -> some View {
        (Text(utterance.speaker + ": ").fontWeight(.semibold) + Text(utterance.text))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Summary

    private var summaryPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                draftBanner
                sectionList("Topics", state.summary.topics)
                sectionList("Decisions", state.summary.decisions)
                sectionList("Tasks", state.summary.tasks.map(\.displayLine))
                sectionList("Open questions", state.summary.openQuestions)
                if state.lastUpdateFailed { failureNote }
                if state.phase == .ended { draftActions }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(A11yID.liveMinutesSummary)
    }

    private var draftBanner: some View {
        Label(
            state.phase == .ended ? "Final automatic draft, not a protocol" : "Automatic draft, may contain errors",
            systemImage: "sparkles",
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier(A11yID.liveMinutesDraftBanner)
    }

    private func sectionList(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if items.isEmpty {
                Text("None yet").foregroundStyle(.secondary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("\u{2022} " + item).textSelection(.enabled)
                }
            }
        }
    }

    private var failureNote: some View {
        Text("The last update failed. Showing the previous summary.")
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

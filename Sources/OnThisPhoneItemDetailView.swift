// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct OnThisPhoneItemDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(ObserverRegistration.self) private var observerRegistration
    @Environment(ObserverManager.self) private var observerManager

    let item: OnThisPhoneItem
    let onRequestDrop: @MainActor (OnThisPhoneItem) -> Void
    @State private var showingDropConfirm = false
    @State private var showingJournal = false

    init(item: OnThisPhoneItem, onRequestDrop: @escaping @MainActor (OnThisPhoneItem) -> Void) {
        self.item = item
        self.onRequestDrop = onRequestDrop
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                self.stateChip
                self.previewBlock
                self.summaryCard
                self.failureBlock
                self.journalBlock
                self.detailsBlock
                self.actionsBlock
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(OnThisPhoneItemDetailPresentation.navigationTitle(for: self.item))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension OnThisPhoneItemDetailView {
    var stateChip: some View {
        HStack {
            Spacer(minLength: 0)
            SendStateChip(state: self.item.sendState)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    var previewBlock: some View {
        switch OnThisPhoneItemDetailPresentation.previewMode(
            sourceKind: self.item.sourceKind,
            contentType: self.item.contentType,
            hasLocalRaw: self.item.hasLocalRaw
        ) {
        case .audioPlayer:
            if let rawFileURL = self.item.rawFileURL {
                OnThisPhoneAudioPlayerView(
                    url: rawFileURL,
                    isObserverActive: self.isObserverActive,
                    gateHint: SourceVocabulary.audioPlaybackObserverActiveHint
                )
            }
        case .thumbnail:
            OnThisPhonePreview(item: self.item)
        case .none:
            if self.item.sourceKind == .audio, !self.item.hasLocalRaw {
                Text(SourceVocabulary.rawOriginalUnavailable)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var summaryCard: some View {
        let summary = OnThisPhoneItemDetailPresentation.summary(for: self.item, now: Date())
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(summary.big)
                    .font(.headline)
                if let badgeLabel = self.item.audioSourceBadgeLabel {
                    onThisPhoneAudioSourceBadge(badgeLabel)
                }
            }
            Text(summary.small)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    var failureBlock: some View {
        if let failure = OnThisPhoneItemDetailPresentation.failureLegibility(for: self.item, now: Date()) {
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let lastTried = failure.lastTried {
                    Text(lastTried)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    var journalBlock: some View {
        let conveyURL = ConveyURL.rootURL(activeLocalPort: self.observerRegistration.activeLocalPort)
        let availability = OnThisPhoneItemDetailPresentation.journalAvailability(
            sendState: self.item.sendState,
            hasConveyURL: conveyURL != nil,
            sourceKind: self.item.sourceKind
        )

        return SourceDetailBlock(title: SourceVocabulary.yourJournalSection) {
            VStack(alignment: .leading, spacing: 10) {
                Text(availability.hint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(SourceVocabulary.openJournalLink) {
                    self.showingJournal = true
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .disabled(!availability.enabled)
                .accessibilityLabel(SourceVocabulary.openJournalLink)
                .accessibilityHint("Opens your journal inside solstone.")
                .sheet(isPresented: self.$showingJournal) {
                    InAppJournalView()
                }
            }
        }
    }

    var detailsBlock: some View {
        let rows = OnThisPhoneItemDetailPresentation.detailRows(for: self.item)
        return SourceDetailBlock(title: SourceVocabulary.details) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    self.detailRow(row)
                }
            }
        }
    }

    @ViewBuilder
    func detailRow(_ row: OnThisPhoneDetailRow) -> some View {
        if self.item.audioSource == .watch,
           row.label == SourceVocabulary.onThisPhoneSourceLabel {
            NavigationLink {
                WatchSourceDetailView()
            } label: {
                LabeledContent(row.label, value: row.value)
            }
            .buttonStyle(.plain)
        } else {
            LabeledContent(row.label, value: row.value)
        }
    }

    var actionsBlock: some View {
        self.dropButton
    }

    var dropButton: some View {
        Button(SourceVocabulary.onThisPhoneDropFromPhone, role: .destructive) {
            self.showingDropConfirm = true
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
        .accessibilityHint("Removes this from this phone.")
        .accessibilityIdentifier("onThisPhone.drop.button")
        .confirmationDialog(
            SourceVocabulary.onThisPhoneDropConfirmTitle,
            isPresented: self.$showingDropConfirm,
            titleVisibility: .visible
        ) {
            Button(SourceVocabulary.drop, role: .destructive) {
                self.onRequestDrop(self.item)
                self.dismiss()
            }
            .accessibilityIdentifier("onThisPhone.drop.confirm")

            Button(SourceVocabulary.cancel, role: .cancel) {}
                .accessibilityIdentifier("onThisPhone.drop.cancel")
        } message: {
            Text(SourceVocabulary.onThisPhoneDropConfirmMessage(sendState: self.item.sendState))
        }
    }

    var isObserverActive: Bool {
        if case .active = self.observerManager.state {
            return true
        }
        return false
    }
}

@MainActor
func onThisPhoneAudioSourceBadge(_ label: String) -> some View {
    Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .accessibilityHidden(true)
}

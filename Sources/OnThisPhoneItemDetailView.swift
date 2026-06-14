// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct OnThisPhoneItemDetailView: View {
    @Environment(ImportQueue.self) private var importQueue
    @Environment(ObserverUploader.self) private var observerUploader
    @Environment(LocationUploader.self) private var locationUploader
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(ObserverRegistration.self) private var observerRegistration
    @Environment(ObserverManager.self) private var observerManager

    let item: OnThisPhoneItem
    let onLocalMutation: @MainActor () -> Void
    @State private var deleteReceipt: String?

    init(item: OnThisPhoneItem, onLocalMutation: @escaping @MainActor () -> Void = {}) {
        self.item = item
        self.onLocalMutation = onLocalMutation
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                self.stateChip
                self.previewBlock
                self.summaryCard
                self.locationHint
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
            Text(summary.big)
                .font(.headline)
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
    var locationHint: some View {
        if self.item.sourceKind == .location {
            Text(SourceVocabulary.onThisPhoneLocationC3Hint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var journalBlock: some View {
        let conveyURL = ConveyURL.dayURL(
            activeLocalPort: self.observerRegistration.activeLocalPort,
            day: self.item.day
        )
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

                Button(SourceVocabulary.openJournalInConvey) {
                    if let conveyURL {
                        self.openURL(conveyURL)
                    }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .disabled(!availability.enabled)
                .accessibilityLabel(SourceVocabulary.openJournalInConvey)
                .accessibilityHint("Opens your journal in the browser.")
            }
        }
    }

    var detailsBlock: some View {
        let rows = OnThisPhoneItemDetailPresentation.detailRows(for: self.item)
        return SourceDetailBlock(title: SourceVocabulary.details) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    LabeledContent(row.label, value: row.value)
                }
            }
        }
    }

    var actionsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                self.dropButton

                if self.item.sendState == .needsAttention, self.item.sourceKind == .share {
                    Button(SourceVocabulary.retry) {
                        self.retry()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .accessibilityHint("Tries sending this again.")
                }
            }

            self.deleteReceiptBlock
        }
    }

    var dropButton: some View {
        Button(SourceVocabulary.onThisPhoneDropFromPhone, role: .destructive) {
            self.drop()
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
        .accessibilityHint("Removes this from this phone.")
    }

    @ViewBuilder
    var deleteReceiptBlock: some View {
        if let deleteReceipt {
            Text(deleteReceipt)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
        }
    }

    var isObserverActive: Bool {
        if case .active = self.observerManager.state {
            return true
        }
        return false
    }

    func retry() {
        guard let itemID = UUID(uuidString: self.item.id) else { return }
        Task {
            try? await self.importQueue.requeueFailedItem(itemID: itemID)
            self.dismiss()
        }
    }

    func drop() {
        guard let parsedID = OnThisPhoneItemID(sourceKind: self.item.sourceKind, id: self.item.id) else { return }
        switch parsedID {
        case .share(let itemID):
            self.importQueue.dropItem(itemID: itemID)
        case .audio(let sessionID, let chunkID):
            self.observerUploader.dropItem(sessionID: sessionID, chunkID: chunkID)
        case .location(let fileID):
            self.locationUploader.dropItem(fileID: fileID)
        }
        self.deleteReceipt = SourceVocabulary.onThisPhoneDeleteReceipt
        self.onLocalMutation()
    }
}

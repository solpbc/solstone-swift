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
                SourceDetailBlock(title: SourceVocabulary.onThisPhoneSource) {
                    self.sourceBlock
                }

                SourceDetailBlock(title: SourceVocabulary.onThisPhonePlacement) {
                    self.placementBlock
                }

                SourceDetailBlock(title: SourceVocabulary.onThisPhone) {
                    self.rawBlock
                }

                SourceDetailBlock(title: SourceVocabulary.yourJournalSection) {
                    self.derivedBlock
                }

                if self.item.sendState == .needsAttention {
                    SourceDetailBlock(title: SourceVocabulary.needsAttention) {
                        self.failedActionsBlock
                    }
                } else if self.item.sendState == .savedOnThisPhone || self.item.sendState == .sending {
                    SourceDetailBlock(title: SourceVocabulary.drop) {
                        self.dropOnlyBlock
                    }
                }
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(self.item.filename ?? SourceVocabulary.onThisPhone)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension OnThisPhoneItemDetailView {
    var sourceBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SourceVocabulary.onThisPhoneSourceName(for: self.item.sourceKind))
                .font(.subheadline.weight(.semibold))
            switch self.item.sourceKind {
            case .audio, .location:
                Text(self.item.itemTime?.formatted() ?? SourceVocabulary.notProvided)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .share:
                Text(self.item.originApp ?? SourceVocabulary.originAppNotProvided)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var placementBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("day", value: self.item.day ?? SourceVocabulary.notProvided)
            LabeledContent("stream", value: self.item.stream ?? SourceVocabulary.notProvided)
            LabeledContent("segment", value: self.item.segment ?? SourceVocabulary.notProvided)
        }
    }

    var rawBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !self.item.hasLocalRaw {
                Text(SourceVocabulary.rawOriginalUnavailable)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            OnThisPhonePreview(item: self.item)

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(SourceVocabulary.filenameLabel, value: self.item.filename ?? SourceVocabulary.notProvided)
                LabeledContent("content type", value: self.item.contentType ?? SourceVocabulary.notProvided)
                LabeledContent("size", value: self.sizeText)
                if self.item.sourceKind == .share {
                    LabeledContent(SourceVocabulary.originAppLabel, value: self.item.originApp ?? SourceVocabulary.originAppNotProvided)
                }
                LabeledContent("basis", value: self.item.basis ?? SourceVocabulary.notProvided)
                LabeledContent("when", value: self.item.itemTime?.formatted() ?? SourceVocabulary.notProvided)
                LabeledContent("target journal", value: self.item.targetJournal ?? SourceVocabulary.notProvided)
                LabeledContent("stream", value: self.item.stream ?? SourceVocabulary.notProvided)
                LabeledContent("day", value: self.item.day ?? SourceVocabulary.notProvided)
                LabeledContent("segment", value: self.item.segment ?? SourceVocabulary.notProvided)
                LabeledContent(SourceVocabulary.sendStateLabel, value: self.item.sendState.label)
                if let deliveredAt = self.item.deliveredAt {
                    LabeledContent(SourceVocabulary.deliveredAtLabel, value: deliveredAt.formatted())
                }
            }
        }
    }

    @ViewBuilder
    var derivedBlock: some View {
        if self.item.sendState == .inYourJournal {
            // Opens the connected journal's convey day view in system Safari via the
            // openURL seam — never embedded. Relies on the existing 20s
            // `backgroundDisconnectTask` grace (SolstoneSwiftApp) to keep the loopback
            // alive across the Safari handoff; longer browsing-session survival is
            // validated VPE-direct (AD-10), not here.
            let conveyURL = ConveyURL.dayURL(
                activeLocalPort: self.observerRegistration.activeLocalPort,
                day: self.item.day
            )
            Button(SourceVocabulary.openJournalInConvey) {
                if let conveyURL {
                    self.openURL(conveyURL)
                }
            }
                .buttonStyle(.bordered)
                .disabled(conveyURL == nil)
                .accessibilityLabel(SourceVocabulary.openJournalInConvey)
                .accessibilityHint("Opens your journal in the browser.")

            if conveyURL == nil {
                Text(SourceVocabulary.notConnectedRowAffordance)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(SourceVocabulary.derivedNotInJournalYet)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    var failedActionsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if self.item.sourceKind == .share {
                Text(SourceVocabulary.failedImportSubtext)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack {
                    // Audio and location retry on their own; manual requeue is share-only for now.
                    Button(SourceVocabulary.retry) {
                        self.retry()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Tries sending this again.")

                    Button(SourceVocabulary.drop, role: .destructive) {
                        self.drop()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Removes this from this phone.")
                }
            } else {
                self.dropButton
            }

            self.deleteReceiptBlock
        }
    }

    var dropOnlyBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.dropButton
            self.deleteReceiptBlock
        }
    }

    var dropButton: some View {
        Button(SourceVocabulary.drop, role: .destructive) {
            self.drop()
        }
        .buttonStyle(.bordered)
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

    var sizeText: String {
        guard let bytes = self.item.bytes else {
            return SourceVocabulary.notProvided
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct OnThisPhoneItemDetailView: View {
    @Environment(ImportQueue.self) private var importQueue
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let item: OnThisPhoneItem

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

                SourceDetailBlock(title: SourceVocabulary.onThisPhoneDerived) {
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
            Text(SourceVocabulary.shareSheetDisplayName)
                .font(.subheadline.weight(.semibold))
            Text(self.item.originApp ?? SourceVocabulary.originAppNotProvided)
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
                LabeledContent(SourceVocabulary.originAppLabel, value: self.item.originApp ?? SourceVocabulary.originAppNotProvided)
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
            Button(SourceVocabulary.derivedOpenInConvey) {}
                .buttonStyle(.bordered)
                .disabled(true)
        } else {
            Text(SourceVocabulary.derivedNotInJournalYet)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    var failedActionsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(SourceVocabulary.failedImportSubtext)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Button(SourceVocabulary.retry) {
                    self.retry()
                }
                .buttonStyle(.borderedProminent)

                Button(SourceVocabulary.drop, role: .destructive) {
                    self.drop()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    var dropOnlyBlock: some View {
        Button(SourceVocabulary.drop, role: .destructive) {
            self.drop()
        }
        .buttonStyle(.bordered)
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
        guard let itemID = UUID(uuidString: self.item.id) else { return }
        self.importQueue.dropItem(itemID: itemID)
        self.dismiss()
    }
}

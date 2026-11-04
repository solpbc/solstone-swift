// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// One place something answered instead of the journal: the row, and its own expand. Lives in the
/// status pane's `your journal` section with the other connection facts. Nothing here reaches the
/// pill or the lead.
struct UnknownJournalRow: View {
    let notice: UnknownJournalNotice
    let yourJournal: JournalIdentity

    private var identifier: String {
        switch self.notice.place {
        case .address(let address): "shell.pane.status.unknownJournal.\(address)"
        case .relay: "shell.pane.status.unknownJournal.relay"
        }
    }

    var body: some View {
        DisclosureGroup {
            UnknownJournalDetail(notice: self.notice, yourJournal: self.yourJournal, identifier: self.identifier)
            NavigationLink(value: ShellDestination.pairFlow) {
                Text(SourceVocabulary.stallPairAgainLabel)
                    .font(.body)
            }
            .accessibilityIdentifier("\(self.identifier).pairAgain")
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: UnknownJournalCopy.localized(UnknownJournalCopy.rowKey(self.notice.place), place: self.notice.place))
                    .font(.body)
                Text(verbatim: UnknownJournalCopy.localized(UnknownJournalCopy.expandKey))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(self.identifier)
        }
    }
}

private struct UnknownJournalDetail: View {
    /// Small enough that two cards sit side by side in a phone's list row, with the longest words
    /// a mark can draw scaled to fit.
    private static let markSide: CGFloat = 40

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let notice: UnknownJournalNotice
    let yourJournal: JournalIdentity
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: UnknownJournalCopy.localized(UnknownJournalCopy.headingKey))
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: UnknownJournalCopy.localized(UnknownJournalCopy.bodyKey(self.notice.place), place: self.notice.place))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // why: not ViewThatFits. It measures a card at its words' full size, before they scale
            // down, so a long pair of words stacked the marks at the default type size.
            if self.dynamicTypeSize <= .xLarge {
                HStack(alignment: .top, spacing: 12) {
                    self.whatAnswered
                    self.yours
                }
            } else {
                VStack(spacing: 12) {
                    self.whatAnswered
                    self.yours
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var whatAnswered: some View {
        UnknownJournalMarkColumn(
            labelKey: UnknownJournalCopy.whatAnsweredKey,
            captionKey: UnknownJournalCopy.captionKey(self.notice.claim),
            spokenValue: UnknownJournalCopy.whatAnsweredSpokenValue(self.notice.claim),
            identifier: "\(self.identifier).whatAnswered"
        ) {
            switch self.notice.claim {
            case .mark(let mark):
                JournalMarkView(identity: .mark(mark), side: Self.markSide)
            case .noIdentity:
                JournalMarkNotPresentedView(side: Self.markSide)
            case .unavailable:
                JournalMarkView(identity: .unavailable, side: Self.markSide)
            case .deriving:
                ProgressView()
                    .frame(width: Self.markSide * 2, height: Self.markSide * 2)
            }
        }
    }

    private var yours: some View {
        UnknownJournalMarkColumn(
            labelKey: UnknownJournalCopy.yourJournalKey,
            captionKey: nil,
            spokenValue: self.yourJournal.spokenValue,
            identifier: "\(self.identifier).yourJournal"
        ) {
            JournalMarkView(identity: self.yourJournal, side: Self.markSide)
        }
    }
}

/// A label, a mark and its caption, read by VoiceOver as one element.
private struct UnknownJournalMarkColumn<Mark: View>: View {
    let labelKey: String
    let captionKey: String?
    let spokenValue: String
    let identifier: String
    @ViewBuilder let mark: Mark

    var body: some View {
        let label = UnknownJournalCopy.localized(self.labelKey)
        VStack(spacing: 6) {
            Text(verbatim: label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            self.mark
            if let captionKey {
                Text(verbatim: UnknownJournalCopy.localized(captionKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(self.spokenValue)
        .accessibilityIdentifier(self.identifier)
    }
}

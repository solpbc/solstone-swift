// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct OnThisPhoneView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(ImportQueue.self) private var importQueue
    @Environment(ObserverManager.self) private var observerManager
    @Environment(ObserverUploader.self) private var observerUploader
    @Environment(LocationUploader.self) private var locationUploader
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(AudioStorageKey.enrolled) private var audioEnrolled = false
    @AppStorage(AudioStorageKey.magicMomentFirstSeen) private var magicMomentFirstSeen = false
    @State private var aggregate: OnThisPhoneAggregateSnapshot?
    @State private var showingConnectJournal = false
    @State private var backlogNudgeDismissed = UserSettings.onThisPhoneBacklogNudgeDismissed
    @State private var magicMomentItem: OnThisPhoneItem?
    @State private var magicMomentDismissed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(SourceVocabulary.onThisPhoneScope)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                self.magicMomentSection

                if !self.appConfig.isPaired && !self.isShowingMagicMomentSection {
                    self.notBackedUpNudge
                }

                if let aggregate {
                    OnThisPhoneCountsHeader(sources: aggregate.sources)
                    if !self.appConfig.isPaired,
                       OnThisPhoneBacklogNudge.shouldShow(items: aggregate.items, now: Date()),
                       !self.backlogNudgeDismissed {
                        self.agedBacklogNudge(count: aggregate.items.count)
                    }
                    self.content(aggregate: aggregate)
                }
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("onThisPhone.surface")
        .navigationTitle(SourceVocabulary.onThisPhone)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            self.backlogNudgeDismissed = UserSettings.onThisPhoneBacklogNudgeDismissed
            self.loadSnapshot()
        }
        .onChange(of: self.observerUploader.pendingCount) { _, _ in
            self.loadSnapshot()
        }
        .onChange(of: self.observerUploader.failedCount) { _, _ in
            self.loadSnapshot()
        }
        .sheet(isPresented: self.$showingConnectJournal) {
            ConnectJournalSheet(isPresented: self.$showingConnectJournal)
        }
    }
}

private extension OnThisPhoneView {
    @ViewBuilder
    var magicMomentSection: some View {
        if let magicMomentItem, !self.magicMomentDismissed {
            self.magicMomentShownCard(item: magicMomentItem)
        } else if self.shouldShowMagicMomentPending {
            self.magicMomentPendingCard
        }
    }

    var isShowingMagicMomentSection: Bool {
        if self.magicMomentItem != nil && !self.magicMomentDismissed {
            return true
        }
        return self.shouldShowMagicMomentPending
    }

    var shouldShowMagicMomentPending: Bool {
        guard self.audioEnrolled,
              !self.magicMomentFirstSeen,
              !self.magicMomentDismissed,
              self.magicMomentItem == nil,
              self.aggregate?.items.contains(where: { $0.sourceKind == .audio }) == false
        else {
            return false
        }

        switch self.observerManager.state {
        case .starting, .active:
            return true
        case .idle, .stopping, .error:
            return false
        }
    }

    func magicMomentShownCard(item: OnThisPhoneItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 6) {
                    Text(SourceVocabulary.magicMomentShownHeadline)
                        .font(.headline)
                    Text(SourceVocabulary.magicMomentShownBody)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                self.magicMomentDismissButton
            }

            if let duration = OnThisPhoneItem.formattedDuration(item.audioDurationS) {
                Text(duration)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("magicMoment.duration")
            }

            Button(SourceVocabulary.magicMomentShownSecondary) {
                self.showingConnectJournal = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .frame(minWidth: 44, minHeight: 44)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("magicMoment.card")
    }

    var magicMomentPendingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "ear")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 6) {
                    Text(SourceVocabulary.magicMomentPendingHeadline)
                        .font(.headline)
                    Text(SourceVocabulary.magicMomentPendingBody)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                self.magicMomentDismissButton
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("magicMoment.card")
    }

    var magicMomentDismissButton: some View {
        Button {
            self.magicMomentDismissed = true
        } label: {
            Image(systemName: "xmark")
                .font(.footnote.weight(.bold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .accessibilityLabel("dismiss")
        .accessibilityIdentifier("magicMoment.dismiss")
    }

    var notBackedUpNudge: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "info.circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            Text(SourceVocabulary.onThisPhoneNotBackedUp)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onThisPhone.notBackedUp")

            Spacer(minLength: 0)

            Button("connect a journal") {
                self.showingConnectJournal = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("onThisPhone.connectJournal")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    func agedBacklogNudge(count: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "clock")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            Text(SourceVocabulary.onThisPhoneAgedBacklog(count: count))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onThisPhone.agedBacklog")

            Spacer(minLength: 0)

            Button {
                UserSettings.onThisPhoneBacklogNudgeDismissed = true
                self.backlogNudgeDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityLabel("dismiss")
            .accessibilityIdentifier("onThisPhone.agedBacklog.dismiss")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    func content(aggregate: OnThisPhoneAggregateSnapshot) -> some View {
        if aggregate.items.isEmpty {
            Text(SourceVocabulary.onThisPhoneEmpty)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(aggregate.items) { item in
                    NavigationLink {
                        OnThisPhoneItemDetailView(item: item) {
                            self.loadSnapshot()
                        }
                    } label: {
                        OnThisPhoneRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    func loadSnapshot() {
        let aggregate = OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: self.importQueue,
            observerUploader: self.observerUploader,
            locationUploader: self.locationUploader
        )
        self.aggregate = aggregate
        self.updateMagicMoment(from: aggregate)
    }

    func updateMagicMoment(from aggregate: OnThisPhoneAggregateSnapshot) {
        guard self.audioEnrolled,
              !self.magicMomentFirstSeen,
              !self.magicMomentDismissed,
              self.magicMomentItem == nil,
              self.observerManager.state != .error(.permissionDenied)
        else {
            return
        }

        guard let audioItem = aggregate.items.first(where: { $0.sourceKind == .audio }) else {
            return
        }

        self.magicMomentItem = audioItem
        self.magicMomentFirstSeen = true
    }
}

private struct OnThisPhoneCountsHeader: View {
    let sources: [OnThisPhoneSourceSnapshot]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(self.sources, id: \.sourceKind) { source in
                Text(SourceVocabulary.onThisPhoneCountLabel(
                    for: source.sourceKind,
                    count: source.result.count
                ))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(source.result.count == nil ? .secondary : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .accessibilityIdentifier("onThisPhone.counts.\(source.sourceKind.accessibilityID)")
                .accessibilityLabel(SourceVocabulary.onThisPhoneCountAccessibilityLabel(
                    for: source.sourceKind,
                    count: source.result.count
                ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OnThisPhoneRow: View {
    let item: OnThisPhoneItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SourceVocabulary.onThisPhoneSourceName(for: self.item.sourceKind))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            Text(self.item.rowPayloadText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: self.symbolName)
                Text(self.item.sendState.label)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(self.stateColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.item.voiceOverText)
        .accessibilityIdentifier("onThisPhone.row.\(self.item.id)")
    }

    private var symbolName: String {
        switch self.item.sendState {
        case .inYourJournal:
            "checkmark.circle"
        case .sending:
            "arrow.up.circle"
        case .savedOnThisPhone:
            "internaldrive"
        case .needsAttention:
            "exclamationmark.triangle"
        }
    }

    private var stateColor: Color {
        switch self.item.sendState {
        case .needsAttention:
            .red
        case .inYourJournal, .sending, .savedOnThisPhone:
            .secondary
        }
    }
}

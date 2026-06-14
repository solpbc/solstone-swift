// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct OnThisPhoneView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(ImportQueue.self) private var importQueue
    @Environment(ObserverManager.self) private var observerManager
    @Environment(ObserverUploader.self) private var observerUploader
    @Environment(LocationUploader.self) private var locationUploader
    @Environment(ObserverRegistration.self) private var observerRegistration
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(AudioStorageKey.enrolled) private var audioEnrolled = false
    @AppStorage(AudioStorageKey.magicMomentFirstSeen) private var magicMomentFirstSeen = false
    @State private var aggregate: OnThisPhoneAggregateSnapshot?
    @State private var dropController = OnThisPhoneDropController()
    @State private var showingConnectJournal = false
    @State private var backlogNudgeDismissed = UserSettings.onThisPhoneBacklogNudgeDismissed
    @State private var magicMomentItem: OnThisPhoneItem?
    @State private var magicMomentDismissed = false
    @State private var migrationSawUndelivered = false
    @State private var migrationCompletionDismissed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !self.isShowingNotBackedUpNudge {
                    Text(SourceVocabulary.onThisPhoneScope)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                self.magicMomentSection

                if self.isShowingNotBackedUpNudge {
                    self.notBackedUpNudge
                }

                if let displayAggregate = self.displayAggregate {
                    let migration = onThisPhoneMigration(
                        snapshot: displayAggregate,
                        journalConnected: self.observerRegistration.activeLocalPort != nil
                    )
                    if self.appConfig.isPaired, !migration.isEmpty {
                        self.migrationSection(migration: migration)
                    }
                    OnThisPhoneStateSummaryView(summary: displayAggregate.sendStateSummary)
                    if !self.appConfig.isPaired,
                       OnThisPhoneBacklogNudge.shouldShow(items: displayAggregate.items, now: Date()),
                       !self.backlogNudgeDismissed {
                        self.agedBacklogNudge(count: displayAggregate.items.count)
                    }
                    self.content(snapshot: displayAggregate)
                }
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .bottom) {
            self.dropSnackbar
        }
        .animation(.snappy(duration: 0.2), value: self.dropController.surfaced?.id)
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
        .onChange(of: self.importQueue.pendingCount) { _, _ in
            self.loadSnapshot()
        }
        .onChange(of: self.importQueue.failedCount) { _, _ in
            self.loadSnapshot()
        }
        .onChange(of: self.locationUploader.pendingCount) { _, _ in
            self.loadSnapshot()
        }
        .onChange(of: self.locationUploader.failedCount) { _, _ in
            self.loadSnapshot()
        }
        .onChange(of: self.observerRegistration.activeLocalPort) { _, _ in
            self.loadSnapshot()
        }
        .sheet(isPresented: self.$showingConnectJournal) {
            ConnectJournalSheet(isPresented: self.$showingConnectJournal)
        }
    }
}

private extension OnThisPhoneView {
    var displayAggregate: OnThisPhoneAggregateSnapshot? {
        self.aggregate?.filteringOutPending(self.dropController.pendingIDs)
    }

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

    var isShowingNotBackedUpNudge: Bool {
        !self.appConfig.isPaired && !self.isShowingMagicMomentSection
    }

    var shouldShowMagicMomentPending: Bool {
        guard self.audioEnrolled,
              !self.magicMomentFirstSeen,
              !self.magicMomentDismissed,
              self.magicMomentItem == nil,
              self.displayAggregate?.items.contains(where: { $0.sourceKind == .audio }) == false
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

    func migrationSection(migration: OnThisPhoneMigration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            self.migrationStageRow(migration: migration)

            if migration.showsCompletion(sawUndelivered: self.migrationSawUndelivered),
               !self.migrationCompletionDismissed {
                self.migrationCompletionCard(count: migration.inYourJournal)
            } else {
                let splitText = self.migrationSplitText(migration: migration)
                if !splitText.isEmpty {
                    Text(splitText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onThisPhone.migration.split")
                }
            }

            if migration.needsAttention > 0 {
                self.migrationNeedsAttentionRow(count: migration.needsAttention)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onThisPhone.migration")
    }

    func migrationStageRow(migration: OnThisPhoneMigration) -> some View {
        HStack(alignment: .top, spacing: 8) {
            self.migrationStagePill(
                count: migration.onThisPhone,
                stage: SourceVocabulary.migrationStageOnThisPhone,
                accessibilityID: "onThisPhone.migration.stage.onThisPhone"
            )
            self.migrationStagePill(
                count: migration.onItsWay,
                stage: SourceVocabulary.migrationStageOnItsWay,
                accessibilityID: "onThisPhone.migration.stage.onItsWay"
            )
            self.migrationStagePill(
                count: migration.inYourJournal,
                stage: SourceVocabulary.migrationStageInYourJournal,
                accessibilityID: "onThisPhone.migration.stage.inYourJournal"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func migrationStagePill(count: Int, stage: String, accessibilityID: String) -> some View {
        Text(SourceVocabulary.migrationStageCount(count, stage: stage))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .accessibilityIdentifier(accessibilityID)
    }

    func migrationCompletionCard(count: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            Text(SourceVocabulary.migrationReached(count: count))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button {
                self.migrationCompletionDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityLabel("dismiss")
            .accessibilityIdentifier("onThisPhone.migration.completion.dismiss")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onThisPhone.migration.completion")
    }

    func migrationNeedsAttentionRow(count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(SourceVocabulary.migrationStageCount(count, stage: SourceVocabulary.needsAttention))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.red)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onThisPhone.migration.needsAttention")
    }

    func migrationSplitText(migration: OnThisPhoneMigration) -> String {
        [
            (migration.onThisPhone, SourceVocabulary.migrationStageOnThisPhone),
            (migration.onItsWay, SourceVocabulary.migrationStageOnItsWay),
            (migration.inYourJournal, SourceVocabulary.migrationStageInYourJournal),
        ]
        .filter { count, _ in count > 0 }
        .map { count, stage in SourceVocabulary.migrationStageCount(count, stage: stage) }
        .joined(separator: " · ")
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

            Button("connect") {
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
    var dropSnackbar: some View {
        if let surfaced = self.dropController.surfaced {
            let snackbarText = SourceVocabulary.onThisPhoneDropSnackbar(descriptor: surfaced.descriptor)
            HStack(spacing: 12) {
                Text(snackbarText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onThisPhone.drop.snackbar")

                Spacer(minLength: 0)

                Button(SourceVocabulary.undo) {
                    self.dropController.undo(itemID: surfaced.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("onThisPhone.drop.undo")
            }
            .padding(12)
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            }
            .padding()
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    func content(snapshot: OnThisPhoneAggregateSnapshot) -> some View {
        if snapshot.items.isEmpty {
            Text(SourceVocabulary.onThisPhoneEmpty)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(snapshot.items) { item in
                    NavigationLink {
                        OnThisPhoneItemDetailView(item: item) { item in
                            guard let commit = makeDropCommit(
                                for: item,
                                importQueue: self.importQueue,
                                observerUploader: self.observerUploader,
                                locationUploader: self.locationUploader
                            ) else {
                                return
                            }
                            self.dropController.requestDrop(
                                itemID: item.id,
                                descriptor: item.dropDescriptor,
                                commit: commit
                            )
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
        let displayAggregate = self.displayAggregate ?? aggregate
        self.updateMagicMoment(from: displayAggregate)
        let migration = onThisPhoneMigration(
            snapshot: displayAggregate,
            journalConnected: self.observerRegistration.activeLocalPort != nil
        )
        if !migration.isEmpty && !migration.isAllDelivered {
            self.migrationSawUndelivered = true
            self.migrationCompletionDismissed = false
        }
    }

    func updateMagicMoment(from snapshot: OnThisPhoneAggregateSnapshot) {
        guard self.audioEnrolled,
              !self.magicMomentFirstSeen,
              !self.magicMomentDismissed,
              self.magicMomentItem == nil,
              self.observerManager.state != .error(.permissionDenied)
        else {
            return
        }

        guard let audioItem = snapshot.items.first(where: { $0.sourceKind == .audio }) else {
            return
        }

        self.magicMomentItem = audioItem
        self.magicMomentFirstSeen = true
    }
}

private struct OnThisPhoneStateSummaryView: View {
    let summary: [OnThisPhoneSendStateSummary]

    var body: some View {
        if !self.summary.isEmpty {
            HStack(spacing: 8) {
                ForEach(self.summary) { item in
                    let style = SendStateStyle.style(for: item.sendState)
                    let label = "\(item.count) \(style.compactLabel)"
                    Text(label)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(style.foreground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(style.chipBackground, in: Capsule())
                        .accessibilityIdentifier("onThisPhone.summary.\(item.sendState.stateID)")
                        .accessibilityLabel(label)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct OnThisPhoneRow: View {
    let item: OnThisPhoneItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(SourceVocabulary.onThisPhoneSourceName(for: self.item.sourceKind))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(self.item.rowTimestampText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            Text(self.item.rowDescriptorText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            SendStateChip(state: self.item.sendState)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.item.voiceOverText)
        .accessibilityIdentifier("onThisPhone.row.\(self.item.id)")
    }
}

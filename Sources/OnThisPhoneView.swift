// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct OnThisPhoneView: View {
    let onTurnOnSource: () -> Void

    init(onTurnOnSource: @escaping () -> Void = {}) {
        self.onTurnOnSource = onTurnOnSource
    }

    var body: some View {
        OnThisPhoneMomentsView(
            onTurnOnSource: self.onTurnOnSource,
            foldBadgeVisible: false
        ) { EmptyView() }
            .navigationTitle(SourceVocabulary.onThisPhone)
            .navigationBarTitleDisplayMode(.inline)
    }
}

nonisolated enum LoadTrigger: String, Sendable {
    case appear
    case observerCounts
    case omiCounts
    case watchCounts
    case importCounts
    case locationCounts
    case activePort
}

struct OnThisPhoneMomentsView<Header: View>: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(ImportQueue.self) private var importQueue
    @Environment(ObserverManager.self) private var observerManager
    @Environment(ObserverUploader.self) private var observerUploader
    @Environment(OmiUploaderHolder.self) private var omiUploaderHolder
    @Environment(WatchUploaderHolder.self) private var watchUploaderHolder
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(FinishSyncingCoordinator.self) private var finishSyncingCoordinator
    @Environment(LocationUploader.self) private var locationUploader
    @Environment(ObserverRegistration.self) private var observerRegistration
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(AudioStorageKey.enrolled) private var audioEnrolled = false
    @AppStorage(AudioStorageKey.magicMomentFirstSeen) private var magicMomentFirstSeen = false
    let onTurnOnSource: () -> Void
    @State private var aggregate: OnThisPhoneAggregateSnapshot?
    @State private var dropController = OnThisPhoneDropController()
    @State private var showingConnectJournal = false
    @State private var showingOfflineExplanation = false
    @State private var backlogNudgeDismissed = UserSettings.onThisPhoneBacklogNudgeDismissed
    @State private var magicMomentItem: OnThisPhoneItem?
    @State private var magicMomentDismissed = false
    @State private var statusDetailsExpanded = false
    @State private var openRowID: String?
    @State private var pendingDropItem: OnThisPhoneItem?
    @State private var welcomeFraming: String?
    @State private var welcomeFramingTask: Task<Void, Never>?
    @State private var coalescer = OnThisPhoneSnapshotCoalescer()
    private let pulsePoller = HomePulsePoller()
    private let askBarState: DayHomeJournalState?
    private let onAskBarChat: () -> Void
    private let foldBadgeVisible: Bool
    private let header: Header

    init(
        onTurnOnSource: @escaping () -> Void = {},
        askBarState: DayHomeJournalState? = nil,
        onAskBarChat: @escaping () -> Void = {},
        foldBadgeVisible: Bool,
        @ViewBuilder header: () -> Header
    ) {
        self.onTurnOnSource = onTurnOnSource
        self.askBarState = askBarState
        self.onAskBarChat = onAskBarChat
        self.foldBadgeVisible = foldBadgeVisible
        self.header = header()
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    self.header

                    if self.hasItems, !self.isShowingNotBackedUpNudge {
                        Text(self.onThisPhoneScopeText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    self.magicMomentSection

                    if let welcomeFraming = self.welcomeFraming {
                        Text(welcomeFraming)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("onThisPhone.welcomeFraming")
                    }

                    if self.hasItems, self.isShowingNotBackedUpNudge {
                        self.notBackedUpNudge
                    }

                    if let displayAggregate = self.displayAggregate {
                        let migration = onThisPhoneMigration(
                            snapshot: displayAggregate
                        )
                        if !migration.isEmpty {
                            self.statusBlock(
                                migration: migration,
                                items: displayAggregate.items,
                                summary: displayAggregate.sendStateSummary
                            )
                        }
                        if !self.appConfig.isPaired,
                           OnThisPhoneBacklogNudge.shouldShow(items: displayAggregate.items, now: Date()),
                           !self.backlogNudgeDismissed {
                            self.agedBacklogNudge(count: displayAggregate.items.count)
                        }
                        self.finishSyncingCard
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
            .confirmationDialog(
                SourceVocabulary.onThisPhoneDropConfirmTitle,
                isPresented: self.isPresentingSwipeDropConfirm,
                titleVisibility: .visible,
                presenting: self.pendingDropItem
            ) { item in
                Button(SourceVocabulary.drop, role: .destructive) {
                    self.requestDrop(item)
                }
                .accessibilityIdentifier("onThisPhone.swipe.drop.confirm")

                Button(SourceVocabulary.cancel, role: .cancel) {}
            } message: { item in
                Text(SourceVocabulary.onThisPhoneDropConfirmMessage(sendState: item.sendState))
            }
            .animation(.snappy(duration: 0.2), value: self.dropController.surfaced?.id)
            .accessibilityIdentifier("onThisPhone.surface")
            .onAppear {
                self.backlogNudgeDismissed = UserSettings.onThisPhoneBacklogNudgeDismissed
                self.loadSnapshot(trigger: .appear)
                self.refreshWelcomeFraming()
            }
            .onChange(of: self.observerUploader.pendingCount) { _, _ in
                self.coalescer.schedule { self.loadSnapshot(trigger: .observerCounts) }
            }
            .onChange(of: self.observerUploader.failedCount) { _, _ in
                self.coalescer.schedule { self.loadSnapshot(trigger: .observerCounts) }
            }
            .onChange(of: self.omiUploaderHolder.pendingCount) { _, _ in
                self.coalescer.schedule { self.loadSnapshot(trigger: .omiCounts) }
            }
            .onChange(of: self.omiUploaderHolder.failedCount) { _, _ in
                self.coalescer.schedule { self.loadSnapshot(trigger: .omiCounts) }
            }
            .onChange(of: self.watchUploaderHolder.pendingCount) { _, _ in
                self.coalescer.schedule { self.loadSnapshot(trigger: .watchCounts) }
            }
            .onChange(of: self.watchUploaderHolder.failedCount) { _, _ in
                self.coalescer.schedule { self.loadSnapshot(trigger: .watchCounts) }
            }
            .onChange(of: self.importQueue.pendingCount) { _, _ in
                self.coalescer.schedule { self.loadSnapshot(trigger: .importCounts) }
            }
            .onChange(of: self.importQueue.failedCount) { _, _ in
                self.coalescer.schedule { self.loadSnapshot(trigger: .importCounts) }
            }
            .onChange(of: self.locationUploader.pendingCount) { _, _ in
                self.coalescer.schedule { self.loadSnapshot(trigger: .locationCounts) }
            }
            .onChange(of: self.locationUploader.failedCount) { _, _ in
                self.coalescer.schedule { self.loadSnapshot(trigger: .locationCounts) }
            }
            .onChange(of: self.observerRegistration.activeLocalPort) { _, _ in
                self.loadSnapshot(trigger: .activePort)
                self.refreshWelcomeFraming()
            }
            .onDisappear {
                self.coalescer.cancel()
            }
            .sheet(isPresented: self.$showingConnectJournal) {
                ConnectJournalSheet(isPresented: self.$showingConnectJournal)
            }

            if let askBarState = self.askBarState {
                let configuration = self.askBarConfiguration(for: askBarState)
                DayHomeAskBar(
                    title: configuration.title,
                    isEnabled: configuration.isEnabled,
                    foldBadgeVisible: self.foldBadgeVisible,
                    action: configuration.action
                )
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .alert(SourceVocabulary.askBarOfflineExplanationTitle, isPresented: self.$showingOfflineExplanation) {
            Button("ok") {}
        } message: {
            Text(SourceVocabulary.askBarOfflineExplanationBody)
        }
    }
}

private extension OnThisPhoneMomentsView {
    var onThisPhoneScopeText: String {
        switch self.askBarState {
        case .linkedOnline:
            SourceVocabulary.onThisPhoneScopeConnected
        case .linkedOffline:
            SourceVocabulary.onThisPhoneScopeOfflinePaired
        case .noJournal, nil:
            SourceVocabulary.onThisPhoneScope
        }
    }

    var displayAggregate: OnThisPhoneAggregateSnapshot? {
        self.aggregate?.filteringOutPending(self.dropController.pendingIDs)
    }

    var hasItems: Bool {
        self.displayAggregate?.items.isEmpty == false
    }

    var isPresentingSwipeDropConfirm: Binding<Bool> {
        Binding(
            get: {
                self.pendingDropItem != nil
            },
            set: { isPresented in
                if !isPresented {
                    self.pendingDropItem = nil
                }
            }
        )
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

    @ViewBuilder
    func statusBlock(
        migration: OnThisPhoneMigration,
        items: [OnThisPhoneItem],
        summary: [OnThisPhoneSendStateSummary]
    ) -> some View {
        let reach = uploadReach(
            observer: self.observerUploader,
            omi: self.omiUploaderHolder,
            watch: self.watchUploaderHolder,
            importQueue: self.importQueue,
            location: self.locationUploader
        )
        let headline = onThisPhoneHeadline(migration: migration, reachingJournal: reach != .failing)
        let lines = self.appConfig.isPaired
            ? headline.lines
            : headline.lines.filter { $0.role == .needsAttention }

        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                self.statusLine(line)
            }

            if let last = onThisPhoneLastActive(items: items) {
                Text(SourceVocabulary.lastActiveLine(
                    relative: SourceVocabulary.probeRelativeLabel(secondsAgo: Date().timeIntervalSince(last))
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("onThisPhone.status.lastActive")
            }

            DisclosureGroup(isExpanded: self.$statusDetailsExpanded) {
                EmptyView()
            } label: {
                Text(SourceVocabulary.details)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("onThisPhone.details")

            if self.statusDetailsExpanded {
                self.detailsBreakdown(summary: summary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onThisPhone.status")
    }

    @ViewBuilder
    func statusLine(_ line: OnThisPhoneHeadline.Line) -> some View {
        switch line.role {
        case .needsAttention:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text(line.text)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.red)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onThisPhone.status.needsAttention")
        case .syncing:
            Text(line.text)
                .font(.headline)
                .accessibilityIdentifier("onThisPhone.status.headline")
        case .trouble:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                Text(line.text)
            }
            .font(.headline.weight(.semibold))
            .foregroundStyle(Color("SendState/Sending/Foreground"))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onThisPhone.status.headline")
        case .upToDate:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(Color.accentColor)
                Text(line.text)
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("onThisPhone.status.headline")
        }
    }

    @ViewBuilder
    func detailsBreakdown(summary: [OnThisPhoneSendStateSummary]) -> some View {
        HStack(spacing: 8) {
            ForEach(summary) { item in
                let style = SendStateStyle.style(for: item.sendState)
                let label = "\(item.count) \(style.compactLabel)"
                Text(label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(style.foreground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(style.chipBackground, in: Capsule())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(label)
                    .accessibilityIdentifier("onThisPhone.summary.\(item.sendState.stateID)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

            if !self.appConfig.isPaired {
                Button(SourceVocabulary.magicMomentShownSecondary) {
                    self.showingConnectJournal = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .frame(minWidth: 44, minHeight: 44)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("magicMoment.card")
    }

    func askBarConfiguration(for state: DayHomeJournalState) -> (title: String, isEnabled: Bool, action: () -> Void) {
        switch state {
        case .noJournal:
            return (
                title: SourceVocabulary.dayHomeAskBarHint,
                isEnabled: true,
                action: { self.showingConnectJournal = true }
            )
        case .linkedOffline:
            return (
                title: SourceVocabulary.askBarOffline,
                isEnabled: true,
                action: { self.showingOfflineExplanation = true }
            )
        case .linkedOnline:
            return (
                title: SourceVocabulary.chatNavTitle,
                isEnabled: true,
                action: self.onAskBarChat
            )
        }
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

    private var finishSyncingBacklog: Int {
        let totals = uploadTotals(
            observer: self.observerUploader,
            omi: self.omiUploaderHolder,
            watch: self.watchUploaderHolder,
            importQueue: self.importQueue,
            location: self.locationUploader
        )
        return totals.failed + totals.pending
    }

    private var finishSyncingCardState: FinishSyncingCoordinator.CardState {
        FinishSyncingCoordinator.cardState(
            isPaired: self.appConfig.isPaired,
            isConnected: self.tunnelManager.state.isConnected,
            backlog: self.finishSyncingBacklog,
            isFinishing: self.finishSyncingCoordinator.isFinishing,
            lastOutcome: self.finishSyncingCoordinator.lastOutcome,
            threshold: FinishSyncingCoordinator.backlogThreshold
        )
    }

    private var finishSyncingUnavailableReason: String? {
        if case .unavailable(let reason) = self.finishSyncingCoordinator.availability {
            return reason
        }
        return nil
    }

    @ViewBuilder
    var finishSyncingCard: some View {
        switch self.finishSyncingCardState {
        case .hidden:
            EmptyView()
        case .idle:
            self.finishSyncingIdleCard
        case .inProgress:
            self.finishSyncingCardChrome(icon: "arrow.up.circle") {
                Text(SourceVocabulary.finishSyncingInProgress)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                EmptyView()
            }
        case .completed:
            self.finishSyncingCardChrome(icon: "checkmark.circle") {
                Text(SourceVocabulary.finishSyncingCompleted)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                self.finishSyncingDismissButton
            }
        case .interrupted(let remaining):
            self.finishSyncingCardChrome(icon: "info.circle") {
                Text(
                    remaining > 0
                        ? SourceVocabulary.finishSyncingInterrupted(count: remaining)
                        : SourceVocabulary.finishSyncingInterruptedFallback
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } trailing: {
                self.finishSyncingDismissButton
            }
        }
    }

    private var finishSyncingIdleCard: some View {
        let unavailableReason = self.finishSyncingUnavailableReason
        return self.finishSyncingCardChrome(icon: "arrow.up.circle") {
            VStack(alignment: .leading, spacing: 4) {
                Text(SourceVocabulary.finishSyncingCardHeadline)
                    .font(.subheadline.weight(.semibold))
                Text(SourceVocabulary.finishSyncingCardBody(count: self.finishSyncingBacklog))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } trailing: {
            VStack(alignment: .trailing, spacing: 6) {
                Button(SourceVocabulary.finishSyncingButton) {
                    self.finishSyncingCoordinator.submit()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(unavailableReason != nil)
                .accessibilityIdentifier("onThisPhone.finishSyncing.start")

                if let unavailableReason {
                    Text(unavailableReason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var finishSyncingDismissButton: some View {
        Button {
            self.finishSyncingCoordinator.dismissOutcome()
        } label: {
            Image(systemName: "xmark")
                .font(.footnote.weight(.bold))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .accessibilityLabel("dismiss")
        .accessibilityIdentifier("onThisPhone.finishSyncing.dismiss")
    }

    private func finishSyncingCardChrome<Content: View, Trailing: View>(
        icon: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            content()

            Spacer(minLength: 0)

            trailing()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onThisPhone.finishSyncing")
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
            VStack(alignment: .leading, spacing: 12) {
                Text(SourceVocabulary.onThisPhoneEmpty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button(SourceVocabulary.onThisPhoneTurnOnSourceButton) {
                    self.onTurnOnSource()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("onThisPhone.turnOnSource")
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(snapshot.items) { item in
                    SwipeToDropRow(
                        item: item,
                        openRowID: self.$openRowID,
                        onRequestDrop: { item in self.requestDrop(item) },
                        onDrop: { item in self.pendingDropItem = item }
                    )
                }
            }
        }
    }

    private func requestDrop(_ item: OnThisPhoneItem) {
        guard let commit = makeDropCommit(
            for: item,
            importQueue: self.importQueue,
            observerUploader: self.observerUploader,
            omiUploader: self.omiUploaderHolder.uploader,
            watchUploader: self.watchUploaderHolder.uploader,
            locationUploader: self.locationUploader,
            removeWatchStaging: self.watchUploaderHolder.removeStaging
        ) else {
            return
        }
        self.dropController.requestDrop(
            itemID: item.id,
            descriptor: item.dropDescriptor,
            commit: commit
        )
    }

    func loadSnapshot(trigger: LoadTrigger) {
        let interval = DrainSignpost.begin(
            .aggregateRefresh,
            source: .view,
            fields: DrainFields(trigger: trigger.rawValue)
        )
        let aggregate = OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: self.importQueue,
            observerUploader: self.observerUploader,
            omiUploader: self.omiUploaderHolder.uploader,
            watchUploader: self.watchUploaderHolder.uploader,
            locationUploader: self.locationUploader
        )
        self.aggregate = aggregate
        let displayAggregate = self.displayAggregate ?? aggregate
        self.updateMagicMoment(from: displayAggregate)
        DrainSignpost.end(
            interval,
            source: .view,
            fields: DrainFields(
                status: "success",
                items: aggregate.items.count,
                published: true,
                sources: aggregate.sources.count,
                failedSources: aggregate.failedSourceCount
            )
        )
    }

    private func refreshWelcomeFraming() {
        self.welcomeFramingTask?.cancel()
        guard let port = self.observerRegistration.activeLocalPort else {
            self.welcomeFraming = nil
            return
        }
        self.welcomeFramingTask = Task {
            let framing = await self.pulsePoller.fetch(localPort: port)
            guard !Task.isCancelled else { return }
            self.welcomeFraming = framing
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

private struct SwipeToDropRow: View {
    let item: OnThisPhoneItem
    @Binding var openRowID: String?
    let onRequestDrop: @MainActor (OnThisPhoneItem) -> Void
    let onDrop: @MainActor (OnThisPhoneItem) -> Void
    @State private var offset: CGFloat = 0
    @State private var dragStartOffset: CGFloat?

    private let actionWidth: CGFloat = 88
    private var maxPull: CGFloat { self.actionWidth * 1.3 }
    private var halfThreshold: CGFloat { self.actionWidth / 2 }
    private var fullSwipeThreshold: CGFloat { self.actionWidth * 1.1 }
    private var spring: Animation {
        .spring(response: 0.26, dampingFraction: 0.88, blendDuration: 0)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            self.dropActionButton
            self.foregroundCard
        }
        .onChange(of: self.openRowID) { _, newValue in
            self.syncOffset(openRowID: newValue)
        }
    }
}

private extension SwipeToDropRow {
    var dropActionButton: some View {
        Button {
            self.promptDrop()
        } label: {
            Label {
                Text(SourceVocabulary.drop)
            } icon: {
                Image(systemName: "trash")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .frame(width: self.actionWidth)
        .frame(minHeight: 44)
        .background(Color.red, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier("onThisPhone.swipe.drop.\(self.item.id)")
    }

    var foregroundCard: some View {
        NavigationLink {
            OnThisPhoneItemDetailView(item: self.item) { item in
                self.onRequestDrop(item)
            }
        } label: {
            OnThisPhoneRow(item: self.item)
                .simultaneousGesture(self.dragGesture)
                .accessibilityAction(named: Text(SourceVocabulary.onThisPhoneDropFromPhone)) {
                    self.promptDrop()
                }
        }
        .buttonStyle(.plain)
        .offset(x: self.offset)
        .simultaneousGesture(
            TapGesture()
                .onEnded {
                    self.openRowID = nil
                }
        )
    }

    var dragGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                guard value.translation.width < 0 || self.dragStartOffset != nil else { return }
                if self.dragStartOffset == nil {
                    self.dragStartOffset = self.offset
                    self.openRowID = self.item.id
                }
                let proposed = (self.dragStartOffset ?? 0) + value.translation.width
                self.offset = min(0, max(-self.maxPull, proposed))
            }
            .onEnded { value in
                self.dragStartOffset = nil
                if value.translation.width < -self.fullSwipeThreshold {
                    self.openRowID = nil
                    withAnimation(self.spring) {
                        self.offset = 0
                    }
                    self.onDrop(self.item)
                } else if self.offset < -self.halfThreshold {
                    self.openRowID = self.item.id
                    withAnimation(self.spring) {
                        self.offset = -self.actionWidth
                    }
                } else {
                    self.openRowID = nil
                    withAnimation(self.spring) {
                        self.offset = 0
                    }
                }
            }
    }

    func promptDrop() {
        self.openRowID = nil
        withAnimation(self.spring) {
            self.offset = 0
        }
        self.onDrop(self.item)
    }

    func syncOffset(openRowID: String?) {
        guard self.dragStartOffset == nil else { return }
        if openRowID != self.item.id {
            withAnimation(self.spring) {
                self.offset = 0
            }
        } else {
            withAnimation(self.spring) {
                self.offset = -self.actionWidth
            }
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
                if let badgeLabel = self.item.audioSourceBadgeLabel {
                    onThisPhoneAudioSourceBadge(badgeLabel)
                }
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

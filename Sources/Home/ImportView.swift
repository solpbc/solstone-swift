// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

nonisolated enum ImportQueueHoldPresentation {
    static func holdLine(
        isPaired: Bool,
        isPairingRefused: Bool,
        awaitingMarkConfirmation: Bool,
        journalTooOld: Bool = false,
        isConnected: Bool
    ) -> String? {
        if !isPaired {
            return AppStrings.ios_app_importholdunpaired()
        }
        if isPairingRefused {
            return AppStrings.ios_app_importholdrefused()
        }
        if awaitingMarkConfirmation {
            return AppStrings.ios_app_importholdmark()
        }
        if journalTooOld {
            return AppStrings.ios_app_importholdupdate()
        }
        if !isConnected {
            return AppStrings.ios_app_importholdoffline()
        }
        return nil
    }
}

nonisolated enum ImportRemoveDialogPresentation {
    static func title(for item: ShareImportActiveItem) -> String {
        AppStrings.ios_app_importremovetitle(item.filename)
    }

    static func body(for item: ShareImportActiveItem) -> String {
        if !item.hasLocalCopy {
            return AppStrings.ios_app_importremovebodymissing()
        }
        if case .readyToReview = item.phase {
            return AppStrings.ios_app_importremovebodyreview()
        }
        return AppStrings.ios_app_importremovebodylocal()
    }
}

nonisolated enum ImportCancelDialogPresentation {
    static func title(for item: ShareImportActiveItem) -> String {
        AppStrings.ios_app_importcanceltitle(item.filename)
    }

    static var body: String {
        AppStrings.ios_app_importcancelbody()
    }
}

nonisolated struct ImportRowProgressPresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case sending
        case checking
        case paused
    }

    let kind: Kind
    let statusWord: String
    let detailLine: String
    let fraction: Double

    static func build(for item: ShareImportActiveItem) -> ImportRowProgressPresentation? {
        guard let progress = item.resumableProgress else { return nil }
        let total = max(Int64(1), progress.bytesTotal)
        let clampedSent = min(max(Int64(0), progress.bytesSent), total)
        let sentText = ImportByteFormat.bytes(clampedSent)
        let totalText = ImportByteFormat.bytes(total)
        let percent = ImportByteFormat.percent(sent: clampedSent, total: total)
        let fraction = Double(clampedSent) / Double(total)

        switch item.phase {
        case .sending:
            switch progress.phase {
            case .checking:
                return ImportRowProgressPresentation(
                    kind: .checking,
                    statusWord: AppStrings.ios_app_importtilechecking(),
                    detailLine: AppStrings.ios_app_importrowchecking(),
                    fraction: 1.0
                )
            case .paused:
                return ImportRowProgressPresentation(
                    kind: .paused,
                    statusWord: AppStrings.ios_app_importtilepaused(),
                    detailLine: AppStrings.ios_app_importrowpaused(sentText, totalText),
                    fraction: fraction
                )
            case .sending:
                let detail = (progress.isResuming && clampedSent > 0)
                    ? AppStrings.ios_app_importrowresuming(sentText, totalText)
                    : AppStrings.ios_app_importrowprogress(sentText, totalText, "\(percent)")
                return ImportRowProgressPresentation(
                    kind: .sending,
                    statusWord: AppStrings.ios_app_sending(),
                    detailLine: detail,
                    fraction: fraction
                )
            }
        case .waiting:
            return ImportRowProgressPresentation(
                kind: .paused,
                statusWord: AppStrings.ios_app_importtilepaused(),
                detailLine: AppStrings.ios_app_importrowpaused(sentText, totalText),
                fraction: fraction
            )
        case .readyToReview, .reviewExpired, .needsAttention:
            return nil
        }
    }
}

nonisolated enum ImportRecentTimeFormatter {
    static func relative(from date: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(date)))
        if elapsed < 60 {
            return AppStrings.ios_about_relative_second(max(1, elapsed))
        }
        if elapsed < 3600 {
            return AppStrings.ios_about_relative_minute(elapsed / 60)
        }
        return AppStrings.ios_about_relative_hour(max(1, elapsed / 3600))
    }
}

struct ImportView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(ShareTransferHolder.self) private var shareTransferHolder
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(ConnectionSyncModel.self) private var connectionSyncModel
    @Environment(ConnectionStallMonitor.self) private var connectionStallMonitor
    @Environment(ShareImportStore.self) private var shareImportStore
    @Environment(ForegroundDrainGate.self) private var foregroundDrainGate
    @Environment(PendingJournalOpenState.self) private var pendingJournalOpen: PendingJournalOpenState?
    @Environment(ScreenshotsSourceHandle.self) private var screenshotsSourceHandle: ScreenshotsSourceHandle?
    @Environment(ImportBackgroundUploadCoordinator.self) private var importBackgroundUploadCoordinator: ImportBackgroundUploadCoordinator?
    @Environment(LocationManager.self) private var locationManager: LocationManager?
    @Environment(FinishSyncingCoordinator.self) private var finishSyncingCoordinator: FinishSyncingCoordinator?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var sectionFocused: Bool

    static let journalImportPath = "/app/import/"

    @State private var isPickingFiles = false
    @State private var isDropTargeted = false
    @State private var intake: Intake = .idle
    @State private var pendingRemoveItem: ShareImportActiveItem?
    @State private var pendingCancelItem: ShareImportActiveItem?
    @State private var now = Date()

    private enum Intake: Equatable {
        case idle
        case working
        case finished(String)
    }

    private var canOpenJournal: Bool {
        self.appConfig.isPaired && self.appConfig.journalSendConfirmed
    }

    private var reviewItems: [ShareImportActiveItem] {
        self.shareTransferHolder.reviewItems
    }

    private var onDeviceItems: [ShareImportActiveItem] {
        self.shareTransferHolder.onDeviceItems
    }

    private var recentReceipts: [ImportRecentReceipt] {
        self.shareTransferHolder.recentReceipts(
            instanceID: self.appConfig.deviceID,
            isPaired: self.appConfig.isPaired,
            markConfirmed: self.appConfig.journalSendConfirmed,
            now: self.now
        )
    }

    private var queueHoldLine: String? {
        ImportQueueHoldPresentation.holdLine(
            isPaired: self.appConfig.isPaired,
            isPairingRefused: self.shareTransferHolder.isPairingRefused,
            awaitingMarkConfirmation: self.appConfig.awaitingMarkConfirmation,
            isConnected: self.tunnelManager.state.isConnected && !self.connectionStallMonitor.isStalled
        )
    }

    private var backgroundUploadCardState: ImportBackgroundUploadCoordinator.CardState {
        guard let coordinator = self.importBackgroundUploadCoordinator else { return .hidden }
        let isSustaining = (self.locationManager?.isSustainingBackground ?? false)
            || (self.finishSyncingCoordinator?.isSustainingBackground ?? false)
        return ImportBackgroundUploadCoordinator.cardState(
            isPaired: self.appConfig.isPaired,
            isConnected: self.tunnelManager.state.isConnected && !self.connectionStallMonitor.isStalled,
            isSustaining: isSustaining,
            isCapable: coordinator.isCapable,
            hasLargeImport: self.shareTransferHolder.hasLargeBackgroundImportCandidate,
            isPairingRefused: self.shareTransferHolder.isPairingRefused,
            isRunning: coordinator.isRunning,
            lastOutcome: coordinator.lastOutcome,
            awaitingMarkConfirmation: self.appConfig.awaitingMarkConfirmation
        )
    }

    private var isPresentingRemoveConfirm: Binding<Bool> {
        Binding(
            get: { self.pendingRemoveItem != nil },
            set: { if !$0 { self.pendingRemoveItem = nil } }
        )
    }

    private var isPresentingCancelConfirm: Binding<Bool> {
        Binding(
            get: { self.pendingCancelItem != nil },
            set: { if !$0 { self.pendingCancelItem = nil } }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SourceDetailBlock(title: SourceVocabulary.whatItAddsTitle) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(SourceVocabulary.importerWhatItAdds)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityFocused(self.$sectionFocused)

                        // The picker is the way in; a drop onto this pane is the shortcut, never the only path.
                        self.pickRow(
                            title: SourceVocabulary.importFilesRow,
                            detail: nil,
                            systemImage: "folder",
                            hint: SourceVocabulary.importFilesHint,
                            identifier: "import.pickFiles"
                        ) {
                            self.isPickingFiles = true
                        }
                        if self.canOpenJournal {
                            self.pickRow(
                                title: AppStrings.ios_app_moreimportsrow(),
                                detail: AppStrings.ios_app_importmoreimportsdetail(),
                                systemImage: "square.and.arrow.down.on.square",
                                hint: AppStrings.ios_app_moreimportshint(),
                                identifier: "import.moreImports"
                            ) {
                                self.pendingJournalOpen?.open(path: Self.journalImportPath)
                            }
                        }
                        self.screenshotsLine
                        self.intakeLine
                    }
                }

                SourceIntakeFacts(source: .imports)

                if !self.reviewItems.isEmpty {
                    self.waitingForReviewSection
                }

                if let coordinator = self.importBackgroundUploadCoordinator,
                   self.backgroundUploadCardState != .hidden
                {
                    ImportBackgroundUploadCard(
                        coordinator: coordinator,
                        state: self.backgroundUploadCardState
                    )
                }

                if !self.onDeviceItems.isEmpty {
                    self.onThisDeviceSection
                }

                self.recentSection
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding(ShellMetrics.screenMargin)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if self.isDropTargeted {
                ShellMetrics.cardShape
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: InAppImport.acceptedContentTypes, isTargeted: self.$isDropTargeted) { providers in
            guard self.intake != .working else { return false }
            self.take { queue in
                await InAppImport.accept(itemProviders: providers, queue: queue)
            }
            return true
        }
        .fileImporter(
            isPresented: self.$isPickingFiles,
            allowedContentTypes: InAppImport.acceptedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                self.take { queue in
                    await InAppImport.accept(fileURLs: urls, queue: queue)
                }
            case .failure:
                self.finish(ShareImportFailure.unreadable.message)
            }
        }
        .confirmationDialog(
            self.pendingRemoveItem.map(ImportRemoveDialogPresentation.title(for:)) ?? "",
            isPresented: self.isPresentingRemoveConfirm,
            titleVisibility: .visible,
            presenting: self.pendingRemoveItem
        ) { item in
            Button(AppStrings.ios_app_importremoveaction(), role: .destructive) {
                self.pendingRemoveItem = nil
                Task {
                    await self.shareTransferHolder.dropShare(itemID: item.id)
                }
            }
            .accessibilityIdentifier("import.remove.confirm")

            Button(AppStrings.ios_app_importremovecancel(), role: .cancel) {
                self.pendingRemoveItem = nil
            }
        } message: { item in
            Text(ImportRemoveDialogPresentation.body(for: item))
        }
        .confirmationDialog(
            self.pendingCancelItem.map(ImportCancelDialogPresentation.title(for:)) ?? "",
            isPresented: self.isPresentingCancelConfirm,
            titleVisibility: .visible,
            presenting: self.pendingCancelItem
        ) { item in
            Button(AppStrings.ios_app_importcancelconfirm(), role: .destructive) {
                self.pendingCancelItem = nil
                Task {
                    await self.shareTransferHolder.dropShare(itemID: item.id)
                }
            }
            .accessibilityIdentifier("import.cancel.confirm")

            Button(AppStrings.ios_app_importcancelkeep(), role: .cancel) {
                self.pendingCancelItem = nil
            }
        } message: { _ in
            Text(ImportCancelDialogPresentation.body)
        }
        .onAppear {
            self.now = Date()
            self.shareImportStore.reloadRecentReceiptsFromDisk()
            Task {
                await self.shareTransferHolder.refreshActiveItems()
                await self.shareTransferHolder.reconcileReadyToReview(
                    localPort: self.tunnelManager.activeConnection?.port,
                    instanceID: self.appConfig.deviceID,
                    isPaired: self.appConfig.isPaired,
                    markConfirmed: self.appConfig.journalSendConfirmed
                )
            }
        }
        .onChange(of: self.pendingJournalOpen?.dismissCount) { _, _ in
            self.sectionFocused = true
            Task {
                await self.shareTransferHolder.refreshActiveItems()
            }
        }
        .task {
            await refreshNowPeriodically { self.now = Date() }
        }
        .background(Color.deckGround.ignoresSafeArea())
        .navigationTitle(SourceVocabulary.importTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("shell.pane.import")
    }

    // MARK: - Waiting for your review

    private var waitingForReviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppStrings.ios_app_importwaitingforreviewheading())
                .font(ShellFont.sectionTitle)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("import.section.waitingForReview")

            ForEach(Array(self.reviewItems.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider()
                }
                self.reviewRow(item)
            }
        }
        .padding(ShellMetrics.surfacePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.deckSurface, in: ShellMetrics.cardShape)
        .overlay {
            ShellMetrics.cardShape
                .stroke(Color.solOrange.opacity(0.65), lineWidth: 1.5)
        }
    }

    private func reviewRow(_ item: ShareImportActiveItem) -> some View {
        let itemID = item.id.uuidString.lowercased()
        let isExpired: Bool
        let detail: String
        let statusWord: String
        let markerSignal: HomeImportTileSignal
        let statusColor: Color
        switch item.phase {
        case .readyToReview(let kind, _):
            isExpired = false
            detail = kind == "body_confirmation_required"
                ? AppStrings.ios_app_importreviewdetailexpiry()
                : AppStrings.ios_app_importreviewdetail()
            statusWord = AppStrings.ios_app_importtilereadytoreview()
            markerSignal = .readyToReview(detail: item.filename)
            statusColor = Color.solOrangeAdaptive
        case .reviewExpired:
            isExpired = true
            detail = AppStrings.ios_app_importreviewexpired()
            statusWord = AppStrings.ios_app_importexpired()
            markerSignal = .waiting(detail: item.filename)
            statusColor = .secondary
        default:
            isExpired = false
            detail = AppStrings.ios_app_importreviewdetail()
            statusWord = AppStrings.ios_app_importtilereadytoreview()
            markerSignal = .readyToReview(detail: item.filename)
            statusColor = Color.solOrangeAdaptive
        }

        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("import.review.row.\(itemID)")
                HStack(spacing: 6) {
                    HomeImportStateMarker(signal: markerSignal)
                    Text(statusWord)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(statusColor)
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            self.actionButtonsLayout {
                if isExpired {
                    Button {
                        Task {
                            _ = await self.shareTransferHolder.sendAgain(itemID: item.id)
                            await self.foregroundDrainGate.requestDrain()
                        }
                    } label: {
                        Text(AppStrings.ios_app_importsendagainaction())
                            .frame(maxWidth: self.dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 44)
                    }
                    .buttonStyle(BrandProminentButtonStyle())
                    .accessibilityLabel(AppStrings.ios_app_importsendagainactionlabel(item.filename))
                    .accessibilityIdentifier("import.review.sendAgain.\(itemID)")
                } else if case .readyToReview(_, let importID) = item.phase,
                          let path = ShareImportID.detailPath(for: importID)
                {
                    Button {
                        self.pendingJournalOpen?.open(path: path)
                    } label: {
                        Text(AppStrings.ios_app_importreviewaction())
                            .frame(maxWidth: self.dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 44)
                    }
                    .buttonStyle(BrandProminentButtonStyle())
                    .disabled(!self.canOpenJournal)
                    .accessibilityLabel(AppStrings.ios_app_importreviewactionlabel(item.filename))
                    .accessibilityIdentifier("import.review.open.\(itemID)")
                }

                Button {
                    self.pendingRemoveItem = item
                } label: {
                    Text(AppStrings.ios_app_importremoveaction())
                        .frame(maxWidth: self.dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 44)
                }
                .buttonStyle(BrandQuietButtonStyle())
                .accessibilityLabel(AppStrings.ios_app_importremoveactionlabel(item.filename))
                .accessibilityIdentifier("import.review.remove.\(itemID)")
            }
        }
    }

    // MARK: - On this device

    private var onThisDeviceSection: some View {
        SourceDetailBlock(
            title: SourceVocabulary.onThisPhone,
            titleIdentifier: "import.section.onThisDevice"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if let holdLine = self.queueHoldLine {
                    Text(holdLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("import.onDevice.holdLine")
                }

                ForEach(Array(self.onDeviceItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider()
                    }
                    self.onDeviceRow(item)
                }
            }
        }
    }

    private func onDeviceRow(_ item: ShareImportActiveItem) -> some View {
        let itemID = item.id.uuidString.lowercased()
        let resumablePresentation = ImportRowProgressPresentation.build(for: item)
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.filename)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("import.onDevice.row.\(itemID)")

                if let presentation = resumablePresentation {
                    let markerSignal: HomeImportTileSignal = switch presentation.kind {
                    case .sending: .sending(detail: item.filename)
                    case .checking: .checking(detail: item.filename)
                    case .paused: .paused(detail: item.filename)
                    }
                    let tint: Color = presentation.kind == .paused ? .secondary : Color.solOrangeAdaptive
                    HStack(spacing: 6) {
                        HomeImportStateMarker(signal: markerSignal)
                        Text(presentation.statusWord)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(tint)
                    }
                    ProgressView(value: presentation.fraction, total: 1.0)
                        .tint(tint)
                        .padding(.vertical, 2)
                        .accessibilityHidden(true)
                    Text(presentation.detailLine)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("import.onDevice.progress.\(itemID)")
                } else {
                    switch item.phase {
                    case .sending:
                        HStack(spacing: 6) {
                            HomeImportStateMarker(signal: .sending(detail: item.filename))
                            Text(AppStrings.ios_app_sending())
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.solOrangeAdaptive)
                        }
                        Text(AppStrings.ios_app_importsendingdetail())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                    case .waiting:
                        HStack(spacing: 6) {
                            HomeImportStateMarker(signal: .waiting(detail: item.filename))
                            Text(AppStrings.ios_app_importtilewaiting())
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Text(AppStrings.ios_app_importwaitingdetail())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                    case .needsAttention(_, let reason):
                        HStack(spacing: 6) {
                            HomeImportStateMarker(signal: .needsAttention(detail: item.filename))
                            Text(AppStrings.ios_transfer_needsattention())
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.red)
                        }
                        Text(reason)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                    case .readyToReview, .reviewExpired:
                        EmptyView()
                    }
                }
            }

            if resumablePresentation != nil {
                self.actionButtonsLayout {
                    Button {
                        self.pendingCancelItem = item
                    } label: {
                        Text(AppStrings.ios_app_importcancelaction())
                            .frame(maxWidth: self.dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 44)
                    }
                    .buttonStyle(BrandQuietButtonStyle())
                    .accessibilityLabel(AppStrings.ios_app_importcancelactionlabel(item.filename))
                    .accessibilityIdentifier("import.onDevice.cancel.\(itemID)")
                }
            } else {
                switch item.phase {
                case .sending:
                    // No buttons while actively uploading a small non-resumable file.
                    EmptyView()
                case .waiting:
                    self.actionButtonsLayout {
                        Button {
                            self.pendingRemoveItem = item
                        } label: {
                            Text(AppStrings.ios_app_importremoveaction())
                                .frame(maxWidth: self.dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 44)
                        }
                        .buttonStyle(BrandQuietButtonStyle())
                        .accessibilityLabel(AppStrings.ios_app_importremoveactionlabel(item.filename))
                        .accessibilityIdentifier("import.onDevice.remove.\(itemID)")
                    }
                case .needsAttention(let retryable, _):
                    self.actionButtonsLayout {
                        if retryable && !item.isUnadopted {
                            Button {
                                Task {
                                    _ = await self.shareTransferHolder.retryShare(itemID: item.id)
                                    await self.foregroundDrainGate.requestDrain()
                                }
                            } label: {
                                Text(AppStrings.ios_app_trynow())
                                    .frame(maxWidth: self.dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 44)
                            }
                            .buttonStyle(BrandProminentButtonStyle())
                            .accessibilityLabel(AppStrings.ios_app_importtrynowactionlabel(item.filename))
                            .accessibilityIdentifier("import.onDevice.tryNow.\(itemID)")
                        }
                        Button {
                            self.pendingRemoveItem = item
                        } label: {
                            Text(AppStrings.ios_app_importremoveaction())
                                .frame(maxWidth: self.dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 44)
                        }
                        .buttonStyle(BrandQuietButtonStyle())
                        .accessibilityLabel(AppStrings.ios_app_importremoveactionlabel(item.filename))
                        .accessibilityIdentifier("import.onDevice.remove.\(itemID)")
                    }
                case .readyToReview, .reviewExpired:
                    EmptyView()
                }
            }
        }
    }

    // MARK: - Recent (24h, max 5)

    private var recentSection: some View {
        let receipts = self.recentReceipts
        return SourceDetailBlock(
            title: AppStrings.ios_app_recent(),
            titleIdentifier: "import.section.recent"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if receipts.isEmpty {
                    Text(AppStrings.ios_app_importrecentempty())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("import.recent.empty")
                } else {
                    ForEach(Array(receipts.enumerated()), id: \.element.id) { index, receipt in
                        if index > 0 {
                            Divider()
                        }
                        self.recentReceiptRow(receipt)
                    }
                }

                if self.canOpenJournal {
                    Button {
                        self.pendingJournalOpen?.open(path: Self.journalImportPath)
                    } label: {
                        Text(AppStrings.ios_app_importallhistory())
                            .font(.subheadline)
                            .underline()
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("import.recent.allHistory")
                }
            }
        }
    }

    @ViewBuilder
    private func recentReceiptRow(_ receipt: ImportRecentReceipt) -> some View {
        let relative = ImportRecentTimeFormatter.relative(from: receipt.deliveredAt, now: self.now)
        let detailText = AppStrings.ios_app_importrecentdetail(relative)
        if let path = receipt.journalDetailPath {
            Button {
                self.pendingJournalOpen?.open(path: path)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(receipt.filename)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(Color.solSavedGreen)
                                .accessibilityHidden(true)
                            Text(detailText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppStrings.ios_app_importrecentrowlabelopen(receipt.filename, relative))
            .accessibilityIdentifier("import.recent.row.\(receipt.id)")
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(receipt.filename)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.solSavedGreen)
                        .accessibilityHidden(true)
                    Text(detailText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(AppStrings.ios_app_importrecentrowlabel(receipt.filename, relative))
            .accessibilityIdentifier("import.recent.row.\(receipt.id)")
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func actionButtonsLayout<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if self.dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        } else {
            HStack(spacing: 10) {
                content()
            }
        }
    }

    /// Open once the source has been on, including when photo access later needs attention.
    /// Off, and never set up, both say set up.
    private var screenshotsOpens: Bool {
        guard let snapshot = self.screenshotsSourceHandle?.source.snapshot else { return false }
        let needsAttention = snapshot.view.sourceState == .needsAttention
        return snapshot.everOn && (snapshot.enabled || needsAttention)
    }

    private var screenshotsLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ScreenshotsVocabulary.importLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            NavigationLink(value: ShellDestination.source(.screenshots)) {
                HStack {
                    Text(ScreenshotsVocabulary.importAction(isOn: self.screenshotsOpens))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("import.screenshots")
        }
    }

    private func pickRow(
        title: String,
        detail: String?,
        systemImage: String,
        hint: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.solOrangeAdaptive)
                    .frame(width: 24, alignment: .center)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(self.intake == .working)
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var intakeLine: some View {
        switch self.intake {
        case .idle:
            EmptyView()
        case .working:
            ProgressView()
                .accessibilityLabel(SourceVocabulary.shareSendingProgress)
                .accessibilityIdentifier("import.intake.working")
        case .finished(let text):
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("import.intake.outcome")
        }
    }

    /// Lands the items through the share route, says how it went, then wakes the same drain a
    /// share does when the app comes forward, so the items move on toward the journal.
    private func take(_ accept: @escaping (ShareImportStore) async -> [ShareImportResult]) {
        self.intake = .working
        let queue = self.shareImportStore
        let drainGate = self.foregroundDrainGate
        Task {
            let results = await accept(queue)
            if let text = InAppImport.outcomeText(for: results) {
                self.finish(text)
            } else {
                self.intake = .idle
            }
            await drainGate.requestDrain()
            await self.shareTransferHolder.refreshActiveItems()
        }
    }

    private func finish(_ text: String) {
        self.intake = .finished(text)
        AccessibilityNotification.Announcement(text).post()
    }
}

private struct ImportBackgroundUploadCard: View {
    let coordinator: ImportBackgroundUploadCoordinator
    let state: ImportBackgroundUploadCoordinator.CardState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch self.state {
            case .hidden:
                EmptyView()
            case .idle:
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.up.circle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.solOrangeAdaptive)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppStrings.ios_app_importbgcardheadline())
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(AppStrings.ios_app_importbgcardbody())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                let unavailableReason: String? = {
                    if case .unavailable(let reason) = self.coordinator.availability { return reason }
                    return nil
                }()
                Button {
                    self.coordinator.submit()
                } label: {
                    Text(AppStrings.ios_app_importbgbutton())
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(BrandProminentButtonStyle())
                .disabled(unavailableReason != nil)
                .accessibilityIdentifier("import.backgroundUpload.start")

                if let unavailableReason {
                    Text(unavailableReason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("import.backgroundUpload.unavailable")
                }

            case .inProgress:
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.solOrangeAdaptive)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppStrings.ios_app_importbgcardheadline())
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(AppStrings.ios_app_importbginprogress())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("import.backgroundUpload.inProgress")

            case .completed:
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.solSavedGreen)
                        .accessibilityHidden(true)
                    Text(AppStrings.ios_app_importbgcompleted())
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    self.dismissButton
                }
                .accessibilityIdentifier("import.backgroundUpload.completed")

            case .paused:
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "pause.circle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(AppStrings.ios_app_importbgpaused())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    self.dismissButton
                }
                .accessibilityIdentifier("import.backgroundUpload.paused")
            }
        }
        .padding(ShellMetrics.surfacePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.deckSurface, in: ShellMetrics.cardShape)
        .overlay {
            ShellMetrics.cardShape.stroke(
                self.state == .idle || self.state == .inProgress ? Color.solOrange.opacity(0.45) : Color.deckHairline,
                lineWidth: self.state == .idle || self.state == .inProgress ? 1 : 0.5
            )
        }
    }

    private var dismissButton: some View {
        Button {
            self.coordinator.dismissOutcome()
        } label: {
            Image(systemName: "xmark")
                .font(.footnote.weight(.bold))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(BrandQuietButtonStyle())
        .accessibilityLabel(AppStrings.ios_app_dismiss())
        .accessibilityIdentifier("import.backgroundUpload.dismiss")
    }
}

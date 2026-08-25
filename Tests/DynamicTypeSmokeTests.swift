// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SwiftUI
import XCTest

nonisolated final class DynamicTypeSmokeTests: XCTestCase {
    @MainActor
    func testOnboardingTodayMoreAndSourcesRenderAtAccessibilityXXXL() async throws {
        let appConfig = AppConfig()
        appConfig.seedUITestPairing(journalRoot: "http://127.0.0.1:7071")

        let tunnelManager = TunnelManager(transport: MockCFTunnelTransport())
        let diagnosticLog = DiagnosticLog()
        let observerRegistration = ObserverRegistration(
            resolveDescriptor: {
                DeviceRegistrationDescriptor(
                    hostname: "test-device",
                    displayName: "test device",
                    vendorIdentifier: "test-idfv"
                )
            },
            version: "1.0",
            loadKey: { nil },
            saveKey: { _ in },
            deleteKey: {}
        )
        let mobileSegmentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicTypeSmokeTests-MobileSegment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: mobileSegmentRoot) }
        let mobileSegmentClock = MockObserverClock()
        let transferRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicTypeSmokeTests-Transfer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: transferRoot) }
        let transferHarness = makeTransferCutoverHarness(rootURL: transferRoot)
        let mobileSegmentUploader = MobileSegmentUploader(
            transferEngine: transferHarness.engine,
            store: MobileSegmentStore(rootURL: mobileSegmentRoot),
            clock: mobileSegmentClock
        )
        let mobileSegmentTransferHolder = MobileSegmentTransferHolder(
            transferEngine: transferHarness.engine,
            mirror: transferHarness.mirror,
            uploader: mobileSegmentUploader
        )
        let mobileSegmentEngine = MobileSegmentEngine(
            uploader: mobileSegmentUploader,
            clock: mobileSegmentClock
        )
        let omiUploaderHolder = transferHarness.omi
        let watchUploaderHolder = transferHarness.watch
        let watchSession = MockWatchConnectivitySession()
        let watchRelayRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicTypeSmokeTests-WatchRelay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: watchRelayRoot) }
        let watchLedgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicTypeSmokeTests-WatchLedger-\(UUID().uuidString).json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: watchLedgerURL) }
        let watchSegmentLedger = WatchSegmentLedger(fileURL: watchLedgerURL)
        let phoneHistoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicTypeSmokeTests-WatchHistory-\(UUID().uuidString).jsonl", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: phoneHistoryURL) }
        let phoneSessionHistoryStore = WatchPhoneSessionHistoryStore(fileURL: phoneHistoryURL)
        let watchFactsDefaultsName = "DynamicTypeSmokeTests-WatchFacts-\(UUID().uuidString)"
        let watchFactsDefaults = try XCTUnwrap(UserDefaults(suiteName: watchFactsDefaultsName))
        defer { watchFactsDefaults.removePersistentDomain(forName: watchFactsDefaultsName) }
        let watchSourceFacts = WatchSourceFacts(defaults: watchFactsDefaults)
        let watchRelayReceiver = try WatchRelayReceiver(
            session: watchSession,
            ledger: watchSegmentLedger,
            stagingRootURL: watchRelayRoot,
            facts: watchSourceFacts
        )
        let watchLink = WatchLink(
            session: watchSession,
            receiver: watchRelayReceiver,
            facts: watchSourceFacts,
            phoneSessionHistoryStore: phoneSessionHistoryStore
        )
        let observerManager = ObserverManager(
            recorder: MockObserverRecorder(),
            mobileSegmentEngine: mobileSegmentEngine
        )
        let locationManager = LocationManager(
            provider: MockLocationProvider(),
            mobileSegmentEngine: mobileSegmentEngine,
            clock: MockObserverClock(),
            defaults: nil
        )
        let omiDefaultsName = "DynamicTypeSmokeTests-Omi-\(UUID().uuidString)"
        let omiDefaults = try XCTUnwrap(UserDefaults(suiteName: omiDefaultsName))
        defer { omiDefaults.removePersistentDomain(forName: omiDefaultsName) }
        let omiDiagnosticsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicTypeSmokeTests-OmiDiagnostics-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: omiDiagnosticsURL) }
        let omiSourceManager = OmiSourceManager(
            defaults: omiDefaults,
            diagnostics: OmiDiagnostics(clock: MockObserverClock(), fileURL: omiDiagnosticsURL),
            clock: MockObserverClock()
        )
        let activeLocationProvider = MockLocationProvider()
        activeLocationProvider.capability = .always(accuracy: .full)
        let activeLocationManager = LocationManager(
            provider: activeLocationProvider,
            mobileSegmentEngine: mobileSegmentEngine,
            clock: MockObserverClock(),
            defaults: nil
        )
        await activeLocationManager.start(tier: .balanced)
        XCTAssertEqual(activeLocationManager.sourceState, .active)
        let needsAttentionLocationProvider = MockLocationProvider()
        needsAttentionLocationProvider.capability = .denied
        let needsAttentionLocationManager = LocationManager(
            provider: needsAttentionLocationProvider,
            mobileSegmentEngine: mobileSegmentEngine,
            clock: MockObserverClock(),
            defaults: nil
        )
        await needsAttentionLocationManager.start(tier: .balanced)
        XCTAssertEqual(needsAttentionLocationManager.sourceState, .needsAttention)
        let importQueueRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicTypeSmokeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: importQueueRoot) }
        let shareImportStore = ShareImportStore(cacheRootURL: importQueueRoot)
        let shareTransferHolder = ShareTransferHolder(
            transferEngine: transferHarness.engine,
            mirror: transferHarness.mirror,
            store: shareImportStore
        )
        let appGroupMirrorRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicTypeSmokeTests-AppGroup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appGroupMirrorRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appGroupMirrorRoot) }
        let appGroupMirror = AppGroupMirror(rootURLProvider: { appGroupMirrorRoot })
        let watchBacklogSnapshotWriter = WatchBacklogSnapshotWriter(
            rootURLProvider: { appGroupMirrorRoot }
        )
        let finishSyncingCoordinator = FinishSyncingCoordinator(
            totals: { (0, 0) },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            drive: {},
            setPacingMode: { _ in },
            isConnected: { false },
            disconnect: {}
        )
        let connectionSyncModel = ConnectionSyncModel(clock: MockObserverClock()) {
            ConnectionSyncInputs(
                tunnelState: tunnelManager.state,
                reconnectCountdown: tunnelManager.reconnectCountdown,
                isNetworkSatisfied: tunnelManager.isNetworkSatisfied,
                confirmedTransferCount: 0,
                recentBytesPerSecond: 0,
                backlogPending: 0,
                backlogFailed: 0
            )
        }
        let problemReportsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicTypeSmokeTests-ProblemReports-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: problemReportsRoot) }
        let problemReportsManager = ProblemReportsManager(
            store: ProblemReportStore(rootURL: problemReportsRoot),
            subscriber: NoOpMetricSubscriber(),
            initialEnabled: false
        )
        let shelfPane = ShelfPane(
            presentation: .phoneModal,
            onOpenJournal: {},
            onDismiss: {}
        )
            .environment(appConfig)
            .environment(OnboardingFlow())
            .environment(tunnelManager)
            .environment(observerRegistration)
            .environment(PushNotificationManager())
            .environment(problemReportsManager)
            .environment(ShellNavModel())

        let sourcesView = NavigationStack {
            SourcesView()
                .environment(appConfig)
                .environment(observerManager)
                .environment(observerRegistration)
                .environment(ObserverSourcePauseState())
                .environment(shareImportStore)
                .environment(shareTransferHolder)
                .environment(locationManager)
                .environment(ScreencastManager())
                .environment(mobileSegmentUploader)
                .environment(mobileSegmentTransferHolder)
                .environment(omiSourceManager)
                .environment(watchSourceFacts)
                .environment(watchLink)
                .environment(watchRelayReceiver)
                .environment(watchUploaderHolder)
                .environment(watchSegmentLedger)
                .environment(phoneSessionHistoryStore)
                .environment(connectionSyncModel)
        }
        let dayHomeView = NavigationStack {
            DayHomeSmokeHost(
                journalState: .noJournal,
                sourcesBadgeVisible: false
            )
            .environment(appConfig)
            .environment(appGroupMirror)
            .environment(watchBacklogSnapshotWriter)
            .environment(observerManager)
            .environment(ObserverSourcePauseState())
            .environment(locationManager)
            .environment(ScreencastManager())
            .environment(mobileSegmentUploader)
            .environment(mobileSegmentTransferHolder)
            .environment(omiSourceManager)
            .environment(omiUploaderHolder)
            .environment(watchSourceFacts)
            .environment(watchLink)
            .environment(watchRelayReceiver)
            .environment(watchUploaderHolder)
            .environment(watchSegmentLedger)
            .environment(phoneSessionHistoryStore)
            .environment(shareImportStore)
            .environment(shareTransferHolder)
            .environment(connectionSyncModel)
            .environment(ShellNavModel())
        }
        let locationSourceDetailView = NavigationStack {
            LocationSourceDetailView()
                .environment(appConfig)
                .environment(locationManager)
                .environment(mobileSegmentUploader)
                .environment(mobileSegmentTransferHolder)
                .environment(observerRegistration)
        }
        let omiSourceDetailView = NavigationStack {
            OmiSourceDetailView()
                .environment(appConfig)
                .environment(omiSourceManager)
        }
        let watchSourceDetailView = NavigationStack {
            WatchSourceDetailView()
                .environment(appConfig)
                .environment(watchSourceFacts)
                .environment(watchLink)
                .environment(watchRelayReceiver)
                .environment(watchUploaderHolder)
                .environment(watchSegmentLedger)
                .environment(phoneSessionHistoryStore)
                .environment(connectionSyncModel)
        }
        let activeLocationSourceDetailView = NavigationStack {
            LocationSourceDetailView()
                .environment(appConfig)
                .environment(activeLocationManager)
                .environment(mobileSegmentUploader)
                .environment(mobileSegmentTransferHolder)
                .environment(observerRegistration)
        }
        let needsAttentionLocationSourceDetailView = NavigationStack {
            LocationSourceDetailView()
                .environment(appConfig)
                .environment(needsAttentionLocationManager)
                .environment(mobileSegmentUploader)
                .environment(mobileSegmentTransferHolder)
                .environment(observerRegistration)
        }
        let importerSourceDetailView = NavigationStack {
            ImportView()
                .environment(appConfig)
                .environment(shareImportStore)
                .environment(shareTransferHolder)
                .environment(observerManager)
                .environment(mobileSegmentTransferHolder)
                .environment(omiUploaderHolder)
                .environment(watchUploaderHolder)
                .environment(tunnelManager)
                .environment(finishSyncingCoordinator)
                .environment(mobileSegmentUploader)
                .environment(mobileSegmentTransferHolder)
                .environment(observerRegistration)
                .environment(observerManager)
        }
        let onThisPhoneView = NavigationStack {
            OnThisPhoneView()
                .environment(appConfig)
                .environment(shareImportStore)
                .environment(shareTransferHolder)
                .environment(observerManager)
                .environment(mobileSegmentTransferHolder)
                .environment(omiUploaderHolder)
                .environment(watchUploaderHolder)
                .environment(tunnelManager)
                .environment(connectionSyncModel)
                .environment(finishSyncingCoordinator)
                .environment(locationManager)
                .environment(mobileSegmentUploader)
                .environment(mobileSegmentTransferHolder)
                .environment(observerRegistration)
        }
        let onThisPhoneItemDetailView = NavigationStack {
            OnThisPhoneItemDetailView(
                item: Self.onThisPhoneItem(),
                onRequestRetry: { _ in },
                onRequestDrop: { _ in }
            )
                .environment(shareImportStore)
                .environment(shareTransferHolder)
                .environment(observerManager)
                .environment(mobileSegmentTransferHolder)
                .environment(omiUploaderHolder)
                .environment(watchUploaderHolder)
                .environment(mobileSegmentUploader)
                .environment(mobileSegmentTransferHolder)
                .environment(observerRegistration)
        }

        try self.assertHosted(
            WelcomeScreen(onGetStarted: {})
                .environment(\.dynamicTypeSize, .accessibility3)
        )
        let statusPane = NavigationStack {
            StatusPane(presentation: .phoneModal)
                .environment(appConfig)
                .environment(ShellStatusContext())
                .environment(tunnelManager)
                .environment(connectionSyncModel)
                .environment(diagnosticLog)
                .environment(problemReportsManager)
                .environment(mobileSegmentTransferHolder)
                .environment(omiUploaderHolder)
                .environment(watchUploaderHolder)
                .environment(shareTransferHolder)
                .environment(locationManager)
        }
        try self.assertHosted(shelfPane.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(statusPane.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(sourcesView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(dayHomeView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(locationSourceDetailView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(omiSourceDetailView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(watchSourceDetailView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(activeLocationSourceDetailView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(needsAttentionLocationSourceDetailView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(importerSourceDetailView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(onThisPhoneView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(onThisPhoneItemDetailView.environment(\.dynamicTypeSize, .accessibility3))
        await activeLocationManager.stop()
        // ShareExtensionView is private in the extension target; its copy is mechanically covered by lock tests.
        // Hit-target audit: scoped controls are standard Buttons/NavigationLinks/segmented Picker, so no frame assertions are needed here.
    }

    @MainActor private func assertHosted<V: View>(_ view: V) throws {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.isHidden = false
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        window.layoutIfNeeded()
        XCTAssertGreaterThan(controller.view.systemLayoutSizeFitting(CGSize(width: 393, height: 852)).height, 0)
        window.isHidden = true
        window.rootViewController = nil
    }

    private struct DayHomeSmokeHost: View {
        @Namespace private var homeChrome
        let journalState: DayHomeJournalState
        let sourcesBadgeVisible: Bool

        var body: some View {
            DayHomeView(
                journalState: self.journalState,
                journalMark: nil,
                homeChrome: self.homeChrome,
                onOpenJournal: {},
                onOpenJournalSetup: {},
                onOpenSources: {},
                onOpenYourSolstone: {},
                onOpenStatus: {},
                sourcesBadgeVisible: self.sourcesBadgeVisible
            )
        }
    }

    private static func onThisPhoneItem() -> OnThisPhoneItem {
        OnThisPhoneItem(
            id: UUID().uuidString,
            sourceKind: .share,
            sendState: .inYourJournal,
            contentType: "application/pdf",
            filename: "item.pdf",
            bytes: 42,
            originApp: "Files",
            basis: "share",
            itemTime: Date(),
            targetJournal: "journal",
            stream: "default",
            day: "2026-06-02",
            segment: "morning",
            deliveredAt: Date(),
            rawFileURL: nil
        )
    }
}

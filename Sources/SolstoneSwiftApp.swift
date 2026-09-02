// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppIntents
import UIKit
import Security
import SwiftUI
import SPLTunnel
import os

@main
struct SolstoneSwiftApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appConfig: AppConfig
    @State private var appGroupMirror: AppGroupMirror
    @State private var watchBacklogSnapshotWriter: WatchBacklogSnapshotWriter
    @State private var onboardingFlow: OnboardingFlow
    @State private var tunnelManager: TunnelManager
    @State private var connectionSyncModel: ConnectionSyncModel
    @State private var diagnosticLog: DiagnosticLog
    @State private var problemReportsManager: ProblemReportsManager
    @State private var mobileSegmentTransferHolder: MobileSegmentTransferHolder
    @State private var omiUploaderHolder: OmiUploaderHolder
    @State private var watchUploaderHolder: WatchUploaderHolder
    @State private var watchSourceFacts: WatchSourceFacts
    @State private var transferEndpointResolver: LoopbackTransferEndpointResolver
    @State private var transferStatusMirror: TransferStatusMirror
    @State private var transferConditionsSource: TransferConditionsSource
    @State private var transferEngine: TransferEngine
    @State private var transferEnqueuer: ObserverAudioTransferEnqueuer
    @State private var shareImportStore: ShareImportStore
    @State private var shareTransferHolder: ShareTransferHolder
    @State private var watchSegmentDrain: WatchSegmentDrain?
    @State private var watchRelayReceiver: WatchRelayReceiver?
    @State private var watchSegmentLedger: WatchSegmentLedger
    @State private var phoneSessionHistoryStore: WatchPhoneSessionHistoryStore
    @State private var mobileSegmentUploader: MobileSegmentUploader
    @State private var mobileSegmentEngine: MobileSegmentEngine
    @State private var locationManager: LocationManager
    @State private var screencastManager: ScreencastManager
    @State private var observerManager: ObserverManager
    @State private var watchLink: WatchLink
    @State private var pendingObserverCommand = PendingObserverCommandState()
    @State private var pendingJournalOpen = PendingJournalOpenState()
    @State private var pairingHandoff = PairingHandoffState()
    @State private var shellNav = ShellNavModel()
    @State private var omiSourceManager: OmiSourceManager
    @State private var launchCaptureCommitCoordinator: OmiLaunchCaptureCommitCoordinator
    @State private var finishSyncingCoordinator: FinishSyncingCoordinator
    @State private var foregroundDrainGate: ForegroundDrainGate
    @State private var launchMaintenanceCoordinator: LaunchMaintenanceCoordinator
    @State private var backgroundDrainTask: Task<Void, Never>?
    @State private var didBootstrapTransfer = false
    @State private var integrationObserverStartTask: Task<Void, Never>?
    @State private var integrationObserverStopTask: Task<Void, Never>?
    @State private var didAutoStartIntegrationObserver = false
    @State private var didAutoStopIntegrationObserver = false
#if DEBUG && targetEnvironment(simulator)
    @State private var integrationGateDriver: IntegrationGateDriver?
#endif
    @Environment(\.scenePhase) private var scenePhase

    private static var isIntegrationTest: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--integration-test")
#else
        false
#endif
    }

    private static var isIntegrationTestLive: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--integration-test-live")
#else
        false
#endif
    }

    private static var isIntegrationMode: Bool {
        Self.isIntegrationTest || Self.isIntegrationTestLive
    }

    private static var isUITest: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-test")
#else
        false
#endif
    }

    private static var isUnitTest: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment.keys.contains {
            $0.lowercased() == "xctestconfigurationfilepath"
        }
#else
        false
#endif
    }

    static func shouldRunLaunchMaintenance(scenePhase: ScenePhase) -> Bool {
        guard scenePhase == .active else { return false }
        return !Self.isIntegrationMode && !Self.isUITest && !Self.isUnitTest
    }

    private static func tunnelScenePhase(_ phase: ScenePhase) -> TunnelScenePhase {
        switch phase {
        case .active:
            .active
        case .background:
            .background
        case .inactive:
            .inactive
        @unknown default:
            .inactive
        }
    }

    @MainActor
    static func revalidateThenRequestDrain(
        tunnelManager: TunnelManager,
        requestDrain: () async -> Void
    ) async {
        guard await tunnelManager.revalidateConnectedTunnelForForeground() else { return }
        await requestDrain()
    }

    @MainActor
    static func bootstrapTransfer(
        initialize: () async throws -> Void,
        appGroupRoot: () throws -> URL,
        cachesRootURL: URL?,
        migrate: (URL, URL?) async throws -> Void,
        reconcile: (URL) async throws -> Void,
        reconcileLaunchCapture: (URL) async throws -> Void = { _ in },
        conservativelyGateOmi: () async -> Void = {},
        enableDispatch: () async -> Void,
        openOmiReadiness: () async -> Void,
        reportFailure: (String, (any Error)?) -> Void
    ) async {
        func finishBootstrap() async {
            await enableDispatch()
            await openOmiReadiness()
        }
        do {
            try await initialize()
        } catch {
            reportFailure("start failed", error)
            await openOmiReadiness()
            return
        }
        let rootURL: URL
        do {
            rootURL = try appGroupRoot()
        } catch {
            await conservativelyGateOmi()
            reportFailure("app-group unavailable", error)
            await finishBootstrap()
            return
        }
        do {
            try await migrate(rootURL, cachesRootURL)
        } catch {
            await conservativelyGateOmi()
            reportFailure("migration failed", error)
            await finishBootstrap()
            return
        }
        do {
            try await reconcile(rootURL)
        } catch {
            await conservativelyGateOmi()
            reportFailure("reconciliation failed", error)
            await finishBootstrap()
            return
        }
        do {
            try await reconcileLaunchCapture(rootURL)
        } catch {
            await conservativelyGateOmi()
            reportFailure("launch capture reconciliation failed", error)
            await finishBootstrap()
            return
        }
        await finishBootstrap()
    }

    private static var shouldUseUITestObserverRecorder: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-test-observer-recorder")
            || ProcessInfo.processInfo.arguments.contains("--ui-test-observer-permission-denied")
#else
        false
#endif
    }

    private static var uiTestObserverPermissionGranted: Bool {
#if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--ui-test-observer-permission-denied")
#else
        true
#endif
    }

    private static var integrationObserverTapKind: String? {
#if DEBUG
        guard let tapArgument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--integration-test-observer-tap=") }) else {
            return nil
        }
        return String(tapArgument.dropFirst("--integration-test-observer-tap=".count))
#else
        nil
#endif
    }

    init() {
        SPLLogging.configure(subsystem: "app.solstone.swift")
        ShellFont.applyNavigationBarAppearance()
        Self.purgeLegacyKeychainEntries()
        InnerTLS.purgeOrphanedIdentities()
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--integration-test-onboarding") {
            Self.resetOnboardingIntegrationState()
        }
#endif
        let log = DiagnosticLog()
        let appGroupMirror = AppGroupMirror()
        let watchBacklogSnapshotWriter = WatchBacklogSnapshotWriter()
        let appConfig = AppConfig(appGroupMirror: appGroupMirror)
        let observerClock = SystemObserverClock()
        let onboardingFlow = OnboardingFlow()
        let transport = CFTunnelTransport(appConfig: appConfig)
#if DEBUG
        OnThisPhoneUITestSeeder.runIfRequested()
        ProblemReportsUITestSeeder.runIfRequested()
#endif
        let problemReportStore = ProblemReportStore(diagnosticLog: log)
        let problemReports = ProblemReportsManager(
            store: problemReportStore,
            makeSubscriber: { ingest in
                Self.makeMetricSubscriber(ingest: ingest)
            }
        )
        let mobileSegmentStore: MobileSegmentStore
        let mobileSegmentStorageDisabledReason: String?
        let mobileSegmentMigrationDiagnostics: [String]
        do {
            let appGroupRoot = try AppGroupContainer.rootURL()
            let appGroupMobileSegmentRoot = appGroupRoot
                .appendingPathComponent(MobileSegmentStore.directoryName, isDirectory: true)
            mobileSegmentStore = MobileSegmentStore(rootURL: appGroupMobileSegmentRoot)
            mobileSegmentStorageDisabledReason = nil
            let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            let legacyMobileSegmentRoot = cachesRoot?
                .appendingPathComponent(MobileSegmentStore.directoryName, isDirectory: true)
            if let legacyMobileSegmentRoot {
                mobileSegmentMigrationDiagnostics = mobileSegmentStore.migrateRoot(fromLegacyCachesRoot: legacyMobileSegmentRoot)
            } else {
                mobileSegmentMigrationDiagnostics = []
            }
            Self.applyMagicMomentLaunchGuard(
                mobileSegmentStore: mobileSegmentStore,
                appGroupRootURL: appGroupRoot,
                cachesRootURL: cachesRoot
            )
        } catch {
            let diagnostic = "mobile segment storage unavailable source=app-group"
            Logger(subsystem: "app.solstone.swift", category: "mobile-segment")
                .error("\(diagnostic, privacy: .public)")
            mobileSegmentStore = MobileSegmentStore(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("mobile-segment-unavailable", isDirectory: true)
            )
            mobileSegmentStorageDisabledReason = diagnostic
            mobileSegmentMigrationDiagnostics = []
        }
        let transferEndpointResolver = LoopbackTransferEndpointResolver()
        let transferStatusMirror = TransferStatusMirror()
        let transferConditionsSource = TransferConditionsSource()
        let transferSpool: TransferSpool
        do {
            transferSpool = try TransferSpool()
        } catch {
            let diagnostic = "transfer spool unavailable source=app-group"
            Logger(subsystem: "app.solstone.swift", category: "transfer")
                .error("\(diagnostic, privacy: .public)")
            log.append(category: .upload, severity: .warning, message: "needs attention", detail: diagnostic)
            transferSpool = TransferSpool(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("transfer-unavailable", isDirectory: true)
            )
        }
        let transferEngine = TransferEngine(
            spool: transferSpool,
            transport: TransferTransport(),
            endpointResolver: transferEndpointResolver,
            diagnosticsSink: ObserverAudioTransferDiagnostics.makeSink(diagnosticLog: log),
            statusMirror: transferStatusMirror,
            conditions: transferConditionsSource.provider,
            bodyBuilder: { item, spool in
                if item.manifest.endpoint.destinationKind == .saveThenStart,
                   item.manifest.saveThenStart?.phase != .startPending
                {
                    return try ShareImportSaveBody.build(item: item, spool: spool)
                }
                return try DefaultTransferBodyBuilder.build(item: item, spool: spool)
            }
        )
        let transferEnqueuer = ObserverAudioTransferEnqueuer(engine: transferEngine)
        let mobileSegmentUploader = MobileSegmentUploader(
            transferEngine: transferEngine,
            store: mobileSegmentStore,
            clock: observerClock,
            storageDisabledReason: mobileSegmentStorageDisabledReason
        )
        if mobileSegmentUploader.lastError == nil {
            mobileSegmentUploader.lastError = mobileSegmentMigrationDiagnostics.first
        }
        let mobileSegmentTransferHolder = MobileSegmentTransferHolder(
            transferEngine: transferEngine,
            mirror: transferStatusMirror,
            uploader: mobileSegmentUploader
        )
        let mobileSegmentEngine = MobileSegmentEngine(
            uploader: mobileSegmentUploader,
            clock: observerClock
        )
        let omiUploaderHolder = OmiUploaderHolder(
            transferEngine: transferEngine,
            mirror: transferStatusMirror
        )
        let watchSourceFacts = WatchSourceFacts()
        let watchConnectivitySession = LiveWatchConnectivitySession()
        let watchPipeline = makeWatchPhonePipeline(
            transferEngine: transferEngine,
            transferStatusMirror: transferStatusMirror,
            transferEnqueuer: transferEnqueuer,
            watchConnectivitySession: watchConnectivitySession,
            watchSourceFacts: watchSourceFacts,
            diagnosticLog: log
        )
        let watchUploaderHolder = watchPipeline.watchUploaderHolder
        let watchSegmentDrain = watchPipeline.watchSegmentDrain
        let watchRelayReceiver = watchPipeline.watchRelayReceiver
        let watchSegmentLedger = watchPipeline.watchSegmentLedger
        let phoneSessionHistoryStore = watchPipeline.phoneSessionHistoryStore
        let watchLink = watchPipeline.watchLink
        let shareImportStore = ShareImportStore(
            ledgerDropSink: { droppedCount in
                log.append(
                    category: .upload,
                    severity: .info,
                    message: "share history rotated",
                    detail: "dropped_rows=\(droppedCount)"
                )
            }
        )
        let shareTransferHolder = ShareTransferHolder(
            transferEngine: transferEngine,
            mirror: transferStatusMirror,
            store: shareImportStore
        )
        let tunnel = TunnelManager(
            transport: transport,
            activeLocalTransferCountProvider: {
                confirmedTransferCount(
                    mobileSegment: mobileSegmentTransferHolder,
                    omi: omiUploaderHolder,
                    watch: watchUploaderHolder,
                    share: shareTransferHolder
                )
            },
            diagnosticLog: log
        )
        let connectionSyncModel = ConnectionSyncModel(clock: observerClock) {
            let totals = uploadTotals(
                mobileSegment: mobileSegmentTransferHolder,
                omi: omiUploaderHolder,
                watch: watchUploaderHolder,
                share: shareTransferHolder
            )
            return ConnectionSyncInputs(
                tunnelState: tunnel.state,
                reconnectCountdown: tunnel.reconnectCountdown,
                isNetworkSatisfied: tunnel.isNetworkSatisfied,
                confirmedTransferCount: confirmedTransferCount(
                    mobileSegment: mobileSegmentTransferHolder,
                    omi: omiUploaderHolder,
                    watch: watchUploaderHolder,
                    share: shareTransferHolder
                ),
                recentBytesPerSecond: recentBytesTotal(
                    mobileSegment: mobileSegmentTransferHolder,
                    omi: omiUploaderHolder,
                    watch: watchUploaderHolder,
                    share: shareTransferHolder
                ),
                backlogPending: totals.pending,
                backlogFailed: totals.failed
            )
        }
        let locationManager = LocationManager(mobileSegmentEngine: mobileSegmentEngine)
        let screencastManager = ScreencastManager(
            engine: mobileSegmentEngine,
            uploader: mobileSegmentUploader,
            clock: observerClock
        )
        let observerRecorder = Self.makeObserverRecorder()
        let observerManager = ObserverManager(
            recorder: observerRecorder,
            mobileSegmentEngine: mobileSegmentEngine,
            clock: observerClock
        )
        AppDependencyManager.shared.add(dependency: observerManager)
        AppDependencyManager.shared.add(dependency: observerManager as any ObserverSessionControlling)
        ObserverManagerDependencyRegistrationWitness.recordRegistration(of: observerManager)
        let omiSegmentWriter = OmiSegmentWriter(transferEnqueuer: transferEnqueuer, clock: observerClock)
        let omiSource = makeOmiSourceManager(clock: observerClock, diagnosticLog: log)
        let launchCaptureCommitCoordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: nil,
            engine: transferEngine,
            sourceManager: omiSource
        )
        omiSource.onLaunchCaptureExplicitEnable = { [weak launchCaptureCommitCoordinator] in
            await launchCaptureCommitCoordinator?.resumeAfterExplicitEnable()
        }
        let omiHeardTally = omiSource.heardTally
        omiSegmentWriter.onChunkFinalized = { day, durationS, identity in
            omiHeardTally.record(day: day, durationS: durationS, identity: identity)
        }
        omiSegmentWriter.onWriterFault = { [weak omiSource] in
            omiSource?.noteWriterFault()
        }
        omiSegmentWriter.freezeSegmentMetadata = { [weak omiSource] in
            omiSource?.freezeSegmentMetadata()
        }
        omiSegmentWriter.acknowledgeSegmentMetadata = { [weak omiSource] tokens in
            omiSource?.acknowledgeSegmentMetadata(tokens: tokens)
        }
        omiSegmentWriter.onHandoffDegradation = { detail in
            log.append(
                category: .upload,
                severity: .warning,
                message: "needs attention",
                detail: detail
            )
        }
        omiSource.omiSegmentWriter = omiSegmentWriter
        omiSource.onDecodedSamples = { [weak omiSegmentWriter] samples in
            omiSegmentWriter?.append(samples)
        }
        let finishSyncing = FinishSyncingCoordinator(
            totals: {
                uploadTotals(
                    mobileSegment: mobileSegmentTransferHolder,
                    omi: omiUploaderHolder,
                    watch: watchUploaderHolder,
                    share: shareTransferHolder
                )
            },
            inFlight: {
                uploadInFlight(
                    mobileSegment: mobileSegmentTransferHolder,
                    omi: omiUploaderHolder,
                    watch: watchUploaderHolder,
                    share: shareTransferHolder
                )
            },
            backoff: {
                uploadBackoff(mirror: transferStatusMirror)
            },
            drive: {
                await driveUploadDrain(
                    mobileSegment: mobileSegmentUploader,
                    transferEngine: transferEngine,
                    shareImportStore: shareImportStore,
                    shareTransferHolder: shareTransferHolder,
                    diagnosticLog: log,
                    watchDrain: watchSegmentDrain
                )
            },
            setPacingMode: { mode in
                await transferEngine.setPacingMode(mode)
            },
            isConnected: {
                tunnel.state.isConnected
            },
            disconnect: {
                tunnel.cancelConnect()
                tunnel.cancelReconnect()
                tunnel.stopNetworkMonitoring()
                await tunnel.disconnect()
            }
        )
        let foregroundDrainGate = ForegroundDrainGate(drive: {
            await driveUploadDrain(
                mobileSegment: mobileSegmentUploader,
                transferEngine: transferEngine,
                shareImportStore: shareImportStore,
                shareTransferHolder: shareTransferHolder,
                diagnosticLog: log,
                watchDrain: watchSegmentDrain
            )
        })
        let launchMaintenanceCoordinator = LaunchMaintenanceCoordinator(
            operations: LaunchMaintenanceCoordinator.Operations(
                startScreencastObserving: {
                    screencastManager.startObservingDarwin()
                },
                reconcileScreencast: { reason in
                    await screencastManager.reconcileScreencast(reason: reason)
                },
                resumeImportQueue: {
                    await resumeShareImports(
                        shareImportStore: shareImportStore,
                        transferEngine: transferEngine,
                        diagnosticLog: log
                    )
                },
                migrateLegacyMobileItems: {
                    await mobileSegmentUploader.migrateLegacyMobileItems()
                },
                resumeMobileSegments: {
                    await mobileSegmentEngine.resumeFromDisk()
                },
                migrateLegacyAudioKeys: {
                    return
                },
                replayWatchACKs: {
                    watchRelayReceiver?.replayACKsForCommittedSegments()
                },
                drainWatch: {
                    await watchSegmentDrain?.drain()
                },
                endStaleObserverActivitiesIfIdle: {
                    if case .idle = observerManager.state {
                        await observerManager.endStaleObserverActivities()
                    }
                }
            )
        )
        if !Self.isIntegrationMode && !Self.isUITest && !Self.isUnitTest {
            finishSyncing.registerLaunchHandler()
        }
#if DEBUG && targetEnvironment(simulator)
        let integrationGateDriver: IntegrationGateDriver?
        if IntegrationGateDriver.shouldRun() {
            integrationGateDriver = IntegrationGateDriver(
                dependencies: IntegrationGateDependencies(
                    keychainStore: SPLRuntime.keychainStore,
                    tunnelManager: tunnel,
                    transport: transport,
                    connectionSyncModel: connectionSyncModel
                )
            )
        } else {
            integrationGateDriver = nil
        }
#endif
        self._appConfig = State(initialValue: appConfig)
        self._appGroupMirror = State(initialValue: appGroupMirror)
        self._watchBacklogSnapshotWriter = State(initialValue: watchBacklogSnapshotWriter)
        self._onboardingFlow = State(initialValue: onboardingFlow)
        self._diagnosticLog = State(initialValue: log)
        self._problemReportsManager = State(initialValue: problemReports)
        self._tunnelManager = State(initialValue: tunnel)
        self._connectionSyncModel = State(initialValue: connectionSyncModel)
        self._mobileSegmentTransferHolder = State(initialValue: mobileSegmentTransferHolder)
        self._omiUploaderHolder = State(initialValue: omiUploaderHolder)
        self._watchUploaderHolder = State(initialValue: watchUploaderHolder)
        self._watchSourceFacts = State(initialValue: watchSourceFacts)
        self._transferEndpointResolver = State(initialValue: transferEndpointResolver)
        self._transferStatusMirror = State(initialValue: transferStatusMirror)
        self._transferConditionsSource = State(initialValue: transferConditionsSource)
        self._transferEngine = State(initialValue: transferEngine)
        self._transferEnqueuer = State(initialValue: transferEnqueuer)
        self._shareImportStore = State(initialValue: shareImportStore)
        self._shareTransferHolder = State(initialValue: shareTransferHolder)
        self._watchSegmentDrain = State(initialValue: watchSegmentDrain)
        self._watchRelayReceiver = State(initialValue: watchRelayReceiver)
        self._watchSegmentLedger = State(initialValue: watchSegmentLedger)
        self._phoneSessionHistoryStore = State(initialValue: phoneSessionHistoryStore)
        self._mobileSegmentUploader = State(initialValue: mobileSegmentUploader)
        self._mobileSegmentEngine = State(initialValue: mobileSegmentEngine)
        self._locationManager = State(initialValue: locationManager)
        self._screencastManager = State(initialValue: screencastManager)
        self._observerManager = State(initialValue: observerManager)
        self._watchLink = State(initialValue: watchLink)
        self._omiSourceManager = State(initialValue: omiSource)
        self._launchCaptureCommitCoordinator = State(initialValue: launchCaptureCommitCoordinator)
        self._finishSyncingCoordinator = State(initialValue: finishSyncing)
        self._foregroundDrainGate = State(initialValue: foregroundDrainGate)
        self._launchMaintenanceCoordinator = State(initialValue: launchMaintenanceCoordinator)
#if DEBUG && targetEnvironment(simulator)
        self._integrationGateDriver = State(initialValue: integrationGateDriver)
#endif
    }

    @MainActor
    private static func applyMagicMomentLaunchGuard(
        mobileSegmentStore: MobileSegmentStore,
        appGroupRootURL: URL,
        cachesRootURL: URL?
    ) {
        let magicMomentFirstSeen = UserDefaults.standard.bool(forKey: AudioStorageKey.magicMomentFirstSeen)
        let hasExistingOnThisPhoneItems = OnThisPhoneLaunchMagicMomentStoreProbe.hasExistingOnThisPhoneItems(
            mobileSegmentStore: mobileSegmentStore,
            appGroupRootURL: appGroupRootURL,
            cachesRootURL: cachesRootURL
        )
        guard shouldMarkMagicMomentFirstSeenOnLaunch(
            magicMomentFirstSeen: magicMomentFirstSeen,
            hasExistingOnThisPhoneItems: hasExistingOnThisPhoneItems,
            isUITest: Self.isUITest
        ) else {
            return
        }
        UserDefaults.standard.set(true, forKey: AudioStorageKey.magicMomentFirstSeen)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(self.appConfig)
                .environment(self.appGroupMirror)
                .environment(self.watchBacklogSnapshotWriter)
                .environment(self.onboardingFlow)
                .environment(self.shellNav)
                .environment(self.tunnelManager)
                .environment(self.connectionSyncModel)
                .environment(self.finishSyncingCoordinator)
                .environment(self.foregroundDrainGate)
                .environment(self.omiSourceManager)
                .environment(self.mobileSegmentTransferHolder)
                .environment(self.omiUploaderHolder)
                .environment(self.watchUploaderHolder)
                .environment(self.watchSourceFacts)
                .environment(self.watchLink)
                .environment(self.watchRelayReceiver)
                .environment(self.watchSegmentLedger)
                .environment(self.phoneSessionHistoryStore)
                .environment(self.shareImportStore)
                .environment(self.shareTransferHolder)
                .environment(self.mobileSegmentUploader)
                .environment(self.mobileSegmentEngine)
                .environment(self.locationManager)
                .environment(self.screencastManager)
                .environment(self.observerManager)
                .environment(self.pendingObserverCommand)
                .environment(self.pendingJournalOpen)
                .environment(self.pairingHandoff)
                .environment(self.diagnosticLog)
                .environment(self.problemReportsManager)
                .environment(self.appDelegate.pushManager)
                .environment(self.appDelegate.pendingRoute)
                .onOpenURL { url in
                    if self.pairingHandoff.applyUniversalLink(url) {
                        return
                    }
                    switch SolstoneDeepLink.parse(url) {
                    case .observerStop:
                        self.pendingObserverCommand.command = .stopRequested
                    case .journal:
                        self.pendingJournalOpen.isOpenRequested = true
                    case nil:
                        break
                    }
                }
                .onChange(of: self.pendingObserverCommand.command) { _, command in
                    guard command == .stopRequested else { return }
                    self.pendingObserverCommand.command = nil
                    Task {
                        _ = await self.observerManager.stopSession()
                    }
                }
                .task {
                    await self.connectionSyncModel.run()
                }
#if DEBUG && targetEnvironment(simulator)
                .task {
                    await self.integrationGateDriver?.run()
                }
#endif
                .task {
                    await self.bootstrapTransfer()
                    _ = await self.omiSourceManager.resumeLaunchCaptureOnce()
                }
                .task {
                    await Task.yield()
                    guard Self.shouldRunLaunchMaintenance(scenePhase: self.scenePhase) else { return }
                    await self.launchMaintenanceCoordinator.runForegroundMaintenance()
                }
                .task {
                    await self.locationManager.resumeIfEnabled()
                }
                .task {
                    self.tunnelManager.receiveScenePhase(Self.tunnelScenePhase(self.scenePhase))
                }
                .task {
                    // cold-launch-into-connected: .onChange doesn't fire for the initial tunnel value.
                    // Revalidate the existing epoch before foreground drain; failed validation drives
                    // reconnect, and the connected-edge handler drains after recovery.
                    if Self.isIntegrationMode || Self.isUITest { return }
                    guard self.appConfig.isPaired else { return }
                    guard case .connected = self.tunnelManager.state else { return }
                    await Self.revalidateThenRequestDrain(tunnelManager: self.tunnelManager) {
                        await self.foregroundDrainGate.requestDrain()
                    }
                }
                .task {
                    // Initial connected state needs the same transfer edge handling because
                    // onChange does not fire for its initial value.
                    guard case .connected(let port, _) = self.tunnelManager.state else { return }
                    await self.transferEndpointResolver.update(activeLocalPort: port)
                    await self.transferEngine.noteNewConnectionEstablished()
                    await self.transferEngine.endpointAvailabilityChanged()
                }
        }
        .onChange(of: self.scenePhase) { _, newPhase in
            self.tunnelManager.receiveScenePhase(Self.tunnelScenePhase(newPhase))
            switch newPhase {
            case .active:
                self.backgroundDrainTask?.cancel()
                self.backgroundDrainTask = nil
                if Self.shouldRunLaunchMaintenance(scenePhase: newPhase) {
                    Task {
                        await self.launchMaintenanceCoordinator.runForegroundMaintenance()
                    }
                }
                Task {
                    await self.screencastManager.reconcileScreencast(reason: .foreground)
                }
                if Self.isIntegrationMode || Self.isUITest {
                    return
                }
                guard self.appConfig.isPaired else {
                    return
                }
                self.connectionSyncModel.refreshFromInputChange()
                self.tunnelManager.startNetworkMonitoring()

                switch self.tunnelManager.state {
                case .connected:
                    // Connected tunnels are probed before foreground drain starts; waitingForHome is
                    // re-driven below because suspended timers may not have fired while backgrounded.
                    // Disconnected and retryable-error states use retryNow().
                    Task {
                        await Self.revalidateThenRequestDrain(tunnelManager: self.tunnelManager) {
                            await self.foregroundDrainGate.requestDrain()
                        }
                    }
                case .connecting:
                    break
                case .waitingForHome:
                    break
                case .disconnected:
                    Task {
                        await self.tunnelManager.retryNow()
                    }
                case .error(let error):
                    if error.isRetryable {
                        Task {
                            await self.tunnelManager.retryNow()
                        }
                    }
                }
            case .background:
                let omiFinalizeTask = Task { @MainActor in
                    await self.omiSourceManager.finalizeOpenChunkForBackground()
                }
                Task {
                    await self.screencastManager.prepareForBackground()
                }
                self.launchMaintenanceCoordinator.cancel()
                self.integrationObserverStartTask?.cancel()
                self.integrationObserverStartTask = nil
                self.integrationObserverStopTask?.cancel()
                self.integrationObserverStopTask = nil
                if Self.isIntegrationMode || Self.isUITest {
                    return
                }
                let coordinator = BackgroundDrainCoordinator(
                    totals: {
                        uploadTotals(
                            mobileSegment: self.mobileSegmentTransferHolder,
                            omi: self.omiUploaderHolder,
                            watch: self.watchUploaderHolder,
                            share: self.shareTransferHolder
                        )
                    },
                    inFlight: {
                        uploadInFlight(
                            mobileSegment: self.mobileSegmentTransferHolder,
                            omi: self.omiUploaderHolder,
                            watch: self.watchUploaderHolder,
                            share: self.shareTransferHolder
                        )
                    },
                    backoff: {
                        uploadBackoff(mirror: self.transferStatusMirror)
                    },
                    isSustaining: { self.locationManager.isSustainingBackground },
                    isConnected: { self.tunnelManager.state.isConnected },
                    drive: {
                        await driveUploadDrain(
                            mobileSegment: self.mobileSegmentUploader,
                            transferEngine: self.transferEngine,
                            shareImportStore: self.shareImportStore,
                            shareTransferHolder: self.shareTransferHolder,
                            diagnosticLog: self.diagnosticLog,
                            watchDrain: self.watchSegmentDrain
                        )
                    },
                    disconnect: {
                        self.tunnelManager.cancelConnect()
                        self.tunnelManager.cancelReconnect()
                        self.tunnelManager.stopNetworkMonitoring()
                        await self.tunnelManager.disconnect()
                    },
                    asserter: UIBackgroundTaskAsserter()
                )
                self.backgroundDrainTask = Task {
                    await omiFinalizeTask.value
                    await coordinator.run()
                }
            default:
                break
            }
        }
        .onChange(of: self.tunnelManager.state) { _, newState in
            switch newState {
            case .connected(let port, _):
                Task {
                    await self.transferEndpointResolver.update(activeLocalPort: port)
                    await self.transferEngine.noteNewConnectionEstablished()
                    await self.transferEngine.endpointAvailabilityChanged()
                }
                Task { await self.foregroundDrainGate.requestDrain() }

                if Self.isIntegrationMode,
                   // Internal compatibility arg for automation; not owner-facing UI vocabulary.
                   Self.integrationObserverTapKind == "sense",
                   !self.didAutoStartIntegrationObserver
                {
                    self.didAutoStartIntegrationObserver = true
                    self.integrationObserverStartTask?.cancel()
                    self.integrationObserverStartTask = Task {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled else { return }
                        _ = await self.observerManager.startSession(mode: .meeting)
                    }
                }
            case .connecting, .waitingForHome, .disconnected, .error:
                Task {
                    await self.transferEndpointResolver.update(activeLocalPort: nil)
                    await self.transferEngine.endpointAvailabilityChanged()
                }
                self.integrationObserverStartTask?.cancel()
                self.integrationObserverStartTask = nil
                self.integrationObserverStopTask?.cancel()
                self.integrationObserverStopTask = nil
            }
        }
        .onChange(of: self.observerManager.state) { _, newState in
            guard Self.isIntegrationMode,
                  Self.integrationObserverTapKind != nil
            else { return }

            switch newState {
            case .active:
                guard !self.didAutoStopIntegrationObserver else { return }
                self.didAutoStopIntegrationObserver = true
                self.integrationObserverStopTask?.cancel()
                self.integrationObserverStopTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    _ = await self.observerManager.stopSession()
                }
            case .idle, .starting, .stopping, .error:
                break
            }
        }
        .commands {
            if shouldBuildShellMenuCommands(userInterfaceIdiom: UIDevice.current.userInterfaceIdiom) {
                ShellMenuCommands(
                    nav: self.shellNav,
                    onboardingFlow: self.onboardingFlow,
                    appConfig: self.appConfig,
                    connectionSyncModel: self.connectionSyncModel
                )
            }
        }
    }

    private func bootstrapTransfer() async {
        guard !self.didBootstrapTransfer else { return }
        self.didBootstrapTransfer = true

        await self.transferEngine.registerDeliveredHook(sourceKey: ObserverAudioTransferSource.mobileSegment) { [weak mobileSegmentUploader = self.mobileSegmentUploader] manifest, _ in
            guard let segmentID = manifest.observerIngest?.segmentID else { return }
            try await MainActor.run {
                try mobileSegmentUploader?.writeUploadedTombstone(segmentID: segmentID)
            }
        }
        await self.transferEngine.registerDeliveredHook(sourceKey: ObserverAudioTransferSource.share) { [weak shareImportStore = self.shareImportStore] manifest, successKind in
            try await MainActor.run {
                try shareImportStore?.recordDelivered(manifest: manifest, successKind: successKind)
            }
        }

        let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        await Self.bootstrapTransfer(
            initialize: {
                self.transferConditionsSource.start {
                    Task { await self.transferEngine.kick() }
                }
                try await self.transferEngine.initialize()
            },
            appGroupRoot: {
                try AppGroupContainer.rootURL()
            },
            cachesRootURL: cachesRoot,
            migrate: { appGroupRoot, cacheRoot in
                await OmiTransferSpoolMigrator.migrate(
                    appGroupRootURL: appGroupRoot,
                    legacyCachesRootURL: cacheRoot?.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true),
                    transferEnqueuer: self.transferEnqueuer,
                    diagnosticLog: self.diagnosticLog,
                    acknowledgeTokens: { [weak omiSource = self.omiSourceManager] tokens in
                        omiSource?.acknowledgeSegmentMetadata(tokens: tokens)
                    },
                    registerDispatchHold: { itemID in
                        await self.transferEngine.hold(itemID: itemID)
                    }
                )
                await WatchTransferSpoolMigrator.migrate(
                    appGroupRootURL: appGroupRoot,
                    legacyRootURL: (cacheRoot ?? FileManager.default.temporaryDirectory)
                        .appendingPathComponent(WatchTransferSpoolMigrator.legacyCacheDirectoryName, isDirectory: true),
                    transferEnqueuer: self.transferEnqueuer,
                    diagnosticLog: self.diagnosticLog
                )
                await MobileSegmentTransferSpoolMigrator.migrate(
                    appGroupRootURL: appGroupRoot,
                    observerCacheRootURL: cacheRoot?.appendingPathComponent("Observer", isDirectory: true),
                    store: self.mobileSegmentUploader.storeForTransferMigration,
                    diagnosticLog: self.diagnosticLog
                )
                await ShareImportTransferSpoolMigrator.migrate(
                    appGroupRootURL: appGroupRoot,
                    store: self.shareImportStore,
                    transferEngine: self.transferEngine,
                    diagnosticLog: self.diagnosticLog
                )
            },
            reconcile: { appGroupRoot in
                await self.mobileSegmentUploader.resumeFromDisk()
                self.shareImportStore.refreshFromDisk()
                if UserDefaults.standard.bool(forKey: OmiTransferSpoolMigrator.flagKey) {
                    await self.recoverOmiInProgress(appGroupRootURL: appGroupRoot)
                }
            },
            reconcileLaunchCapture: { appGroupRoot in
                await self.launchCaptureCommitCoordinator.reconcile(
                    rootURL: appGroupRoot.appendingPathComponent(
                        OmiLaunchCaptureFormat.rootDirectoryName,
                        isDirectory: true
                    )
                )
            },
            conservativelyGateOmi: {
                await self.launchCaptureCommitCoordinator.conservativelyGateOmi()
            },
            enableDispatch: {
                await self.transferEngine.enableDispatch()
            },
            openOmiReadiness: {
                await self.omiSourceManager.openLaunchReadiness()
            },
            reportFailure: { reason, error in
                self.diagnosticLog.append(
                    category: .upload,
                    severity: .warning,
                    message: "needs attention",
                    detail: "source=transfer reason=\(reason)"
                )
                if let error {
                    Logger(subsystem: "app.solstone.swift", category: "transfer")
                        .error("transfer start failed: \(String(describing: error), privacy: .public)")
                }
            }
        )
    }

    private func recoverOmiInProgress(appGroupRootURL: URL) async {
        let rootURL = appGroupRootURL.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: rootURL.path),
              let sessions = try? FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else {
            return
        }
        let quarantineRoot = OmiTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRootURL)
        for sessionURL in sessions where (try? sessionURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let sessionID = UUID(uuidString: sessionURL.lastPathComponent) else { continue }
            _ = await OmiInProgressRecovery.recoverInProgressFiles(
                sessionID: sessionID,
                rootURL: rootURL,
                transferEnqueuer: self.transferEnqueuer,
                acknowledgeTokens: { [weak omiSource = self.omiSourceManager] tokens in
                    omiSource?.acknowledgeSegmentMetadata(tokens: tokens)
                },
                registerDispatchHold: { itemID in
                    await self.transferEngine.hold(itemID: itemID)
                },
                quarantineRootURL: quarantineRoot,
                diagnosticLog: self.diagnosticLog
            )
        }
    }
}

private extension SolstoneSwiftApp {
    static func purgeLegacyKeychainEntries() {
        for account in [
            "solstone-swift-identity-key",
            "solstone-swift-host-key",
            "solstone-swift-pair-identity",
            "solstone-swift-pair-session",
            "solstone-swift-observer-ingest-key-v2",
            "solstone-swift-observer-ingest-prefix",
            "solstone-swift-omi-ingest-key-v2",
            "solstone-swift-omi-ingest-prefix",
            "solstone-swift-watch-ingest-key-v2",
            "solstone-swift-watch-ingest-prefix",
        ] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "app.solstone.swift",
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
        Logger(subsystem: "app.solstone.swift", category: "app-config").debug("legacy keychain entries purged")
    }

    static func resetOnboardingIntegrationState() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "onboarding.step")
        defaults.removeObject(forKey: "onboarding.completed")
        defaults.removeObject(forKey: AudioStorageKey.enrolled)
        defaults.removeObject(forKey: AudioStorageKey.magicMomentFirstSeen)
        defaults.removeObject(forKey: "push.pendingRegistrationToken")
        defaults.removeObject(forKey: "push.lastRegisteredToken")
        defaults.removeObject(forKey: "push.lastRegisteredEnvironment")
        AppConfig().clearPairing()
    }

    static func makeObserverRecorder() -> any ObserverRecording {
#if DEBUG
        if self.isIntegrationTest {
            return IntegrationTestObserverRecorder()
        }
        if self.isUITest && self.shouldUseUITestObserverRecorder {
            return IntegrationTestObserverRecorder(permissionGranted: self.uiTestObserverPermissionGranted)
        }
#endif
        return LiveObserverRecorder()
    }

    static func makeMetricSubscriber(
        ingest: @escaping @MainActor @Sendable ([ProblemReportPayloadInput]) -> Void
    ) -> any MetricSubscribing {
#if DEBUG
        if self.isIntegrationMode || self.isUITest || self.isUnitTest {
            return NoOpMetricSubscriber()
        }
#endif
        return LiveMetricSubscriber(ingest: ingest)
    }

}

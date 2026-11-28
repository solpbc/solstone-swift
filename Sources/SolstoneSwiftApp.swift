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
    @State private var safariPassGate = SafariPassGate()
    @State private var onboardingFlow: OnboardingFlow
    @State private var tunnelManager: TunnelManager
    @State private var connectionStallMonitor: ConnectionStallMonitor
    @State private var connectionSyncModel: ConnectionSyncModel
    @State private var diagnosticLog: DiagnosticLog
    @State private var problemReportsManager: ProblemReportsManager
    @State private var mobileSegmentTransferHolder: MobileSegmentTransferHolder
    @State private var watchUploaderHolder: WatchUploaderHolder
    @State private var watchSourceFacts: WatchSourceFacts
    @State private var transferEndpointResolver: LoopbackTransferEndpointResolver
    @State private var transferStatusMirror: TransferStatusMirror
    @State private var transferConditionsSource: TransferConditionsSource
    @State private var transferEngine: TransferEngine
    @State private var transferEnqueuer: ObserverAudioTransferEnqueuer
    @State private var shareImportStore: ShareImportStore
    @State private var sourceIntakeModel: SourceIntakeModel
    @State private var shareTransferHolder: ShareTransferHolder
    @State private var calendarSource: CalendarSourceEngine
    @State private var calendarSourceHandle: CalendarSourceHandle
    @State private var obsidianSource: ObsidianSourceEngine
    @State private var obsidianSourceHandle: ObsidianSourceHandle
    @State private var obsidianTransferHolder: ObsidianTransferHolder
    @State private var screenshotsSource: ScreenshotsSourceEngine
    @State private var screenshotsSourceHandle: ScreenshotsSourceHandle
#if SOLSTONE_PHOTOS_LIBRARY
    @State private var photosLibraryEngine: PhotosLibraryEngine
    @State private var photosLibrarySourceHandle: PhotosLibrarySourceHandle
#endif
    @State private var foldersEngine: FoldersEngine
    @State private var foldersSourceHandle: FoldersSourceHandle
    @State private var safariSource: SafariSourceModel?
    @State private var calendarTransferHolder: CalendarTransferHolder
    @State private var calendarBackgroundRefresh: CalendarBackgroundRefresh
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
    @State private var finishSyncingCoordinator: FinishSyncingCoordinator
    @State private var importBackgroundUploadCoordinator: ImportBackgroundUploadCoordinator
    @State private var journalExportTransferManager: JournalExportTransferManager
    @State private var exportBackgroundDownloadCoordinator: ExportBackgroundDownloadCoordinator
    @State private var foregroundDrainGate: ForegroundDrainGate
    @State private var launchMaintenanceCoordinator: LaunchMaintenanceCoordinator
    @State private var journalSendRelease: JournalSendRelease
    @State private var deviceMigrationOwner: DeviceMigrationOwnerModel
    @State private var pairFlowPresence: PairFlowPresence
    @State private var ageSignal: AgeSignalModel
    private let observerBackgroundTunnelCoordinator: ObserverBackgroundTunnelCoordinator
    @State private var safariTransferReady = false
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

    /// The app build a settled journal refusal is recorded under.
    static var refusalAppBuild: String? {
        let build = AppVersion.build
        return build == "?" ? nil : build
    }

    /// The journal version's change slot holds one closure, so it does both jobs: the watch link
    /// publishes the version to the watch, and the transfer engine learns of it (a new version
    /// offers refusals made under the old one again).
    static func wireJournalVersion(
        _ metadata: JournalVersionMetadata,
        watchLink: WatchLink,
        transferEngine: TransferEngine,
        calendarGate: CalendarCapabilityGate? = nil,
        obsidianGate: ObsidianCapabilityGate? = nil,
        screenshotsGate: ScreenshotsCapabilityGate? = nil
    ) {
        watchLink.journalVersionProvider = { [metadata] in
            (
                identity: metadata.identity,
                version: metadata.version,
                current: metadata.isCurrent,
                versionObservedAt: metadata.versionObservedAt,
                journalOS: metadata.journalOS,
                journalOSVersion: metadata.journalOSVersion,
                journalArch: metadata.journalArch,
                journalBuild: metadata.journalBuild
            )
        }
        metadata.onChange = { [weak watchLink, weak metadata] in
            watchLink?.publishJournalVersion()
            let version = metadata?.version
            let identity = metadata?.identity
            Task {
                await transferEngine.noteJournalVersion(version)
                // Whether a journal takes calendar notes is read again for a new pairing or version.
                await calendarGate?.journalChanged(identity: identity, version: version)
                await obsidianGate?.journalChanged(identity: identity, version: version)
                await screenshotsGate?.journalChanged(identity: identity, version: version)
            }
        }
    }

    /// The endpoint was resolved under the pairing committed now, not an earlier one.
    nonisolated static func isCurrentPairing(_ endpoint: TransferResolvedEndpoint, snapshot: PairingCredentialSnapshot) -> Bool {
        guard let owner = endpoint.dispatchOwner, let pairing = snapshot.pairing else { return false }
        return owner.pairingGeneration == snapshot.pairingGeneration && owner.credentialCID == pairing.fingerprint
    }

    static func shouldRunLaunchMaintenance(scenePhase: ScenePhase) -> Bool {
        guard scenePhase == .active else { return false }
        return !Self.isIntegrationMode && !Self.isUITest && !Self.isUnitTest
    }

    private static func screencastScenePhase(_ phase: ScenePhase) -> ScreencastScenePhase {
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
        reconcile: () async throws -> Void,
        enableDispatch: () async -> Void,
        reportFailure: (String, (any Error)?) -> Void
    ) async {
        do {
            try await initialize()
        } catch {
            reportFailure(AppStrings.ios_app_bootstraptransfer5(), error)
            return
        }
        let rootURL: URL
        do {
            rootURL = try appGroupRoot()
        } catch {
            reportFailure(AppStrings.ios_app_bootstraptransfer(), error)
            await enableDispatch()
            return
        }
        do {
            try await migrate(rootURL, cachesRootURL)
        } catch {
            reportFailure(AppStrings.ios_app_bootstraptransfer2(), error)
            await enableDispatch()
            return
        }
        do {
            try await reconcile()
        } catch {
            reportFailure(AppStrings.ios_app_bootstraptransfer3(), error)
            await enableDispatch()
            return
        }
        await enableDispatch()
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
#if DEBUG && targetEnvironment(simulator)
        // Deterministic visual acceptance hook for the system-owned launch screen.
        // The release binary has no hold; a fresh simulator launch with this flag
        // keeps the static storyboard visible long enough for `make launch-shots`.
        if ProcessInfo.processInfo.arguments.contains("--ui-test-hold-launch-screen") {
            Thread.sleep(forTimeInterval: 3)
        }
#endif
        SPLLogging.configure(subsystem: "app.solstone.swift")
        ShellFont.applyNavigationBarAppearance()
        Self.scheduleLegacyKeychainPurgeIfNeeded()
        InnerTLSOrphanPurgeBarrier.shared.start()
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--integration-test-onboarding") {
            Self.resetOnboardingIntegrationState()
        }
#endif
        let log = DiagnosticLog(defaults: .standard)
        let appGroupMirror = AppGroupMirror()
        let appConfig = AppConfig(store: SPLRuntime.pairingStore, appGroupMirror: appGroupMirror)
        // Only a build that carries the Safari extension keeps its store.
        if SafariSourceModel.isBundled {
            appConfig.safariAuthorityCoordinator = SafariAuthorityCoordinator()
        }
        let observerClock = SystemObserverClock()
        let onboardingFlow = OnboardingFlow()
        let transport = CFTunnelTransport(appConfig: appConfig, diagnosticLog: log)
#if DEBUG
        OnThisPhoneUITestSeeder.runIfRequested()
        ProblemReportsUITestSeeder.runIfRequested()
#endif
        let problemReportStore = ProblemReportStore(diagnosticLog: log)
        let problemReports = ProblemReportsManager(
            store: problemReportStore,
            deferInitialLoad: true,
            makeSubscriber: { ingest in
                Self.makeMetricSubscriber(ingest: ingest)
            }
        )
        let mobileSegmentStore: MobileSegmentStore
        let mobileSegmentStorageDisabledReason: String?
        let mobileSegmentMigrationDiagnostics: [String]
        let sourceIntakeStore: SourceIntakeStore?
        do {
            let appGroupRoot = try AppGroupContainer.rootURL()
            sourceIntakeStore = SourceIntakeStore(containerRoot: appGroupRoot)
            let appGroupMobileSegmentRoot = appGroupRoot
                .appendingPathComponent(MobileSegmentStore.directoryName, isDirectory: true)
            mobileSegmentStore = MobileSegmentStore(rootURL: appGroupMobileSegmentRoot)
            mobileSegmentStore.intake = sourceIntakeStore
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
            sourceIntakeStore = nil
            let diagnostic = AppStrings.ios_app_diagnostic()
            Logger(subsystem: "app.solstone.swift", category: "mobile-segment")
                .error("\(diagnostic, privacy: .public)")
            mobileSegmentStore = MobileSegmentStore(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("mobile-segment-unavailable", isDirectory: true)
            )
            mobileSegmentStorageDisabledReason = diagnostic
            mobileSegmentMigrationDiagnostics = []
        }
        let transferEndpointResolver = LoopbackTransferEndpointResolver(
            credentials: appConfig.store,
            confirmation: SPLRuntime.confirmationStore
        )
        appConfig.sharedSources.admitted = { [weak appConfig] in appConfig?.journalSendConfirmed == true }
        let homeClient = appConfig.sharedSources.client
        let calendarGate = CalendarCapabilityGate(
            read: { endpoint in
                guard let port = endpoint.port else { return .failed }
                return await homeClient.fetchStatusReport(localPort: port)
            },
            isCurrent: { endpoint in
                await transferEndpointResolver.isCurrent(endpoint)
            }
        )
        let obsidianGate = ObsidianCapabilityGate(
            readStatus: { endpoint in
                guard let port = endpoint.port else { return .failed }
                return await homeClient.fetchStatusReport(localPort: port)
            },
            fetchVaults: { endpoint in
                guard let port = endpoint.port else { return nil }
                return await AuthenticatedHomeClient().fetchObsidianVaults(localPort: port)
            },
            isCurrent: { endpoint in
                await transferEndpointResolver.isCurrent(endpoint)
            }
        )
        let screenshotsGate = ScreenshotsCapabilityGate(
            read: { endpoint in
                guard let port = endpoint.port else { return .failed }
                return await homeClient.fetchStatusReport(localPort: port)
            },
            isCurrent: { endpoint in
                await transferEndpointResolver.isCurrent(endpoint)
            }
        )
        let transferStatusMirror = TransferStatusMirror()
        let transferConditionsSource = TransferConditionsSource()
        let transferSpool: TransferSpool
        do {
            transferSpool = try TransferSpool()
        } catch {
            let diagnostic = AppStrings.ios_app_diagnostic2()
            Logger(subsystem: "app.solstone.swift", category: "transfer")
                .error("\(diagnostic, privacy: .public)")
            log.append(category: .upload, severity: .warning, message: AppStrings.ios_presentation_solstoneswiftapp_n20(), detail: diagnostic)
            transferSpool = TransferSpool(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("transfer-unavailable", isDirectory: true)
            )
        }
        let connectionHeardReporter = ConnectionHeardReporter()
        let transferTransport = TransferTransport(admission: { endpoint in
            await transferEndpointResolver.isCurrent(endpoint)
        }, requestAdmission: { endpoint, start in
            await transferEndpointResolver.startRequest(endpoint, start: start)
        })
        let resumableImportProbe = JournalResumableImportCapabilityProbe(transport: transferTransport)
        let transferEngine = TransferEngine(
            spool: transferSpool,
            transport: transferTransport,
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
            },
            heardReporter: connectionHeardReporter,
            sourceGate: SafariBrowserSourceGate(
                calendar: calendarGate,
                obsidian: obsidianGate,
                screenshots: screenshotsGate
            ),
            resumableImportProbe: resumableImportProbe,
            deviceNoun: JournalImportQueueIntake.currentDeviceNoun(),
            appBuild: Self.refusalAppBuild,
            journalVersion: appConfig.journalVersion.version
        )
        let transferEnqueuer = ObserverAudioTransferEnqueuer(engine: transferEngine)
        let calendarTransferHolder = CalendarTransferHolder(transferEngine: transferEngine, mirror: transferStatusMirror)
        Task {
            await calendarGate.connect(
                wake: { await transferEngine.kick() },
                publish: { capability in
                    Task { @MainActor in
                        calendarTransferHolder.capability = capability
                    }
                }
            )
        }
        let calendarStore = CalendarSourceStore(rootURL: CalendarSourceStore.defaultRootURL())
        let calendarSource = CalendarSourceEngine(
            access: EventKitCalendarAccess(),
            reader: EventKitCalendarReader(),
            store: calendarStore,
            delivery: CalendarTransferDelivery(
                engine: transferEngine,
                stagingURL: calendarStore.rootURL.appendingPathComponent("staging", isDirectory: true)
            ),
            dependencies: CalendarSourceEngine.Dependencies(
                delivery: {
                    (
                        waiting: calendarTransferHolder.notesWaiting,
                        attention: calendarTransferHolder.notesNeedingAttention,
                        waitingForJournalUpdate: calendarTransferHolder.waitingForJournalUpdate
                    )
                },
                deliveryChanged: {
                    Task { await calendarTransferHolder.refreshNoteCounts() }
                }
            ),
            intake: sourceIntakeStore
        )
        let calendarBackgroundRefresh = CalendarBackgroundRefresh(engine: calendarSource)
        calendarTransferHolder.importFilesNotYetQueued = { [weak calendarSource] in
            calendarSource?.importFilesNotYetQueued ?? 0
        }
        calendarTransferHolder.importFilesHeld = { [weak calendarSource] in
            calendarSource?.importFilesHeld ?? 0
        }
#if DEBUG
        let seededCalendarSource: (any CalendarSourceControlling)? = CalendarUITestSource.seeded()
        let calendarSourceHandle = CalendarSourceHandle(source: seededCalendarSource ?? calendarSource)
#else
        let calendarSourceHandle = CalendarSourceHandle(source: calendarSource)
#endif
        let obsidianTransferHolder = ObsidianTransferHolder(transferEngine: transferEngine, mirror: transferStatusMirror)
        let obsidianStore = ObsidianStore()
        let obsidianSource = ObsidianSourceEngine(
            store: obsidianStore,
            intakeStore: sourceIntakeStore,
            delivery: ObsidianTransferDelivery(engine: transferEngine)
        )
        obsidianSource.isPairedProvider = { [weak appConfig] in
            appConfig?.isPaired ?? false
        }
        obsidianTransferHolder.activeVaultIDProvider = { [weak obsidianSource] in
            obsidianSource?.status.selectedVaultID
        }
        obsidianTransferHolder.isEnabledProvider = { [weak obsidianSource] in
            obsidianSource?.canDeliver ?? false
        }
        obsidianTransferHolder.isPausedProvider = { [weak obsidianSource] in
            obsidianSource?.status.isPaused ?? false
        }
        obsidianTransferHolder.continueSameNameAction = { [weak obsidianGate] in
            await obsidianGate?.continueSameName()
        }
        obsidianTransferHolder.publishSnapshots = { [weak obsidianSource] snapshots in
            obsidianSource?.transferSnapshots = snapshots
            obsidianSource?.refreshStatus()
        }
        obsidianTransferHolder.cancelSameNameAction = { [weak obsidianGate] in
            await obsidianGate?.cancelSameName()
        }
        Task { [weak obsidianSource] in
            await transferEngine.registerObsidianAcknowledgementCommit { [weak obsidianSource, weak appConfig] manifest, successKind, endpoint in
                // An acknowledgement from before a new pairing is not the new journal's progress:
                // the item is held and goes again, to the journal paired now.
                let current = await MainActor.run {
                    appConfig.map { Self.isCurrentPairing(endpoint, snapshot: $0.store.snapshot()) } ?? false
                }
                guard let obsidianSource, current else { throw CocoaError(.fileWriteUnknown) }
                try await obsidianSource.commitDelivered(manifest: manifest, successKind: successKind)
            }
            await obsidianGate.configure(
                isSourceEnabled: {
                    await MainActor.run { obsidianSource?.canDeliver ?? false }
                },
                isSourcePaused: {
                    await MainActor.run { obsidianSource?.status.isPaused ?? false }
                },
                activeVaultID: {
                    await MainActor.run { obsidianSource?.status.selectedVaultID }
                },
                isAcceptedForSameName: { vaultID in
                    await MainActor.run { obsidianSource?.isAcceptedForSameName(vaultID: vaultID) ?? false }
                },
                recordAcceptance: { [weak appConfig] vaultID, endpoint in
                    await MainActor.run {
                        guard let appConfig, Self.isCurrentPairing(endpoint, snapshot: appConfig.store.snapshot()) else { return false }
                        return obsidianSource?.markSameNameAccepted(vaultID: vaultID) ?? false
                    }
                },
                turnSourceOff: {
                    await MainActor.run { obsidianSource?.turnOff() }
                },
                wake: { await transferEngine.kick() },
                publishChecking: { checking in
                    Task { @MainActor in obsidianTransferHolder.checkingVaultName = checking }
                },
                publishCapability: { capability in
                    Task { @MainActor in
                        obsidianTransferHolder.capability = capability
                    }
                },
                publishAdvisory: { advisory in
                    Task { @MainActor in
                        obsidianTransferHolder.sameNameAdvisory = advisory
                    }
                }
            )

        }
        calendarBackgroundRefresh.obsidianEngine = obsidianSource
        let obsidianSourceHandle = ObsidianSourceHandle(source: obsidianSource)
        let screenshotsLibrary = ScreenshotsPhotoKit()
        let screenshotsStore = ScreenshotsStore(fileURL: ScreenshotsStore.defaultFileURL())
        let screenshotsSource = ScreenshotsSourceEngine(
            library: screenshotsLibrary,
            store: screenshotsStore,
            sender: ScreenshotsTransferDelivery(
                engine: transferEngine,
                stagingURL: screenshotsStore.fileURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("staging", isDirectory: true)
            ),
            intake: sourceIntakeStore
        )
        screenshotsSource.isPaired = { [weak appConfig] in
            appConfig?.isPaired ?? false
        }
        screenshotsLibrary.setOnChange { [weak screenshotsSource] in
            Task { @MainActor in
                await screenshotsSource?.libraryChanged()
            }
        }
        Task {
            await screenshotsGate.connect(
                wake: { await transferEngine.kick() },
                publish: { capability in
                    Task { @MainActor in
                        screenshotsSource.noteCapability(capability)
                    }
                }
            )
        }
        calendarBackgroundRefresh.screenshotsEngine = screenshotsSource
        let screenshotsSourceHandle = ScreenshotsSourceHandle(source: screenshotsSource)
#if DEBUG
        let safariSource = SafariUITestSource.seeded() ?? (SafariSourceModel.isBundled ? SafariSourceModel(deferInitialLoad: true) : nil)
#else
        let safariSource = SafariSourceModel.isBundled ? SafariSourceModel(deferInitialLoad: true) : nil
#endif
        safariSource?.bindTransferMirror(transferStatusMirror)
        let mobileSegmentUploader = MobileSegmentUploader(
            transferEngine: transferEngine,
            store: mobileSegmentStore,
            clock: observerClock,
            storageDisabledReason: mobileSegmentStorageDisabledReason,
            diagnosticLog: log,
            deferInitialCountScan: true
        )
        if let migrationDiagnostic = mobileSegmentMigrationDiagnostics.first {
            mobileSegmentUploader.noteError(migrationDiagnostic)
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
        watchRelayReceiver?.intake = sourceIntakeStore
        let watchSegmentLedger = watchPipeline.watchSegmentLedger
        let phoneSessionHistoryStore = watchPipeline.phoneSessionHistoryStore
        let watchLink = watchPipeline.watchLink
        Self.wireJournalVersion(
            appConfig.journalVersion,
            watchLink: watchLink,
            transferEngine: transferEngine,
            calendarGate: calendarGate,
            obsidianGate: obsidianGate,
            screenshotsGate: screenshotsGate
        )
        let shareImportStore = ShareImportStore(
            ledgerDropSink: { droppedCount in
                log.append(
                    category: .upload,
                    severity: .info,
                    message: AppStrings.ios_app_init(),
                    detail: "dropped_rows=\(droppedCount)"
                )
            }
        )
        shareImportStore.intake = sourceIntakeStore
        let shareTransferHolder = ShareTransferHolder(
            transferEngine: transferEngine,
            mirror: transferStatusMirror,
            store: shareImportStore
        )
        // A new pairing gives the journal each source's first setup again. What is held still
        // goes, to the journal paired now.
        appConfig.store.registerOnNewPairing { [weak obsidianSource, weak calendarSource, weak screenshotsSource, weak shareTransferHolder, weak appConfig] in
            obsidianSource?.restartFirstSetup()
            calendarSource?.restartFirstSetup()
            screenshotsSource?.restartFirstSetup()
            if let shareTransferHolder, let currentID = appConfig?.deviceID {
                Task { @MainActor in
                    await shareTransferHolder.handlePairingChange(currentInstanceID: currentID)
                }
            }
        }
        let deviceMigrationOwner = DeviceMigrationOwnerModel(
            credentials: appConfig.store,
            confirmation: appConfig.confirmationStore
        )
        let homeJobs = HomeAuthenticatedJobs(
            store: appConfig.store,
            journalVersion: appConfig.journalVersion,
            client: homeClient,
            isSendAdmissionAllowed: {
                SPLRuntime.pairingStore.hasActiveOwner
                    && SPLRuntime.confirmationStore.allowsSend(pairing: SPLRuntime.pairingStore.snapshot().pairing)
            },
            deviceMigrationOwner: deviceMigrationOwner
        )
        let migrationCoordinator = DeviceMigrationCoordinator(
            credentials: appConfig.store,
            confirmation: appConfig.confirmationStore,
            appConfig: appConfig,
            didRotateCredential: {
                (UIApplication.shared.delegate as? AppDelegate)?.pushManager.credentialDidRotate()
            }
        )
        appConfig.store.registerOnCredentialReplacement {
            (UIApplication.shared.delegate as? AppDelegate)?.pushManager.credentialDidRotate()
        }
        let tunnel = TunnelManager(
            transport: transport,
            store: appConfig.store,
            activeLocalTransferCountProvider: {
                confirmedTransferCount(
                    mobileSegment: mobileSegmentTransferHolder,
                    watch: watchUploaderHolder,
                    share: shareTransferHolder,
                    calendar: calendarTransferHolder
                )
            },
            diagnosticLog: log,
            journalVersion: appConfig.journalVersion,
            homeJobs: homeJobs,
            migrationCoordinator: migrationCoordinator,
            automaticallyReconnectOnCredentialReplacement: !(Self.isIntegrationMode || Self.isUITest || Self.isUnitTest)
        )
        deviceMigrationOwner.bindActiveConnection { [weak tunnel] port, epoch in
            guard let active = tunnel?.activeConnection else { return false }
            return active.port == port && active.epoch == epoch
        }
#if SOLSTONE_PHOTOS_LIBRARY
        let photosLibraryStore = PhotosLibraryStore(fileURL: PhotosLibraryStore.defaultFileURL())
        let photosLibraryClient = AuthenticatedPhotosLibraryClient(
            homeClient: homeClient,
            localPortProvider: { [weak tunnel] in
                await MainActor.run { tunnel?.activeConnection?.port }
            },
            admitSend: {
                await MainActor.run {
                    SPLRuntime.pairingStore.hasActiveOwner
                        && SPLRuntime.confirmationStore.allowsSend(pairing: SPLRuntime.pairingStore.snapshot().pairing)
                }
            }
        )
        let photosLibraryEngine = PhotosLibraryEngine(
            media: screenshotsLibrary,
            store: photosLibraryStore,
            transport: photosLibraryClient,
            intake: sourceIntakeStore,
            deviceNameProvider: { UIDevice.current.name },
            deviceKind: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        )
        let photosLibrarySourceHandle = PhotosLibrarySourceHandle(source: photosLibraryEngine)
        photosLibraryEngine.isPaired = { [weak appConfig] in
            appConfig?.isPaired ?? false
        }
        if Self.isUITest,
           let flagIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "--ui-test-photos-state"),
           flagIndex + 1 < ProcessInfo.processInfo.arguments.count
        {
            let mode = ProcessInfo.processInfo.arguments[flagIndex + 1]
            photosLibraryEngine.isPaired = { mode != "unpaired" }
            photosLibraryEngine.applyUITestState(mode)
        }
        screenshotsLibrary.addPhotosLibraryOnChange { [weak photosLibraryEngine] in
            Task { @MainActor in
                await photosLibraryEngine?.libraryChanged()
            }
        }
        appConfig.store.registerOnNewPairing { [weak photosLibraryEngine] in
            photosLibraryEngine?.restartFirstSetup()
        }
#endif
        let foldersStore = FoldersStore(fileURL: FoldersStore.defaultFileURL())
        let foldersClient = AuthenticatedFoldersClient(
            homeClient: homeClient,
            localPortProvider: { [weak tunnel] in
                await MainActor.run { tunnel?.activeConnection?.port }
            },
            isPairedProvider: { [weak appConfig] in
                await MainActor.run { appConfig?.isPaired ?? false }
            },
            admitSend: {
                await MainActor.run {
                    SPLRuntime.pairingStore.hasActiveOwner
                        && SPLRuntime.confirmationStore.allowsSend(pairing: SPLRuntime.pairingStore.snapshot().pairing)
                }
            },
            pairingGeneration: { [weak appConfig] in
                await MainActor.run { appConfig?.store.snapshot().pairingGeneration ?? 0 }
            }
        )
        let foldersEngine = FoldersEngine(
            store: foldersStore,
            transport: foldersClient,
            intake: sourceIntakeStore,
            obsidianVaultProvider: { [weak obsidianSource] in
                guard let obsidianSource,
                      let vaultID = obsidianSource.store.document.selectedVaultID,
                      let vault = obsidianSource.store.document.vaults[vaultID],
                      let bookmark = vault.bookmarkData
                else { return nil }
                var stale = false
                guard let url = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withoutUI, .withoutImplicitStartAccessing],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ) else { return nil }
                return (url.standardizedFileURL.path, vault.folderName)
            }
        )
        let foldersSourceHandle = FoldersSourceHandle(source: foldersEngine)
        foldersEngine.isPairedProvider = { [weak appConfig] in
            appConfig?.isPaired ?? false
        }
        foldersEngine.isConnectedProvider = { [weak tunnel] in
            tunnel?.state.isConnected ?? false
        }
#if DEBUG
        if Self.isUITest,
           let flagIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "--ui-test-folders-state"),
           flagIndex + 1 < ProcessInfo.processInfo.arguments.count
        {
            let mode = ProcessInfo.processInfo.arguments[flagIndex + 1]
            foldersEngine.isPairedProvider = { mode != "unpaired" }
            foldersEngine.applyUITestState(mode)
        }
#endif
        calendarBackgroundRefresh.foldersEngine = foldersEngine
        appConfig.store.registerOnNewPairing { [weak foldersEngine] in
            foldersEngine?.restartFirstSetup()
        }
        let connectionStallMonitor = ConnectionStallMonitor(
            store: ConnectionStallStoreFactory.make(),
            clock: SystemConnectionStallClock(),
            credentials: appConfig.store
        )
        connectionHeardReporter.bind(
            dialedIdentity: { [weak tunnel] in
                await MainActor.run { tunnel?.dialedPairingIdentity }
            },
            sink: { [weak connectionStallMonitor, weak tunnel] event in
                await MainActor.run {
                    tunnel?.noteJournalHeard()
                    connectionStallMonitor?.noteHeard(identity: event.pairingIdentity)
                }
            }
        )
        tunnel.connectionHeardSink = { [weak connectionStallMonitor] event in
            connectionStallMonitor?.noteHeard(identity: event.pairingIdentity)
        }
        let connectionSyncModel = ConnectionSyncModel(clock: observerClock) {
            let totals = uploadTotals(
                mobileSegment: mobileSegmentTransferHolder,
                watch: watchUploaderHolder,
                share: shareTransferHolder,
                calendar: calendarTransferHolder,
                safari: safariSource,
                obsidian: obsidianTransferHolder,
                screenshotsPending: screenshotsSource.waitingCount,
                foldersPending: foldersEngine.waitingCount
            )
            return ConnectionSyncInputs(
                tunnelState: tunnel.state,
                reconnectCountdown: tunnel.reconnectCountdown,
                isNetworkSatisfied: tunnel.isNetworkSatisfied,
                confirmedTransferCount: confirmedTransferCount(
                    mobileSegment: mobileSegmentTransferHolder,
                    watch: watchUploaderHolder,
                    share: shareTransferHolder,
                    calendar: calendarTransferHolder
                ),
                recentBytesPerSecond: recentBytesTotal(
                    mobileSegment: mobileSegmentTransferHolder,
                    watch: watchUploaderHolder,
                    share: shareTransferHolder,
                    calendar: calendarTransferHolder
                ),
                backlogPending: totals.pending,
                backlogFailed: totals.failed,
                lastHeardAt: tunnel.lastHeardAt,
                captureBacklog: totals.pending + totals.failed
            )
        }
        let locationManager = LocationManager(mobileSegmentEngine: mobileSegmentEngine)
        let screencastManager = ScreencastManager(
            engine: mobileSegmentEngine,
            uploader: mobileSegmentUploader,
            clock: observerClock
        )
        let journalEvents = mobileSegmentUploader.journalEvents
        appConfig.onJournalIdentityCommitted = {
            mobileSegmentTransferHolder.refreshJournalGap()
        }
        appConfig.attachJournalEvents(journalEvents)
        log.journalEvents = journalEvents
        let observerRecorder = Self.makeObserverRecorder(journalEventsDirectory: journalEvents.rootURL)
        let observerManager = ObserverManager(
            recorder: observerRecorder,
            mobileSegmentEngine: mobileSegmentEngine,
            journalEvents: journalEvents,
            diagnosticLog: log,
            clock: observerClock
        )
        AppDependencyManager.shared.add(dependency: observerManager)
        AppDependencyManager.shared.add(dependency: observerManager as any ObserverSessionControlling)
        ObserverManagerDependencyRegistrationWitness.recordRegistration(of: observerManager)
        weak var importBackgroundUploadRef: ImportBackgroundUploadCoordinator?
        weak var exportBackgroundDownloadRef: ExportBackgroundDownloadCoordinator?
        let journalExportTransferManager = JournalExportTransferManager()
        appConfig.store.registerOnNewPairing { [weak journalExportTransferManager] in
            journalExportTransferManager?.cancelForUnpair()
        }
        let finishSyncing = FinishSyncingCoordinator(
            totals: {
                sendableUploadTotals(
                    mobileSegment: mobileSegmentTransferHolder,
                    watch: watchUploaderHolder,
                    share: shareTransferHolder,
                    calendar: calendarTransferHolder,
                    obsidian: obsidianTransferHolder,
                    screenshotsPending: screenshotsSource.waitingCount,
                    screenshotsUnsendable: screenshotsSource.unsendableCount,
                    foldersPending: foldersEngine.waitingCount,
                    foldersUnsendable: foldersEngine.unsendableCount
                )
            },
            heldTotals: {
                uploadTotals(
                    mobileSegment: mobileSegmentTransferHolder,
                    watch: watchUploaderHolder,
                    share: shareTransferHolder,
                    calendar: calendarTransferHolder,
                    obsidian: obsidianTransferHolder,
                    screenshotsPending: screenshotsSource.waitingCount,
                    foldersPending: foldersEngine.waitingCount
                )
            },
            inFlight: {
                uploadInFlight(
                    mobileSegment: mobileSegmentTransferHolder,
                    watch: watchUploaderHolder,
                    share: shareTransferHolder,
                    calendar: calendarTransferHolder
                ) + foldersEngine.inFlightCount
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
                await foldersEngine.drainPending()
            },
            setPacingMode: { mode in
                await transferEngine.setPacingMode(mode)
            },
            isConnected: {
                tunnel.state.isConnected
            },
            isSiblingSustaining: {
                isBackgroundTunnelSustained(
                    locationSustaining: locationManager.isSustainingBackground,
                    finishSyncingActive: false,
                    importUploadActive: importBackgroundUploadRef?.isSustainingBackground ?? false,
                    observerAudioSustaining: observerManager.isSustainingBackground,
                    exportDownloadActive: exportBackgroundDownloadRef?.isSustainingBackground ?? false
                )
            },
            disconnect: {
                guard !isBackgroundTunnelSustained(
                    locationSustaining: locationManager.isSustainingBackground,
                    finishSyncingActive: false,
                    importUploadActive: importBackgroundUploadRef?.isSustainingBackground ?? false,
                    observerAudioSustaining: observerManager.isSustainingBackground,
                    exportDownloadActive: exportBackgroundDownloadRef?.isSustainingBackground ?? false
                ) else {
                    return
                }
                tunnel.cancelConnect()
                tunnel.cancelReconnect()
                tunnel.stopNetworkMonitoring()
                await tunnel.disconnect()
            }
        )
        let importBackgroundUpload = ImportBackgroundUploadCoordinator(
            activeTarget: {
                shareTransferHolder.primaryBackgroundImportTarget
            },
            filenameForItem: { itemID in
                shareTransferHolder.filename(forItemID: itemID)
            },
            pendingSendableCount: {
                max(0, shareTransferHolder.pendingCount - shareTransferHolder.unsendableCount)
            },
            inFlightCount: {
                shareTransferHolder.inFlightCount
            },
            isPairingRefused: {
                shareTransferHolder.isPairingRefused
            },
            backoff: {
                uploadBackoff(mirror: transferStatusMirror)
            },
            drive: {
                await resumeShareImports(
                    shareImportStore: shareImportStore,
                    transferEngine: transferEngine,
                    diagnosticLog: log
                )
                if shareTransferHolder.pendingCount > 0 {
                    await transferEngine.kick()
                }
            },
            setPacingMode: { mode in
                await transferEngine.setPacingMode(mode)
            },
            isConnected: {
                tunnel.state.isConnected
            },
            shouldDisconnectOnExit: {
                UIApplication.shared.applicationState == .background
                    && !isBackgroundTunnelSustained(
                        locationSustaining: locationManager.isSustainingBackground,
                        finishSyncingActive: finishSyncing.isSustainingBackground,
                        importUploadActive: false,
                        observerAudioSustaining: observerManager.isSustainingBackground,
                        exportDownloadActive: exportBackgroundDownloadRef?.isSustainingBackground ?? false
                    )
            },
            disconnect: {
                tunnel.cancelConnect()
                tunnel.cancelReconnect()
                tunnel.stopNetworkMonitoring()
                await tunnel.disconnect()
            }
        )
        importBackgroundUploadRef = importBackgroundUpload
        let exportBackgroundDownload = ExportBackgroundDownloadCoordinator(
            activeTarget: { [weak journalExportTransferManager] in
                journalExportTransferManager?.activeBackgroundTarget
            },
            isConnected: {
                tunnel.state.isConnected
            },
            onExpirePause: { [weak journalExportTransferManager] in
                journalExportTransferManager?.pauseForBackgroundExpiry()
            },
            shouldDisconnectOnExit: {
                UIApplication.shared.applicationState == .background
                    && !isBackgroundTunnelSustained(
                        locationSustaining: locationManager.isSustainingBackground,
                        finishSyncingActive: finishSyncing.isSustainingBackground,
                        importUploadActive: importBackgroundUpload.isSustainingBackground,
                        observerAudioSustaining: observerManager.isSustainingBackground,
                        exportDownloadActive: false
                    )
            },
            disconnect: {
                tunnel.cancelConnect()
                tunnel.cancelReconnect()
                tunnel.stopNetworkMonitoring()
                await tunnel.disconnect()
            }
        )
        exportBackgroundDownloadRef = exportBackgroundDownload
        journalExportTransferManager.backgroundCoordinator = exportBackgroundDownload
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
            importBackgroundUpload.registerLaunchHandler()
            calendarBackgroundRefresh.register()
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
        let journalSendRelease = JournalSendRelease(
            credentialStore: appConfig.store,
            confirmationStore: SPLRuntime.confirmationStore,
            transferEngine: transferEngine,
            foregroundDrainGate: foregroundDrainGate,
            homeJobs: homeJobs
        )
        let pairFlowPresence = PairFlowPresence()
        let ageSignal = AgeSignalModel.live()
        ageSignal.onBlocked = { [weak observerManager, weak locationManager, weak tunnel] in
            Task {
                _ = await observerManager?.stopSession()
                await locationManager?.haltSystemMonitoring()
                tunnel?.cancelConnect()
                tunnel?.cancelReconnect()
                tunnel?.stopNetworkMonitoring()
                await tunnel?.disconnect()
            }
        }
        // A process iOS starts while the last check stopped or held the app stops what the OS
        // keeps running for it, such as location monitoring, before anything else.
        if ageSignal.presentation == .stopped || ageSignal.presentation == .held {
            ageSignal.onBlocked()
        }
        tunnel.isBackgroundSustained = { [weak locationManager, weak finishSyncing, weak importBackgroundUpload, weak exportBackgroundDownload, weak observerManager] in
            isBackgroundTunnelSustained(
                locationSustaining: locationManager?.isSustainingBackground ?? false,
                finishSyncingActive: finishSyncing?.isSustainingBackground ?? false,
                importUploadActive: importBackgroundUpload?.isSustainingBackground ?? false,
                observerAudioSustaining: observerManager?.isSustainingBackground ?? false,
                exportDownloadActive: exportBackgroundDownload?.isSustainingBackground ?? false
            )
        }
        let observerBackgroundTunnelCoordinator = ObserverBackgroundTunnelCoordinator(
            tunnelManager: tunnel,
            transferEndpointResolver: transferEndpointResolver,
            transferEngine: transferEngine,
            bootstrapTransferAction: {
                let isAppActive = tunnel.hasReceivedScenePhase
                    ? (tunnel.scenePhase == .active)
                    : (ObserverBackgroundTunnelCoordinator.applicationScenePhase() == .active)
                await Self.runAppBootstrapTransfer(
                    appConfig: appConfig,
                    transferConditionsSource: transferConditionsSource,
                    transferEngine: transferEngine,
                    transferEnqueuer: transferEnqueuer,
                    mobileSegmentUploader: mobileSegmentUploader,
                    shareImportStore: shareImportStore,
                    shareTransferHolder: shareTransferHolder,
                    importBackgroundUpload: importBackgroundUpload,
                    calendarSource: calendarSource,
                    calendarTransferHolder: calendarTransferHolder,
                    obsidianSource: obsidianSource,
                    obsidianTransferHolder: obsidianTransferHolder,
                    screenshotsSource: screenshotsSource,
                    foldersEngine: foldersEngine,
                    diagnosticLog: log,
                    isAppActive: isAppActive
                )
            },
            onTunnelConnected: { localPort in
                await shareTransferHolder.reconcileReadyToReview(
                    localPort: localPort,
                    instanceID: appConfig.deviceID,
                    isPaired: appConfig.isPaired,
                    markConfirmed: appConfig.journalSendConfirmed
                )
                await foregroundDrainGate.requestDrain()
            },
            onTunnelRevoked: {
                appConfig.sharedSources.revoke()
                journalExportTransferManager.cancelForUnpair()
            },
            onTunnelClearPairingRefused: {
                shareTransferHolder.clearPairingRefused()
            },
            isPaired: {
                appConfig.isPaired
            },
            allowsActivity: {
                ageSignal.allowsActivity
            },
            isObserverSustaining: {
                observerManager.isSustainingBackground
            },
            isAnyBackgroundSustaining: {
                isBackgroundTunnelSustained(
                    locationSustaining: locationManager.isSustainingBackground,
                    finishSyncingActive: finishSyncing.isSustainingBackground,
                    importUploadActive: importBackgroundUpload.isSustainingBackground,
                    observerAudioSustaining: observerManager.isSustainingBackground,
                    exportDownloadActive: exportBackgroundDownload.isSustainingBackground
                )
            },
            totals: {
                sendableUploadTotals(
                    mobileSegment: mobileSegmentTransferHolder,
                    watch: watchUploaderHolder,
                    share: shareTransferHolder,
                    calendar: calendarTransferHolder,
                    obsidian: obsidianTransferHolder,
                    screenshotsPending: screenshotsSource.waitingCount,
                    screenshotsUnsendable: screenshotsSource.unsendableCount
                )
            },
            inFlight: {
                uploadInFlight(
                    mobileSegment: mobileSegmentTransferHolder,
                    watch: watchUploaderHolder,
                    share: shareTransferHolder,
                    calendar: calendarTransferHolder
                )
            },
            backoff: {
                uploadBackoff(mirror: transferStatusMirror)
            },
            driveDrain: {
                await driveUploadDrain(
                    mobileSegment: mobileSegmentUploader,
                    transferEngine: transferEngine,
                    shareImportStore: shareImportStore,
                    shareTransferHolder: shareTransferHolder,
                    diagnosticLog: log,
                    watchDrain: watchSegmentDrain
                )
            },
            clock: observerClock,
            isIntegrationMode: Self.isIntegrationMode,
            isUITest: Self.isUITest
        )
        if !Self.isUnitTest {
            observerBackgroundTunnelCoordinator.install(on: observerManager)
        }
        self.observerBackgroundTunnelCoordinator = observerBackgroundTunnelCoordinator
        self._appConfig = State(initialValue: appConfig)
        self._appGroupMirror = State(initialValue: appGroupMirror)
        self._onboardingFlow = State(initialValue: onboardingFlow)
        self._diagnosticLog = State(initialValue: log)
        self._problemReportsManager = State(initialValue: problemReports)
        self._tunnelManager = State(initialValue: tunnel)
        self._connectionStallMonitor = State(initialValue: connectionStallMonitor)
        self._connectionSyncModel = State(initialValue: connectionSyncModel)
        self._mobileSegmentTransferHolder = State(initialValue: mobileSegmentTransferHolder)
        self._watchUploaderHolder = State(initialValue: watchUploaderHolder)
        self._watchSourceFacts = State(initialValue: watchSourceFacts)
        self._transferEndpointResolver = State(initialValue: transferEndpointResolver)
        self._transferStatusMirror = State(initialValue: transferStatusMirror)
        self._transferConditionsSource = State(initialValue: transferConditionsSource)
        self._transferEngine = State(initialValue: transferEngine)
        self._transferEnqueuer = State(initialValue: transferEnqueuer)
        self._shareImportStore = State(initialValue: shareImportStore)
        self._sourceIntakeModel = State(initialValue: SourceIntakeModel(store: sourceIntakeStore, deferInitialLoad: true))
        self._shareTransferHolder = State(initialValue: shareTransferHolder)
        self._calendarSource = State(initialValue: calendarSource)
        self._calendarSourceHandle = State(initialValue: calendarSourceHandle)
        self._obsidianSource = State(initialValue: obsidianSource)
        self._obsidianSourceHandle = State(initialValue: obsidianSourceHandle)
        self._obsidianTransferHolder = State(initialValue: obsidianTransferHolder)
        self._screenshotsSource = State(initialValue: screenshotsSource)
        self._screenshotsSourceHandle = State(initialValue: screenshotsSourceHandle)
#if SOLSTONE_PHOTOS_LIBRARY
        self._photosLibraryEngine = State(initialValue: photosLibraryEngine)
        self._photosLibrarySourceHandle = State(initialValue: photosLibrarySourceHandle)
#endif
        self._foldersEngine = State(initialValue: foldersEngine)
        self._foldersSourceHandle = State(initialValue: foldersSourceHandle)
        self._safariSource = State(initialValue: safariSource)
        self._calendarTransferHolder = State(initialValue: calendarTransferHolder)
        self._calendarBackgroundRefresh = State(initialValue: calendarBackgroundRefresh)
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
        self._finishSyncingCoordinator = State(initialValue: finishSyncing)
        self._importBackgroundUploadCoordinator = State(initialValue: importBackgroundUpload)
        self._journalExportTransferManager = State(initialValue: journalExportTransferManager)
        self._exportBackgroundDownloadCoordinator = State(initialValue: exportBackgroundDownload)
        self._foregroundDrainGate = State(initialValue: foregroundDrainGate)
        self._launchMaintenanceCoordinator = State(initialValue: launchMaintenanceCoordinator)
        self._journalSendRelease = State(initialValue: journalSendRelease)
        self._deviceMigrationOwner = State(initialValue: deviceMigrationOwner)
        self._pairFlowPresence = State(initialValue: pairFlowPresence)
        self._ageSignal = State(initialValue: ageSignal)
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
                .environment(self.onboardingFlow)
                .environment(self.shellNav)
                .environment(self.tunnelManager)
                .environment(self.connectionStallMonitor)
                .environment(self.connectionSyncModel)
                .environment(self.finishSyncingCoordinator)
                .environment(self.importBackgroundUploadCoordinator)
                .environment(self.journalExportTransferManager)
                .environment(self.foregroundDrainGate)
                .environment(self.mobileSegmentTransferHolder)
                .environment(self.watchUploaderHolder)
                .environment(self.watchSourceFacts)
                .environment(self.watchLink)
                .environment(self.watchRelayReceiver)
                .environment(self.watchSegmentLedger)
                .environment(self.phoneSessionHistoryStore)
                .environment(self.shareImportStore)
                .environment(self.sourceIntakeModel)
                .environment(self.shareTransferHolder)
                .environment(self.calendarSource)
                .environment(self.calendarSourceHandle)
                .environment(self.obsidianSource)
                .environment(self.obsidianSourceHandle)
                .environment(self.obsidianTransferHolder)
                .environment(self.screenshotsSource)
                .environment(self.screenshotsSourceHandle)
#if SOLSTONE_PHOTOS_LIBRARY
                .environment(self.photosLibraryEngine)
                .environment(self.photosLibrarySourceHandle)
#endif
                .environment(self.foldersEngine)
                .environment(self.foldersSourceHandle)
                .environment(self.safariSource)
                .environment(self.calendarTransferHolder)
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
                .environment(self.journalSendRelease)
                .environment(self.deviceMigrationOwner)
                .environment(self.pairFlowPresence)
                .environment(self.appDelegate.pushManager)
                .environment(self.appDelegate.pendingRoute)
                .onOpenURL { url in
                    ExternalPairLinkIntake.handle(
                        url: url,
                        pairingHandoff: self.pairingHandoff,
                        appConfig: self.appConfig,
                        pendingObserverCommand: self.pendingObserverCommand,
                        pendingJournalOpen: self.pendingJournalOpen
                    )
                }
                .onChange(of: self.pendingObserverCommand.command) { _, command in
                    guard command == .stopRequested else { return }
                    self.pendingObserverCommand.command = nil
                    Task {
                        _ = await self.observerManager.stopSession()
                    }
                }
                .task {
                    self.connectionSyncModel.setInBackground(self.scenePhase == .background)
                    await self.connectionSyncModel.run()
                }
#if DEBUG && targetEnvironment(simulator)
                .task {
                    await self.integrationGateDriver?.run()
                }
#endif
                .task(priority: .userInitiated) {
                    self.sourceIntakeModel.reload()
                    self.mobileSegmentUploader.scheduleRefreshCounts()
                    let problemReportsTask = Task {
                        await self.problemReportsManager.refreshAsync()
                    }
                    if SafariSourceModel.isBundled {
                        _ = await self.appConfig.syncSafariAuthorityAsync()
                        await self.safariSource?.refreshAsync()
                    }
                    await problemReportsTask.value
                }
                .task {
                    await self.bootstrapTransfer()
                    self.safariTransferReady = SafariSourceModel.isBundled
                }
                .task {
                    while !Task.isCancelled {
                        if self.safariTransferReady {
                            let queued = await SafariBrowserDelivery.queuedBytes(engine: self.transferEngine)
                            if self.safariPassGate.shouldRun(confirmed: self.appConfig.journalSendConfirmed, queued: queued) {
                                let published = await self.appConfig.syncSafariAuthorityAsync()
                                let drained = await SafariBrowserDelivery.drain(engine: self.transferEngine)
                                await self.safariSource?.refreshAsync()
                                if !(published && drained) { self.safariPassGate.forget() }
                            } else {
                                await self.transferEngine.kick()
                            }
                        }
                        do { try await Task.sleep(for: .seconds(5)) }
                        catch { break }
                    }
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
                    self.screencastManager.receiveScenePhase(Self.screencastScenePhase(self.scenePhase))
                }
                .task {
                    ConnectionScenePhaseFanout.deliver(
                        self.scenePhase,
                        tunnel: self.tunnelManager,
                        monitor: self.connectionStallMonitor
                    )
                }
                .task {
                    self.connectionStallMonitor.setNetworkPathSatisfied(self.tunnelManager.isNetworkSatisfied)
                }
                .onChange(of: self.tunnelManager.isNetworkSatisfied) { _, newValue in
                    self.connectionStallMonitor.setNetworkPathSatisfied(newValue)
                }
                .onChange(of: self.appConfig.isPaired) { _, _ in
                    self.connectionStallMonitor.evaluate()
                }
                .onChange(of: self.appConfig.pairedAt) { _, _ in
                    self.connectionStallMonitor.evaluate()
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
                    await self.shareTransferHolder.refreshActiveItems()
                    guard let connection = self.tunnelManager.activeConnection else { return }
                    let pairingIdentity = self.tunnelManager.dialedPairingIdentity
                    await self.transferEndpointResolver.update(
                        activeLocalPort: connection.port,
                        connectionEpoch: connection.epoch
                    )
                    await self.transferEngine.noteNewConnectionEstablished(pairingIdentity: pairingIdentity)
                    await self.transferEngine.endpointAvailabilityChanged()
                    await self.shareTransferHolder.reconcileReadyToReview(
                        localPort: connection.port,
                        instanceID: self.appConfig.deviceID,
                        isPaired: self.appConfig.isPaired,
                        markConfirmed: self.appConfig.journalSendConfirmed
                    )
#if SOLSTONE_PHOTOS_LIBRARY
                    if !Self.isIntegrationMode && !Self.isUITest && self.appConfig.isPaired {
                        await self.photosLibraryEngine.foreground()
                    }
#endif
                    if !Self.isIntegrationMode && !Self.isUITest && self.appConfig.isPaired {
                        await self.foldersEngine.foreground()
                    }
                }
                .onChange(of: self.transferStatusMirror.applyCount) { _, _ in
                    Task { await self.shareTransferHolder.refreshActiveItems() }
                }
                .onChange(of: self.appConfig.deviceID) { prior, current in
                    guard !current.isEmpty, prior != current else { return }
                    Task { await self.shareTransferHolder.handlePairingChange(currentInstanceID: current) }
                }
                .onChange(of: self.appConfig.journalSendConfirmed) { _, confirmed in
                    guard confirmed else { return }
                    Task {
                        await self.shareTransferHolder.reconcileReadyToReview(
                            localPort: self.tunnelManager.activeConnection?.port,
                            instanceID: self.appConfig.deviceID,
                            isPaired: self.appConfig.isPaired,
                            markConfirmed: confirmed
                        )
#if SOLSTONE_PHOTOS_LIBRARY
                        if !Self.isIntegrationMode && !Self.isUITest && self.appConfig.isPaired {
                            await self.photosLibraryEngine.foreground()
                        }
#endif
                        if !Self.isIntegrationMode && !Self.isUITest && self.appConfig.isPaired {
                            self.foldersEngine.clearRetryBackoff()
                            await self.foldersEngine.foreground()
                        }
                    }
                }
                // Last, so a stopped or held app builds none of the above.
                .modifier(AgeSignalGateModifier(model: self.ageSignal))
        }
        .onChange(of: self.scenePhase, initial: true) { _, phase in
            self.ageSignal.scenePhaseChanged(phase)
        }
        .onChange(of: self.scenePhase) { oldPhase, newPhase in
            self.handleScenePhase(oldPhase, newPhase)
        }
        // The first foreground's work waits for the launch check; it runs once the check lets
        // the app go, and again when a parent approves a hold.
        .onChange(of: self.ageSignal.allowsActivity) { _, allowed in
            guard allowed else { return }
            self.handleScenePhase(.inactive, self.scenePhase)
        }
        .onChange(of: self.tunnelManager.state) { _, newState in
            switch newState {
            case .connected(_, let endpoint):
                self.journalExportTransferManager.handleTransportChange(
                    newTransport: endpoint == .remote ? "relay" : "local"
                )
#if SOLSTONE_PHOTOS_LIBRARY
                if !Self.isIntegrationMode && !Self.isUITest && self.appConfig.isPaired {
                    Task { await self.photosLibraryEngine.foreground() }
                }
#endif
                if !Self.isIntegrationMode && !Self.isUITest && self.appConfig.isPaired {
                    self.foldersEngine.clearRetryBackoff()
                    Task { await self.foldersEngine.foreground() }
                }
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
            case .idle, .starting, .stopping, .microphoneTaken, .error:
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

    private func handleScenePhase(_ oldPhase: ScenePhase, _ newPhase: ScenePhase) {
        // While a launch check is open, or has stopped or held the app, none of this runs.
        guard self.ageSignal.allowsActivity else { return }
        self.obsidianSource.setAppActive(newPhase == .active)
        if !Self.isUITest && !Self.isIntegrationMode {
            self.foldersEngine.setAppActive(newPhase == .active)
        }
        self.screencastManager.receiveScenePhase(Self.screencastScenePhase(newPhase))
        ConnectionScenePhaseFanout.deliver(
            newPhase,
            tunnel: self.tunnelManager,
            monitor: self.connectionStallMonitor
        )
        // Leaving the background comes a frame before `.active`, and that first frame must
        // not show the drop going to the background caused.
        if oldPhase == .background, newPhase == .inactive,
           !Self.isIntegrationMode, !Self.isUITest, self.appConfig.isPaired {
            self.connectionSyncModel.noteForeground()
        }
        self.connectionSyncModel.setInBackground(newPhase == .background)
        switch newPhase {
        case .active:
            self.mobileSegmentTransferHolder.refreshJournalGap()
            self.sourceIntakeModel.reload()
            if let safariSource = self.safariSource {
                Task { await safariSource.refreshAsync() }
                Task { await safariSource.refreshExtensionState() }
            }
            self.observerBackgroundTunnelCoordinator.cancelBackgroundDrain()
            if Self.shouldRunLaunchMaintenance(scenePhase: newPhase) {
                Task {
                    await self.launchMaintenanceCoordinator.runForegroundMaintenance()
                }
            }
            Task {
                await self.screencastManager.reconcileScreencast(reason: .foreground)
            }
            self.calendarSource.foreground()
            Task { await self.screenshotsSource.foreground() }
#if SOLSTONE_PHOTOS_LIBRARY
            if !Self.isUITest {
                Task { await self.photosLibraryEngine.foreground() }
            }
#endif
            if !Self.isUITest {
                Task { await self.foldersEngine.foreground() }
            }
            Task { await self.obsidianSource.checkNow() }
            Task {
                await self.shareTransferHolder.refreshActiveItems()
                await self.shareTransferHolder.reconcileReadyToReview(
                    localPort: self.tunnelManager.activeConnection?.port,
                    instanceID: self.appConfig.deviceID,
                    isPaired: self.appConfig.isPaired,
                    markConfirmed: self.appConfig.journalSendConfirmed
                )
            }
            if Self.isIntegrationMode || Self.isUITest {
                return
            }
            guard self.appConfig.isPaired else {
                return
            }
            self.connectionSyncModel.noteForeground()
            self.tunnelManager.startNetworkMonitoring()
            if self.appConfig.retrySettleIfNeeded() {
                self.journalSendRelease.kickConfirmedSend()
            }

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
            Task {
                await self.screencastManager.prepareForBackground()
            }
            self.calendarBackgroundRefresh.schedule()
            self.screenshotsSource.background()
            self.launchMaintenanceCoordinator.cancel()
            self.integrationObserverStartTask?.cancel()
            self.integrationObserverStartTask = nil
            self.integrationObserverStopTask?.cancel()
            self.integrationObserverStopTask = nil
            if Self.isIntegrationMode || Self.isUITest {
                return
            }
            self.observerBackgroundTunnelCoordinator.startBackgroundDrain()
        default:
            break
        }
    }

    private func bootstrapTransfer() async {
        await self.observerBackgroundTunnelCoordinator.bootstrapTransferIfNeeded()
    }

    @MainActor
    private static func runAppBootstrapTransfer(
        appConfig: AppConfig,
        transferConditionsSource: TransferConditionsSource,
        transferEngine: TransferEngine,
        transferEnqueuer: ObserverAudioTransferEnqueuer,
        mobileSegmentUploader: MobileSegmentUploader,
        shareImportStore: ShareImportStore,
        shareTransferHolder: ShareTransferHolder,
        importBackgroundUpload: ImportBackgroundUploadCoordinator,
        calendarSource: CalendarSourceEngine,
        calendarTransferHolder: CalendarTransferHolder,
        obsidianSource: ObsidianSourceEngine,
        obsidianTransferHolder: ObsidianTransferHolder,
        screenshotsSource: ScreenshotsSourceEngine,
        foldersEngine: FoldersEngine,
        diagnosticLog: DiagnosticLog,
        isAppActive: Bool
    ) async {
        await transferEngine.registerDeliveredHook(sourceKey: ObserverAudioTransferSource.mobileSegment) { [weak mobileSegmentUploader] manifest, _ in
            guard let segmentID = manifest.observerIngest?.segmentID else { return }
            try await MainActor.run {
                try mobileSegmentUploader?.writeUploadedTombstone(segmentID: segmentID)
            }
        }
        await transferEngine.registerDeliveredHook(sourceKey: ObserverAudioTransferSource.share) { [weak shareImportStore, weak shareTransferHolder, weak appConfig] manifest, successKind in
            try await MainActor.run {
                try shareImportStore?.recordDelivered(
                    manifest: manifest,
                    successKind: successKind,
                    fallbackInstanceID: appConfig?.deviceID
                )
            }
            await shareTransferHolder?.refreshActiveItems()
        }
        await transferEngine.registerAttentionHook(sourceKey: ObserverAudioTransferSource.share) { [weak shareTransferHolder] _ in
            await shareTransferHolder?.refreshActiveItems()
        }
        await transferEngine.setResumableProgressObserver { [weak coordinator = importBackgroundUpload] itemID, progress in
            await MainActor.run {
                coordinator?.handleResumableProgress(itemID: itemID, progress: progress)
            }
        }
        // A calendar file reaching the journal, or one the owner removed there, leaves room for
        // an import's next files.
        await transferEngine.registerDeliveredHook(sourceKey: CalendarTransfer.sourceKey) { [calendarSource, calendarTransferHolder] _, _ in
            await MainActor.run {
                calendarSource.deliveryProgressed()
            }
            await calendarTransferHolder.refreshNoteCounts()
        }
        // A calendar file the journal turned away leaves the queue too, so an import does not
        // stall behind it.
        await transferEngine.registerAttentionHook(sourceKey: CalendarTransfer.sourceKey) { [calendarSource, calendarTransferHolder] _ in
            await MainActor.run {
                calendarSource.deliveryProgressed()
            }
            await calendarTransferHolder.refreshNoteCounts()
        }
        // An obsidian file reaching the journal leaves room for next files.
        await transferEngine.registerDeliveredHook(sourceKey: ObsidianTransfer.sourceKey) { [obsidianTransferHolder] _, _ in
            await obsidianTransferHolder.refreshNoteCounts()
        }
        // An obsidian file the journal turned away leaves the queue too.
        await transferEngine.registerAttentionHook(sourceKey: ObsidianTransfer.sourceKey) { [obsidianTransferHolder] _ in
            await obsidianTransferHolder.refreshNoteCounts()
        }
        await transferEngine.registerDeliveredHook(sourceKey: ScreenshotsWire.sourceKey) { [screenshotsSource] manifest, _ in
            guard let localIdentifier = ScreenshotsTransfer.localIdentifier(manifest),
                  let hash = ScreenshotsTransfer.hash(manifest) else { return }
            await MainActor.run {
                screenshotsSource.noteDelivered(localIdentifier: localIdentifier, hash: hash)
            }
        }
        await transferEngine.registerAttentionHook(sourceKey: ScreenshotsWire.sourceKey) { [screenshotsSource] manifest in
            guard let localIdentifier = ScreenshotsTransfer.localIdentifier(manifest) else { return }
            await MainActor.run {
                screenshotsSource.noteRefused(localIdentifier: localIdentifier)
            }
        }

        let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        await Self.bootstrapTransfer(
            initialize: {
                transferConditionsSource.start {
                    Task { await transferEngine.kick() }
                }
                try await transferEngine.initialize()
            },
            appGroupRoot: {
                try AppGroupContainer.rootURL()
            },
            cachesRootURL: cachesRoot,
            migrate: { appGroupRoot, cacheRoot in
                await WatchTransferSpoolMigrator.migrate(
                    appGroupRootURL: appGroupRoot,
                    legacyRootURL: (cacheRoot ?? FileManager.default.temporaryDirectory)
                        .appendingPathComponent(WatchTransferSpoolMigrator.legacyCacheDirectoryName, isDirectory: true),
                    transferEnqueuer: transferEnqueuer,
                    diagnosticLog: diagnosticLog
                )
                await MobileSegmentTransferSpoolMigrator.migrate(
                    appGroupRootURL: appGroupRoot,
                    observerCacheRootURL: cacheRoot?.appendingPathComponent("Observer", isDirectory: true),
                    store: mobileSegmentUploader.storeForTransferMigration,
                    diagnosticLog: diagnosticLog
                )
                await ShareImportTransferSpoolMigrator.migrate(
                    appGroupRootURL: appGroupRoot,
                    store: shareImportStore,
                    transferEngine: transferEngine,
                    diagnosticLog: diagnosticLog
                )
            },
            reconcile: {
                await mobileSegmentUploader.resumeFromDisk()
                shareImportStore.refreshFromDisk()
                // The photo-library import is retired. An album import that was in progress does not continue.
                // The calendar source finishes a step a kill interrupted before anything is sent.
                // It reads nothing unless the owner has set it up.
                await calendarSource.launch()
                await calendarTransferHolder.refreshNoteCounts()
                obsidianSource.setAppActive(isAppActive)
                await obsidianSource.launch()
                await obsidianTransferHolder.refreshNoteCounts()
                await screenshotsSource.launch()
                if !Self.isUITest && !Self.isIntegrationMode {
                    foldersEngine.setAppActive(isAppActive)
                }
            },
            enableDispatch: {
                await transferEngine.enableDispatch()
            },
            reportFailure: { reason, error in
                diagnosticLog.append(
                    category: .upload,
                    severity: .warning,
                    message: AppStrings.ios_transfer_needsattention(),
                    detail: AppStrings.ios_app_bootstraptransfer4("\(reason)")
                )
                if let error {
                    Logger(subsystem: "app.solstone.swift", category: "transfer")
                        .error("transfer start failed: \(String(describing: error), privacy: .public)")
                }
            }
        )
    }
}

private extension SolstoneSwiftApp {
    static let legacyKeychainPurgeDoneKey = "didPurgeLegacyKeychainEntriesV1"

    static func scheduleLegacyKeychainPurgeIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.legacyKeychainPurgeDoneKey) else { return }
        let key = Self.legacyKeychainPurgeDoneKey
        Task.detached(priority: .utility) {
            if Self.purgeLegacyKeychainEntries() {
                UserDefaults.standard.set(true, forKey: key)
            }
        }
    }

    @discardableResult
    nonisolated static func purgeLegacyKeychainEntries() -> Bool {
        var allSucceeded = true
        for account in [
            "solstone-swift-identity-key",
            "solstone-swift-host-key",
            "solstone-swift-pair-identity",
            "solstone-swift-pair-session",
            "solstone-swift-observer-ingest-key-v2",
            "solstone-swift-observer-ingest-prefix",
            "solstone-swift-watch-ingest-key-v2",
            "solstone-swift-watch-ingest-prefix",
        ] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "app.solstone.swift",
                kSecAttrAccount as String: account,
            ]
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                allSucceeded = false
            }
        }
        if allSucceeded {
            Logger(subsystem: "app.solstone.swift", category: "app-config").debug("legacy keychain entries purged")
        } else {
            Logger(subsystem: "app.solstone.swift", category: "app-config").warning("legacy keychain purge incomplete; will retry next launch")
        }
        return allSucceeded
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

    static func makeObserverRecorder(journalEventsDirectory: URL) -> any ObserverRecording {
#if DEBUG
        if self.isIntegrationTest {
            return IntegrationTestObserverRecorder()
        }
        if self.isUITest && self.shouldUseUITestObserverRecorder {
            return IntegrationTestObserverRecorder(permissionGranted: self.uiTestObserverPermissionGranted)
        }
#endif
        return LiveObserverRecorder(journalEventsDirectory: journalEventsDirectory)
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

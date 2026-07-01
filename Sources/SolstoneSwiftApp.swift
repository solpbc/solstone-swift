// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import UIKit
import Security
import SwiftUI
import SPLTunnel
import os

@main
struct SolstoneSwiftApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appConfig: AppConfig
    @State private var onboardingFlow: OnboardingFlow
    @State private var tunnelManager: TunnelManager
    @State private var brainStatusMonitor: BrainStatusMonitor
    @State private var diagnosticLog: DiagnosticLog
    @State private var observerRegistration: ObserverRegistration
    @State private var observerUploader: ObserverUploader
    @State private var mobileHealthBeacon: ObserverHealthBeacon
    @State private var omiRegistration: ObserverRegistration
    @State private var omiUploader: ObserverUploader
    @State private var omiHealthBeacon: ObserverHealthBeacon
    @State private var omiUploaderHolder: OmiUploaderHolder
    @State private var watchRegistration: ObserverRegistration
    @State private var watchUploader: ObserverUploader
    @State private var watchHealthBeacon: ObserverHealthBeacon
    @State private var watchUploaderHolder: WatchUploaderHolder
    @State private var watchSegmentDrain: WatchSegmentDrain?
    @State private var watchRelayReceiver: WatchRelayReceiver?
    @State private var importQueue: ImportQueue
    @State private var mobileSegmentUploader: MobileSegmentUploader
    @State private var mobileSegmentEngine: MobileSegmentEngine
    @State private var locationManager: LocationManager
    @State private var screencastManager: ScreencastManager
    @State private var observerManager: ObserverManager
    @State private var watchLink: WatchLink
    @State private var pendingObserverCommand = PendingObserverCommandState()
    @State private var pendingFold = PendingFoldState()
    @State private var pairingHandoff = PairingHandoffState()
    @State private var voiceManager: VoiceManager
    @State private var chatManager: ChatManager
    @State private var omiSourceManager: OmiSourceManager
    @State private var finishSyncingCoordinator: FinishSyncingCoordinator
    @State private var foregroundDrainGate: ForegroundDrainGate
    @State private var backgroundDrainTask: Task<Void, Never>?
    @State private var integrationVoiceStartTask: Task<Void, Never>?
    @State private var integrationObserverStartTask: Task<Void, Never>?
    @State private var integrationObserverStopTask: Task<Void, Never>?
    @State private var didAutoStartIntegrationVoice = false
    @State private var didAutoStartIntegrationObserver = false
    @State private var didAutoStopIntegrationObserver = false
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

    private static var shouldAutoStartIntegrationVoice: Bool {
#if DEBUG
        if let observerTap = self.integrationObserverTapKind {
            return observerTap == "voice"
        }
        return !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--integration-test-push-tap=") })
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

    private static var shouldResetIntegrationObserverRegistration: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--integration-test-observer-reset-registration")
#else
        false
#endif
    }

    init() {
        Self.purgeLegacyKeychainEntries()
        Self.migrateLegacyIngestPrefixes()
        InnerTLS.purgeOrphanedIdentities()
        if ProcessInfo.processInfo.arguments.contains("--integration-test-onboarding") {
            Self.resetOnboardingIntegrationState()
        }
        let log = DiagnosticLog()
        let appConfig = AppConfig()
        let observerClock = SystemObserverClock()
        let healthSession = URLSession(configuration: .default)
        let onboardingFlow = OnboardingFlow()
        let transport = CFTunnelTransport(appConfig: appConfig)
        let tunnel = TunnelManager(
            transport: transport,
            diagnosticLog: log
        )
        let brain = BrainStatusMonitor(diagnosticLog: log)
        let observerRegistration = ObserverRegistration(
            hostname: UIDevice.current.name,
            version: AppVersion.shortVersion,
            streamType: "mobile",
            label: nil
        )
        if Self.shouldResetIntegrationObserverRegistration {
            observerRegistration.reset()
        }
#if DEBUG
        OnThisPhoneUITestSeeder.runIfRequested()
#endif
        let observerUploader = ObserverUploader(
            ensureRegistered: {
                try await observerRegistration.ensureRegistered()
            },
            isJournalConfigured: {
                appConfig.isPaired
            },
            localPortProvider: {
                observerRegistration.activeLocalPort
            },
            registrationPrefixProvider: {
                observerRegistration.registrationPrefix
            },
            diagnosticLog: log
        )
        let mobileSegmentStore: MobileSegmentStore
        let mobileSegmentStorageDisabledReason: String?
        let mobileSegmentMigrationDiagnostics: [String]
        do {
            let appGroupMobileSegmentRoot = try AppGroupContainer.rootURL()
                .appendingPathComponent(MobileSegmentStore.directoryName, isDirectory: true)
            mobileSegmentStore = MobileSegmentStore(rootURL: appGroupMobileSegmentRoot)
            mobileSegmentStorageDisabledReason = nil
            let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent(MobileSegmentStore.directoryName, isDirectory: true)
            if let cachesRoot {
                mobileSegmentMigrationDiagnostics = mobileSegmentStore.migrateRoot(fromLegacyCachesRoot: cachesRoot)
            } else {
                mobileSegmentMigrationDiagnostics = []
            }
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
        let mobileSegmentUploader = MobileSegmentUploader(
            transport: observerUploader,
            store: mobileSegmentStore,
            clock: observerClock,
            storageDisabledReason: mobileSegmentStorageDisabledReason
        )
        if mobileSegmentUploader.lastError == nil {
            mobileSegmentUploader.lastError = mobileSegmentMigrationDiagnostics.first
        }
        let mobileSegmentEngine = MobileSegmentEngine(
            uploader: mobileSegmentUploader,
            clock: observerClock
        )
        let mobileHealthBeacon = ObserverHealthBeacon(
            registration: observerRegistration,
            uploader: mobileSegmentUploader,
            isJournalConfigured: {
                appConfig.isPaired
            },
            session: healthSession,
            clock: observerClock
        )
        let omiRegistration = ObserverRegistration(
            hostname: UIDevice.current.name,
            version: AppVersion.shortVersion,
            streamType: "omi",
            label: "omi pendant",
            loadKey: {
                try ObserverKeychain.loadOmiIngestKey()
            },
            saveKey: {
                try ObserverKeychain.saveOmiIngestKey($0)
            },
            deleteKey: {
                try ObserverKeychain.deleteOmiIngestKey()
            },
            loadPrefix: {
                IngestPrefixStore().load(.omi)
            },
            savePrefix: {
                IngestPrefixStore().save($0, for: .omi)
            },
            deletePrefix: {
                IngestPrefixStore().clear(.omi)
            }
        )
        let omiUploadConfiguration = URLSessionConfiguration.background(
            withIdentifier: OmiSegmentWriter.backgroundSessionIdentifier
        )
        omiUploadConfiguration.waitsForConnectivity = true
        let omiCacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true)
        let omiUploader = ObserverUploader(
            cacheRootURL: omiCacheRoot,
            sessionConfiguration: omiUploadConfiguration,
            ensureRegistered: {
                try await omiRegistration.ensureRegistered()
            },
            isJournalConfigured: {
                appConfig.isPaired
            },
            localPortProvider: {
                omiRegistration.activeLocalPort
            },
            registrationPrefixProvider: {
                omiRegistration.registrationPrefix
            },
            diagnosticLog: log,
            sourceType: "omi-audio"
        )
        let omiHealthBeacon = ObserverHealthBeacon(
            registration: omiRegistration,
            uploader: omiUploader,
            isJournalConfigured: {
                appConfig.isPaired
            },
            session: healthSession,
            clock: observerClock
        )
        let omiUploaderHolder = OmiUploaderHolder(omiUploader)
        let watchRegistration = ObserverRegistration(
            hostname: UIDevice.current.name,
            version: AppVersion.shortVersion,
            streamType: "watch",
            label: "watch",
            loadKey: {
                try ObserverKeychain.loadWatchIngestKey()
            },
            saveKey: {
                try ObserverKeychain.saveWatchIngestKey($0)
            },
            deleteKey: {
                try ObserverKeychain.deleteWatchIngestKey()
            },
            loadPrefix: {
                IngestPrefixStore().load(.watch)
            },
            savePrefix: {
                IngestPrefixStore().save($0, for: .watch)
            },
            deletePrefix: {
                IngestPrefixStore().clear(.watch)
            }
        )
        let watchUploadConfiguration = URLSessionConfiguration.background(
            withIdentifier: WatchSegmentDrain.backgroundSessionIdentifier
        )
        watchUploadConfiguration.waitsForConnectivity = true
        let watchCacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(WatchSegmentDrain.cacheDirectoryName, isDirectory: true)
        let watchUploader = ObserverUploader(
            cacheRootURL: watchCacheRoot,
            sessionConfiguration: watchUploadConfiguration,
            ensureRegistered: {
                try await watchRegistration.ensureRegistered()
            },
            isJournalConfigured: {
                appConfig.isPaired
            },
            localPortProvider: {
                watchRegistration.activeLocalPort
            },
            registrationPrefixProvider: {
                watchRegistration.registrationPrefix
            },
            diagnosticLog: log,
            sourceType: "watch-audio",
            platform: "watchos"
        )
        let watchHealthBeacon = ObserverHealthBeacon(
            registration: watchRegistration,
            uploader: watchUploader,
            isJournalConfigured: {
                appConfig.isPaired
            },
            session: healthSession,
            clock: observerClock
        )
        let watchUploaderHolder = WatchUploaderHolder(watchUploader)
        let watchSegmentDrain: WatchSegmentDrain?
        do {
            watchSegmentDrain = try WatchSegmentDrain(
                watchUploader: watchUploader,
                watchRegistration: watchRegistration,
                localPortProvider: {
                    watchRegistration.activeLocalPort
                }
            )
        } catch {
            Logger(subsystem: "app.solstone.swift", category: "watch-drain")
                .error("watch segment drain unavailable: \(String(describing: error), privacy: .public)")
            watchSegmentDrain = nil
        }
        watchUploaderHolder.removeStaging = { [weak watchSegmentDrain] id in
            watchSegmentDrain?.removeStaged(id)
        }
        let importQueue = ImportQueue(
            ensureRegistered: {
                try await observerRegistration.ensureRegistered()
            },
            isJournalConfigured: {
                appConfig.isPaired
            },
            localPortProvider: {
                observerRegistration.activeLocalPort
            }
        )
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
        let watchConnectivitySession = LiveWatchConnectivitySession()
        let watchRelayReceiver: WatchRelayReceiver?
        do {
            watchRelayReceiver = try WatchRelayReceiver(session: watchConnectivitySession)
        } catch {
            Logger(subsystem: "app.solstone.swift", category: "watch-relay")
                .error("watch relay receiver unavailable: \(String(describing: error), privacy: .public)")
            watchRelayReceiver = nil
        }
        watchRelayReceiver?.onSegmentStaged = { _ in
            Task {
                await watchSegmentDrain?.drain()
            }
        }
        let watchLink = WatchLink(session: watchConnectivitySession, receiver: watchRelayReceiver)
        watchLink.activate()
        let voice = VoiceManager(
            webrtc: Self.makeWebRTCConnector(),
            diagnosticLog: log
        )
        let chatTransport = ConveyChatTransport(
            localPortProvider: {
                observerRegistration.activeLocalPort
            }
        )
        let chat = ChatManager(
            transport: chatTransport,
            isReachable: {
                tunnel.state.isConnected
            },
            localPortProvider: {
                observerRegistration.activeLocalPort
            }
        )
        let omiSegmentWriter = OmiSegmentWriter(uploader: omiUploader, clock: observerClock)
        let omiSource = OmiSourceManager()
        let omiHeardTally = omiSource.heardTally
        omiSegmentWriter.onChunkFinalized = { day, durationS, identity in
            omiHeardTally.record(day: day, durationS: durationS, identity: identity)
        }
        omiSource.omiSegmentWriter = omiSegmentWriter
        omiSource.onDecodedSamples = { [weak omiSegmentWriter] samples in
            omiSegmentWriter?.append(samples)
        }
        voice.onObserverAction = { @MainActor action in
            switch action {
            case .startObserver(let mode):
                Task { @MainActor in
                    await observerManager.startSession(mode: mode)
                    observerManager.persistEnrolledIfActive()
                }
            }
        }
        let finishSyncing = FinishSyncingCoordinator(
            totals: {
                uploadTotals(
                    mobileSegment: mobileSegmentUploader,
                    omi: omiUploaderHolder,
                    watch: watchUploaderHolder,
                    importQueue: importQueue
                )
            },
            inFlight: {
                uploadInFlight(
                    mobileSegment: mobileSegmentUploader,
                    omi: omiUploaderHolder,
                    watch: watchUploaderHolder,
                    importQueue: importQueue
                )
            },
            drive: {
                await driveUploadDrain(
                    mobileSegment: mobileSegmentUploader,
                    omi: omiUploader,
                    watch: watchUploader,
                    importQueue: importQueue,
                    watchDrain: watchSegmentDrain
                )
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
                omi: omiUploader,
                watch: watchUploader,
                importQueue: importQueue,
                watchDrain: watchSegmentDrain
            )
        })
        if !Self.isIntegrationMode && !Self.isUITest && !Self.isUnitTest {
            finishSyncing.registerLaunchHandler()
        }
        self._appConfig = State(initialValue: appConfig)
        self._onboardingFlow = State(initialValue: onboardingFlow)
        self._diagnosticLog = State(initialValue: log)
        self._brainStatusMonitor = State(initialValue: brain)
        self._tunnelManager = State(initialValue: tunnel)
        self._observerRegistration = State(initialValue: observerRegistration)
        self._observerUploader = State(initialValue: observerUploader)
        self._mobileHealthBeacon = State(initialValue: mobileHealthBeacon)
        self._omiRegistration = State(initialValue: omiRegistration)
        self._omiUploader = State(initialValue: omiUploader)
        self._omiHealthBeacon = State(initialValue: omiHealthBeacon)
        self._omiUploaderHolder = State(initialValue: omiUploaderHolder)
        self._watchRegistration = State(initialValue: watchRegistration)
        self._watchUploader = State(initialValue: watchUploader)
        self._watchHealthBeacon = State(initialValue: watchHealthBeacon)
        self._watchUploaderHolder = State(initialValue: watchUploaderHolder)
        self._watchSegmentDrain = State(initialValue: watchSegmentDrain)
        self._watchRelayReceiver = State(initialValue: watchRelayReceiver)
        self._importQueue = State(initialValue: importQueue)
        self._mobileSegmentUploader = State(initialValue: mobileSegmentUploader)
        self._mobileSegmentEngine = State(initialValue: mobileSegmentEngine)
        self._locationManager = State(initialValue: locationManager)
        self._screencastManager = State(initialValue: screencastManager)
        self._observerManager = State(initialValue: observerManager)
        self._watchLink = State(initialValue: watchLink)
        self._voiceManager = State(initialValue: voice)
        self._chatManager = State(initialValue: chat)
        self._omiSourceManager = State(initialValue: omiSource)
        self._finishSyncingCoordinator = State(initialValue: finishSyncing)
        self._foregroundDrainGate = State(initialValue: foregroundDrainGate)
        self.appDelegate.observerUploader = observerUploader
        self.appDelegate.omiUploader = omiUploader
        self.appDelegate.watchUploader = watchUploader
        self.appDelegate.importQueue = importQueue
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(self.appConfig)
                .environment(self.onboardingFlow)
                .environment(self.tunnelManager)
                .environment(self.finishSyncingCoordinator)
                .environment(self.foregroundDrainGate)
                .environment(self.voiceManager)
                .environment(self.chatManager)
                .environment(self.omiSourceManager)
                .environment(self.observerRegistration)
                .environment(self.observerUploader)
                .environment(self.omiUploaderHolder)
                .environment(self.watchUploaderHolder)
                .environment(self.watchLink)
                .environment(self.watchRelayReceiver)
                .environment(self.importQueue)
                .environment(self.mobileSegmentUploader)
                .environment(self.mobileSegmentEngine)
                .environment(self.locationManager)
                .environment(self.screencastManager)
                .environment(self.observerManager)
                .environment(self.pendingObserverCommand)
                .environment(self.pairingHandoff)
                .environment(self.brainStatusMonitor)
                .environment(self.diagnosticLog)
                .environment(self.appDelegate.pushManager)
                .environment(self.appDelegate.pendingRoute)
                .environment(self.pendingFold)
                .onOpenURL { url in
                    if self.pairingHandoff.applyUniversalLink(url) {
                        return
                    }
                    switch SolstoneDeepLink.parse(url) {
                    case .observerStop:
                        self.pendingObserverCommand.command = .stopRequested
                    case nil:
                        break
                    }
                }
                .onChange(of: self.pendingObserverCommand.command) { _, command in
                    guard command == .stopRequested else { return }
                    self.pendingObserverCommand.command = nil
                    Task {
                        await self.observerManager.stopSession()
                    }
                }
                .task {
                    self.mobileHealthBeacon.start()
                    self.omiHealthBeacon.start()
                    self.watchHealthBeacon.start()
                }
                .task {
                    await self.importQueue.resumeFromDisk()
                }
                .task {
                    self.screencastManager.startObservingDarwin()
                    await self.screencastManager.reconcileScreencast(reason: .launch)
                }
                .task {
                    guard !UserDefaults.standard.bool(forKey: "didMigrateLegacyMobileSegmentsV1") else {
                        await self.mobileSegmentEngine.resumeFromDisk()
                        await self.screencastManager.reconcileScreencast(reason: .mobileSegmentResume)
                        return
                    }
                    await self.mobileSegmentUploader.migrateLegacyMobileItems()
                    UserDefaults.standard.set(true, forKey: "didMigrateLegacyMobileSegmentsV1")
                    await self.screencastManager.reconcileScreencast(reason: .mobileSegmentResume)
                }
                .task {
                    guard !UserDefaults.standard.bool(forKey: "didMigrateLegacyAudioSegmentKeysV1") else { return }
                    _ = await self.omiUploader.migrateLegacySegmentKeys()
                    UserDefaults.standard.set(true, forKey: "didMigrateLegacyAudioSegmentKeysV1")
                }
                .task {
                    _ = ObserverKeychain.migrateIngestKeyAccessibility()
                }
                .task {
                    await self.locationManager.resumeIfEnabled()
                }
                .task {
                    await self.omiSourceManager.resumeIfEnabled()
                }
                .task {
                    await self.watchSegmentDrain?.drain()
                }
                .task {
                    // cold-launch-into-connected: .onChange doesn't fire for the initial tunnel value,
                    // so an already-connected tunnel at launch is driven by neither the connected-edge
                    // nor the scene-active handler. This is the only trigger covering that case.
                    if Self.isIntegrationMode || Self.isUITest { return }
                    guard self.appConfig.isPaired else { return }
                    guard case .connected = self.tunnelManager.state else { return }
                    await self.foregroundDrainGate.requestDrain()
                }
                .task {
                    if case .idle = self.observerManager.state {
                        await self.observerManager.endStaleObserverActivities()
                    }
                }
        }
        .onChange(of: self.scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                self.backgroundDrainTask?.cancel()
                self.backgroundDrainTask = nil
                Task {
                    await self.screencastManager.reconcileScreencast(reason: .foreground)
                }
                if Self.isIntegrationMode || Self.isUITest {
                    return
                }
                guard self.appConfig.isPaired else {
                    return
                }
                self.tunnelManager.startNetworkMonitoring()

                switch self.tunnelManager.state {
                case .connected:
                    // Only an already-connected tunnel needs a foreground drain kick: connecting /
                    // waitingForHome / disconnected / retryable-error all converge on a future .connected
                    // edge (which drives via the .onChange handler); already-connected has no future edge.
                    Task { await self.foregroundDrainGate.requestDrain() }
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
                self.integrationVoiceStartTask?.cancel()
                self.integrationVoiceStartTask = nil
                self.integrationObserverStartTask?.cancel()
                self.integrationObserverStartTask = nil
                self.integrationObserverStopTask?.cancel()
                self.integrationObserverStopTask = nil
                self.voiceManager.endSession()
                if Self.isIntegrationMode || Self.isUITest {
                    return
                }
                let coordinator = BackgroundDrainCoordinator(
                    totals: {
                        uploadTotals(
                            mobileSegment: self.mobileSegmentUploader,
                            omi: self.omiUploaderHolder,
                            watch: self.watchUploaderHolder,
                            importQueue: self.importQueue
                        )
                    },
                    inFlight: {
                        uploadInFlight(
                            mobileSegment: self.mobileSegmentUploader,
                            omi: self.omiUploaderHolder,
                            watch: self.watchUploaderHolder,
                            importQueue: self.importQueue
                        )
                    },
                    isSustaining: { self.locationManager.isSustainingBackground },
                    isConnected: { self.tunnelManager.state.isConnected },
                    drive: {
                        await driveUploadDrain(
                            mobileSegment: self.mobileSegmentUploader,
                            omi: self.omiUploader,
                            watch: self.watchUploader,
                            importQueue: self.importQueue,
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
                    await coordinator.run()
                }
            default:
                break
            }
        }
        .onChange(of: self.tunnelManager.state) { _, newState in
            switch newState {
            case .connected(let port, _):
                self.observerRegistration.activeLocalPort = port
                self.omiRegistration.activeLocalPort = port
                self.watchRegistration.activeLocalPort = port
                self.brainStatusMonitor.startPolling(localPort: port)
                Task { await self.foregroundDrainGate.requestDrain() }

                if Self.isIntegrationMode,
                   Self.shouldAutoStartIntegrationVoice,
                   !self.didAutoStartIntegrationVoice
                {
                    self.didAutoStartIntegrationVoice = true
                    self.integrationVoiceStartTask?.cancel()
                    self.integrationVoiceStartTask = Task {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled else { return }
                        await self.voiceManager.startSession(localPort: port)
                    }
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
                        await self.observerManager.startSession(mode: .meeting)
                    }
                }
            case .connecting, .waitingForHome, .disconnected, .error:
                self.observerRegistration.activeLocalPort = nil
                self.omiRegistration.activeLocalPort = nil
                self.watchRegistration.activeLocalPort = nil
                self.integrationVoiceStartTask?.cancel()
                self.integrationVoiceStartTask = nil
                self.integrationObserverStartTask?.cancel()
                self.integrationObserverStartTask = nil
                self.integrationObserverStopTask?.cancel()
                self.integrationObserverStopTask = nil
                self.brainStatusMonitor.stopPolling()
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
                    await self.observerManager.stopSession()
                }
            case .idle, .starting, .stopping, .error:
                break
            }
        }
    }
}

extension SolstoneSwiftApp {
    typealias LegacyIngestPrefixStream = (
        stream: IngestPrefixStore.Stream,
        name: String,
        legacyLoad: () throws -> String?,
        legacyDelete: () throws -> Void
    )

    static func migrateLegacyIngestPrefixes(store: IngestPrefixStore, streams: [LegacyIngestPrefixStream]) {
        let log = Logger(subsystem: "app.solstone.swift", category: "ingest-prefix-migration")

        for (stream, name, legacyLoad, legacyDelete) in streams {
            guard let legacy = try? legacyLoad() else { continue }
            let current = store.load(stream)
            if current == nil {
                store.save(legacy, for: stream)
                guard store.load(stream) != nil else { continue }
            } else if current != legacy {
                log.error("legacy ingest prefix conflict for \(name, privacy: .public): keeping defaults value")
            }

            do {
                try legacyDelete()
            } catch {
                log.error("legacy ingest prefix delete failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
        }
    }
}

private extension SolstoneSwiftApp {
    static func migrateLegacyIngestPrefixes() {
        let store = IngestPrefixStore()
        let streams: [LegacyIngestPrefixStream] = [
            (.observer, "observer",
             { try ObserverKeychain.legacyLoadObserverIngestPrefix() },
             { try ObserverKeychain.legacyDeleteObserverIngestPrefix() }),
            (.omi, "omi",
             { try ObserverKeychain.legacyLoadOmiIngestPrefix() },
             { try ObserverKeychain.legacyDeleteOmiIngestPrefix() }),
            (.watch, "watch",
             { try ObserverKeychain.legacyLoadWatchIngestPrefix() },
             { try ObserverKeychain.legacyDeleteWatchIngestPrefix() }),
        ]

        self.migrateLegacyIngestPrefixes(store: store, streams: streams)
    }

    static func purgeLegacyKeychainEntries() {
        for account in [
            "solstone-swift-identity-key",
            "solstone-swift-host-key",
            "solstone-swift-pair-identity",
            "solstone-swift-pair-session",
        ] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "app.solstone.swift",
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
        Logger(subsystem: "app.solstone.swift", category: "app-config").debug("legacy SSH keychain entries purged")
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

    static func makeWebRTCConnector() -> any WebRTCConnecting {
#if DEBUG
        if self.isIntegrationTest {
            return IntegrationTestWebRTCConnector()
        }
#endif
        return WebRTCManager()
    }
}

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
    @State private var omiRegistration: ObserverRegistration
    @State private var omiUploader: ObserverUploader
    @State private var omiUploaderHolder: OmiUploaderHolder
    @State private var watchRegistration: ObserverRegistration
    @State private var watchUploader: ObserverUploader
    @State private var watchUploaderHolder: WatchUploaderHolder
    @State private var watchSegmentDrain: WatchSegmentDrain?
    @State private var importQueue: ImportQueue
    @State private var locationUploader: LocationUploader
    @State private var locationManager: LocationManager
    @State private var observerManager: ObserverManager
    @State private var watchLink: WatchLink
    @State private var pendingObserverCommand = PendingObserverCommandState()
    @State private var pendingFold = PendingFoldState()
    @State private var pairingHandoff = PairingHandoffState()
    @State private var voiceManager: VoiceManager
    @State private var chatManager: ChatManager
    @State private var omiSourceManager: OmiSourceManager
    @State private var backgroundDisconnectTask: Task<Void, Never>?
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
        InnerTLS.purgeOrphanedIdentities()
        if ProcessInfo.processInfo.arguments.contains("--integration-test-onboarding") {
            Self.resetOnboardingIntegrationState()
        }
        let log = DiagnosticLog()
        let appConfig = AppConfig()
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
                try ObserverKeychain.loadOmiIngestPrefix()
            },
            savePrefix: {
                try ObserverKeychain.saveOmiIngestPrefix($0)
            },
            deletePrefix: {
                try ObserverKeychain.deleteOmiIngestPrefix()
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
                try ObserverKeychain.loadWatchIngestPrefix()
            },
            savePrefix: {
                try ObserverKeychain.saveWatchIngestPrefix($0)
            },
            deletePrefix: {
                try ObserverKeychain.deleteWatchIngestPrefix()
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
        let locationUploader = LocationUploader(
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
        let locationManager = LocationManager(uploader: locationUploader)
        let observerRecorder = Self.makeObserverRecorder()
        let observerManager = ObserverManager(recorder: observerRecorder, uploader: observerUploader)
        let watchConnectivitySession = LiveWatchConnectivitySession()
        let watchRelayReceiver: WatchRelayReceiver?
        do {
            watchRelayReceiver = try WatchRelayReceiver(session: watchConnectivitySession)
        } catch {
            Logger(subsystem: "app.solstone.swift", category: "watch-relay")
                .error("watch relay receiver unavailable: \(String(describing: error), privacy: .public)")
            watchRelayReceiver = nil
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
        let omiSegmentWriter = OmiSegmentWriter(uploader: omiUploader)
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
        self._appConfig = State(initialValue: appConfig)
        self._onboardingFlow = State(initialValue: onboardingFlow)
        self._diagnosticLog = State(initialValue: log)
        self._brainStatusMonitor = State(initialValue: brain)
        self._tunnelManager = State(initialValue: tunnel)
        self._observerRegistration = State(initialValue: observerRegistration)
        self._observerUploader = State(initialValue: observerUploader)
        self._omiRegistration = State(initialValue: omiRegistration)
        self._omiUploader = State(initialValue: omiUploader)
        self._omiUploaderHolder = State(initialValue: omiUploaderHolder)
        self._watchRegistration = State(initialValue: watchRegistration)
        self._watchUploader = State(initialValue: watchUploader)
        self._watchUploaderHolder = State(initialValue: watchUploaderHolder)
        self._watchSegmentDrain = State(initialValue: watchSegmentDrain)
        self._importQueue = State(initialValue: importQueue)
        self._locationUploader = State(initialValue: locationUploader)
        self._locationManager = State(initialValue: locationManager)
        self._observerManager = State(initialValue: observerManager)
        self._watchLink = State(initialValue: watchLink)
        self._voiceManager = State(initialValue: voice)
        self._chatManager = State(initialValue: chat)
        self._omiSourceManager = State(initialValue: omiSource)
        self.appDelegate.observerUploader = observerUploader
        self.appDelegate.omiUploader = omiUploader
        self.appDelegate.watchUploader = watchUploader
        self.appDelegate.importQueue = importQueue
        self.appDelegate.locationUploader = locationUploader
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(self.appConfig)
                .environment(self.onboardingFlow)
                .environment(self.tunnelManager)
                .environment(self.voiceManager)
                .environment(self.chatManager)
                .environment(self.omiSourceManager)
                .environment(self.observerRegistration)
                .environment(self.observerUploader)
                .environment(self.omiUploaderHolder)
                .environment(self.watchUploaderHolder)
                .environment(self.importQueue)
                .environment(self.locationManager)
                .environment(self.locationUploader)
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
                    await self.importQueue.resumeFromDisk()
                }
                .task {
                    guard !UserDefaults.standard.bool(forKey: "didMigrateLegacyAudioSegmentKeysV1") else { return }
                    _ = await self.observerUploader.migrateLegacySegmentKeys()
                    _ = await self.omiUploader.migrateLegacySegmentKeys()
                    UserDefaults.standard.set(true, forKey: "didMigrateLegacyAudioSegmentKeysV1")
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
                    if case .idle = self.observerManager.state {
                        await self.observerManager.endStaleObserverActivities()
                    }
                }
        }
        .onChange(of: self.scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                self.backgroundDisconnectTask?.cancel()
                self.backgroundDisconnectTask = nil
                if Self.isIntegrationMode || Self.isUITest {
                    return
                }
                guard self.appConfig.isPaired else {
                    return
                }
                self.tunnelManager.startNetworkMonitoring()

                switch self.tunnelManager.state {
                case .connected, .connecting:
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
                self.integrationVoiceStartTask?.cancel()
                self.integrationVoiceStartTask = nil
                self.integrationObserverStartTask?.cancel()
                self.integrationObserverStartTask = nil
                self.integrationObserverStopTask?.cancel()
                self.integrationObserverStopTask = nil
                self.voiceManager.endSession()
                self.tunnelManager.cancelConnect()
                self.tunnelManager.cancelReconnect()
                self.tunnelManager.stopNetworkMonitoring()

                self.backgroundDisconnectTask = Task {
                    let application = UIApplication.shared
                    var taskID = UIBackgroundTaskIdentifier.invalid
                    taskID = application.beginBackgroundTask {
                        application.endBackgroundTask(taskID)
                        taskID = .invalid
                    }
                    defer {
                        if taskID != .invalid {
                            application.endBackgroundTask(taskID)
                        }
                    }
                    try? await Task.sleep(for: .seconds(20))
                    if !Task.isCancelled {
                        await self.tunnelManager.disconnect()
                    }
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
                Task {
                    await self.observerUploader.reconcilePortAndResume()
                }
                Task {
                    await self.omiUploader.reconcilePortAndResume()
                }
                Task {
                    await self.watchUploader.reconcilePortAndResume()
                }
                // follow-up: ImportQueue and LocationUploader share the same stale-port background-task shape.
                Task {
                    await self.importQueue.resumeFromDisk()
                }
                Task {
                    await self.locationUploader.resumeFromDisk()
                }
                Task {
                    await self.observerUploader.retryFailed()
                }
                Task {
                    await self.omiUploader.retryFailed()
                }
                Task {
                    await self.watchUploader.retryFailed()
                }
                Task {
                    await self.importQueue.retryFailed()
                }
                Task {
                    await self.locationUploader.retryFailed()
                }
                Task {
                    await self.watchSegmentDrain?.drain()
                }

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
            case .connecting, .disconnected, .error:
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

private extension SolstoneSwiftApp {
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

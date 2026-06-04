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
    @State private var portalPage: PortalPage
    @State private var diagnosticLog: DiagnosticLog
    @State private var observerRegistration: ObserverRegistration
    @State private var observerUploader: ObserverUploader
    @State private var importQueue: ImportQueue
    @State private var locationUploader: LocationUploader
    @State private var locationManager: LocationManager
    @State private var observerManager: ObserverManager
    @State private var pendingObserverCommand = PendingObserverCommandState()
    @State private var pendingLocationCommand = PendingLocationCommandState()
    @State private var pairingHandoff = PairingHandoffState()
    @State private var voiceManager: VoiceManager
    @State private var bannerPresenter: BannerPresenter
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
        let portal = PortalPage(
            tunnelManager: tunnel,
            brainStatusMonitor: brain
        )
        let observerRegistration = ObserverRegistration()
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
            }
        )
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
        let voice = VoiceManager(
            webrtc: Self.makeWebRTCConnector(),
            onNavHint: { @MainActor hint in
                portal.applyNavHint(hint)
            },
            diagnosticLog: log
        )
        voice.onObserverAction = { @MainActor action in
            switch action {
            case .startObserver(let mode):
                Task { @MainActor in
                    await observerManager.startSession(mode: mode)
                }
            }
        }
        self._appConfig = State(initialValue: appConfig)
        self._onboardingFlow = State(initialValue: onboardingFlow)
        self._diagnosticLog = State(initialValue: log)
        self._brainStatusMonitor = State(initialValue: brain)
        self._portalPage = State(initialValue: portal)
        self._tunnelManager = State(initialValue: tunnel)
        self._observerRegistration = State(initialValue: observerRegistration)
        self._observerUploader = State(initialValue: observerUploader)
        self._importQueue = State(initialValue: importQueue)
        self._locationUploader = State(initialValue: locationUploader)
        self._locationManager = State(initialValue: locationManager)
        self._observerManager = State(initialValue: observerManager)
        self._voiceManager = State(initialValue: voice)
        self._bannerPresenter = State(initialValue: BannerPresenter(
            diagnosticLog: log,
            voiceManager: voice,
            tunnelManager: tunnel
        ))
        self.appDelegate.observerUploader = observerUploader
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
                .environment(self.observerRegistration)
                .environment(self.observerUploader)
                .environment(self.importQueue)
                .environment(self.locationManager)
                .environment(self.locationUploader)
                .environment(self.observerManager)
                .environment(self.pendingObserverCommand)
                .environment(self.pendingLocationCommand)
                .environment(self.pairingHandoff)
                .environment(self.brainStatusMonitor)
                .environment(self.portalPage)
                .environment(self.diagnosticLog)
                .environment(self.bannerPresenter)
                .environment(self.appDelegate.pushManager)
                .environment(self.appDelegate.pushEnablement)
                .environment(self.appDelegate.pendingRoute)
                .onOpenURL { url in
                    if let result = UniversalLinkRouter.route(url) {
                        switch result {
                        case .success(let pairURL):
                            self.pairingHandoff.pairURL = pairURL
                            self.pairingHandoff.pairURLError = nil
                        case .failure(let error):
                            self.pairingHandoff.pairURL = nil
                            self.pairingHandoff.pairURLError = error
                        }
                        return
                    }
                    guard url.scheme == "solstone",
                          url.host == "observer",
                          url.path == "/stop"
                    else {
                        guard url.scheme == "solstone",
                              url.host == "location",
                              url.path == "/pause"
                        else { return }
                        self.pendingLocationCommand.command = .pauseRequested
                        return
                    }
                    self.pendingObserverCommand.command = .stopRequested
                }
                .onChange(of: self.pendingObserverCommand.command) { _, command in
                    guard command == .stopRequested else { return }
                    self.pendingObserverCommand.command = nil
                    Task {
                        await self.observerManager.stopSession()
                    }
                }
                .onChange(of: self.pendingLocationCommand.command) { _, command in
                    guard command == .pauseRequested else { return }
                    self.pendingLocationCommand.command = nil
                    Task {
                        await self.locationManager.pause()
                    }
                }
                .task {
                    await self.importQueue.resumeFromDisk()
                }
        }
        .commands {
            CommandMenu("hub") {
                Button("refresh brain") {
                    guard case .connected(let port, _) = self.tunnelManager.state else { return }
                    Task {
                        guard let url = VoiceServerURL.url(localPort: port, path: "/api/voice/refresh-brain") else { return }
                        var request = URLRequest(url: url)
                        request.httpMethod = "POST"
                        _ = try? await URLSession.shared.data(for: request)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
        .onChange(of: self.scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                self.locationManager.noteAppDidEnterForeground()
                self.backgroundDisconnectTask?.cancel()
                self.backgroundDisconnectTask = nil
                if Self.isIntegrationMode {
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
                self.locationManager.noteAppDidEnterBackground()
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
                self.brainStatusMonitor.startPolling(localPort: port)
                Task {
                    await self.observerUploader.resumeFromDisk()
                }
                Task {
                    await self.importQueue.resumeFromDisk()
                }
                Task {
                    await self.locationUploader.resumeFromDisk()
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
        defaults.removeObject(forKey: "briefing.firstSeen")
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

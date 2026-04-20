// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import UIKit
import SwiftUI

@main
struct SolstoneSwiftApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var tunnelManager: TunnelManager
    @State private var brainStatusMonitor: BrainStatusMonitor
    @State private var portalPage: PortalPage
    @State private var diagnosticLog: DiagnosticLog
    @State private var voiceManager: VoiceManager
    @State private var bannerPresenter: BannerPresenter
    @State private var backgroundDisconnectTask: Task<Void, Never>?
    @State private var integrationVoiceStartTask: Task<Void, Never>?
    @State private var didAutoStartIntegrationVoice = false
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

    private static var shouldAutoStartIntegrationVoice: Bool {
#if DEBUG
        !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--integration-test-push-tap=") })
#else
        true
#endif
    }

    init() {
        let log = DiagnosticLog()
        let tunnel = TunnelManager(diagnosticLog: log)
        let brain = BrainStatusMonitor(diagnosticLog: log)
        let portal = PortalPage(
            tunnelManager: tunnel,
            brainStatusMonitor: brain
        )
        let voice = VoiceManager(
            webrtc: Self.isIntegrationTest ? IntegrationTestWebRTCConnector() : WebRTCManager(),
            onNavHint: { @MainActor hint in
                portal.applyNavHint(hint)
            },
            diagnosticLog: log
        )
        self._diagnosticLog = State(initialValue: log)
        self._brainStatusMonitor = State(initialValue: brain)
        self._portalPage = State(initialValue: portal)
        self._tunnelManager = State(initialValue: tunnel)
        self._voiceManager = State(initialValue: voice)
        self._bannerPresenter = State(initialValue: BannerPresenter(
            diagnosticLog: log,
            voiceManager: voice,
            tunnelManager: tunnel
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(self.tunnelManager)
                .environment(self.voiceManager)
                .environment(self.brainStatusMonitor)
                .environment(self.portalPage)
                .environment(self.diagnosticLog)
                .environment(self.bannerPresenter)
                .environment(self.appDelegate.pushManager)
                .environment(self.appDelegate.pendingRoute)
        }
        .commands {
            CommandMenu("Hub") {
                Button("Refresh Brain") {
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
                self.backgroundDisconnectTask?.cancel()
                self.backgroundDisconnectTask = nil
                if Self.isIntegrationMode {
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
                self.brainStatusMonitor.startPolling(localPort: port)

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
            case .connecting, .disconnected, .error:
                self.integrationVoiceStartTask?.cancel()
                self.integrationVoiceStartTask = nil
                self.brainStatusMonitor.stopPolling()
            }
        }
    }
}

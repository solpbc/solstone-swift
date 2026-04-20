// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import UIKit
import SwiftUI

@main
struct SolstoneSwiftApp: App {
    @State private var tunnelManager: TunnelManager
    @State private var brainStatusMonitor: BrainStatusMonitor
    @State private var portalPage: PortalPage
    @State private var diagnosticLog: DiagnosticLog
    @State private var voiceManager: VoiceManager
    @State private var bannerPresenter: BannerPresenter
    @State private var backgroundDisconnectTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let log = DiagnosticLog()
        let tunnel = TunnelManager(diagnosticLog: log)
        let brain = BrainStatusMonitor(diagnosticLog: log)
        let voice = VoiceManager(diagnosticLog: log)
        self._diagnosticLog = State(initialValue: log)
        self._brainStatusMonitor = State(initialValue: brain)
        self._portalPage = State(initialValue: PortalPage(
            tunnelManager: tunnel,
            brainStatusMonitor: brain
        ))
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
        }
        .commands {
            CommandMenu("Hub") {
                Button("Refresh Brain") {
                    guard case .connected(let port, _) = self.tunnelManager.state else { return }
                    Task {
                        guard let url = URL(string: "http://127.0.0.1:\(port)/api/voice/refresh-brain") else { return }
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
                if ProcessInfo.processInfo.arguments.contains("--integration-test") { return }
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
            if !newState.isConnected {
                self.brainStatusMonitor.reset()
            }
        }
    }
}

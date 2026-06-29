// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import os
import SwiftUI
import UIKit

private let log = Logger(subsystem: "app.solstone.swift", category: "ui")

struct ContentView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(OnboardingFlow.self) private var onboardingFlow
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(PushNotificationManager.self) private var pushManager
    @Environment(PairingHandoffState.self) private var pairingHandoff
    @State private var showPairing = false
    @State private var lastPort: Int = 0
    @State private var lastVia: ConnectionEndpoint = .lan
    @State private var showOfflineBanner = false
    @State private var offlineSettleTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var effectivePort: Int {
        if case .connected(let port, _) = self.tunnelManager.state {
            return port
        }
        return self.lastPort
    }

    private var effectiveVia: ConnectionEndpoint {
        if case .connected(_, let via) = self.tunnelManager.state {
            return via
        }
        return self.lastVia
    }

    var body: some View {
        Group {
            if !self.onboardingFlow.isCompleted {
                OnboardingRootView()
            } else {
                RootShellView(
                    localPort: self.effectivePort,
                    via: self.effectiveVia
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if self.appConfig.isPaired && self.showOfflineBanner {
                OfflineBanner()
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: self.tunnelManager.state.isConnected)
        .sheet(isPresented: self.$showPairing) {
            NavigationStack {
                PairFlowView(
                    onBack: {
                        self.dismissPairing()
                    },
                    onComplete: {
                        self.tunnelManager.armOwnerConnectSuccessBanner()
                        self.onboardingFlow.completeViaPairing()
                        self.dismissPairing()
                    }
                )
            }
        }
        .onChange(of: self.tunnelManager.state) { _, newState in
            if case .connected(let port, let via) = newState {
                self.lastPort = port
                self.lastVia = via
                Task {
                    await self.pushManager.handleTunnelConnected(localPort: port)
                }
            } else {
                self.pushManager.activeLocalPort = nil
            }
            let message: String? = switch newState {
            case .connecting:
                "connecting…"
            case .waitingForHome:
                "waiting for your home…"
            case .connected(_, let via):
                via == .lan ? "connected via local network" : "connected via remote journal"
            case .error(let error):
                "connection error, \(error.userMessage)"
            case .disconnected:
                "disconnected"
            }
            if let message {
                UIAccessibility.post(notification: .announcement, argument: message)
            }
            switch newState {
            case .connected:
                if UserSettings.haptics {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            case .error(let error):
                if error == .revoked {
                    self.showPairing = true
                }
                if UserSettings.haptics {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            case .connecting, .waitingForHome, .disconnected:
                break
            }
        }
        .onChange(of: self.appConfig.pairedAt) { _, _ in
            self.startTunnelIfPaired()
            self.updateOfflineBannerVisibility()
        }
        .onChange(of: self.tunnelManager.isNetworkSatisfied) { _, _ in
            self.updateOfflineBannerVisibility()
        }
        .task(id: PairingHandoffPresentation.shouldPresent(
            pairURL: self.pairingHandoff.pairURL,
            pairURLError: self.pairingHandoff.pairURLError
        )) {
            self.presentPairingIfHandoffPending()
        }
        .onAppear {
            defer {
                self.updateOfflineBannerVisibility()
            }
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--ui-test") {
                let port = Self.uiTestPort
                let journalRoot = Self.uiTestJournalRoot(port: port)
                let sessionKey = Self.uiTestPairSessionKey
                let deviceID = Self.uiTestDeviceID
                let onboardingStep = Self.uiTestOnboardingStep
                let noJournal = arguments.contains("--ui-test-no-journal")
                let shouldSeedPairing = !noJournal && (onboardingStep == nil || onboardingStep == .done)
                log.info(
                    "ui-test seeding journalRoot=\(journalRoot, privacy: .public) deviceID=\(deviceID, privacy: .public) hasSession=\(sessionKey != nil)"
                )

                if !shouldSeedPairing {
                    self.appConfig.clearPairing()
                }

                if let onboardingStep {
                    if shouldSeedPairing {
                        self.appConfig.seedUITestPairing(
                            journalRoot: journalRoot,
                            deviceID: deviceID,
                            sessionKey: sessionKey
                        )
                    }
                    self.onboardingFlow.seedUITest(step: onboardingStep)
                } else {
                    if shouldSeedPairing {
                        self.appConfig.seedUITestPairing(
                            journalRoot: journalRoot,
                            deviceID: deviceID,
                            sessionKey: sessionKey
                        )
                    }
                    self.onboardingFlow.markCompletedForUITest()
                }

                if shouldSeedPairing {
                    if arguments.contains("--ui-test-shell-disconnected") {
                        self.tunnelManager.forceDisconnectedForUITest()
                        self.tunnelManager.forceNetworkStatus(
                            isSatisfied: !arguments.contains("--ui-test-network-unsatisfied"),
                            isWiFi: true
                        )
                    } else {
                        self.tunnelManager.forceConnected(port: port, via: .lan)
                        self.tunnelManager.forceNetworkStatus(
                            isSatisfied: !arguments.contains("--ui-test-network-unsatisfied"),
                            isWiFi: true
                        )
                    }
                    self.lastPort = port
                    self.lastVia = .lan
                } else if arguments.contains("--ui-test-network-unsatisfied") {
                    self.tunnelManager.forceNetworkStatus(isSatisfied: false, isWiFi: true)
                }
                if let reconnectDelay = Self.uiTestNetworkReconnectDelay {
                    Task {
                        try? await Task.sleep(for: .seconds(reconnectDelay))
                        self.tunnelManager.forceNetworkStatus(isSatisfied: true, isWiFi: true)
                    }
                }
                return
            }
#if DEBUG
            if arguments.contains("--integration-test") {
                let mockPort = Int(ProcessInfo.processInfo.environment["MOCK_PORT"] ?? "") ?? 7071
                self.appConfig.seedUITestPairing(journalRoot: "http://127.0.0.1:\(mockPort)")
                self.onboardingFlow.markCompletedForUITest()
                self.tunnelManager.forceConnected(port: mockPort, via: .lan)
                self.lastPort = mockPort
                self.lastVia = .lan
                Task {
                    await self.pushManager.handleTunnelConnected(localPort: mockPort)
                }
                return
            }
            if arguments.contains("--integration-test-live") {
                let livePort = Int(ProcessInfo.processInfo.environment["LIVE_PORT"] ?? "") ?? 7071
                self.appConfig.seedUITestPairing(journalRoot: "http://127.0.0.1:\(livePort)")
                self.onboardingFlow.markCompletedForUITest()
                self.tunnelManager.forceConnected(port: livePort, via: .lan)
                self.lastPort = livePort
                self.lastVia = .lan
                Task {
                    await self.pushManager.handleTunnelConnected(localPort: livePort)
                }
                return
            }
#endif
            self.completeOnboardingIfPaired()
            self.startTunnelIfPaired()
        }
        .onDisappear {
            self.offlineSettleTask?.cancel()
            self.offlineSettleTask = nil
        }
    }
}

private extension ContentView {
    func updateOfflineBannerVisibility() {
        self.offlineSettleTask?.cancel()
        self.offlineSettleTask = nil

        guard self.appConfig.isPaired,
              self.tunnelManager.isNetworkSatisfied == false
        else {
            self.showOfflineBanner = false
            return
        }

        self.offlineSettleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled,
                  self.appConfig.isPaired,
                  self.tunnelManager.isNetworkSatisfied == false
            else {
                return
            }
            self.showOfflineBanner = true
            self.offlineSettleTask = nil
        }
    }

    func clearPairingHandoff() {
        self.pairingHandoff.pairURL = nil
        self.pairingHandoff.pairURLError = nil
    }

    func dismissPairing() {
        self.showPairing = false
        self.clearPairingHandoff()
    }

    func presentPairingIfHandoffPending() {
        if PairingHandoffPresentation.shouldPresent(
            pairURL: self.pairingHandoff.pairURL,
            pairURLError: self.pairingHandoff.pairURLError
        ) {
            self.showPairing = true
        }
    }

    func completeOnboardingIfPaired() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains("--ui-test"),
              !arguments.contains("--integration-test"),
              !arguments.contains("--integration-test-live")
        else { return }
        if OnboardingPairingReconciliation.shouldComplete(
            isPaired: self.appConfig.isPaired,
            isOnboardingCompleted: self.onboardingFlow.isCompleted
        ) {
            self.onboardingFlow.completeViaPairing()
        }
    }

    func startTunnelIfPaired() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains("--ui-test"),
              !arguments.contains("--integration-test"),
              !arguments.contains("--integration-test-live")
        else { return }
        guard self.appConfig.isPaired else {
            log.info("ContentView: unpaired shell, skipping tunnel start")
            return
        }
        self.tunnelManager.startNetworkMonitoring()
        log.info("[solstone-swift] tunnel start check state=\(self.tunnelManager.state)")
        switch self.tunnelManager.state {
        case .disconnected, .error(.revoked):
            log.info("[solstone-swift] launching connect task")
            Task {
                await self.tunnelManager.connect()
            }
        case .connecting, .waitingForHome, .connected, .error:
            break
        }
    }

    static var uiTestPort: Int {
        if let raw = ProcessInfo.processInfo.environment["UI_TEST_PORT"],
           let value = Int(raw)
        {
            return value
        }
        return 7071
    }

    static func uiTestJournalRoot(port: Int) -> String {
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-journal-root=") }) {
            return String(argument.dropFirst("--ui-test-journal-root=".count))
        }
        return "http://127.0.0.1:\(port)"
    }

    static var uiTestPairSessionKey: String? {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-pair-session=") }) else {
            return nil
        }
        return String(argument.dropFirst("--ui-test-pair-session=".count))
    }

    static var uiTestDeviceID: String {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-device-id=") }) else {
            return "ui-test-device"
        }
        return String(argument.dropFirst("--ui-test-device-id=".count))
    }

    static var uiTestOnboardingStep: OnboardingFlow.Step? {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-onboarding-step=") }) else {
            return nil
        }
        let rawValue = String(argument.dropFirst("--ui-test-onboarding-step=".count))
        return OnboardingFlow.Step(rawValue: rawValue)
    }

    static var uiTestNetworkReconnectDelay: Double? {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--ui-test-network-reconnect-after=") }) else {
            return nil
        }
        return Double(argument.dropFirst("--ui-test-network-reconnect-after=".count))
    }
}

struct ConnectingView: View {
    let state: TunnelState
    let onRetry: () -> Void
    let reconnectCountdown: Int?
    let consecutiveWiFiFailures: Int
    let currentInterfaceIsWiFi: Bool
    let connectionStages: [ConnectionStage]

    @ViewBuilder
    private var stageListView: some View {
        if self.connectionStages.isEmpty {
            Text("no connection stages yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(self.connectionStages) { stage in
                    HStack(spacing: 8) {
                        Group {
                            switch stage.status {
                            case .active:
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 10, height: 10)
                            case .done:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.system(size: 13))
                            case .failed:
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.system(size: 13))
                            }
                        }
                        .frame(width: 16)

                        Text(self.stageLabel(for: stage))
                            .font(.footnote)
                            .foregroundStyle(stage.status == .active ? .primary : .secondary)

                        Spacer()

                        if stage.status == .done, let duration = stage.duration {
                            Text(String(format: "%.1fs", duration))
                                .font(.footnote.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(self.stageAccessibilityLabel(for: stage))
                    .transition(.opacity)

                    if stage.status == .failed, let detail = stage.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(8)
                            .padding(.leading, 24)
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var retryButton: some View {
        switch self.state {
        case .disconnected:
            Button("try again", action: self.onRetry)
                .buttonStyle(.borderedProminent)
                .accessibilityHint("attempts to reconnect to your journal")
        case .error(let error) where error.isRetryable:
            Button("try again", action: self.onRetry)
                .buttonStyle(.borderedProminent)
                .accessibilityHint("attempts to reconnect to your journal")
        case .connecting, .waitingForHome, .connected, .error:
            EmptyView()
        }
    }

    private var summaryText: String {
        switch self.state {
        case .connecting:
            "connecting…"
        case .waitingForHome:
            // VPX: copy pass before ship.
            "waiting for your home…"
        case .connected:
            "connected"
        case .disconnected:
            "waiting for a network"
        case .error(let error):
            error.userMessage
        }
    }

    private func stageLabel(for stage: ConnectionStage) -> String {
        switch stage.kind {
        case .prepareCandidates:
            return "prepare candidates"
        case .raceCandidates:
            return "race candidates"
        case .tlsHandshake:
            return "verify solstone"
        case .muxReady:
            return "secure channel"
        case .loopback:
            return "local proxy"
        case .connected:
            return "connected"
        }
    }

    private func stageAccessibilityLabel(for stage: ConnectionStage) -> String {
        let statusText: String
        switch stage.status {
        case .active:
            statusText = "in progress"
        case .done:
            statusText = "complete"
        case .failed:
            statusText = "failed"
        }
        let label = self.stageLabel(for: stage)
        if stage.status == .done, let duration = stage.duration {
            return "\(statusText), \(label), \(String(format: "%.1f", duration)) seconds"
        }
        return "\(statusText), \(label)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("connection details")
                    .font(.headline)

                Text(self.summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let countdown = self.reconnectCountdown {
                    Text("reconnecting in \(countdown)s")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("reconnecting in \(countdown) seconds")
                }

                if case .error(let error) = self.state,
                   error.isRetryable,
                   self.currentInterfaceIsWiFi,
                   self.consecutiveWiFiFailures >= 2
                {
                    Text("your WiFi network may require sign-in — try opening your browser to complete any captive portal login")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                self.stageListView
                self.retryButton
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

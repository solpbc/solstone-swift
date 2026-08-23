// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import os
import SwiftUI
import UIKit

private let log = Logger(subsystem: "app.solstone.swift", category: "ui")

private struct ContentPairingIdentity: Equatable {
    let instanceID: String
    let certificateFingerprint: String
    let pairedAt: Date?
}

struct ContentView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(OnboardingFlow.self) private var onboardingFlow
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(ConnectionSyncModel.self) private var connectionSyncModel
    @Environment(PushNotificationManager.self) private var pushManager
    @Environment(PairingHandoffState.self) private var pairingHandoff
    @State private var showPairing = false
    @State private var lastPort: Int = 0
    @State private var lastVia: ConnectionEndpoint = .lan
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

    private var isRevoked: Bool {
        if case .error(.revoked) = self.tunnelManager.state {
            return true
        }
        return false
    }

    private var pairingIdentity: ContentPairingIdentity? {
        guard self.appConfig.isPaired else { return nil }
        return ContentPairingIdentity(
            instanceID: self.appConfig.deviceID,
            certificateFingerprint: self.appConfig.caFingerprintHex,
            pairedAt: self.appConfig.pairedAt
        )
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
            if self.appConfig.isPaired && self.isRevoked {
                RePairBanner {
                    self.showPairing = true
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: self.isRevoked)
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
            case .error:
                if UserSettings.haptics {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            case .connecting, .waitingForHome, .disconnected:
                break
            }
        }
        .onChange(of: self.pairingIdentity) { priorPairing, currentPairing in
            self.startTunnelIfPaired(
                replacingExistingPairing: priorPairing != nil && currentPairing != nil
            )
        }
        .task(id: PairingHandoffPresentation.shouldPresent(
            pairURL: self.pairingHandoff.pairURL,
            pairURLError: self.pairingHandoff.pairURLError
        )) {
            self.presentPairingIfHandoffPending()
        }
        .onAppear {
#if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--ui-test") {
                let port = Self.uiTestPort
                let journalRoot = Self.uiTestJournalRoot(port: port)
                let sessionKey = Self.uiTestPairSessionKey
                let deviceID = Self.uiTestDeviceID
                let onboardingStep = Self.uiTestOnboardingStep
                let noJournal = arguments.contains("--ui-test-no-journal")
                let shouldSeedPairing = !noJournal && (onboardingStep == nil || onboardingStep == .done)
                let openPane = arguments.first { $0.hasPrefix("--ui-test-open-pane=") } ?? ""
                log.info(
                    "ui-test seeding journalRoot=\(journalRoot, privacy: .public) deviceID=\(deviceID, privacy: .public) hasSession=\(sessionKey != nil) openPane=\(openPane, privacy: .public) journalMark=\(arguments.contains("--ui-test-journal-mark"), privacy: .public)"
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

                if arguments.contains("--ui-test-mark-confirm") {
                    self.appConfig.seedUITestPairing(
                        journalRoot: journalRoot,
                        deviceID: deviceID,
                        sessionKey: sessionKey
                    )
                    self.onboardingFlow.markCompletedForUITest()
                    self.tunnelManager.forceConnected(port: port, via: .lan)
                    self.tunnelManager.forceNetworkStatus(
                        isSatisfied: !arguments.contains("--ui-test-network-unsatisfied"),
                        isWiFi: true
                    )
                    self.lastPort = port
                    self.lastVia = .lan
                    self.showPairing = true
                    self.connectionSyncModel.refreshNow()
                    return
                }
                if arguments.contains("--ui-test-revoked") {
                    self.appConfig.seedUITestPairing(
                        journalRoot: journalRoot,
                        deviceID: deviceID,
                        sessionKey: sessionKey
                    )
                    self.onboardingFlow.markCompletedForUITest()
                    self.tunnelManager.forceDisconnectedForUITest()
                    self.tunnelManager.forceNetworkStatus(
                        isSatisfied: !arguments.contains("--ui-test-network-unsatisfied"),
                        isWiFi: true
                    )
                    self.tunnelManager.state = .error(.revoked)
                    self.lastPort = port
                    self.lastVia = .lan
                    self.connectionSyncModel.refreshNow()
                    return
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
                self.connectionSyncModel.refreshNow()
                if let reconnectDelay = Self.uiTestNetworkReconnectDelay {
                    Task {
                        try? await Task.sleep(for: .seconds(reconnectDelay))
                        self.tunnelManager.forceNetworkStatus(isSatisfied: true, isWiFi: true)
                        self.connectionSyncModel.refreshNow()
                    }
                }
                return
            }
            if arguments.contains("--integration-test") {
                let mockPort = Int(ProcessInfo.processInfo.environment["MOCK_PORT"] ?? "") ?? 7071
                self.appConfig.seedUITestPairing(journalRoot: "http://127.0.0.1:\(mockPort)")
                self.onboardingFlow.markCompletedForUITest()
                self.tunnelManager.forceConnected(port: mockPort, via: .lan)
                self.lastPort = mockPort
                self.lastVia = .lan
                self.connectionSyncModel.refreshNow()
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
                self.connectionSyncModel.refreshNow()
                Task {
                    await self.pushManager.handleTunnelConnected(localPort: livePort)
                }
                return
            }
#endif
            self.completeOnboardingIfPaired()
            self.startTunnelIfPaired()
        }
    }
}

private extension ContentView {
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

    func startTunnelIfPaired(replacingExistingPairing: Bool = false) {
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
        if replacingExistingPairing {
            log.info("[solstone-swift] replacing active tunnel pairing")
            Task {
                await self.tunnelManager.reconnectAfterPairingChange()
            }
            return
        }
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

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SwiftUI
import XCTest

nonisolated final class DynamicTypeSmokeTests: XCTestCase {
    @MainActor
    func testOnboardingTodayMoreAndSenseRenderAtAccessibilityXXXL() throws {
        let appConfig = AppConfig(
            defaults: UserDefaults(suiteName: "DynamicTypeSmokeTests.\(UUID().uuidString)")!,
            loadPairSession: { "pair-session" },
            savePairSession: { _ in },
            deletePairSession: {},
            deletePairIdentity: {}
        )
        try appConfig.applyPairConfirm(
            PairConfirmResponse(
                sessionKey: "pair-session",
                deviceID: "device-123",
                journalRoot: "https://journal.example.com",
                ownerIdentity: "sol",
                serverVersion: "test",
                host: "journal.example.com",
                port: 22
            )
        )

        let pairingClient = MockPairingClient()
        let tunnelManager = TunnelManager(transport: MockSSHTransport())
        let diagnosticLog = DiagnosticLog()
        let brainStatusMonitor = BrainStatusMonitor()
        let observerRegistration = ObserverRegistration(
            loadKey: { nil },
            saveKey: { _ in },
            deleteKey: {}
        )
        let observerUploader = ObserverUploader(
            ensureRegistered: { "observer-key" },
            localPortProvider: { 7071 }
        )
        let observerManager = ObserverManager(
            recorder: MockObserverRecorder(),
            uploader: observerUploader
        )
        let voiceManager = VoiceManager(
            webrtc: MockWebRTCConnector(),
            diagnosticLog: diagnosticLog
        )
        let moreView = NavigationStack {
            MoreView(
                localPort: 7071,
                via: .lan,
                connectedSince: .now,
                navigateToDiagnostics: .constant(false),
                pairingClient: pairingClient
            )
            .environment(appConfig)
            .environment(OnboardingFlow())
            .environment(tunnelManager)
            .environment(voiceManager)
            .environment(brainStatusMonitor)
            .environment(diagnosticLog)
            .environment(PushNotificationManager())
            .environment(observerRegistration)
            .environment(observerUploader)
            .environment(observerManager)
        }

        let senseView = NavigationStack {
            SenseView()
                .environment(observerManager)
                .environment(observerRegistration)
        }

        try self.assertHosted(
            WelcomeScreen(onGetStarted: {})
                .environment(\.dynamicTypeSize, .accessibility3)
        )
        try self.assertHosted(
            DayZeroOverlayView(pairingClient: pairingClient, onBrowseJournal: {})
                .environment(appConfig)
                .environment(\.dynamicTypeSize, .accessibility3)
        )
        try self.assertHosted(moreView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(senseView.environment(\.dynamicTypeSize, .accessibility3))
    }

    @MainActor private func assertHosted<V: View>(_ view: V) throws {
        let controller = UIHostingController(rootView: view)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        XCTAssertGreaterThan(controller.view.systemLayoutSizeFitting(CGSize(width: 393, height: 852)).height, 0)
    }
}

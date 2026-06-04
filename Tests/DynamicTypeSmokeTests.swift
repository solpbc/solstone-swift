// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SwiftUI
import XCTest

nonisolated final class DynamicTypeSmokeTests: XCTestCase {
    @MainActor
    func testOnboardingTodayMoreAndSourcesRenderAtAccessibilityXXXL() async throws {
        let appConfig = AppConfig()
        appConfig.seedUITestPairing(journalRoot: "http://127.0.0.1:7071")

        let tunnelManager = TunnelManager(transport: MockCFTunnelTransport())
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
        let locationUploaderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicTypeSmokeTests-LocationUploader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: locationUploaderRoot) }
        let locationUploader = LocationUploader(
            cacheRootURL: locationUploaderRoot,
            sessionConfiguration: .ephemeral,
            ensureRegistered: { "location-key" },
            localPortProvider: { 7071 },
            startPathMonitor: false
        )
        let observerManager = ObserverManager(
            recorder: MockObserverRecorder(),
            uploader: observerUploader
        )
        let locationManager = LocationManager(
            provider: MockLocationProvider(),
            uploader: locationUploader,
            clock: MockObserverClock(),
            defaults: nil
        )
        let activeLocationProvider = MockLocationProvider()
        activeLocationProvider.capability = .always(accuracy: .full)
        let activeLocationManager = LocationManager(
            provider: activeLocationProvider,
            uploader: locationUploader,
            clock: MockObserverClock(),
            defaults: nil
        )
        await activeLocationManager.start(tier: .balanced)
        XCTAssertEqual(activeLocationManager.sourceState, .active)
        let needsAttentionLocationProvider = MockLocationProvider()
        needsAttentionLocationProvider.capability = .denied
        let needsAttentionLocationManager = LocationManager(
            provider: needsAttentionLocationProvider,
            uploader: locationUploader,
            clock: MockObserverClock(),
            defaults: nil
        )
        await needsAttentionLocationManager.start(tier: .balanced)
        XCTAssertEqual(needsAttentionLocationManager.sourceState, .needsAttention)
        let importQueueRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicTypeSmokeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: importQueueRoot) }
        let importQueue = ImportQueue(
            cacheRootURL: importQueueRoot,
            ensureRegistered: { throw ImportQueueError.registrationUnavailable },
            startPathMonitor: false
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
                navigateToDiagnostics: .constant(false)
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

        let sourcesView = NavigationStack {
            SourcesView()
                .environment(observerManager)
                .environment(observerRegistration)
                .environment(ObserverSourcePauseState())
                .environment(importQueue)
                .environment(locationManager)
        }
        let locationSourceDetailView = NavigationStack {
            LocationSourceDetailView()
                .environment(locationManager)
                .environment(locationUploader)
                .environment(observerRegistration)
        }
        let activeLocationSourceDetailView = NavigationStack {
            LocationSourceDetailView()
                .environment(activeLocationManager)
                .environment(locationUploader)
                .environment(observerRegistration)
        }
        let needsAttentionLocationSourceDetailView = NavigationStack {
            LocationSourceDetailView()
                .environment(needsAttentionLocationManager)
                .environment(locationUploader)
                .environment(observerRegistration)
        }
        let importerSourceDetailView = NavigationStack {
            ImporterSourceDetailView(source: Self.shareSource())
                .environment(appConfig)
                .environment(importQueue)
                .environment(observerUploader)
                .environment(locationUploader)
        }
        let onThisPhoneView = NavigationStack {
            OnThisPhoneView()
                .environment(appConfig)
                .environment(importQueue)
                .environment(observerUploader)
                .environment(locationUploader)
        }
        let onThisPhoneItemDetailView = NavigationStack {
            OnThisPhoneItemDetailView(item: Self.onThisPhoneItem())
                .environment(importQueue)
                .environment(observerUploader)
                .environment(locationUploader)
                .environment(observerRegistration)
        }

        try self.assertHosted(
            WelcomeScreen(onGetStarted: {})
                .environment(\.dynamicTypeSize, .accessibility3)
        )
        try self.assertHosted(
            DayZeroOverlayView(localPort: 7071, onBrowseJournal: {})
                .environment(appConfig)
                .environment(\.dynamicTypeSize, .accessibility3)
        )
        try self.assertHosted(moreView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(sourcesView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(locationSourceDetailView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(activeLocationSourceDetailView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(needsAttentionLocationSourceDetailView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(importerSourceDetailView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(onThisPhoneView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(onThisPhoneItemDetailView.environment(\.dynamicTypeSize, .accessibility3))
        await activeLocationManager.stop()
        // ShareExtensionView is private in the extension target; its copy is mechanically covered by lock tests.
        // Hit-target audit: scoped controls are standard Buttons/NavigationLinks/segmented Picker, so no frame assertions are needed here.
    }

    @MainActor private func assertHosted<V: View>(_ view: V) throws {
        let controller = UIHostingController(rootView: view)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        XCTAssertGreaterThan(controller.view.systemLayoutSizeFitting(CGSize(width: 393, height: 852)).height, 0)
    }

    private static func shareSource() -> Source {
        Source(
            id: "share-sheet",
            displayName: SourceVocabulary.shareSheetDisplayName,
            kind: .importer,
            group: .bringingInYourself,
            state: .active,
            activeSubtext: SourceVocabulary.importerActiveSubtext,
            attention: nil,
            pendingStatus: .nonePending,
            isJournalConnected: true
        )
    }

    private static func onThisPhoneItem() -> OnThisPhoneItem {
        OnThisPhoneItem(
            id: UUID().uuidString,
            sourceKind: .share,
            sendState: .inYourJournal,
            contentType: "application/pdf",
            filename: "item.pdf",
            bytes: 42,
            originApp: "Files",
            basis: "share",
            itemTime: Date(),
            targetJournal: "journal",
            stream: "default",
            day: "2026-06-02",
            segment: "morning",
            deliveredAt: Date(),
            rawFileURL: nil
        )
    }
}

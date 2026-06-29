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
            hostname: "test-device",
            version: "1.0",
            loadKey: { nil },
            saveKey: { _ in },
            deleteKey: {}
        )
        let observerUploader = ObserverUploader(
            ensureRegistered: { "observer-key" },
            localPortProvider: { 7071 }
        )
        let mobileSegmentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicTypeSmokeTests-MobileSegment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: mobileSegmentRoot) }
        let mobileSegmentClock = MockObserverClock()
        let mobileSegmentUploader = MobileSegmentUploader(
            transport: observerUploader,
            store: MobileSegmentStore(rootURL: mobileSegmentRoot),
            clock: mobileSegmentClock
        )
        let mobileSegmentEngine = MobileSegmentEngine(
            uploader: mobileSegmentUploader,
            clock: mobileSegmentClock
        )
        let omiUploaderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicTypeSmokeTests-OmiUploader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: omiUploaderRoot) }
        let omiUploader = ObserverUploader(
            cacheRootURL: omiUploaderRoot,
            sessionConfiguration: .ephemeral,
            sourceType: "omi-audio",
            startPathMonitor: false
        )
        let omiUploaderHolder = OmiUploaderHolder(omiUploader)
        let watchUploaderRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicTypeSmokeTests-WatchUploader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: watchUploaderRoot) }
        let watchUploader = ObserverUploader(
            cacheRootURL: watchUploaderRoot,
            sessionConfiguration: .ephemeral,
            sourceType: "watch-audio",
            platform: "watchos",
            startPathMonitor: false
        )
        let watchUploaderHolder = WatchUploaderHolder(watchUploader)
        let watchSession = MockWatchConnectivitySession()
        let watchRelayRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicTypeSmokeTests-WatchRelay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: watchRelayRoot) }
        let watchRelayReceiver = try WatchRelayReceiver(session: watchSession, stagingRootURL: watchRelayRoot)
        let watchLink = WatchLink(session: watchSession, receiver: watchRelayReceiver)
        let observerManager = ObserverManager(
            recorder: MockObserverRecorder(),
            uploader: observerUploader,
            mobileSegmentEngine: mobileSegmentEngine
        )
        let locationManager = LocationManager(
            provider: MockLocationProvider(),
            mobileSegmentEngine: mobileSegmentEngine,
            clock: MockObserverClock(),
            defaults: nil
        )
        let omiDefaultsName = "DynamicTypeSmokeTests-Omi-\(UUID().uuidString)"
        let omiDefaults = try XCTUnwrap(UserDefaults(suiteName: omiDefaultsName))
        defer { omiDefaults.removePersistentDomain(forName: omiDefaultsName) }
        let omiDiagnosticsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DynamicTypeSmokeTests-OmiDiagnostics-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: omiDiagnosticsURL) }
        let omiSourceManager = OmiSourceManager(
            defaults: omiDefaults,
            diagnostics: OmiDiagnostics(clock: MockObserverClock(), fileURL: omiDiagnosticsURL),
            clock: MockObserverClock()
        )
        let activeLocationProvider = MockLocationProvider()
        activeLocationProvider.capability = .always(accuracy: .full)
        let activeLocationManager = LocationManager(
            provider: activeLocationProvider,
            mobileSegmentEngine: mobileSegmentEngine,
            clock: MockObserverClock(),
            defaults: nil
        )
        await activeLocationManager.start(tier: .balanced)
        XCTAssertEqual(activeLocationManager.sourceState, .active)
        let needsAttentionLocationProvider = MockLocationProvider()
        needsAttentionLocationProvider.capability = .denied
        let needsAttentionLocationManager = LocationManager(
            provider: needsAttentionLocationProvider,
            mobileSegmentEngine: mobileSegmentEngine,
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
        let chatManager = ChatManager(
            transport: ScriptedChatTransport(),
            isReachable: { true },
            localPortProvider: { 7071 }
        )
        let finishSyncingCoordinator = FinishSyncingCoordinator(
            totals: { (0, 0) },
            inFlight: { 0 },
            drive: {},
            isConnected: { false },
            disconnect: {}
        )
        chatManager.pendingOffer = ChatOffer(text: "I can ask support to help with this.")
        chatManager.pendingDraft = ChatDraft(
            id: "draft-1",
            body: "Please help with journal connection.",
            fields: [ChatDraftField(id: "summary", label: "summary", value: "journal connection")],
            diagnosticsIncluded: true
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
            .environment(omiUploaderHolder)
            .environment(watchUploaderHolder)
            .environment(importQueue)
            .environment(locationManager)
            .environment(mobileSegmentUploader)
            .environment(mobileSegmentEngine)
            .environment(observerManager)
        }

        let sourcesView = NavigationStack {
            SourcesView()
                .environment(appConfig)
                .environment(observerManager)
                .environment(observerRegistration)
                .environment(ObserverSourcePauseState())
                .environment(importQueue)
                .environment(locationManager)
                .environment(mobileSegmentUploader)
                .environment(omiSourceManager)
                .environment(watchLink)
                .environment(watchRelayReceiver)
                .environment(watchUploaderHolder)
        }
        let locationSourceDetailView = NavigationStack {
            LocationSourceDetailView()
                .environment(locationManager)
                .environment(mobileSegmentUploader)
                .environment(observerRegistration)
        }
        let omiSourceDetailView = NavigationStack {
            OmiSourceDetailView()
                .environment(omiSourceManager)
        }
        let watchSourceDetailView = NavigationStack {
            WatchSourceDetailView()
                .environment(watchLink)
                .environment(watchRelayReceiver)
                .environment(watchUploaderHolder)
        }
        let activeLocationSourceDetailView = NavigationStack {
            LocationSourceDetailView()
                .environment(activeLocationManager)
                .environment(mobileSegmentUploader)
                .environment(observerRegistration)
        }
        let needsAttentionLocationSourceDetailView = NavigationStack {
            LocationSourceDetailView()
                .environment(needsAttentionLocationManager)
                .environment(mobileSegmentUploader)
                .environment(observerRegistration)
        }
        let importerSourceDetailView = NavigationStack {
            ImporterSourceDetailView(source: Self.shareSource())
                .environment(appConfig)
                .environment(importQueue)
                .environment(observerManager)
                .environment(observerUploader)
                .environment(omiUploaderHolder)
                .environment(watchUploaderHolder)
                .environment(tunnelManager)
                .environment(finishSyncingCoordinator)
                .environment(mobileSegmentUploader)
                .environment(observerRegistration)
                .environment(observerManager)
        }
        let onThisPhoneView = NavigationStack {
            OnThisPhoneView()
                .environment(appConfig)
                .environment(importQueue)
                .environment(observerManager)
                .environment(observerUploader)
                .environment(omiUploaderHolder)
                .environment(watchUploaderHolder)
                .environment(tunnelManager)
                .environment(finishSyncingCoordinator)
                .environment(locationManager)
                .environment(mobileSegmentUploader)
                .environment(observerRegistration)
        }
        let onThisPhoneItemDetailView = NavigationStack {
            OnThisPhoneItemDetailView(item: Self.onThisPhoneItem(), onRequestDrop: { _ in })
                .environment(importQueue)
                .environment(observerManager)
                .environment(observerUploader)
                .environment(omiUploaderHolder)
                .environment(watchUploaderHolder)
                .environment(mobileSegmentUploader)
                .environment(observerRegistration)
        }
        let chatView = ChatView()
            .environment(chatManager)
            .environment(tunnelManager)
            .environment(PendingFoldState())
        let assistantSourcedBubble = AssistantBubble(
            message: ChatMessage(
                role: .assistant,
                text: "i can answer here once native ask connects to your journal.",
                provenance: AnswerProvenance(
                    state: .answered,
                    sources: [Self.provenanceSource()],
                    coverage: ["read your journal"]
                )
            )
        )
        let assistantPartialBubble = AssistantBubble(
            message: ChatMessage(
                role: .assistant,
                text: "i don't have enough to answer that.",
                provenance: AnswerProvenance(state: .partial, coverage: ["Reading your journal…"])
            )
        )
        let assistantFailedBubble = AssistantBubble(
            message: ChatMessage(
                role: .assistant,
                text: "could not answer",
                provenance: AnswerProvenance(state: .failed)
            )
        )
        let provenanceSourcesPanel = ProvenanceSourcesPanel(sources: [Self.provenanceSource()])

        try self.assertHosted(
            WelcomeScreen(onGetStarted: {})
                .environment(\.dynamicTypeSize, .accessibility3)
        )
        try self.assertHosted(moreView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(sourcesView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(locationSourceDetailView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(omiSourceDetailView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(watchSourceDetailView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(activeLocationSourceDetailView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(needsAttentionLocationSourceDetailView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(importerSourceDetailView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(onThisPhoneView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(onThisPhoneItemDetailView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(chatView.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(assistantSourcedBubble.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(assistantPartialBubble.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(assistantFailedBubble.environment(\.dynamicTypeSize, .accessibility3))
        try self.assertHosted(provenanceSourcesPanel.environment(\.dynamicTypeSize, .accessibility3))
        await activeLocationManager.stop()
        // ShareExtensionView is private in the extension target; its copy is mechanically covered by lock tests.
        // Hit-target audit: scoped controls are standard Buttons/NavigationLinks/segmented Picker, so no frame assertions are needed here.
    }

    @MainActor private func assertHosted<V: View>(_ view: V) throws {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.isHidden = false
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        window.layoutIfNeeded()
        XCTAssertGreaterThan(controller.view.systemLayoutSizeFitting(CGSize(width: 393, height: 852)).height, 0)
        window.isHidden = true
        window.rootViewController = nil
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
            pendingStatus: .nonePending
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

    private static func provenanceSource() -> AnswerProvenance.ProvenanceSource {
        AnswerProvenance.ProvenanceSource(
            ref: "sol://entry/902",
            label: "9:02 call with jack",
            url: URL(string: "http://127.0.0.1/")
        )
    }
}

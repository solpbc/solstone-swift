// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class BannerPresenterTests: XCTestCase {
    @MainActor private lazy var log = DiagnosticLog()
    @MainActor private lazy var voiceManager = VoiceManager()
    @MainActor private lazy var tunnelManager: TunnelManager = {
        let manager = TunnelManager()
        manager.state = .connected(localPort: 8080, via: .lan)
        return manager
    }()
    @MainActor private lazy var presenter = BannerPresenter(
        diagnosticLog: self.log,
        voiceManager: self.voiceManager,
        tunnelManager: self.tunnelManager
    )

    @MainActor
    func testInfoNetworkEventIsBannerWorthy() {
        XCTAssertTrue(BannerPresenter.isBannerWorthy(self.makeEvent(.network, .info, "interface changed to wifi")))
    }

    @MainActor
    func testInfoNetworkStatusIsBannerWorthy() {
        XCTAssertTrue(BannerPresenter.isBannerWorthy(self.makeEvent(.network, .info, "network satisfied")))
    }

    @MainActor
    func testInfoTunnelConnectedIsBannerWorthy() {
        XCTAssertTrue(BannerPresenter.isBannerWorthy(self.makeEvent(.tunnel, .info, "journal connected")))
    }

    @MainActor
    func testInfoTunnelPortBearingConnectedIsNotBannerWorthy() {
        let event = self.makeEvent(.tunnel, .info, "connected via local network on port 8080")

        XCTAssertFalse(BannerPresenter.isBannerWorthy(event))
        XCTAssertTrue(event.message.range(of: #":?\d{2,5}"#, options: .regularExpression) != nil)
    }

    @MainActor
    func testInfoTunnelStageNotBannerWorthy() {
        XCTAssertFalse(BannerPresenter.isBannerWorthy(self.makeEvent(.tunnel, .info, "stage: sshConnect started")))
    }

    @MainActor
    func testInfoTunnelLanProbeNotBannerWorthy() {
        XCTAssertFalse(BannerPresenter.isBannerWorthy(self.makeEvent(.tunnel, .info, "lan probe: reachable")))
    }

    @MainActor
    func testInfoUploadBatchIsBannerWorthy() {
        XCTAssertTrue(BannerPresenter.isBannerWorthy(self.makeEvent(.upload, .info, "3 files sent")))
    }

    @MainActor
    func testInfoUploadPerFileNotBannerWorthy() {
        XCTAssertFalse(BannerPresenter.isBannerWorthy(self.makeEvent(.upload, .info, "sent photo.jpg")))
    }

    @MainActor
    func testInfoUploadProcessingNotBannerWorthy() {
        XCTAssertFalse(BannerPresenter.isBannerWorthy(self.makeEvent(.upload, .info, "processing 3 files")))
    }

    @MainActor
    func testInfoVoiceSessionWithPortIsNotBannerWorthy() {
        XCTAssertFalse(BannerPresenter.isBannerWorthy(self.makeEvent(.voice, .info, "session starting on port 8080")))
    }

    @MainActor
    func testInfoVoiceListeningNotBannerWorthy() {
        XCTAssertFalse(BannerPresenter.isBannerWorthy(self.makeEvent(.voice, .info, "listening")))
    }

    @MainActor
    func testInfoVoiceKeyNotBannerWorthy() {
        XCTAssertFalse(BannerPresenter.isBannerWorthy(self.makeEvent(.voice, .info, "ephemeral key fetched")))
    }

    @MainActor
    func testInfoBrainIsBannerWorthy() {
        XCTAssertTrue(BannerPresenter.isBannerWorthy(self.makeEvent(.brain, .info, "brain: idle → refreshing")))
    }

    @MainActor
    func testWarningAlwaysBannerWorthy() {
        XCTAssertTrue(BannerPresenter.isBannerWorthy(self.makeEvent(.tunnel, .warning, "anything")))
    }

    @MainActor
    func testErrorAlwaysBannerWorthy() {
        XCTAssertTrue(BannerPresenter.isBannerWorthy(self.makeEvent(.voice, .error, "anything")))
    }

    @MainActor
    func testProcessNewEventsShowsBanner() {
        self.append(.network, .info, "network satisfied")

        self.presenter.processNewEvents()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "network satisfied")
    }

    @MainActor
    func testCoalescingSameCategoryWithin1s() {
        self.append(.network, .info, "network satisfied")
        self.append(.network, .info, "interface changed to wifi")

        self.presenter.processNewEvents()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "interface changed to wifi")
        self.presenter.dismiss()
        XCTAssertNil(self.presenter.currentBanner)
    }

    @MainActor
    func testNoCoalescingDifferentCategory() {
        self.append(.network, .info, "network satisfied")
        self.append(.tunnel, .info, "journal connected")

        self.presenter.processNewEvents()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "network satisfied")
        self.presenter.dismiss()
        XCTAssertEqual(self.presenter.currentBanner?.event.message, "journal connected")
    }

    @MainActor
    func testQueueMaxDepth3() {
        self.append(.network, .info, "network satisfied")
        self.append(.tunnel, .info, "journal connected")
        self.append(.upload, .info, "1 files sent")
        self.append(.brain, .info, "brain: idle → refreshing")
        self.append(.voice, .error, "voice failed")

        self.presenter.processNewEvents()

        var messages: [String] = []
        while let banner = self.presenter.currentBanner {
            messages.append(banner.event.message)
            self.presenter.dismiss()
        }

        XCTAssertEqual(messages, [
            "network satisfied",
            "1 files sent",
            "brain: idle → refreshing",
            "voice failed",
        ])
    }

    @MainActor
    func testVoiceSuppressionDropsInfo() {
        self.voiceManager.state = .listening
        self.append(.network, .info, "network satisfied")

        self.presenter.processNewEvents()

        XCTAssertNil(self.presenter.currentBanner)
    }

    @MainActor
    func testVoiceSuppressionAllowsWarning() {
        self.voiceManager.state = .listening
        self.append(.network, .warning, "network unsatisfied")

        self.presenter.processNewEvents()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "network unsatisfied")
    }

    @MainActor
    func testVoiceSuppressionAllowsError() {
        self.voiceManager.state = .speaking
        self.append(.voice, .error, "connection failed")

        self.presenter.processNewEvents()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "connection failed")
    }

    @MainActor
    func testDismissInfoIfVoiceActiveRemovesVisibleInfoBanner() {
        self.append(.network, .info, "network satisfied")
        self.presenter.processNewEvents()

        self.voiceManager.state = .listening
        self.presenter.dismissInfoIfVoiceActive()

        XCTAssertNil(self.presenter.currentBanner)
    }

    @MainActor
    func testDismissInfoIfVoiceActiveDropsQueuedInfoBanners() {
        self.append(.network, .info, "network satisfied")
        self.append(.brain, .info, "brain: idle → refreshing")
        self.append(.voice, .warning, "connection failed")
        self.presenter.processNewEvents()

        self.voiceManager.state = .speaking
        self.presenter.dismissInfoIfVoiceActive()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "connection failed")
        self.presenter.dismiss()
        XCTAssertNil(self.presenter.currentBanner)
    }

    @MainActor
    func testDisconnectedSuppressesAll() {
        self.tunnelManager.state = .disconnected
        self.append(.network, .warning, "network unsatisfied")
        self.append(.voice, .error, "connection failed")

        self.presenter.processNewEvents()

        XCTAssertNil(self.presenter.currentBanner)
    }

    @MainActor
    func testResolutionDismissesError() {
        self.append(.tunnel, .error, "connection failed")
        self.presenter.processNewEvents()

        self.append(.tunnel, .info, "journal connected")
        self.presenter.processNewEvents()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "journal connected")
        XCTAssertEqual(self.presenter.currentBanner?.event.severity, .info)
    }

    @MainActor
    func testResolutionOnlySameCategory() {
        self.append(.tunnel, .error, "connection failed")
        self.presenter.processNewEvents()

        self.append(.network, .info, "network satisfied")
        self.presenter.processNewEvents()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "connection failed")
        XCTAssertEqual(self.presenter.currentBanner?.event.severity, .error)
    }

    @MainActor
    func testAutoDismissInfoIs3Seconds() {
        let item = BannerPresenter.BannerItem(event: self.makeEvent(.network, .info, "network satisfied"))
        XCTAssertEqual(item.autoDismissSeconds, 3)
    }

    @MainActor
    func testAutoDismissWarningIs5Seconds() {
        let item = BannerPresenter.BannerItem(event: self.makeEvent(.network, .warning, "network unsatisfied"))
        XCTAssertEqual(item.autoDismissSeconds, 5)
    }

    @MainActor
    func testAutoDismissErrorIsNil() {
        let item = BannerPresenter.BannerItem(event: self.makeEvent(.network, .error, "network failed"))
        XCTAssertNil(item.autoDismissSeconds)
    }

    @MainActor
    func testDismissAdvancesQueue() {
        self.append(.network, .info, "network satisfied")
        self.append(.tunnel, .info, "journal connected")

        self.presenter.processNewEvents()
        self.presenter.dismiss()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "journal connected")
    }

    @MainActor
    func testTapSetsDiagnosticsFlag() {
        self.append(.network, .info, "network satisfied")
        self.presenter.processNewEvents()

        self.presenter.tap()

        XCTAssertTrue(self.presenter.showDiagnostics)
        XCTAssertNil(self.presenter.currentBanner)
    }

    @MainActor
    func testClearAllRemovesEverything() {
        self.append(.network, .info, "network satisfied")
        self.append(.tunnel, .info, "journal connected")

        self.presenter.processNewEvents()
        self.presenter.clearAll()

        XCTAssertNil(self.presenter.currentBanner)
        self.presenter.dismiss()
        XCTAssertNil(self.presenter.currentBanner)
    }

    @MainActor
    func testRingBufferShrinkageRecovery() {
        self.append(.network, .info, "network satisfied")
        self.presenter.processNewEvents()

        self.log.clear()
        self.presenter.processNewEvents()
        self.presenter.clearAll()

        self.append(.upload, .info, "2 files sent")
        self.presenter.processNewEvents()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "2 files sent")
    }

    @MainActor private func append(_ category: DiagnosticCategory, _ severity: DiagnosticSeverity, _ message: String) {
        _ = self.presenter
        self.log.append(self.makeEvent(category, severity, message))
    }

    @MainActor private func makeEvent(_ category: DiagnosticCategory, _ severity: DiagnosticSeverity, _ message: String) -> DiagnosticEvent {
        DiagnosticEvent(category: category, severity: severity, message: message)
    }
}

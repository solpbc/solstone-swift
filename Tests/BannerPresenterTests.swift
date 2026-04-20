// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

final class BannerPresenterTests: XCTestCase {
    private var log: DiagnosticLog!
    private var voiceManager: VoiceManager!
    private var tunnelManager: TunnelManager!
    private var presenter: BannerPresenter!

    override func setUp() {
        self.log = DiagnosticLog()
        self.voiceManager = VoiceManager()
        self.tunnelManager = TunnelManager()
        self.tunnelManager.state = .connected(localPort: 8080, via: .lan)
        self.presenter = BannerPresenter(
            diagnosticLog: self.log,
            voiceManager: self.voiceManager,
            tunnelManager: self.tunnelManager
        )
    }

    override func tearDown() {
        self.presenter?.clearAll()
        self.presenter = nil
        self.tunnelManager = nil
        self.voiceManager = nil
        self.log = nil
    }

    func testInfoNetworkEventIsBannerWorthy() {
        XCTAssertTrue(BannerPresenter.isBannerWorthy(self.makeEvent(.network, .info, "interface changed to wifi")))
    }

    func testInfoNetworkStatusIsBannerWorthy() {
        XCTAssertTrue(BannerPresenter.isBannerWorthy(self.makeEvent(.network, .info, "network satisfied")))
    }

    func testInfoTunnelConnectedIsBannerWorthy() {
        XCTAssertTrue(BannerPresenter.isBannerWorthy(self.makeEvent(.tunnel, .info, "connected via local network on port 8080")))
    }

    func testInfoTunnelStageNotBannerWorthy() {
        XCTAssertFalse(BannerPresenter.isBannerWorthy(self.makeEvent(.tunnel, .info, "stage: sshConnect started")))
    }

    func testInfoTunnelLanProbeNotBannerWorthy() {
        XCTAssertFalse(BannerPresenter.isBannerWorthy(self.makeEvent(.tunnel, .info, "lan probe: reachable")))
    }

    func testInfoUploadBatchIsBannerWorthy() {
        XCTAssertTrue(BannerPresenter.isBannerWorthy(self.makeEvent(.upload, .info, "3 files sent")))
    }

    func testInfoUploadPerFileNotBannerWorthy() {
        XCTAssertFalse(BannerPresenter.isBannerWorthy(self.makeEvent(.upload, .info, "sent photo.jpg")))
    }

    func testInfoUploadProcessingNotBannerWorthy() {
        XCTAssertFalse(BannerPresenter.isBannerWorthy(self.makeEvent(.upload, .info, "processing 3 files")))
    }

    func testInfoVoiceSessionIsBannerWorthy() {
        XCTAssertTrue(BannerPresenter.isBannerWorthy(self.makeEvent(.voice, .info, "session starting on port 8080")))
    }

    func testInfoVoiceListeningNotBannerWorthy() {
        XCTAssertFalse(BannerPresenter.isBannerWorthy(self.makeEvent(.voice, .info, "listening")))
    }

    func testInfoVoiceKeyNotBannerWorthy() {
        XCTAssertFalse(BannerPresenter.isBannerWorthy(self.makeEvent(.voice, .info, "ephemeral key fetched")))
    }

    func testInfoBrainIsBannerWorthy() {
        XCTAssertTrue(BannerPresenter.isBannerWorthy(self.makeEvent(.brain, .info, "brain: idle → refreshing")))
    }

    func testWarningAlwaysBannerWorthy() {
        XCTAssertTrue(BannerPresenter.isBannerWorthy(self.makeEvent(.tunnel, .warning, "anything")))
    }

    func testErrorAlwaysBannerWorthy() {
        XCTAssertTrue(BannerPresenter.isBannerWorthy(self.makeEvent(.voice, .error, "anything")))
    }

    func testProcessNewEventsShowsBanner() {
        self.append(.network, .info, "network satisfied")

        self.presenter.processNewEvents()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "network satisfied")
    }

    func testCoalescingSameCategoryWithin1s() {
        self.append(.network, .info, "network satisfied")
        self.append(.network, .info, "interface changed to wifi")

        self.presenter.processNewEvents()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "interface changed to wifi")
        self.presenter.dismiss()
        XCTAssertNil(self.presenter.currentBanner)
    }

    func testNoCoalescingDifferentCategory() {
        self.append(.network, .info, "network satisfied")
        self.append(.tunnel, .info, "connected via local network on port 8080")

        self.presenter.processNewEvents()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "network satisfied")
        self.presenter.dismiss()
        XCTAssertEqual(self.presenter.currentBanner?.event.message, "connected via local network on port 8080")
    }

    func testQueueMaxDepth3() {
        self.append(.network, .info, "network satisfied")
        self.append(.tunnel, .info, "connected via local network on port 8080")
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

    func testVoiceSuppressionDropsInfo() {
        self.voiceManager.state = .listening
        self.append(.network, .info, "network satisfied")

        self.presenter.processNewEvents()

        XCTAssertNil(self.presenter.currentBanner)
    }

    func testVoiceSuppressionAllowsWarning() {
        self.voiceManager.state = .listening
        self.append(.network, .warning, "network unsatisfied")

        self.presenter.processNewEvents()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "network unsatisfied")
    }

    func testVoiceSuppressionAllowsError() {
        self.voiceManager.state = .speaking
        self.append(.voice, .error, "connection failed")

        self.presenter.processNewEvents()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "connection failed")
    }

    func testDismissInfoIfVoiceActiveRemovesVisibleInfoBanner() {
        self.append(.network, .info, "network satisfied")
        self.presenter.processNewEvents()

        self.voiceManager.state = .listening
        self.presenter.dismissInfoIfVoiceActive()

        XCTAssertNil(self.presenter.currentBanner)
    }

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

    func testDisconnectedSuppressesAll() {
        self.tunnelManager.state = .disconnected
        self.append(.network, .warning, "network unsatisfied")
        self.append(.voice, .error, "connection failed")

        self.presenter.processNewEvents()

        XCTAssertNil(self.presenter.currentBanner)
    }

    func testResolutionDismissesError() {
        self.append(.tunnel, .error, "connection failed")
        self.presenter.processNewEvents()

        self.append(.tunnel, .info, "connected via local network on port 8080")
        self.presenter.processNewEvents()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "connected via local network on port 8080")
        XCTAssertEqual(self.presenter.currentBanner?.event.severity, .info)
    }

    func testResolutionOnlySameCategory() {
        self.append(.tunnel, .error, "connection failed")
        self.presenter.processNewEvents()

        self.append(.network, .info, "network satisfied")
        self.presenter.processNewEvents()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "connection failed")
        XCTAssertEqual(self.presenter.currentBanner?.event.severity, .error)
    }

    func testAutoDismissInfoIs3Seconds() {
        let item = BannerPresenter.BannerItem(event: self.makeEvent(.network, .info, "network satisfied"))
        XCTAssertEqual(item.autoDismissSeconds, 3)
    }

    func testAutoDismissWarningIs5Seconds() {
        let item = BannerPresenter.BannerItem(event: self.makeEvent(.network, .warning, "network unsatisfied"))
        XCTAssertEqual(item.autoDismissSeconds, 5)
    }

    func testAutoDismissErrorIsNil() {
        let item = BannerPresenter.BannerItem(event: self.makeEvent(.network, .error, "network failed"))
        XCTAssertNil(item.autoDismissSeconds)
    }

    func testDismissAdvancesQueue() {
        self.append(.network, .info, "network satisfied")
        self.append(.tunnel, .info, "connected via local network on port 8080")

        self.presenter.processNewEvents()
        self.presenter.dismiss()

        XCTAssertEqual(self.presenter.currentBanner?.event.message, "connected via local network on port 8080")
    }

    func testTapSetsDiagnosticsFlag() {
        self.append(.network, .info, "network satisfied")
        self.presenter.processNewEvents()

        self.presenter.tap()

        XCTAssertTrue(self.presenter.showDiagnostics)
        XCTAssertNil(self.presenter.currentBanner)
    }

    func testClearAllRemovesEverything() {
        self.append(.network, .info, "network satisfied")
        self.append(.tunnel, .info, "connected via local network on port 8080")

        self.presenter.processNewEvents()
        self.presenter.clearAll()

        XCTAssertNil(self.presenter.currentBanner)
        self.presenter.dismiss()
        XCTAssertNil(self.presenter.currentBanner)
    }

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

    private func append(_ category: DiagnosticCategory, _ severity: DiagnosticSeverity, _ message: String) {
        self.log.append(self.makeEvent(category, severity, message))
    }

    private func makeEvent(_ category: DiagnosticCategory, _ severity: DiagnosticSeverity, _ message: String) -> DiagnosticEvent {
        DiagnosticEvent(category: category, severity: severity, message: message)
    }
}

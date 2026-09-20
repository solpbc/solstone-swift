// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest
import SPLTunnel

nonisolated final class PairFlowViewTests: XCTestCase {
    func testLinkInHandNeverDisplaysTheScanScreen() {
        XCTAssertEqual(PairFlowView.displayedPhase(.pairing, linkInHand: true), .connecting)
        XCTAssertEqual(PairFlowView.displayedPhase(.pairing, linkInHand: false), .pairing)
        XCTAssertEqual(PairFlowView.displayedPhase(.connecting, linkInHand: true), .connecting)
        XCTAssertEqual(PairFlowView.displayedPhase(.couldNotVerify, linkInHand: true), .couldNotVerify)
        XCTAssertEqual(PairFlowView.displayedPhase(.mismatch, linkInHand: true), .mismatch)
    }

    @MainActor
    func testFallbackTimerSurfacesPasteAffordanceAfterDelay() async {
        let timer = PairFlowFallbackTimer(delay: .milliseconds(20))

        timer.start()
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(timer.shouldShowPasteFallback)
    }

    @MainActor
    func testFallbackTimerCancelPreventsAffordance() async {
        let timer = PairFlowFallbackTimer(delay: .milliseconds(40))

        timer.start()
        timer.cancel()
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertFalse(timer.shouldShowPasteFallback)
    }

    @MainActor
    func testFallbackTimerResetAllowsRestart() async {
        let timer = PairFlowFallbackTimer(delay: .milliseconds(20))

        timer.start()
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(timer.shouldShowPasteFallback)

        timer.reset()
        XCTAssertFalse(timer.shouldShowPasteFallback)
        timer.start()
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertTrue(timer.shouldShowPasteFallback)
    }

    @MainActor
    func testStillTryingTimerSurfacesAfterDelay() async {
        let timer = PairFlowStillTryingTimer(delay: .milliseconds(20))

        timer.start()
        XCTAssertFalse(timer.showsStillTrying)
        let surfaced = await self.waitUntil { timer.showsStillTrying }

        XCTAssertTrue(surfaced)
    }

    @MainActor
    func testStillTryingTimerResetBeforeDelayNeverSurfaces() async {
        let timer = PairFlowStillTryingTimer(delay: .milliseconds(40))

        timer.start()
        timer.reset()
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertFalse(timer.showsStillTrying)
    }

    @MainActor
    func testStillTryingTimerResetClearsTheLineAndAllowsRestart() async {
        let timer = PairFlowStillTryingTimer(delay: .milliseconds(20))

        timer.start()
        let first = await self.waitUntil { timer.showsStillTrying }
        XCTAssertTrue(first)

        timer.reset()
        XCTAssertFalse(timer.showsStillTrying)
        timer.start()
        let second = await self.waitUntil { timer.showsStillTrying }

        XCTAssertTrue(second)
    }

    /// Polls with a deadline rather than sleeping a fixed beat, because CI hosts run loaded and a
    /// starved timer task must not read as a failure.
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @MainActor
    func testTitleNamesTheTabTheOwnerIsOn() {
        XCTAssertEqual(PairFlowView.pairingTitle(for: .scan), "scan your pairing code")
        XCTAssertEqual(PairFlowView.pairingTitle(for: .paste), "paste your pairing link")
    }

    @MainActor
    func testConnectingSubtitleIsEmptyUntilStillTrying() {
        XCTAssertEqual(PairFlowView.connectingSubtitle(stillTrying: false), "")
        XCTAssertEqual(PairFlowView.connectingSubtitle(stillTrying: true), SourceVocabulary.pairingStillTrying)
    }

    @MainActor
    func testPairingWindowClosedMessage() {
        XCTAssertEqual(
            PairFlowCoordinator.message(for: PairError.pairingWindowClosed, targetAddress: nil, interfaces: []),
            "the pairing window closed. show a new pairing code on your journal, then try again."
        )
    }

    @MainActor
    func testConnectionDroppedMessageIsDistinctFromPairingWindowClosedMessage() {
        let message = PairFlowCoordinator.message(
            for: PairError.lanClosedBeforeResponse,
            targetAddress: nil,
            interfaces: []
        )

        XCTAssertEqual(
            message,
            "lost the connection to your journal before it answered. try again."
        )
        XCTAssertNotEqual(
            message,
            "the pairing window closed. show a new pairing code on your journal, then try again."
        )
    }

    nonisolated func testClassifyPastedLinkRejectsLoopbackBeforeRouting() {
        for raw in [
            "http://localhost:5015/app/network/",
            "http://127.0.0.1:5015/",
            "http://127.0.0.2/",
            "http://[::1]:5015/"
        ] {
            XCTAssertEqual(PairFlowView.classifyPastedLink(raw), .loopback)
        }
    }

    nonisolated func testClassifyPastedLinkRejectsInvalidInputs() {
        XCTAssertEqual(PairFlowView.classifyPastedLink("https://example.com/x"), .invalid)
        XCTAssertEqual(PairFlowView.classifyPastedLink(""), .invalid)
    }

    nonisolated func testClassifyPastedLinkAcceptsCanonicalPairingLink() {
        let outcome = PairFlowView.classifyPastedLink(Self.canonicalPairingLink)
        guard case .pair = outcome else {
            return XCTFail("expected pair, got \(outcome)")
        }
    }

    private static let canonicalPairingLink = "https://go.solstone.app/p#0G0W000258DSX8DJRFAEBXG7308J4CT4ANK7F26YNPZEZJQYQAZ028T5CY4TQKFF"

    func testPairFlowSubtitlesMatchLockedExactCopy() throws {
        let text = try Self.contents("Sources/Pairing/PairFlowView.swift")
        let scanSubtitle = "on your computer, open your journal's dashboard, go to the network app, and choose \\\"pair a device\\\"."
        let pasteSubtitle = "on your computer, open your journal's dashboard, go to the network app, choose \\\"pair a device\\\", then copy the link."
        XCTAssertTrue(text.contains(scanSubtitle), "scan subtitle missing or modified in PairFlowView.swift")
        XCTAssertTrue(text.contains(pasteSubtitle), "paste subtitle missing or modified in PairFlowView.swift")
    }

    func testQRScannerViewHandlesUnavailableAndErrors() throws {
        let text = try Self.contents("Sources/Pairing/QRScannerView.swift")
        XCTAssertTrue(text.contains("becameUnavailableWithError"), "becameUnavailableWithError delegate method missing")
        XCTAssertFalse(text.contains("try? controller.startScanning()"), "silent try? startScanning() still present")
        XCTAssertTrue(text.contains("Coordinator(onURL: onURL, onUnavailable: onUnavailable)"), "coordinator does not receive onUnavailable")
    }
}

private extension PairFlowViewTests {
    static func contents(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

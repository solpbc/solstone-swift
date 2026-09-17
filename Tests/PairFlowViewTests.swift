// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest
import SPLTunnel

nonisolated final class PairFlowViewTests: XCTestCase {
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

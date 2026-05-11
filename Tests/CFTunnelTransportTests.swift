// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest
import os

nonisolated final class CFTunnelTransportTests: XCTestCase {
    @MainActor
    func testMissingPairingSurfacesCleanErrorAndStage() async {
        let transport = CFTunnelTransport(loadPairing: { nil })
        let stages = OSAllocatedUnfairLock(initialState: [TransportStage]())

        do {
            _ = try await transport.connect(
                candidates: [],
                onDisconnect: { _ in },
                onStageChange: { stage in stages.withLock { $0.append(stage) } }
            )
            XCTFail("expected missing pairing")
        } catch {
            XCTAssertEqual(error as? CFTunnelTransportError, .missingPairing)
        }

        XCTAssertEqual(stages.withLock { $0 }, [.preparingCandidates, .failed("missing pairing")])
    }

    @MainActor
    func testDisconnectClearsConnectionMode() async {
        let transport = CFTunnelTransport(loadPairing: { nil })

        await transport.disconnect()

        XCTAssertNil(transport.connectionMode)
    }
}

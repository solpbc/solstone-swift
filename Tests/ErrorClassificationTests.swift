// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Network
import NIOCore
import XCTest
@testable import solstone_swift
@testable import NIOSSH

nonisolated final class ErrorClassificationTests: XCTestCase {
    @MainActor
    func testHostKeyError_MapsToHostKeyMismatch() {
        XCTAssertEqual(TunnelError.classify(HostKeyError.mismatch), .hostKeyMismatch)
    }

    @MainActor
    func testChannelTimeout_MapsToConnectionTimeout() {
        let error = ChannelError.connectTimeout(.seconds(5))
        XCTAssertEqual(TunnelError.classify(error), .connectionTimeout)
    }

    @MainActor
    func testConnectionRefused_MapsToConnectionRefused() {
        let error = NWError.posix(.ECONNREFUSED)
        XCTAssertEqual(TunnelError.classify(error), .connectionRefused)
    }

    @MainActor
    func testNetworkUnreachable_MapsCorrectly() {
        XCTAssertEqual(TunnelError.classify(NWError.posix(.ENETUNREACH)), .networkUnreachable)
        XCTAssertEqual(TunnelError.classify(NWError.posix(.EHOSTUNREACH)), .networkUnreachable)
    }

    @MainActor
    func testDNSError_MapsToNetworkUnreachable() {
        let error = NWError.dns(1)
        XCTAssertEqual(TunnelError.classify(error), .networkUnreachable)
    }

    @MainActor
    func testSSHChannelClosure_MapsToAuthenticationFailed() {
        let error = NIOSSHError.creatingChannelAfterClosure
        XCTAssertEqual(TunnelError.classify(error), .authenticationFailed)
    }

    @MainActor
    func testUnknownError_MapsToUnknown() {
        struct SomeError: Error {}
        let result = TunnelError.classify(SomeError())
        if case .unknown = result {
        } else {
            XCTFail("Expected .unknown, got \(result)")
        }
    }

    @MainActor
    func testTunnelErrorEquatable_UnknownCase() {
        XCTAssertEqual(TunnelError.unknown("a"), TunnelError.unknown("a"))
        XCTAssertNotEqual(TunnelError.unknown("a"), TunnelError.unknown("b"))
    }
}

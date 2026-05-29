// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel
import XCTest

private final class PairClientURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}

nonisolated final class PairClientTests: XCTestCase {
    func testCancelledLANRequestSurfacesFingerprintMismatch() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairClientURLProtocol.self]
        let client = PairClient(session: URLSession(configuration: configuration))

        do {
            _ = try await client.pair(
                pairURL: try PairURL.parse(Self.canonicalURL()),
                deviceLabel: "test phone",
                relayEndpoint: URL(string: "https://relay.example.com")!
            )
            XCTFail("expected PairError.lanCAFingerprintMismatch")
        } catch let error as PairError {
            XCTAssertEqual(error, .lanCAFingerprintMismatch)
        }
    }

    private static func canonicalURL() -> URL {
        URL(string: "https://link.solpbc.org/p#0G0W000258DSX8DJRFAEBXG7308J4CT4ANK7F26YNPZEZJQYQAZ028T5CY4TQKFF")!
    }
}

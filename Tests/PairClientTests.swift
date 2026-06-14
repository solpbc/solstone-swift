// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@testable import SPLTunnel
import XCTest

nonisolated final class PairClientTests: XCTestCase {
    func testPairTicketRequestTargetsProductionRelayContract() throws {
        let request = try PairClient.makePairTicketRequest(
            relayEndpoint: URL(string: "https://link.solstone.app")!,
            instanceID: "12345678-1234-5678-1234-567812345678",
            totp: "123456",
            userAgent: "test-agent"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://link.solstone.app/session/pair-ticket?instance=12345678-1234-5678-1234-567812345678")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "test-agent")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["instance_id"], "12345678-1234-5678-1234-567812345678")
        XCTAssertEqual(json["totp"], "123456")
    }

    func testRelayPairDialURLConvertsProductionHTTPSOriginToWSS() throws {
        let url = try RelayWSTransport.webSocketURL(
            endpoint: URL(string: "https://link.solstone.app")!,
            path: "session/pair-dial",
            instanceID: "instance-123"
        )

        XCTAssertEqual(url.absoluteString, "wss://link.solstone.app/session/pair-dial?instance=instance-123")
    }

    func testTunnelPairHTTPRequestUsesRelativeMuxPath() throws {
        let body = Data(#"{"csr":"pem","device_label":"phone"}"#.utf8)
        let request = PairClient.buildHTTPRequest(
            method: "POST",
            path: "/app/link/pair?token=012345",
            body: body
        )
        let text = try XCTUnwrap(String(data: request, encoding: .utf8))

        XCTAssertTrue(text.hasPrefix("POST /app/link/pair?token=012345 HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Host: spl.local\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(text.contains("Content-Length: \(body.count)\r\n"))
        XCTAssertTrue(text.hasSuffix(String(data: body, encoding: .utf8)!))
    }

    func testRelayEnrollRequestOmitsClientCert() throws {
        let lanResponse = try PairClient.decodeLANResponse(data: Data(Self.lanResponseJSON.utf8))
        let request = try PairClient.makeRelayRequest(
            relayEndpoint: URL(string: "https://link.solstone.app")!,
            response: lanResponse,
            userAgent: "test-agent"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://link.solstone.app/enroll/device")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["instance_id"], "instance-123")
        XCTAssertEqual(json["home_attestation"], "attestation-123")
        XCTAssertNil(json["client_cert"])
    }

    private static let lanResponseJSON = """
    {
      "instance_id": "instance-123",
      "home_label": "home",
      "client_cert": "-----BEGIN CERTIFICATE-----\\nMIIB\\n-----END CERTIFICATE-----\\n",
      "ca_chain": [],
      "home_attestation": "attestation-123",
      "local_endpoints": []
    }
    """
}

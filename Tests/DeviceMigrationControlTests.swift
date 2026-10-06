// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Crypto
import SPLTunnel
import XCTest
@testable import SPLTunnel
@testable import solstone_swift

private final class MigrationStreamHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: MuxStream?

    func set(_ stream: MuxStream) {
        self.lock.withLock { self.stream = stream }
    }

    func deliver(_ data: Data) {
        let stream = self.lock.withLock { self.stream }
        if let stream {
            Task {
                var offset = 0
                while offset < data.count {
                    let end = min(offset + 19, data.count)
                    _ = await stream.deliverInboundData(Data(data[offset..<end]))
                    offset = end
                }
                await stream.deliverInboundClose()
            }
        }
    }
}

private final class MigrationMuxCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = Data()

    func append(_ data: Data) {
        self.lock.withLock { self.frames.append(data) }
    }

    func data() -> Data {
        self.lock.withLock { self.frames }
    }
}

private final class MigrationResponseCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?

    func set(_ value: Data) {
        self.lock.withLock { self.value = value }
    }

    func get() -> Data? {
        self.lock.withLock { self.value }
    }
}

private actor MigrationControlSession: TunnelSessioning, MuxStreamOpening {
    nonisolated let stateUpdates = AsyncStream<SPLTunnel.TunnelState> { $0.finish() }
    nonisolated let connectionModeUpdates = AsyncStream<ConnectionMode?> { $0.finish() }
    private(set) var connectionMode: ConnectionMode?
    private let stream: MuxStream
    private let capture: MigrationMuxCapture
    private var disconnectCount = 0

    init(response: Data?, capture: MigrationMuxCapture, repliesToClose: Bool = true) {
        self.capture = capture
        let holder = MigrationStreamHolder()
        self.stream = MuxStream(
            id: 7,
            sink: { frame in
                capture.append(frame)
                if repliesToClose,
                   let response,
                   frame.count > 4,
                   frame[4] & FrameFlags.close.rawValue != 0 {
                    holder.deliver(response)
                }
            },
            onTerminal: { _ in }
        )
        holder.set(self.stream)
    }

    func connect(endpoints: [TransportEndpoint]) async throws -> ConnectedVia {
        .lanDirect(host: "192.0.2.1", port: 7657)
    }

    func disconnect() async {
        self.disconnectCount += 1
        self.connectionMode = nil
    }

    func openStream() async throws -> MuxStream { self.stream }

    func inboundActivitySnapshot() async -> UInt64 { 0 }

    func capturedFrames() -> Data { self.capture.data() }

    func disconnections() -> Int { self.disconnectCount }

    func streamState() async -> StreamState { await self.stream.state }
}

@MainActor
final class DeviceMigrationControlTests: XCTestCase {
    func testCryptoCSRPrivatePEMUsesShippedPKCS8Import() throws {
        let material = try CryptoCSR.generate(deviceLabel: "migration-test-device")
        XCTAssertTrue(material.csrPEM.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----"))
        XCTAssertTrue(material.privateKeyPEM.hasPrefix("-----BEGIN PRIVATE KEY-----"))
        let imported = try P256.Signing.PrivateKey(pemRepresentation: material.privateKeyPEM)
        XCTAssertEqual(imported.publicKey.x963Representation.count, 65)
    }

    func testIssuedCryptoCSRFixtureBindsPKCS8KeyToCertificateAndRejectsWrongKey() throws {
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
            .appendingPathComponent("issued-crypto-memory-fixture-261006.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        let responses = try XCTUnwrap(fixture["responses"] as? [String: [String: Any]])
        let operationText = try XCTUnwrap(fixture["operation_id"] as? String)
        let operationID = try XCTUnwrap(UUID(uuidString: operationText))
        let privateKeyPEM = try XCTUnwrap(fixture["private_key_pem"] as? String)
        let csrPEM = try XCTUnwrap(fixture["csr_pem"] as? String)
        XCTAssertTrue(csrPEM.hasPrefix("-----BEGIN CERTIFICATE REQUEST-----"))

        let oldPublic = try XCTUnwrap(fixture["old_pairing_public"] as? [String: Any])
        let oldPairing = StoredPairing(
            instanceID: try XCTUnwrap(oldPublic["instance_id"] as? String),
            homeLabel: try XCTUnwrap(oldPublic["home_label"] as? String),
            relayEndpoint: try XCTUnwrap(oldPublic["relay_endpoint"] as? String),
            fingerprint: try XCTUnwrap(oldPublic["fingerprint"] as? String),
            clientCertPEM: try XCTUnwrap(oldPublic["client_cert"] as? String),
            clientKeyPEM: "unused in validation",
            caChainPEM: try XCTUnwrap(oldPublic["ca_chain_pem"] as? String),
            relayEnrollment: .unavailable,
            localEndpoints: [],
            pairedAt: Date(timeIntervalSince1970: 0)
        )
        let expectedPreviousCID = try XCTUnwrap(responses["without_optional_network_metadata"]?["previous_cid"] as? String)
        let pairedAt = Date(timeIntervalSince1970: try XCTUnwrap(fixture["paired_at_epoch"] as? Double))

        for responseName in ["without_optional_network_metadata", "not_configured"] {
            let response = try XCTUnwrap(responses[responseName])
            let responseBytes = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            let validated = try DeviceMigrationPairingValidator.validate(
                responseData: responseBytes,
                expectedOperationID: operationID,
                expectedPreviousCID: expectedPreviousCID,
                oldPairing: oldPairing,
                privateKeyPEM: privateKeyPEM,
                relayEndpoint: oldPairing.relayEndpoint,
                pairedAt: pairedAt
            )
            XCTAssertEqual(validated.operationID, operationID)
            XCTAssertEqual(validated.pairing.fingerprint, fixture["validated_cid"] as? String)
            XCTAssertTrue(validated.sameInstanceAndCA)
        }

        let wrongKey = try CryptoCSR.generate(deviceLabel: "migration-wrong-key-twin")
        let positiveResponse = try JSONSerialization.data(
            withJSONObject: XCTUnwrap(responses["without_optional_network_metadata"]),
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(try DeviceMigrationPairingValidator.validate(
            responseData: positiveResponse,
            expectedOperationID: operationID,
            expectedPreviousCID: expectedPreviousCID,
            oldPairing: oldPairing,
            privateKeyPEM: wrongKey.privateKeyPEM,
            relayEndpoint: oldPairing.relayEndpoint,
            pairedAt: pairedAt
        )) { error in
            XCTAssertEqual(error as? DeviceMigrationControlError, .keyBindingFailed)
        }
    }

    func testPinnedRekeyVectorDecodesWithoutOptionalNetworkMetadata() throws {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        let vectorsURL = root.appendingPathComponent("v1.vectors.json")
        let vectorsData = try Data(contentsOf: vectorsURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: vectorsData) as? [String: Any])
        let vectors = try XCTUnwrap(object["vectors"] as? [String: Any])
        let vector = try XCTUnwrap(vectors["rekey_without_network_metadata"] as? [String: Any])
        let body = try XCTUnwrap(vector["body"] as? [String: Any])
        let pairingJSON = try XCTUnwrap(body["pairing"] as? [String: Any])
        let pairingData = try JSONSerialization.data(withJSONObject: pairingJSON)

        let pairing = try JSONDecoder().decode(MigrationPairingResponse.self, from: pairingData)
        XCTAssertEqual(pairing.instanceID, "fixture-instance")
        XCTAssertEqual(pairing.homeAttestation, "fixture-attestation")
        XCTAssertTrue(pairing.localEndpoints.isEmpty)
        XCTAssertNil(pairing.relayAccess)
    }

    func testRelayAccessUsesPinnedV2EnvelopeValidationAndRejectsFixturePlaceholder() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiresAt = "2030-01-01T00:00:00Z"
        let token = try Self.v2Token(instanceID: "relay-test-instance", issuedAt: 1_700_000_000, expiresAt: 1_893_456_000)
        let ready = try JSONSerialization.data(withJSONObject: [
            "protocol_version": 2,
            "status": "ready",
            "relay_origin": "https://relay.example.invalid",
            "instance_id": "relay-test-instance",
            "device_token": token,
            "expires_at": expiresAt,
        ], options: [.sortedKeys])
        guard case .ready(let capability) = try RelayAccessValidation.decode(
            ready,
            expectedInstanceID: "relay-test-instance",
            now: now
        ) else {
            return XCTFail("expected validated ready capability")
        }
        XCTAssertEqual(capability.relayOrigin.absoluteString, "https://relay.example.invalid")
        XCTAssertEqual(capability.instanceID, "relay-test-instance")
        XCTAssertEqual(capability.deviceToken, token)

        let notConfigured = Data(#"{"protocol_version":2,"status":"not_configured"}"#.utf8)
        XCTAssertEqual(
            try RelayAccessValidation.decode(notConfigured, expectedInstanceID: "relay-test-instance", now: now),
            .notConfigured
        )
        let extraField = Data(#"{"protocol_version":2,"status":"not_configured","device_token":null}"#.utf8)
        XCTAssertThrowsError(try RelayAccessValidation.decode(extraField, expectedInstanceID: "relay-test-instance", now: now))

        let vectorsURL = try XCTUnwrap(Bundle(for: Self.self).resourceURL).appendingPathComponent("v1.vectors.json")
        let vectorsData = try Data(contentsOf: vectorsURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: vectorsData) as? [String: Any])
        let vectors = try XCTUnwrap(root["vectors"] as? [String: Any])
        let created = try XCTUnwrap(vectors["rekey_created_201"] as? [String: Any])
        let body = try XCTUnwrap(created["body"] as? [String: Any])
        let pairing = try XCTUnwrap(body["pairing"] as? [String: Any])
        let fixtureRelayAccess = try XCTUnwrap(pairing["relay_access"] as? [String: Any])
        XCTAssertThrowsError(try RelayAccessValidation.decode(
            JSONSerialization.data(withJSONObject: fixtureRelayAccess),
            expectedInstanceID: "fixture-instance",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ))
    }

    func testMigrationHTTPParserAcceptsContentLengthAndRejectsMalformedFraming() throws {
        let body = try Self.createdMigrationResponseBody()
        let journalResponse = Data(
            "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
        ) + body
        XCTAssertEqual(MigrationHTTPResponseParser.parse(journalResponse, endOfStream: true)?.body, body)

        let conflicting = Data(
            "HTTP/1.1 201 Created\r\nContent-Length: \(body.count)\r\nContent-Length: \(body.count)\r\n\r\n".utf8
        ) + body
        XCTAssertNil(MigrationHTTPResponseParser.parse(conflicting, endOfStream: true))
        let transferAndLength = Data(
            "HTTP/1.1 201 Created\r\nContent-Length: \(body.count)\r\nTransfer-Encoding: chunked\r\n\r\n".utf8
        ) + body
        XCTAssertNil(MigrationHTTPResponseParser.parse(transferAndLength, endOfStream: true))
        let noLength = Data("HTTP/1.1 201 Created\r\nConnection: close\r\n\r\n".utf8) + body
        XCTAssertNil(MigrationHTTPResponseParser.parse(noLength, endOfStream: true))
        XCTAssertNil(MigrationHTTPResponseParser.parse(journalResponse, endOfStream: false))
        let incomplete = Data("HTTP/1.1 201 Created\r\nContent-Length: \(body.count + 1)\r\n\r\n".utf8) + body
        XCTAssertNil(MigrationHTTPResponseParser.parse(incomplete, endOfStream: true))
        let excess = Data("HTTP/1.1 201 Created\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body + Data([0x21])
        XCTAssertNil(MigrationHTTPResponseParser.parse(excess, endOfStream: true))
        let ambiguousHTTP10 = Data("HTTP/1.0 201 Created\r\nConnection: keep-alive\r\n\r\n".utf8) + body
        XCTAssertNil(MigrationHTTPResponseParser.parse(ambiguousHTTP10, endOfStream: true))
    }

    func testPrivateMuxExchangeCarriesPersistedBodyAndFinishesBeforeDisconnect() async throws {
        let body = Data(#"{"operation_id":"123e4567-e89b-42d3-a456-426614174000"}"#.utf8)
        let expectedResponseBody = try Self.createdMigrationResponseBody()
        let response = Data(
            "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: \(expectedResponseBody.count)\r\nConnection: close\r\n\r\n".utf8
        )
            + expectedResponseBody
        let capture = MigrationMuxCapture()
        let session = MigrationControlSession(response: response, capture: capture)
        let exchange = SPLMigrationControlExchange(makeSession: { _ in session })
        let responseCapture = MigrationResponseCapture()

        try await exchange.postRekey(
            pairing: Self.pairing,
            candidates: [],
            body: body,
            shouldContinue: { true }
        ) { data in
            responseCapture.set(data)
            let disconnectCount = await session.disconnections()
            XCTAssertEqual(disconnectCount, 0)
        }

        XCTAssertEqual(responseCapture.get(), expectedResponseBody)
        let disconnectCount = await session.disconnections()
        XCTAssertEqual(disconnectCount, 1)
        var decoder = FrameDecoder()
        let frames = await session.capturedFrames()
        decoder.feed(frames)
        var requestPayload = Data()
        while let frame = try decoder.next() {
            if frame.flags & FrameFlags.data.rawValue != 0 {
                requestPayload.append(frame.payload)
            }
        }
        let request = try XCTUnwrap(String(data: requestPayload, encoding: .utf8))
        XCTAssertTrue(request.hasPrefix("POST /app/network/api/clients/self/rekey HTTP/1.1\r\n"))
        XCTAssertTrue(request.contains("Content-Length: \(body.count)\r\n\r\n"))
        XCTAssertTrue(request.hasSuffix(String(decoding: body, as: UTF8.self)))
    }

    func testPrivateMuxExchangeRejectsIncompleteAndExcessResponses() async throws {
        let body = try Self.createdMigrationResponseBody()
        let incomplete = Data("HTTP/1.1 201 Created\r\nContent-Length: \(body.count + 1)\r\nConnection: close\r\n\r\n".utf8)
            + body
        let excess = Data("HTTP/1.1 201 Created\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            + body + Data([0x21])

        for response in [incomplete, excess] {
            let capture = MigrationMuxCapture()
            let session = MigrationControlSession(response: response, capture: capture)
            let exchange = SPLMigrationControlExchange(makeSession: { _ in session })
            do {
                try await exchange.postRekey(
                    pairing: Self.pairing,
                    candidates: [],
                    body: Data("exact request".utf8),
                    shouldContinue: { true }
                ) { _ in }
                XCTFail("malformed response framing must be rejected")
            } catch {
                XCTAssertEqual(error as? DeviceMigrationControlError, .invalidHTTP)
            }
            let disconnectCount = await session.disconnections()
            XCTAssertEqual(disconnectCount, 1)
        }
    }

    func testCancelledPrivateMuxReadResetsStreamAndDisconnectsSession() async throws {
        let capture = MigrationMuxCapture()
        let session = MigrationControlSession(response: nil, capture: capture, repliesToClose: false)
        let exchange = SPLMigrationControlExchange(makeSession: { _ in session })
        let task = Task {
            try await exchange.postRekey(
                pairing: Self.pairing,
                candidates: [],
                body: Data("exact request".utf8),
                shouldContinue: { true }
            ) { _ in }
        }

        while (await session.capturedFrames()).isEmpty {
            await Task.yield()
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("cancelled Mux response wait must finish")
        } catch is CancellationError {
            // Cancellation resets the private stream and then closes its one-shot session.
        }

        let disconnectCount = await session.disconnections()
        let streamState = await session.streamState()
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertEqual(streamState, .resetLocal)
    }

    private static let pairing = StoredPairing(
        instanceID: "control-test-instance",
        homeLabel: "test",
        relayEndpoint: "https://relay.example.invalid",
        fingerprint: "sha256:" + String(repeating: "a", count: 64),
        clientCertPEM: CertlessTrustConstants.leafPEM,
        clientKeyPEM: "unused",
        caChainPEM: CertlessTrustConstants.caPEM,
        relayEnrollment: .unavailable,
        localEndpoints: [],
        pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    private static func createdMigrationResponseBody() throws -> Data {
        let root = try XCTUnwrap(Bundle(for: Self.self).resourceURL)
        let vectorsData = try Data(contentsOf: root.appendingPathComponent("v1.vectors.json"))
        let vectorsObject = try XCTUnwrap(JSONSerialization.jsonObject(with: vectorsData) as? [String: Any])
        let vectors = try XCTUnwrap(vectorsObject["vectors"] as? [String: Any])
        let created = try XCTUnwrap(vectors["rekey_created_201"] as? [String: Any])
        let body = try XCTUnwrap(created["body"] as? [String: Any])
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func v2Token(instanceID: String, issuedAt: Int, expiresAt: Int) throws -> String {
        let header = Data(#"{"alg":"ES256","typ":"JWT"}"#.utf8)
        let payload = try JSONSerialization.data(withJSONObject: [
            "iss": "solstone-journal",
            "sub": "instance:\(instanceID)",
            "aud": "spl-relay",
            "scope": "session.dial",
            "ver": 2,
            "instance_id": instanceID,
            "iat": issuedAt,
            "exp": expiresAt,
            "jti": "migration-test-token",
        ], options: [.sortedKeys])
        return "\(Self.base64URL(header)).\(Self.base64URL(payload)).fixture-signature"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

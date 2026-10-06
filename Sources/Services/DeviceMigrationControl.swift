// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import Security
import SPLTunnel
import os

private nonisolated let migrationControlLog = Logger(subsystem: "app.solstone.swift", category: "device-migration")

nonisolated enum DeviceMigrationControlError: Error, Equatable, Sendable {
    case invalidResponse
    case unexpectedStatus(Int)
    case responseTooLarge
    case invalidHTTP
    case identityChanged
    case operationChanged
    case keyBindingFailed
}

nonisolated struct MigrationRekeyRequest: Encodable, Sendable {
    let protocolVersion = 1
    let operationID: UUID
    let csr: String
    let deviceLabel: String
    let clientLabel: String
    let platform = "ios"

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case operationID = "operation_id"
        case csr
        case deviceLabel = "device_label"
        case clientLabel = "client_label"
        case platform
    }
}

nonisolated struct MigrationPairingResponse: Decodable, Sendable {
    let instanceID: String
    let homeLabel: String
    let clientCert: String
    let caChain: [String]
    let fingerprint: String
    let homeAttestation: String
    let localEndpoints: [LocalEndpoint]
    let relayAccess: MigrationRelayAccess?

    enum CodingKeys: String, CodingKey {
        case instanceID = "instance_id"
        case homeLabel = "home_label"
        case clientCert = "client_cert"
        case caChain = "ca_chain"
        case fingerprint
        case homeAttestation = "home_attestation"
        case localEndpoints = "local_endpoints"
        case relayAccess = "relay_access"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.instanceID = try container.decode(String.self, forKey: .instanceID)
        self.homeLabel = try container.decode(String.self, forKey: .homeLabel)
        self.clientCert = try container.decode(String.self, forKey: .clientCert)
        self.caChain = try container.decode([String].self, forKey: .caChain)
        self.fingerprint = try container.decode(String.self, forKey: .fingerprint)
        self.homeAttestation = try container.decode(String.self, forKey: .homeAttestation)
        self.localEndpoints = try container.decodeIfPresent([LocalEndpoint].self, forKey: .localEndpoints) ?? []
        self.relayAccess = try container.decodeIfPresent(MigrationRelayAccess.self, forKey: .relayAccess)
    }
}

nonisolated struct MigrationRelayAccess: Decodable, Encodable, Sendable {
    let protocolVersion: Int
    let status: String
    let relayOrigin: String?
    let instanceID: String?
    let deviceToken: String?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case status
        case relayOrigin = "relay_origin"
        case instanceID = "instance_id"
        case deviceToken = "device_token"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let dynamic = try decoder.container(keyedBy: MigrationDynamicCodingKey.self)
        let keys = Set(dynamic.allKeys.map(\.stringValue))
        self.protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        self.status = try container.decode(String.self, forKey: .status)
        self.relayOrigin = try container.decodeIfPresent(String.self, forKey: .relayOrigin)
        self.instanceID = try container.decodeIfPresent(String.self, forKey: .instanceID)
        self.deviceToken = try container.decodeIfPresent(String.self, forKey: .deviceToken)
        self.expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        let required: Set<String> = self.status == "not_configured"
            ? ["protocol_version", "status"]
            : ["protocol_version", "status", "relay_origin", "instance_id", "device_token", "expires_at"]
        guard keys == required else { throw DeviceMigrationControlError.invalidResponse }
    }
}

nonisolated private struct MigrationDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

nonisolated struct MigrationRekeyResponse: Decodable, Sendable {
    let protocolVersion: Int
    let operationID: UUID
    let state: String
    let previousCID: String
    let cid: String
    let pairing: MigrationPairingResponse

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case operationID = "operation_id"
        case state
        case previousCID = "previous_cid"
        case cid
        case pairing
    }
}

nonisolated struct ValidatedMigrationPairing: Sendable, Equatable {
    let operationID: UUID
    let previousCID: String
    let pairing: StoredPairing
    let sameInstanceAndCA: Bool
}

@MainActor
protocol MigrationControlExchanging: Sendable {
    func postRekey(
        pairing: StoredPairing,
        candidates: [TransportEndpoint],
        body: Data,
        shouldContinue: @MainActor @Sendable () -> Bool,
        afterResponse: @MainActor @Sendable (Data) async throws -> Void
    ) async throws
}

/// One-shot control transport. It only opens Mux streams; it never creates a local port or proxy.
@MainActor
final class SPLMigrationControlExchange: MigrationControlExchanging {
    typealias SessionFactory = @Sendable (StoredPairing) -> any TunnelSessioning & MuxStreamOpening

    private let makeSession: SessionFactory

    init(makeSession: @escaping SessionFactory = CFTunnelTransport.makeProductionSession) {
        self.makeSession = makeSession
    }

    func postRekey(
        pairing: StoredPairing,
        candidates: [TransportEndpoint],
        body: Data,
        shouldContinue: @MainActor @Sendable () -> Bool,
        afterResponse: @MainActor @Sendable (Data) async throws -> Void
    ) async throws {
        let session = self.makeSession(pairing)
        do {
            _ = try await session.connect(endpoints: candidates)
            guard shouldContinue() else { throw CancellationError() }
            let response = try await Self.exchange(
                session: session,
                method: "POST",
                path: "/app/network/api/clients/self/rekey",
                body: body,
                shouldContinue: shouldContinue
            )
            guard response.status == 200 || response.status == 201 else {
                throw DeviceMigrationControlError.unexpectedStatus(response.status)
            }
            try await afterResponse(response.body)
            await session.disconnect()
        } catch {
            await session.disconnect()
            migrationControlLog.error("private migration control exchange failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private static func exchange(
        session: any MuxStreamOpening,
        method: String,
        path: String,
        body: Data,
        shouldContinue: @MainActor @Sendable () -> Bool
    ) async throws -> (status: Int, body: Data) {
        let stream = try await session.openStream()
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard shouldContinue() else { throw CancellationError() }
                let request = Data((
                    "\(method) \(path) HTTP/1.1\r\n" +
                    "Host: journal\r\n" +
                    "Content-Type: application/json\r\n" +
                    "Accept: application/json\r\n" +
                    "Connection: close\r\n" +
                    "Content-Length: \(body.count)\r\n\r\n"
                ).utf8) + body
                try await stream.write(request)
                try Task.checkCancellation()
                guard shouldContinue() else { throw CancellationError() }
                try await stream.close()
                try Task.checkCancellation()
                guard shouldContinue() else { throw CancellationError() }

                var response = Data()
                for try await chunk in stream.inbound {
                    try Task.checkCancellation()
                    guard shouldContinue() else { throw CancellationError() }
                    response.append(chunk)
                    guard response.count <= 1_048_576 else { throw DeviceMigrationControlError.responseTooLarge }
                }
                try Task.checkCancellation()
                guard shouldContinue() else { throw CancellationError() }
                guard let parsed = MigrationHTTPResponseParser.parse(response, endOfStream: true) else {
                    throw DeviceMigrationControlError.invalidHTTP
                }
                return parsed
            } onCancel: {
                Task { await stream.reset(reason: .cancel) }
            }
        } catch {
            await stream.reset(reason: .cancel)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}

nonisolated enum MigrationHTTPResponseParser {
    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let maximumBodySize = 1_048_576
    private static let maximumHeaderSize = 32_768

    static func parse(_ data: Data, endOfStream: Bool) -> (status: Int, body: Data)? {
        guard endOfStream else { return nil }
        guard let headerEnd = data.range(of: Self.headerTerminator) else {
            return nil
        }
        guard headerEnd.lowerBound <= Self.maximumHeaderSize,
              let header = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let statusParts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard statusParts.count >= 2,
              statusParts[0] == "HTTP/1.0" || statusParts[0] == "HTTP/1.1",
              statusParts[1].count == 3,
              let status = Int(statusParts[1]),
              (100...599).contains(status) else { return nil }

        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"),
                  colon != line.startIndex else { return nil }
            let name = line[..<colon].lowercased()
            guard name.utf8.allSatisfy(Self.isHeaderNameByte) else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name, default: []].append(value)
        }

        let bodyStart = headerEnd.upperBound
        let bodyBytes = data[bodyStart...]
        let lengths = headers["content-length"] ?? []
        let encodings = headers["transfer-encoding"] ?? []
        guard lengths.count <= 1, encodings.isEmpty else { return nil }
        if status < 200 || status == 204 || status == 304 {
            guard bodyBytes.isEmpty else { return nil }
            return (status, Data())
        }

        if let lengthText = lengths.first {
            guard !lengthText.isEmpty,
                  lengthText.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                  let length = Int(lengthText),
                  (0...Self.maximumBodySize).contains(length),
                  bodyBytes.count == length else { return nil }
            return (status, Data(bodyBytes))
        }
        return nil
    }

    private static func isHeaderNameByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte)
            || byte == 0x21 || byte == 0x23 || byte == 0x24 || byte == 0x25 || byte == 0x26 || byte == 0x27
            || byte == 0x2a || byte == 0x2b || byte == 0x2d || byte == 0x2e || byte == 0x5e || byte == 0x5f
            || byte == 0x60 || byte == 0x7c || byte == 0x7e
    }

}

nonisolated enum DeviceMigrationPairingValidator {
    static func validate(
        responseData: Data,
        expectedOperationID: UUID,
        expectedPreviousCID: String,
        oldPairing: StoredPairing,
        privateKeyPEM: String,
        relayEndpoint: String,
        pairedAt: Date = Date()
    ) throws -> ValidatedMigrationPairing {
        let response: MigrationRekeyResponse
        do {
            response = try JSONDecoder().decode(MigrationRekeyResponse.self, from: responseData)
        } catch {
            throw DeviceMigrationControlError.invalidResponse
        }
        guard response.protocolVersion == 1,
              response.operationID == expectedOperationID,
              response.state == "pending",
              response.previousCID == expectedPreviousCID,
              response.cid == response.pairing.fingerprint else {
            throw DeviceMigrationControlError.operationChanged
        }
        guard response.pairing.instanceID == oldPairing.instanceID,
              !response.pairing.homeAttestation.isEmpty,
              (try? DevicePairingIdentity.make(for: oldPairing)) == (try? Self.identity(for: response.pairing)) else {
            throw DeviceMigrationControlError.identityChanged
        }
        let validatedRelay = try Self.validateRelayAccess(
            response.pairing.relayAccess,
            instanceID: response.pairing.instanceID,
            now: pairedAt
        )
        try Self.validateKeyBinding(
            privateKeyPEM: privateKeyPEM,
            clientCertPEM: response.pairing.clientCert,
            expectedFingerprint: response.pairing.fingerprint
        )
        let pairing = StoredPairing(
            instanceID: response.pairing.instanceID,
            homeLabel: response.pairing.homeLabel,
            relayEndpoint: validatedRelay.origin ?? relayEndpoint,
            fingerprint: response.pairing.fingerprint,
            clientCertPEM: response.pairing.clientCert,
            clientKeyPEM: privateKeyPEM,
            caChainPEM: response.pairing.caChain.joined(separator: "\n"),
            relayEnrollment: validatedRelay.enrollment,
            localEndpoints: response.pairing.localEndpoints,
            pairedAt: pairedAt
        )
        return ValidatedMigrationPairing(
            operationID: response.operationID,
            previousCID: response.previousCID,
            pairing: pairing,
            sameInstanceAndCA: true
        )
    }

    private static func identity(for response: MigrationPairingResponse) throws -> DevicePairingIdentity {
        let pairing = StoredPairing(
            instanceID: response.instanceID,
            homeLabel: response.homeLabel,
            relayEndpoint: "wss://invalid.local",
            fingerprint: response.fingerprint,
            clientCertPEM: response.clientCert,
            clientKeyPEM: "unused",
            caChainPEM: response.caChain.joined(separator: "\n"),
            relayEnrollment: .unavailable,
            localEndpoints: response.localEndpoints,
            pairedAt: Date(timeIntervalSince1970: 0)
        )
        return try DevicePairingIdentity.make(for: pairing)
    }

    private static func validateRelayAccess(
        _ access: MigrationRelayAccess?,
        instanceID: String,
        now: Date
    ) throws -> (origin: String?, enrollment: RelayEnrollment) {
        guard let access else { return (nil, .unavailable) }
        guard let envelope = try? JSONEncoder().encode(access),
              let status = try? RelayAccessValidation.decode(
                envelope,
                expectedInstanceID: instanceID,
                now: now
              ) else {
            throw DeviceMigrationControlError.invalidResponse
        }
        switch status {
        case .notConfigured:
            return (nil, .unavailable)
        case .ready(let capability):
            return (
                capability.relayOrigin.absoluteString,
                .enrolled(deviceToken: capability.deviceToken, expiresAt: capability.expiresAt)
            )
        }
    }

    private static func validateKeyBinding(
        privateKeyPEM: String,
        clientCertPEM: String,
        expectedFingerprint: String
    ) throws {
        guard let cert = try? CertChain.certificates(fromPEM: clientCertPEM).first,
              let certKey = SecCertificateCopyKey(cert) else {
            throw DeviceMigrationControlError.keyBindingFailed
        }
        guard let privateKey = try? P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM) else {
            throw DeviceMigrationControlError.keyBindingFailed
        }
        var certError: Unmanaged<CFError>?
        guard let certBytes = SecKeyCopyExternalRepresentation(certKey, &certError) as Data?,
              privateKey.publicKey.x963Representation == certBytes,
              !certBytes.isEmpty else {
            throw DeviceMigrationControlError.keyBindingFailed
        }
        let actualFingerprint = "sha256:" + CertChain.sha256Fingerprint(of: cert)
        let expected = expectedFingerprint.lowercased().hasPrefix("sha256:")
            ? expectedFingerprint.lowercased()
            : "sha256:\(expectedFingerprint.lowercased())"
        guard actualFingerprint.caseInsensitiveCompare(expected) == .orderedSame else {
            throw DeviceMigrationControlError.keyBindingFailed
        }
    }
}

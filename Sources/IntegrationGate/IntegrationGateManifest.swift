// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

#if DEBUG && targetEnvironment(simulator)
private let log = Logger(subsystem: "app.solstone.swift", category: "integration-gate-manifest")

struct IntegrationGateManifest: Sendable, Equatable {
    var schemaVersion: Int
    var sequence: UInt64
    var nonce: String
    var action: IntegrationGateAction
    var createdAtUnixMillis: Int64
    var expiresAtUnixMillis: Int64
    var expectedPairing: ExpectedPairing
    var expectedBuild: ExpectedBuild
    var expectedContentLength: UInt64?
    var expectedSHA256Hex: String?
    var rangeStart: UInt64?
    var rangeLength: UInt64?

    struct ExpectedPairing: Sendable, Equatable {
        var instanceID: String
        var fingerprintSHA256Hex: String
        var pairedAtNotBeforeUnixMillis: Int64
    }

    struct ExpectedBuild: Sendable, Equatable {
        var sourceCommit: String
        var splSwiftRevision: String
    }

    var correlationID: String {
        "\(self.sequence)-\(self.nonce)"
    }

    static func decodeAndValidate(_ data: Data) throws -> IntegrationGateManifest {
        let decoder = JSONDecoder()
        let payload = try decoder.decode(StrictPayload.self, from: data)
        return try payload.validated()
    }
}

private struct StrictPayload: Decodable {
    var schemaVersion: Int
    var sequence: UInt64
    var nonce: String
    var action: String
    var createdAtUnixMillis: Int64
    var expiresAtUnixMillis: Int64
    var expectedPairing: StrictExpectedPairing
    var expectedBuild: StrictExpectedBuild
    var expectedContentLength: UInt64?
    var expectedSHA256Hex: String?
    var rangeStart: UInt64?
    var rangeLength: UInt64?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case sequence
        case nonce
        case action
        case createdAtUnixMillis
        case expiresAtUnixMillis
        case expectedPairing
        case expectedBuild
        case expectedContentLength
        case expectedSHA256Hex
        case rangeStart
        case rangeLength
    }

    init(from decoder: Decoder) throws {
        try Self.rejectUnknownFields(decoder: decoder, allowed: CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            sequence = try container.decode(UInt64.self, forKey: .sequence)
            nonce = try container.decode(String.self, forKey: .nonce)
            action = try container.decode(String.self, forKey: .action)
            createdAtUnixMillis = try container.decode(Int64.self, forKey: .createdAtUnixMillis)
            expiresAtUnixMillis = try container.decode(Int64.self, forKey: .expiresAtUnixMillis)
            expectedPairing = try container.decode(StrictExpectedPairing.self, forKey: .expectedPairing)
            expectedBuild = try container.decode(StrictExpectedBuild.self, forKey: .expectedBuild)
            expectedContentLength = try container.decodeIfPresent(UInt64.self, forKey: .expectedContentLength)
            expectedSHA256Hex = try container.decodeIfPresent(String.self, forKey: .expectedSHA256Hex)
            rangeStart = try container.decodeIfPresent(UInt64.self, forKey: .rangeStart)
            rangeLength = try container.decodeIfPresent(UInt64.self, forKey: .rangeLength)
        } catch let error as IntegrationGateValidationError {
            throw error
        } catch {
            throw IntegrationGateValidationError(.missingField)
        }
    }

    func validated() throws -> IntegrationGateManifest {
        guard schemaVersion == IntegrationGateConstants.schemaVersion else {
            throw IntegrationGateValidationError(.schemaMismatch)
        }
        guard sequence > 0 else {
            throw IntegrationGateValidationError(.invalidSequence)
        }
        guard expiresAtUnixMillis > createdAtUnixMillis else {
            throw IntegrationGateValidationError(.expiredManifest)
        }
        let decodedAction: IntegrationGateAction
        if action.contains("://") || action.contains("/") || action.contains("..") {
            throw IntegrationGateValidationError(.malformedRouteInput)
        }
        guard let parsedAction = IntegrationGateAction(rawValue: action) else {
            throw IntegrationGateValidationError(.unknownAction)
        }
        decodedAction = parsedAction

        try Self.validateNonempty(nonce)
        try Self.validateNonempty(expectedPairing.instanceID)
        try Self.validateNonempty(expectedBuild.sourceCommit)
        try Self.validateNonempty(expectedBuild.splSwiftRevision)
        try Self.validateDigest(expectedPairing.fingerprintSHA256Hex)

        if let expectedSHA256Hex {
            try Self.validateDigest(expectedSHA256Hex)
        }

        switch decodedAction {
        case .rangeHash:
            guard let rangeStart, let rangeLength, rangeLength > 0 else {
                throw IntegrationGateValidationError(.invalidRange)
            }
            guard rangeStart <= UInt64.max - rangeLength else {
                throw IntegrationGateValidationError(.invalidRange)
            }
            guard expectedContentLength != nil, expectedSHA256Hex != nil else {
                throw IntegrationGateValidationError(.invalidDigest)
            }
        case .generationRetry:
            guard expectedContentLength != nil, expectedSHA256Hex != nil else {
                throw IntegrationGateValidationError(.invalidDigest)
            }
            if rangeStart != nil || rangeLength != nil {
                throw IntegrationGateValidationError(.invalidRange)
            }
        case .canary, .syncReconnectWindow, .syncTransferWindow:
            if rangeStart != nil || rangeLength != nil {
                throw IntegrationGateValidationError(.invalidRange)
            }
        }

        if let expectedContentLength, expectedContentLength == 0 {
            throw IntegrationGateValidationError(.invalidCeiling)
        }

        return IntegrationGateManifest(
            schemaVersion: schemaVersion,
            sequence: sequence,
            nonce: nonce,
            action: decodedAction,
            createdAtUnixMillis: createdAtUnixMillis,
            expiresAtUnixMillis: expiresAtUnixMillis,
            expectedPairing: .init(
                instanceID: expectedPairing.instanceID,
                fingerprintSHA256Hex: expectedPairing.fingerprintSHA256Hex,
                pairedAtNotBeforeUnixMillis: expectedPairing.pairedAtNotBeforeUnixMillis
            ),
            expectedBuild: .init(
                sourceCommit: expectedBuild.sourceCommit,
                splSwiftRevision: expectedBuild.splSwiftRevision
            ),
            expectedContentLength: expectedContentLength,
            expectedSHA256Hex: expectedSHA256Hex,
            rangeStart: rangeStart,
            rangeLength: rangeLength
        )
    }

    static func validateDigest(_ value: String) throws {
        guard value.count == 64 else {
            throw IntegrationGateValidationError(.invalidDigest)
        }
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw IntegrationGateValidationError(.invalidDigest)
        }
    }

    static func validateNonempty(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntegrationGateValidationError(.missingField)
        }
    }

    static func rejectUnknownFields(decoder: Decoder, allowed: [String]) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowedSet = Set(allowed)
        for key in container.allKeys where !allowedSet.contains(key.stringValue) {
            throw IntegrationGateValidationError(.unknownField)
        }
    }
}

private struct StrictExpectedPairing: Decodable {
    var instanceID: String
    var fingerprintSHA256Hex: String
    var pairedAtNotBeforeUnixMillis: Int64

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case instanceID
        case fingerprintSHA256Hex
        case pairedAtNotBeforeUnixMillis
    }

    init(from decoder: Decoder) throws {
        try StrictPayload.rejectUnknownFields(decoder: decoder, allowed: CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            instanceID = try container.decode(String.self, forKey: .instanceID)
            fingerprintSHA256Hex = try container.decode(String.self, forKey: .fingerprintSHA256Hex)
            pairedAtNotBeforeUnixMillis = try container.decode(Int64.self, forKey: .pairedAtNotBeforeUnixMillis)
        } catch {
            throw IntegrationGateValidationError(.missingField)
        }
    }
}

private struct StrictExpectedBuild: Decodable {
    var sourceCommit: String
    var splSwiftRevision: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case sourceCommit
        case splSwiftRevision
    }

    init(from decoder: Decoder) throws {
        try StrictPayload.rejectUnknownFields(decoder: decoder, allowed: CodingKeys.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            sourceCommit = try container.decode(String.self, forKey: .sourceCommit)
            splSwiftRevision = try container.decode(String.self, forKey: .splSwiftRevision)
        } catch {
            throw IntegrationGateValidationError(.missingField)
        }
    }
}

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
#endif

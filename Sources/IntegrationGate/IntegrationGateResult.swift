// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

#if DEBUG && targetEnvironment(simulator)
private let log = Logger(subsystem: "app.solstone.swift", category: "integration-gate-result")

enum IntegrationGateVerdict: String, Codable, Sendable, Equatable {
    case pass
    case fail
    case error
}

enum IntegrationGateRecordState: String, Codable, Sendable, Equatable {
    case running
    case terminal
}

enum IntegrationGateReasonCode: String, Codable, Sendable, Equatable, CaseIterable {
    case none
    case manifestMissing
    case manifestUnreadable
    case manifestMalformed
    case manifestTooLarge
    case symlinkRejected
    case nonRegularFile
    case unknownField
    case schemaMismatch
    case missingField
    case invalidSequence
    case repeatedNonce
    case staleSequence
    case expiredManifest
    case unknownAction
    case malformedRouteInput
    case invalidDigest
    case invalidRange
    case invalidCeiling
    case buildMismatch
    case zeroPairing
    case changedPairing
    case stalePairing
    case foreignPairing
    case absentRelayEnrollment
    case wrongRelayEndpoint
    case runtimeLanRepopulation
    case selectedLanEndpoint
    case fileWriteFailed
    case runningRecordWriteFailed
    case noActiveConnection
    case noActiveGeneration
    case canaryFailed
    case canaryMissing
    case canaryGenerationMismatch
    case canarySkewExceeded
    case missingPositiveTransition
    case accountingLeak
    case requestFailed
    case requestTimedOut
    case httpStatusMismatch
    case rangeStatusMismatch
    case contentRangeMalformed
    case contentRangeMismatch
    case contentLengthMismatch
    case rangeTooSmall
    case byteCountMismatch
    case digestMismatch
    case earlyFault
    case completedFirstAttempt
    case hungInterruption
    case sameGenerationRetry
    case overlappingRetry
    case releaseProofMissing
    case oldGenerationNotClosed
    case recoveryFailed
    case missingHealthyTransition
    case missingDegradedTransition
    case missingRecoveredTransition
    case terminalDegradedMissing
    case unknownConnectionSyncStatus
}

struct IntegrationGateValidationError: Error, Sendable, Equatable {
    let reasonCode: IntegrationGateReasonCode

    init(_ reasonCode: IntegrationGateReasonCode) {
        self.reasonCode = reasonCode
    }
}

struct IntegrationGateBuildMetadata: Codable, Sendable, Equatable {
    var sourceCommit: String
    var buildConfiguration: String
    var splSwiftIdentity: String
    var splSwiftVersion: String
    var splSwiftRevision: String

    static var current: IntegrationGateBuildMetadata {
        IntegrationGateBuildMetadata(
            sourceCommit: AppVersion.sourceCommit,
            buildConfiguration: AppVersion.buildConfiguration,
            splSwiftIdentity: AppVersion.splSwiftIdentity,
            splSwiftVersion: AppVersion.splSwiftVersion,
            splSwiftRevision: AppVersion.splSwiftRevision
        )
    }
}

struct IntegrationGateResult: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case sequence
        case nonce
        case correlationID
        case recordState
        case verdict
        case reasonCode
        case startedAtUnixMillis
        case updatedAtUnixMillis
        case finishedAtUnixMillis
        case durationMillis
        case buildMetadata
        case pairingSnapshot
        case routeLabel
        case generation
        case httpOutcome
        case accounting
        case samples
        case transportStages
        case reconnectReasonBuckets
    }

    var schemaVersion: Int
    var sequence: UInt64?
    var nonce: String?
    var correlationID: String
    var recordState: IntegrationGateRecordState
    var verdict: IntegrationGateVerdict?
    var reasonCode: IntegrationGateReasonCode
    var startedAtUnixMillis: Int64
    var updatedAtUnixMillis: Int64
    var finishedAtUnixMillis: Int64?
    var durationMillis: UInt64?
    var buildMetadata: IntegrationGateBuildMetadata
    var pairingSnapshot: IntegrationGateResultPairingSnapshot?
    var routeLabel: IntegrationGateRouteLabel?
    var generation: IntegrationGateResultGeneration?
    var httpOutcome: IntegrationGateHTTPOutcome?
    var accounting: IntegrationGateAccounting
    var samples: [IntegrationGateSample]
    var transportStages: [String]
    var reconnectReasonBuckets: [String]

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(nonce, forKey: .nonce)
        try container.encode(correlationID, forKey: .correlationID)
        try container.encode(recordState, forKey: .recordState)
        try container.encode(verdict, forKey: .verdict)
        try container.encode(reasonCode, forKey: .reasonCode)
        try container.encode(startedAtUnixMillis, forKey: .startedAtUnixMillis)
        try container.encode(updatedAtUnixMillis, forKey: .updatedAtUnixMillis)
        try container.encode(finishedAtUnixMillis, forKey: .finishedAtUnixMillis)
        try container.encode(durationMillis, forKey: .durationMillis)
        try container.encode(buildMetadata, forKey: .buildMetadata)
        try container.encode(pairingSnapshot, forKey: .pairingSnapshot)
        try container.encode(routeLabel, forKey: .routeLabel)
        try container.encode(generation, forKey: .generation)
        try container.encode(httpOutcome, forKey: .httpOutcome)
        try container.encode(accounting, forKey: .accounting)
        try container.encode(samples, forKey: .samples)
        try container.encode(transportStages, forKey: .transportStages)
        try container.encode(reconnectReasonBuckets, forKey: .reconnectReasonBuckets)
    }

    static func terminalError(
        sequence: UInt64?,
        nonce: String?,
        correlationID: String,
        reasonCode: IntegrationGateReasonCode,
        startedAtUnixMillis: Int64,
        updatedAtUnixMillis: Int64
    ) -> IntegrationGateResult {
        IntegrationGateResult(
            schemaVersion: IntegrationGateConstants.schemaVersion,
            sequence: sequence,
            nonce: nonce,
            correlationID: correlationID,
            recordState: .terminal,
            verdict: .error,
            reasonCode: reasonCode,
            startedAtUnixMillis: startedAtUnixMillis,
            updatedAtUnixMillis: updatedAtUnixMillis,
            finishedAtUnixMillis: updatedAtUnixMillis,
            durationMillis: UInt64(max(0, updatedAtUnixMillis - startedAtUnixMillis)),
            buildMetadata: .current,
            pairingSnapshot: nil,
            routeLabel: nil,
            generation: nil,
            httpOutcome: nil,
            accounting: .zero,
            samples: [],
            transportStages: [],
            reconnectReasonBuckets: []
        )
    }
}

struct IntegrationGateResultPairingSnapshot: Codable, Sendable, Equatable {
    var instanceID: String
    var fingerprintSHA256Hex: String
    var pairedAtUnixMillis: Int64
    var relayEnrollmentPresent: Bool
    var relayEndpoint: String
}

struct IntegrationGateResultGeneration: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case currentGeneration
        case activeGeneration
        case lastClosedGeneration
    }

    var currentGeneration: UInt64
    var activeGeneration: UInt64?
    var lastClosedGeneration: UInt64?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentGeneration, forKey: .currentGeneration)
        try container.encode(activeGeneration, forKey: .activeGeneration)
        try container.encode(lastClosedGeneration, forKey: .lastClosedGeneration)
    }
}

struct IntegrationGateHTTPOutcome: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case statusCode
        case errorBucket
        case byteCount
        case durationMillis
    }

    var statusCode: Int?
    var errorBucket: String?
    var byteCount: UInt64
    var durationMillis: UInt64

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(statusCode, forKey: .statusCode)
        try container.encode(errorBucket, forKey: .errorBucket)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encode(durationMillis, forKey: .durationMillis)
    }
}

struct IntegrationGateAccounting: Codable, Sendable, Equatable {
    var activeGateIssuedRequestBaseline: Int
    var activeGateIssuedRequestFinal: Int
    var activeGateIssuedRequestReturnedToBaseline: Bool

    static let zero = IntegrationGateAccounting(
        activeGateIssuedRequestBaseline: 0,
        activeGateIssuedRequestFinal: 0,
        activeGateIssuedRequestReturnedToBaseline: true
    )
}

struct IntegrationGateSample: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case sampleIndex
        case wallClockUnixMillis
        case monotonicMillis
        case managerConnectionEpoch
        case transportGeneration
        case endpointKind
        case rawConnectionSyncStatus
        case publishedConnectionSyncStatus
        case httpStatusCode
        case httpErrorBucket
        case requestDurationMillis
        case reconnectCount
        case activeGateIssuedRequestCount
        case activeProductionUploadCount
        case transportStage
        case reconnectReasonBucket
        case canaryGeneration
        case canaryStatusCode
        case canarySkewMillis
    }

    var sampleIndex: UInt64
    var wallClockUnixMillis: Int64
    var monotonicMillis: UInt64
    var managerConnectionEpoch: UInt64
    var transportGeneration: UInt64?
    var endpointKind: String
    var rawConnectionSyncStatus: String
    var publishedConnectionSyncStatus: String
    var httpStatusCode: Int?
    var httpErrorBucket: String?
    var requestDurationMillis: UInt64?
    var reconnectCount: UInt64
    var activeGateIssuedRequestCount: Int
    var activeProductionUploadCount: Int
    var transportStage: String?
    var reconnectReasonBucket: String?
    var canaryGeneration: UInt64?
    var canaryStatusCode: Int?
    var canarySkewMillis: UInt64?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sampleIndex, forKey: .sampleIndex)
        try container.encode(wallClockUnixMillis, forKey: .wallClockUnixMillis)
        try container.encode(monotonicMillis, forKey: .monotonicMillis)
        try container.encode(managerConnectionEpoch, forKey: .managerConnectionEpoch)
        try container.encode(transportGeneration, forKey: .transportGeneration)
        try container.encode(endpointKind, forKey: .endpointKind)
        try container.encode(rawConnectionSyncStatus, forKey: .rawConnectionSyncStatus)
        try container.encode(publishedConnectionSyncStatus, forKey: .publishedConnectionSyncStatus)
        try container.encode(httpStatusCode, forKey: .httpStatusCode)
        try container.encode(httpErrorBucket, forKey: .httpErrorBucket)
        try container.encode(requestDurationMillis, forKey: .requestDurationMillis)
        try container.encode(reconnectCount, forKey: .reconnectCount)
        try container.encode(activeGateIssuedRequestCount, forKey: .activeGateIssuedRequestCount)
        try container.encode(activeProductionUploadCount, forKey: .activeProductionUploadCount)
        try container.encode(transportStage, forKey: .transportStage)
        try container.encode(reconnectReasonBucket, forKey: .reconnectReasonBucket)
        try container.encode(canaryGeneration, forKey: .canaryGeneration)
        try container.encode(canaryStatusCode, forKey: .canaryStatusCode)
        try container.encode(canarySkewMillis, forKey: .canarySkewMillis)
    }
}

struct IntegrationGatePriorResult: Decodable, Sendable, Equatable {
    var schemaVersion: Int
    var sequence: UInt64?
    var nonce: String?
    var recordState: IntegrationGateRecordState
    var verdict: IntegrationGateVerdict?
}
#endif

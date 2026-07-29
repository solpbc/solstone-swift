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
    case notInvoked
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
    case actionNotImplemented
    case fileWriteFailed
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
    var currentGeneration: UInt64
    var activeGeneration: UInt64?
    var lastClosedGeneration: UInt64?
}

struct IntegrationGateHTTPOutcome: Codable, Sendable, Equatable {
    var statusCode: Int?
    var errorBucket: String?
    var byteCount: UInt64
    var durationMillis: UInt64
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
}

struct IntegrationGatePriorResult: Decodable, Sendable, Equatable {
    var schemaVersion: Int
    var sequence: UInt64?
    var nonce: String?
    var recordState: IntegrationGateRecordState
    var verdict: IntegrationGateVerdict?
}
#endif

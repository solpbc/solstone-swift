// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum DiagnosticAvailability<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    case available(Value)
    case unavailable(reason: String)

    private enum CodingKeys: String, CodingKey {
        case state
        case value
        case reason
    }

    private enum State: String, Codable {
        case available
        case unavailable
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(State.self, forKey: .state)
        switch state {
        case .available:
            self = .available(try container.decode(Value.self, forKey: .value))
        case .unavailable:
            self = .unavailable(reason: try container.decode(String.self, forKey: .reason))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .available(value):
            try container.encode(State.available, forKey: .state)
            try container.encode(value, forKey: .value)
        case let .unavailable(reason):
            try container.encode(State.unavailable, forKey: .state)
            try container.encode(reason, forKey: .reason)
        }
    }

    var value: Value? {
        guard case let .available(value) = self else { return nil }
        return value
    }

    var unavailableReason: String? {
        guard case let .unavailable(reason) = self else { return nil }
        return reason
    }
}

nonisolated struct WatchRelayDiagnosticsEnvelopeResult: Equatable, Sendable {
    let payload: WatchRelayDiagnosticsPayload?
    let unavailableReason: String?
    let rawEnvelopeByteCount: Int?
    let unsupportedVersion: Int?

    static let absent = WatchRelayDiagnosticsEnvelopeResult(
        payload: nil,
        unavailableReason: WatchRelayDiagnosticsEnvelopeReason.absent,
        rawEnvelopeByteCount: nil,
        unsupportedVersion: nil
    )

    static func available(_ payload: WatchRelayDiagnosticsPayload, rawEnvelopeByteCount: Int?) -> Self {
        Self(
            payload: payload,
            unavailableReason: nil,
            rawEnvelopeByteCount: rawEnvelopeByteCount,
            unsupportedVersion: nil
        )
    }

    static func unavailable(_ reason: String, rawEnvelopeByteCount: Int?, unsupportedVersion: Int? = nil) -> Self {
        Self(
            payload: nil,
            unavailableReason: WatchRelayDiagnosticsEnvelopeReason.bounded(reason),
            rawEnvelopeByteCount: rawEnvelopeByteCount,
            unsupportedVersion: unsupportedVersion
        )
    }
}

nonisolated enum WatchRelayDiagnosticsEnvelopeReason {
    static let absent = "diagnostic envelope absent"
    static let unreadable = "diagnostic envelope unreadable"
    static let malformed = "diagnostic envelope malformed"
    static let unsupportedVersion = "diagnostic envelope unsupported version"
    static let publicationFailed = "diagnostic envelope publication failed"
    static let encodeFailed = "diagnostic envelope encode failed"
    static let historyUnavailable = "diagnostic history unavailable"
    static let notReportedByThisWatchBuild = "not reported by this watch build"

    static func bounded(_ reason: String) -> String {
        let collapsed = reason
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard collapsed.count > 200 else { return collapsed }
        return String(collapsed.prefix(200))
    }
}

nonisolated enum WatchRelayOriginalFileState: String, Codable, Equatable, Sendable {
    case missing
    case readableNonempty = "readable-nonempty"
    case zeroLength = "zero-length"
    case unreadable
}

nonisolated struct WatchRelayOriginalFileFact: Codable, Equatable, Sendable {
    let state: WatchRelayOriginalFileState
    let byteCount: Int64?
}

nonisolated struct WatchRelayOriginalFileStateCounts: Codable, Equatable, Sendable {
    let missing: Int
    let readableNonempty: Int
    let zeroLength: Int
    let unreadable: Int

    static let zero = WatchRelayOriginalFileStateCounts(
        missing: 0,
        readableNonempty: 0,
        zeroLength: 0,
        unreadable: 0
    )
}

nonisolated enum WatchRelayObservationCollectionResolution: String, Codable, Equatable, Sendable {
    case stable
    case snapshotChangedDuringCollection = "snapshot changed during collection"
}

nonisolated struct WatchRelayDiagnosticsEnvelope: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maxEncodedByteCount = 32 * 1024

    let version: Int
    let generatedAt: Date
    let diagnostics: DiagnosticAvailability<WatchRelayDiagnosticsPayload>

    init(
        version: Int = Self.currentVersion,
        generatedAt: Date,
        diagnostics: DiagnosticAvailability<WatchRelayDiagnosticsPayload>
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.diagnostics = diagnostics
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func unavailableData(generatedAt: Date, reason: String) -> Data? {
        try? Self.makeEncoder().encode(WatchRelayDiagnosticsEnvelope(
            generatedAt: generatedAt,
            diagnostics: .unavailable(reason: reason)
        ))
    }

    static func decodeResult(from data: Data?) -> WatchRelayDiagnosticsEnvelopeResult {
        guard let data else { return .absent }

        let rawByteCount = data.count
        let decoder = Self.makeDecoder()

        guard let versionProbe = try? decoder.decode(WatchRelayDiagnosticsEnvelopeVersionProbe.self, from: data) else {
            return .unavailable(
                WatchRelayDiagnosticsEnvelopeReason.malformed,
                rawEnvelopeByteCount: rawByteCount
            )
        }
        guard versionProbe.version <= Self.currentVersion else {
            return .unavailable(
                WatchRelayDiagnosticsEnvelopeReason.unsupportedVersion,
                rawEnvelopeByteCount: rawByteCount,
                unsupportedVersion: versionProbe.version
            )
        }
        guard let envelope = try? decoder.decode(Self.self, from: data) else {
            return .unavailable(
                WatchRelayDiagnosticsEnvelopeReason.malformed,
                rawEnvelopeByteCount: rawByteCount
            )
        }

        switch envelope.diagnostics {
        case let .available(payload):
            return .available(payload, rawEnvelopeByteCount: rawByteCount)
        case let .unavailable(reason):
            return .unavailable(reason, rawEnvelopeByteCount: rawByteCount)
        }
    }
}

private nonisolated struct WatchRelayDiagnosticsEnvelopeVersionProbe: Decodable {
    let version: Int
}

nonisolated struct WatchRelayDiagnosticsPayload: Codable, Equatable, Sendable {
    let watchAppMarketingVersion: DiagnosticAvailability<String>
    let watchAppBuild: DiagnosticAvailability<String>
    let watchOSVersion: DiagnosticAvailability<String>
    let activationState: String
    let isCompanionAppInstalled: DiagnosticAvailability<Bool>
    let isReachable: Bool
    let iOSDeviceNeedsUnlockAfterRebootForReachability: DiagnosticAvailability<Bool>
    let hasContentPending: Bool
    let watchBatteryLevel: DiagnosticAvailability<Double>
    let watchBatteryState: DiagnosticAvailability<String>
    let watchLowPowerModeEnabled: DiagnosticAvailability<Bool>
    let watchThermalState: DiagnosticAvailability<String>
    let manifestSummary: DiagnosticAvailability<WatchRelayManifestSummary>
    let appleQueue: DiagnosticAvailability<WatchRelayAppleQueueSnapshot>
    let lastFacts: DiagnosticAvailability<WatchRelayLastFactsSummary>
    let observedFileTransfers: [WatchRelayTransferObservation]
    let omittedObservationCount: Int
}

nonisolated struct WatchRelayManifestSummary: Codable, Equatable, Sendable {
    let counts: WatchRelayManifestCounts
    let activeBacklogCount: Int
    let retainedSourceBytes: DiagnosticAvailability<Int64>
    let oldestActiveEnqueuedAt: DiagnosticAvailability<Date?>
    let oldestActiveEnqueueAgeSeconds: DiagnosticAvailability<TimeInterval?>

    let originalAudioFileCounts: DiagnosticAvailability<WatchRelayOriginalFileStateCounts>
    let originalLocationFileCounts: DiagnosticAvailability<WatchRelayOriginalFileStateCounts>
    let originalPayloadReadableBytes: DiagnosticAvailability<Int64>
    let retainedRelayBundleBytes: DiagnosticAvailability<Int64>

    init(
        counts: WatchRelayManifestCounts,
        activeBacklogCount: Int,
        retainedSourceBytes: DiagnosticAvailability<Int64>,
        oldestActiveEnqueuedAt: DiagnosticAvailability<Date?>,
        oldestActiveEnqueueAgeSeconds: DiagnosticAvailability<TimeInterval?>,
        originalAudioFileCounts: DiagnosticAvailability<WatchRelayOriginalFileStateCounts> = .unavailable(
            reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild
        ),
        originalLocationFileCounts: DiagnosticAvailability<WatchRelayOriginalFileStateCounts> = .unavailable(
            reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild
        ),
        originalPayloadReadableBytes: DiagnosticAvailability<Int64> = .unavailable(
            reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild
        ),
        retainedRelayBundleBytes: DiagnosticAvailability<Int64> = .unavailable(
            reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild
        )
    ) {
        self.counts = counts
        self.activeBacklogCount = activeBacklogCount
        self.retainedSourceBytes = retainedSourceBytes
        self.oldestActiveEnqueuedAt = oldestActiveEnqueuedAt
        self.oldestActiveEnqueueAgeSeconds = oldestActiveEnqueueAgeSeconds
        self.originalAudioFileCounts = originalAudioFileCounts
        self.originalLocationFileCounts = originalLocationFileCounts
        self.originalPayloadReadableBytes = originalPayloadReadableBytes
        self.retainedRelayBundleBytes = retainedRelayBundleBytes
    }

    private enum CodingKeys: String, CodingKey {
        case counts
        case activeBacklogCount
        case retainedSourceBytes
        case oldestActiveEnqueuedAt
        case oldestActiveEnqueueAgeSeconds
        case originalAudioFileCounts
        case originalLocationFileCounts
        case originalPayloadReadableBytes
        case retainedRelayBundleBytes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.counts = try container.decode(WatchRelayManifestCounts.self, forKey: .counts)
        self.activeBacklogCount = try container.decode(Int.self, forKey: .activeBacklogCount)
        self.retainedSourceBytes = try container.decode(DiagnosticAvailability<Int64>.self, forKey: .retainedSourceBytes)
        self.oldestActiveEnqueuedAt = try container.decode(
            DiagnosticAvailability<Date?>.self,
            forKey: .oldestActiveEnqueuedAt
        )
        self.oldestActiveEnqueueAgeSeconds = try container.decode(
            DiagnosticAvailability<TimeInterval?>.self,
            forKey: .oldestActiveEnqueueAgeSeconds
        )
        self.originalAudioFileCounts = try container.decodeIfPresent(
            DiagnosticAvailability<WatchRelayOriginalFileStateCounts>.self,
            forKey: .originalAudioFileCounts
        ) ?? .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
        self.originalLocationFileCounts = try container.decodeIfPresent(
            DiagnosticAvailability<WatchRelayOriginalFileStateCounts>.self,
            forKey: .originalLocationFileCounts
        ) ?? .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
        self.originalPayloadReadableBytes = try container.decodeIfPresent(
            DiagnosticAvailability<Int64>.self,
            forKey: .originalPayloadReadableBytes
        ) ?? .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
        self.retainedRelayBundleBytes = try container.decodeIfPresent(
            DiagnosticAvailability<Int64>.self,
            forKey: .retainedRelayBundleBytes
        ) ?? .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.counts, forKey: .counts)
        try container.encode(self.activeBacklogCount, forKey: .activeBacklogCount)
        try container.encode(self.retainedSourceBytes, forKey: .retainedSourceBytes)
        try container.encode(self.oldestActiveEnqueuedAt, forKey: .oldestActiveEnqueuedAt)
        try container.encode(self.oldestActiveEnqueueAgeSeconds, forKey: .oldestActiveEnqueueAgeSeconds)
        try container.encode(self.originalAudioFileCounts, forKey: .originalAudioFileCounts)
        try container.encode(self.originalLocationFileCounts, forKey: .originalLocationFileCounts)
        try container.encode(self.originalPayloadReadableBytes, forKey: .originalPayloadReadableBytes)
        try container.encode(self.retainedRelayBundleBytes, forKey: .retainedRelayBundleBytes)
    }
}

nonisolated struct WatchRelayManifestCounts: Codable, Equatable, Sendable {
    let captured: Int
    let persisted: Int
    let finalized: Int
    let queued: Int
    let transferring: Int
    let delivered: Int
    let acked: Int
    let safeToDelete: Int

    static let zero = WatchRelayManifestCounts(
        captured: 0,
        persisted: 0,
        finalized: 0,
        queued: 0,
        transferring: 0,
        delivered: 0,
        acked: 0,
        safeToDelete: 0
    )
}

nonisolated struct WatchRelayAppleQueueSnapshot: Codable, Equatable, Sendable {
    let asOf: Date
    let outstandingFileTransferCount: Int
    let outstandingUserInfoTransferCountWatchToPhone: Int
    let reconciliation: WatchRelayReconciliationCounts
    let exactObservationCountBeforeCompaction: Int
}

nonisolated struct WatchRelayReconciliationCounts: Codable, Equatable, Sendable {
    let matched: Int
    let appActiveNotObserved: Int
    let duplicate: Int
    let orphaned: Int
    let unparseable: Int

    static let zero = WatchRelayReconciliationCounts(
        matched: 0,
        appActiveNotObserved: 0,
        duplicate: 0,
        orphaned: 0,
        unparseable: 0
    )
}

nonisolated struct WatchRelayTransferObservation: Codable, Equatable, Sendable {
    let asOf: Date
    let segmentID: UUID?
    let idState: WatchRelayTransferIDState
    let relation: WatchRelayObservationRelation
    let appManifestState: String?
    let appOwnedEnqueueAgeSeconds: DiagnosticAvailability<TimeInterval?>
    let appOwnedSourceBytes: DiagnosticAvailability<Int64>
    let sourcePresent: DiagnosticAvailability<Bool>
    let isTransferring: DiagnosticAvailability<Bool>
    let progress: DiagnosticAvailability<WatchConnectivityProgressSnapshot>

    let originalAudioFile: DiagnosticAvailability<WatchRelayOriginalFileFact>
    let originalLocationFile: DiagnosticAvailability<WatchRelayOriginalFileFact>
    let relayBundlePresent: DiagnosticAvailability<Bool>
    let relayBundleBytes: DiagnosticAvailability<Int64>
    let collectionResolution: DiagnosticAvailability<WatchRelayObservationCollectionResolution>

    init(
        asOf: Date,
        segmentID: UUID?,
        idState: WatchRelayTransferIDState,
        relation: WatchRelayObservationRelation,
        appManifestState: String?,
        appOwnedEnqueueAgeSeconds: DiagnosticAvailability<TimeInterval?>,
        appOwnedSourceBytes: DiagnosticAvailability<Int64>,
        sourcePresent: DiagnosticAvailability<Bool>,
        isTransferring: DiagnosticAvailability<Bool>,
        progress: DiagnosticAvailability<WatchConnectivityProgressSnapshot>,
        originalAudioFile: DiagnosticAvailability<WatchRelayOriginalFileFact> = .unavailable(
            reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild
        ),
        originalLocationFile: DiagnosticAvailability<WatchRelayOriginalFileFact> = .unavailable(
            reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild
        ),
        relayBundlePresent: DiagnosticAvailability<Bool> = .unavailable(
            reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild
        ),
        relayBundleBytes: DiagnosticAvailability<Int64> = .unavailable(
            reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild
        ),
        collectionResolution: DiagnosticAvailability<WatchRelayObservationCollectionResolution> = .unavailable(
            reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild
        )
    ) {
        self.asOf = asOf
        self.segmentID = segmentID
        self.idState = idState
        self.relation = relation
        self.appManifestState = appManifestState
        self.appOwnedEnqueueAgeSeconds = appOwnedEnqueueAgeSeconds
        self.appOwnedSourceBytes = appOwnedSourceBytes
        self.sourcePresent = sourcePresent
        self.isTransferring = isTransferring
        self.progress = progress
        self.originalAudioFile = originalAudioFile
        self.originalLocationFile = originalLocationFile
        self.relayBundlePresent = relayBundlePresent
        self.relayBundleBytes = relayBundleBytes
        self.collectionResolution = collectionResolution
    }

    private enum CodingKeys: String, CodingKey {
        case asOf
        case segmentID
        case idState
        case relation
        case appManifestState
        case appOwnedEnqueueAgeSeconds
        case appOwnedSourceBytes
        case sourcePresent
        case isTransferring
        case progress
        case originalAudioFile
        case originalLocationFile
        case relayBundlePresent
        case relayBundleBytes
        case collectionResolution
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.asOf = try container.decode(Date.self, forKey: .asOf)
        self.segmentID = try container.decodeIfPresent(UUID.self, forKey: .segmentID)
        self.idState = try container.decode(WatchRelayTransferIDState.self, forKey: .idState)
        self.relation = try container.decode(WatchRelayObservationRelation.self, forKey: .relation)
        self.appManifestState = try container.decodeIfPresent(String.self, forKey: .appManifestState)
        self.appOwnedEnqueueAgeSeconds = try container.decode(
            DiagnosticAvailability<TimeInterval?>.self,
            forKey: .appOwnedEnqueueAgeSeconds
        )
        self.appOwnedSourceBytes = try container.decode(DiagnosticAvailability<Int64>.self, forKey: .appOwnedSourceBytes)
        self.sourcePresent = try container.decode(DiagnosticAvailability<Bool>.self, forKey: .sourcePresent)
        self.isTransferring = try container.decode(DiagnosticAvailability<Bool>.self, forKey: .isTransferring)
        self.progress = try container.decode(
            DiagnosticAvailability<WatchConnectivityProgressSnapshot>.self,
            forKey: .progress
        )
        self.originalAudioFile = try container.decodeIfPresent(
            DiagnosticAvailability<WatchRelayOriginalFileFact>.self,
            forKey: .originalAudioFile
        ) ?? .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
        self.originalLocationFile = try container.decodeIfPresent(
            DiagnosticAvailability<WatchRelayOriginalFileFact>.self,
            forKey: .originalLocationFile
        ) ?? .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
        self.relayBundlePresent = try container.decodeIfPresent(
            DiagnosticAvailability<Bool>.self,
            forKey: .relayBundlePresent
        ) ?? .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
        self.relayBundleBytes = try container.decodeIfPresent(
            DiagnosticAvailability<Int64>.self,
            forKey: .relayBundleBytes
        ) ?? .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
        self.collectionResolution = try container.decodeIfPresent(
            DiagnosticAvailability<WatchRelayObservationCollectionResolution>.self,
            forKey: .collectionResolution
        ) ?? .unavailable(reason: WatchRelayDiagnosticsEnvelopeReason.notReportedByThisWatchBuild)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.asOf, forKey: .asOf)
        try container.encodeIfPresent(self.segmentID, forKey: .segmentID)
        try container.encode(self.idState, forKey: .idState)
        try container.encode(self.relation, forKey: .relation)
        try container.encodeIfPresent(self.appManifestState, forKey: .appManifestState)
        try container.encode(self.appOwnedEnqueueAgeSeconds, forKey: .appOwnedEnqueueAgeSeconds)
        try container.encode(self.appOwnedSourceBytes, forKey: .appOwnedSourceBytes)
        try container.encode(self.sourcePresent, forKey: .sourcePresent)
        try container.encode(self.isTransferring, forKey: .isTransferring)
        try container.encode(self.progress, forKey: .progress)
        try container.encode(self.originalAudioFile, forKey: .originalAudioFile)
        try container.encode(self.originalLocationFile, forKey: .originalLocationFile)
        try container.encode(self.relayBundlePresent, forKey: .relayBundlePresent)
        try container.encode(self.relayBundleBytes, forKey: .relayBundleBytes)
        try container.encode(self.collectionResolution, forKey: .collectionResolution)
    }
}

nonisolated enum WatchRelayTransferIDState: String, Codable, Equatable, Sendable {
    case parseable
    case missing
    case unparseable
}

nonisolated enum WatchRelayObservationRelation: String, Codable, Equatable, Sendable {
    case matched
    case appActiveNotObserved
    case duplicate
    case orphaned
    case unparseable
}

nonisolated struct WatchRelaySegmentLastFacts: Codable, Equatable, Sendable {
    var lastEnqueue: WatchRelayFactCounter?
    var lastTransferCompletion: WatchRelayTransferCompletionFact?
    var lastStructuredFailure: WatchTransferStructuredFailure?
    var lastDurableACK: WatchRelayFactCounter?
    var lastQueueReconciliationObservation: WatchRelayQueueReconciliationFact?

    static let empty = WatchRelaySegmentLastFacts(
        lastEnqueue: nil,
        lastTransferCompletion: nil,
        lastStructuredFailure: nil,
        lastDurableACK: nil,
        lastQueueReconciliationObservation: nil
    )
}

nonisolated struct WatchRelayLastFactsSummary: Codable, Equatable, Sendable {
    let lastEnqueue: WatchRelayFactCounter?
    let lastTransferCompletion: WatchRelayTransferCompletionFact?
    let lastStructuredFailure: WatchTransferStructuredFailure?
    let lastDurableACK: WatchRelayFactCounter?
    let lastQueueReconciliationObservation: WatchRelayQueueReconciliationFact?
    let lastBackgroundWakeCompletion: WatchRelayBackgroundWakeFact?
    let lastBackgroundWakeDeadline: WatchRelayBackgroundWakeFact?
}

nonisolated struct WatchRelayFactCounter: Codable, Equatable, Sendable {
    let at: Date
    let count: Int
    let segmentID: UUID?
}

nonisolated struct WatchRelayTransferCompletionFact: Codable, Equatable, Sendable {
    let at: Date
    let segmentID: UUID
    let succeeded: Bool
    let successCount: Int
    let failureCount: Int
}

nonisolated struct WatchRelayQueueReconciliationFact: Codable, Equatable, Sendable {
    let at: Date
    let counts: WatchRelayReconciliationCounts
    let observedFileTransferCount: Int
    let activeManifestCount: Int
}

nonisolated struct WatchRelayBackgroundWakeFact: Codable, Equatable, Sendable {
    let at: Date
    let reason: String
    let heldTaskCount: Int
    let completedTaskCount: Int
    let deadlineCount: Int
}

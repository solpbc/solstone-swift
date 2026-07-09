// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum TransferManifestSchema {
    static let current = "solstone.transfer.item/1"
}

nonisolated struct TransferManifest: Codable, Equatable, Sendable {
    var schemaVersion: String
    var itemID: UUID
    var source: String
    var createdAt: Date
    var priority: TransferPriorityInputs
    var payloadParts: [TransferPayloadPartDescriptor]
    var endpoint: TransferEndpointDescriptor
    var observerIngest: TransferObserverIngestMetadata?
    var meta: JSONValue
    var diskState: TransferDiskState
    var nextAttemptAt: Date?
    var saveThenStart: TransferSaveThenStartState?
    var attention: TransferAttentionInfo?
    var appVersion: String?

    init(
        schemaVersion: String = TransferManifestSchema.current,
        itemID: UUID,
        source: String,
        createdAt: Date,
        priority: TransferPriorityInputs,
        payloadParts: [TransferPayloadPartDescriptor],
        endpoint: TransferEndpointDescriptor,
        observerIngest: TransferObserverIngestMetadata? = nil,
        meta: JSONValue = .object([:]),
        diskState: TransferDiskState = .queued,
        nextAttemptAt: Date? = nil,
        saveThenStart: TransferSaveThenStartState? = nil,
        attention: TransferAttentionInfo? = nil,
        appVersion: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.itemID = itemID
        self.source = source
        self.createdAt = createdAt
        self.priority = priority
        self.payloadParts = payloadParts
        self.endpoint = endpoint
        self.observerIngest = observerIngest
        self.meta = meta
        self.diskState = diskState
        self.nextAttemptAt = nextAttemptAt
        self.saveThenStart = saveThenStart
        self.attention = attention
        self.appVersion = appVersion
    }

    /// Grouping key for per-source Transfer status. Producers set
    /// `priority.sourceKey` equal to `source`; an empty priority source key
    /// falls back to `source`.
    var sourceKey: String {
        self.priority.sourceKey.isEmpty ? self.source : self.priority.sourceKey
    }

    func replacingDiskState(_ state: TransferDiskState) -> TransferManifest {
        var copy = self
        copy.diskState = state
        return copy
    }

    func replacingNextAttemptAt(_ date: Date?) -> TransferManifest {
        var copy = self
        copy.nextAttemptAt = date
        return copy
    }

    func validated(for state: TransferDiskState) throws -> TransferManifest {
        let manifest = try self.validatedForScan()
        guard manifest.diskState == state else {
            throw TransferManifestError.stateMismatch(expected: state, actual: manifest.diskState)
        }
        return manifest
    }

    func validatedForScan() throws -> TransferManifest {
        guard self.schemaVersion == TransferManifestSchema.current else {
            throw TransferManifestError.unsupportedSchema(self.schemaVersion)
        }
        guard !self.payloadParts.isEmpty else {
            throw TransferManifestError.emptyPayload
        }
        return self
    }
}

nonisolated struct TransferObserverIngestMetadata: Codable, Equatable, Sendable {
    var platform: String
    var segment: String
    var day: String
    var startedAt: Date
    var durationS: TimeInterval
    var sources: [String]
    var chunkIndex: Int?
    var sessionID: UUID?
    var modeRawValue: String?
    var segmentID: UUID?

    init(
        platform: String = "ios",
        segment: String,
        day: String,
        startedAt: Date,
        durationS: TimeInterval,
        sources: [String],
        chunkIndex: Int? = nil,
        sessionID: UUID? = nil,
        modeRawValue: String? = nil,
        segmentID: UUID? = nil
    ) {
        self.platform = platform
        self.segment = segment
        self.day = day
        self.startedAt = startedAt
        self.durationS = durationS
        self.sources = sources
        self.chunkIndex = chunkIndex
        self.sessionID = sessionID
        self.modeRawValue = modeRawValue
        self.segmentID = segmentID
    }
}

nonisolated enum TransferManifestError: Error, Equatable, Sendable {
    case unsupportedSchema(String)
    case stateMismatch(expected: TransferDiskState, actual: TransferDiskState)
    case emptyPayload
    case invalidRelativePath(String)
    case missingPayload(String)
}

nonisolated struct TransferPriorityInputs: Codable, Equatable, Sendable {
    var basePriority: TransferBasePriority
    /// Grouping key for per-source Transfer status. Producers set this equal to
    /// `TransferManifest.source`.
    var sourceKey: String
    var userInitiated: Bool

    init(
        basePriority: TransferBasePriority = .normal,
        sourceKey: String,
        userInitiated: Bool = false
    ) {
        self.basePriority = basePriority
        self.sourceKey = sourceKey
        self.userInitiated = userInitiated
    }
}

nonisolated enum TransferBasePriority: String, Codable, Equatable, Sendable, Comparable, CaseIterable {
    case high
    case normal
    case low

    private var rank: Int {
        switch self {
        case .high: 0
        case .normal: 1
        case .low: 2
        }
    }

    static func < (lhs: TransferBasePriority, rhs: TransferBasePriority) -> Bool {
        lhs.rank < rhs.rank
    }
}

nonisolated struct TransferPayloadPartDescriptor: Codable, Equatable, Sendable {
    var partID: String
    var kind: TransferPayloadKind
    var relativePath: String
    var filename: String
    var contentType: String
    var byteCount: Int?
    var contentHash: String?
    var requiredForDispatch: Bool

    init(
        partID: String,
        kind: TransferPayloadKind,
        relativePath: String,
        filename: String,
        contentType: String,
        byteCount: Int? = nil,
        contentHash: String? = nil,
        requiredForDispatch: Bool = true
    ) {
        self.partID = partID
        self.kind = kind
        self.relativePath = relativePath
        self.filename = filename
        self.contentType = contentType
        self.byteCount = byteCount
        self.contentHash = contentHash
        self.requiredForDispatch = requiredForDispatch
    }
}

nonisolated enum TransferPayloadKind: String, Codable, Equatable, Sendable {
    case audio
    case location
    case screen
    case file
    case text
}

nonisolated struct TransferEndpointDescriptor: Codable, Equatable, Sendable {
    var destinationKind: TransferDestinationKind
    var path: String
    var startPath: String?
    var destination: String?
    var requiresAuth: Bool

    init(
        destinationKind: TransferDestinationKind,
        path: String,
        startPath: String? = nil,
        destination: String? = nil,
        requiresAuth: Bool = true
    ) {
        self.destinationKind = destinationKind
        self.path = path
        self.startPath = startPath
        self.destination = destination
        self.requiresAuth = requiresAuth
    }
}

nonisolated enum TransferDestinationKind: String, Codable, Equatable, Sendable {
    case observerIngest = "observer_ingest"
    case saveThenStart = "save_then_start"
}

nonisolated enum TransferDiskState: String, Codable, Equatable, Sendable {
    case queued
    case attention
}

nonisolated struct TransferSaveThenStartState: Codable, Equatable, Sendable {
    var phase: TransferSaveThenStartPhase
    var savedPath: String?
    var savedTimestamp: String?
    var recommendedAction: String?
    var serverSource: String?
    var lastStartReasonCode: String?

    init(
        phase: TransferSaveThenStartPhase,
        savedPath: String? = nil,
        savedTimestamp: String? = nil,
        recommendedAction: String? = nil,
        serverSource: String? = nil,
        lastStartReasonCode: String? = nil
    ) {
        self.phase = phase
        self.savedPath = savedPath
        self.savedTimestamp = savedTimestamp
        self.recommendedAction = recommendedAction
        self.serverSource = serverSource
        self.lastStartReasonCode = lastStartReasonCode
    }
}

nonisolated enum TransferSaveThenStartPhase: String, Codable, Equatable, Sendable {
    case savePending = "save_pending"
    case startPending = "start_pending"
}

nonisolated enum TransferRecommendedAction: String, Codable, Equatable, Sendable {
    case start
    case doNotStart = "do_not_start"
}

nonisolated struct TransferAttentionInfo: Codable, Equatable, Sendable {
    var reason: String
    var shortDetail: String
    var movedAt: Date

    init(reason: String, shortDetail: String, movedAt: Date) {
        self.reason = reason
        self.shortDetail = shortDetail
        self.movedAt = movedAt
    }
}

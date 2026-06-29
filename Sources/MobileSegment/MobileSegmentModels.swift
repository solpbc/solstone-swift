// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum MobileSegmentSource: String, Codable, CaseIterable, Sendable {
    case audio
    case location
}

typealias MobileSegmentFacet = MobileSegmentSource

nonisolated enum MobileSegmentLifecycle: String, Sendable {
    case active
    case pending
    case failed
}

nonisolated enum MobileSegmentUploadState: String, Codable, Sendable, Equatable {
    case notReady = "not_ready"
    case pending
    case uploading
    case failed
    case delivered
    case empty
}

nonisolated enum MobileSegmentResolutionState: String, Codable, Sendable, Equatable {
    case notDeclared = "not_declared"
    case unresolved
    case finalizedArtifact = "finalized_artifact"
    case noArtifact = "no_artifact"
    case failedToFinalize = "failed_to_finalize"
    case removed = "removed"

    var isTerminal: Bool {
        switch self {
        case .notDeclared, .finalizedArtifact, .noArtifact, .failedToFinalize, .removed:
            true
        case .unresolved:
            false
        }
    }
}

nonisolated struct MobileSegmentSourceResolution: Codable, Sendable, Equatable {
    var state: MobileSegmentResolutionState
    var artifactFilename: String?
    var bytes: Int64?
    var startedAt: Date?
    var endedAt: Date?
    var durationS: TimeInterval?
    var reason: String?
    var stage: String?
    var lastAttemptAt: Date?
    var mode: ObserverMode?
    var fixCount: Int?

    enum CodingKeys: String, CodingKey {
        case state
        case artifactFilename = "artifact_filename"
        case bytes
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationS = "duration_s"
        case reason
        case stage
        case lastAttemptAt = "last_attempt_at"
        case mode
        case fixCount = "fix_count"
    }

    static let notDeclared = Self(state: .notDeclared)
    static let unresolved = Self(state: .unresolved)

    init(
        state: MobileSegmentResolutionState,
        artifactFilename: String? = nil,
        bytes: Int64? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        durationS: TimeInterval? = nil,
        reason: String? = nil,
        stage: String? = nil,
        lastAttemptAt: Date? = nil,
        mode: ObserverMode? = nil,
        fixCount: Int? = nil
    ) {
        self.state = state
        self.artifactFilename = artifactFilename
        self.bytes = bytes
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationS = durationS
        self.reason = reason
        self.stage = stage
        self.lastAttemptAt = lastAttemptAt
        self.mode = mode
        self.fixCount = fixCount
    }
}

nonisolated struct MobileSegmentManifest: Codable, Sendable, Equatable {
    static let schemaName = "app.solstone.mobile-segment/1"

    var schema: String
    var segmentID: UUID
    var day: String?
    var segment: String?
    var startedAt: Date
    var endedAt: Date?
    var durationS: TimeInterval?
    var openedWithSources: [MobileSegmentSource]
    var activeSourceSetVersion: Int
    var audio: MobileSegmentSourceResolution
    var location: MobileSegmentSourceResolution
    var upload: MobileSegmentUploadState
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case schema
        case segmentID = "segment_id"
        case day
        case segment
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationS = "duration_s"
        case openedWithSources = "opened_with_sources"
        case activeSourceSetVersion = "active_source_set_version"
        case audio
        case location
        case upload
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        segmentID: UUID,
        startedAt: Date,
        openedWithSources: Set<MobileSegmentSource>,
        activeSourceSetVersion: Int
    ) {
        self.schema = Self.schemaName
        self.segmentID = segmentID
        self.day = nil
        self.segment = nil
        self.startedAt = startedAt
        self.endedAt = nil
        self.durationS = nil
        self.openedWithSources = openedWithSources.sortedByStableName()
        self.activeSourceSetVersion = activeSourceSetVersion
        self.audio = openedWithSources.contains(.audio) ? .unresolved : .notDeclared
        self.location = openedWithSources.contains(.location) ? .unresolved : .notDeclared
        self.upload = .notReady
        self.createdAt = startedAt
        self.updatedAt = startedAt
    }

    func resolution(for source: MobileSegmentSource) -> MobileSegmentSourceResolution {
        switch source {
        case .audio:
            self.audio
        case .location:
            self.location
        }
    }

    mutating func setResolution(_ resolution: MobileSegmentSourceResolution, for source: MobileSegmentSource, now: Date) {
        switch source {
        case .audio:
            self.audio = resolution
        case .location:
            self.location = resolution
        }
        self.updatedAt = now
    }

    var declaredSources: [MobileSegmentSource] {
        self.openedWithSources
    }

    var isFullyResolved: Bool {
        self.declaredSources.allSatisfy { self.resolution(for: $0).state.isTerminal }
    }

    var hasArtifact: Bool {
        self.declaredSources.contains { self.resolution(for: $0).state == .finalizedArtifact }
    }

    var hasFinalizeFailure: Bool {
        self.declaredSources.contains { self.resolution(for: $0).state == .failedToFinalize }
    }

    var isEmptyResolved: Bool {
        self.isFullyResolved && !self.hasArtifact && !self.hasFinalizeFailure
    }
}

nonisolated struct MobileSegmentOutcomeRecord: Codable, Sendable, Equatable {
    let schema: String
    let segmentID: UUID
    let source: MobileSegmentSource
    let resolution: MobileSegmentSourceResolution
    let recordedAt: Date

    enum CodingKeys: String, CodingKey {
        case schema
        case segmentID = "segment_id"
        case source
        case resolution
        case recordedAt = "recorded_at"
    }
}

nonisolated struct MobileSegmentFailureSidecar: Codable, Sendable, Equatable {
    let reason: String
    let httpStatus: Int?
    let transportError: String?
    let attemptCount: Int
    let stage: String
    let lastAttemptAt: Date?

    enum CodingKeys: String, CodingKey {
        case reason
        case httpStatus = "http_status"
        case transportError = "transport_error"
        case attemptCount = "attempt_count"
        case stage
        case lastAttemptAt = "last_attempt_at"
    }
}

nonisolated struct MobileSegmentSourceSummary: Sendable, Equatable {
    let pendingCount: Int
    let failedCount: Int
    let lastUploadAt: Date?
    let lastError: String?
}

nonisolated struct MobileSegmentTombstone: Codable, Sendable, Equatable {
    let segmentID: UUID
    let reason: String
    let recordedAt: Date

    enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case reason
        case recordedAt = "recorded_at"
    }
}

private extension Set where Element == MobileSegmentSource {
    nonisolated func sortedByStableName() -> [MobileSegmentSource] {
        self.sorted { $0.rawValue < $1.rawValue }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import Foundation

nonisolated enum MobileSegmentScreencastPaths {
    static let mobileSegmentDirectoryName = "MobileSegment"
    static let screenFilename = "screen.mp4"
    static let screenPartFilename = "screen.mp4.part"
    static let screenLivenessFilename = "screen.live.json"
    static let screenDiagnosticFilename = "screen.failed.json"

    static func activeSegmentRelativeDirectory(segmentID: UUID) -> String {
        "\(Self.mobileSegmentDirectoryName)/active/\(segmentID.uuidString)"
    }

    static func screenRelativePath(segmentID: UUID) -> String {
        "\(Self.activeSegmentRelativeDirectory(segmentID: segmentID))/\(Self.screenFilename)"
    }

    static func screenPartRelativePath(segmentID: UUID) -> String {
        "\(Self.activeSegmentRelativeDirectory(segmentID: segmentID))/\(Self.screenPartFilename)"
    }

    static func screenLivenessRelativePath(segmentID: UUID) -> String {
        "\(Self.activeSegmentRelativeDirectory(segmentID: segmentID))/\(Self.screenLivenessFilename)"
    }

    static func screenDiagnosticRelativePath(segmentID: UUID) -> String {
        "\(Self.activeSegmentRelativeDirectory(segmentID: segmentID))/\(Self.screenDiagnosticFilename)"
    }

    static func handoffRelativePath() -> String {
        "\(Self.mobileSegmentDirectoryName)/screencast/handoff/current.json"
    }

    static func continuationLeaseRelativePath(fromSegmentID: UUID) -> String {
        "\(Self.mobileSegmentDirectoryName)/screencast/leases/\(fromSegmentID.uuidString).json"
    }

    static func runtimeRelativePath() -> String {
        "\(Self.mobileSegmentDirectoryName)/screencast/runtime/current.json"
    }

    static func runtimeDiagnosticRelativePath(sessionID: UUID) -> String {
        "\(Self.mobileSegmentDirectoryName)/screencast/runtime/diagnostics/\(sessionID.uuidString).failed.json"
    }

    static func url(root: URL, relativePath: String) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: false)
    }

    static func screenURL(inSegmentDirectory directory: URL) -> URL {
        directory.appendingPathComponent(Self.screenFilename, isDirectory: false)
    }

    static func screenPartURL(inSegmentDirectory directory: URL) -> URL {
        directory.appendingPathComponent(Self.screenPartFilename, isDirectory: false)
    }

    static func screenLivenessURL(inSegmentDirectory directory: URL) -> URL {
        directory.appendingPathComponent(Self.screenLivenessFilename, isDirectory: false)
    }

    static func screenDiagnosticURL(inSegmentDirectory directory: URL) -> URL {
        directory.appendingPathComponent(Self.screenDiagnosticFilename, isDirectory: false)
    }

    static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty else { throw MobileSegmentScreencastPathError.empty }
        guard !path.hasPrefix("/") else { throw MobileSegmentScreencastPathError.absolute(path) }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains(where: { $0.isEmpty }) else {
            throw MobileSegmentScreencastPathError.emptyComponent(path)
        }
        guard !components.contains("..") else { throw MobileSegmentScreencastPathError.parentTraversal(path) }
        guard components.first == Self.mobileSegmentDirectoryName else {
            throw MobileSegmentScreencastPathError.outsideMobileSegment(path)
        }
    }
}

nonisolated enum MobileSegmentScreencastNotifications {
    static let changed = "app.solstone.swift.screencast.changed"
}

nonisolated enum MobileSegmentScreencastPathError: Error, Equatable, Sendable {
    case empty
    case absolute(String)
    case emptyComponent(String)
    case parentTraversal(String)
    case outsideMobileSegment(String)
}

nonisolated enum MobileSegmentScreencastJSONStore {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func read<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        decoder: JSONDecoder = Self.decoder()
    ) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }

    static func write<T: Encodable>(
        _ value: T,
        to url: URL,
        fileManager: FileManager = .default,
        encoder: JSONEncoder = Self.encoder()
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tempURL = url
            .deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).tmp.\(UUID().uuidString)", isDirectory: false)
        do {
            try encoder.encode(value).write(to: tempURL)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    static func finalizePart(
        partURL: URL,
        finalURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: finalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: finalURL.path) {
            _ = try fileManager.replaceItemAt(finalURL, withItemAt: partURL)
        } else {
            try fileManager.moveItem(at: partURL, to: finalURL)
        }
    }
}

nonisolated struct MobileSegmentScreencastHandoffRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let revision: Int64
    let eventID: UUID
    let sessionID: UUID
    let segmentID: UUID
    let sourceSetVersion: Int
    let sourceSet: [MobileSegmentSource]
    let startedAt: Date
    let segmentDirectoryRelativePath: String
    let screenPartRelativePath: String
    let screenFinalRelativePath: String
    let desiredState: MobileSegmentScreencastDesiredState
    let rolloverAfter: Date
    let lastHostUpdateAt: Date

    init(
        schemaVersion: Int = 1,
        revision: Int64,
        eventID: UUID,
        sessionID: UUID,
        segmentID: UUID,
        sourceSetVersion: Int,
        sourceSet: [MobileSegmentSource],
        startedAt: Date,
        segmentDirectoryRelativePath: String,
        screenPartRelativePath: String,
        screenFinalRelativePath: String,
        desiredState: MobileSegmentScreencastDesiredState,
        rolloverAfter: Date,
        lastHostUpdateAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.eventID = eventID
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.sourceSetVersion = sourceSetVersion
        self.sourceSet = sourceSet
        self.startedAt = startedAt
        self.segmentDirectoryRelativePath = segmentDirectoryRelativePath
        self.screenPartRelativePath = screenPartRelativePath
        self.screenFinalRelativePath = screenFinalRelativePath
        self.desiredState = desiredState
        self.rolloverAfter = rolloverAfter
        self.lastHostUpdateAt = lastHostUpdateAt
    }
}

nonisolated enum MobileSegmentScreencastDesiredState: String, Codable, Sendable {
    case writing
    case stopping
    case closed
}

nonisolated struct MobileSegmentScreencastContinuationLease: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let leaseID: UUID
    let revision: Int64
    let fromSegmentID: UUID
    let segmentID: UUID
    let sourceSetVersion: Int
    let sourceSet: [MobileSegmentSource]
    let notBefore: Date
    let startsAt: Date
    let rolloverAfter: Date
    let expiresAt: Date
    let issuedAt: Date
    let segmentDirectoryRelativePath: String
    let screenPartRelativePath: String
    let screenFinalRelativePath: String

    init(
        schemaVersion: Int = 1,
        leaseID: UUID,
        revision: Int64,
        fromSegmentID: UUID,
        segmentID: UUID,
        sourceSetVersion: Int,
        sourceSet: [MobileSegmentSource],
        notBefore: Date,
        startsAt: Date,
        rolloverAfter: Date,
        expiresAt: Date,
        issuedAt: Date,
        segmentDirectoryRelativePath: String,
        screenPartRelativePath: String,
        screenFinalRelativePath: String
    ) {
        self.schemaVersion = schemaVersion
        self.leaseID = leaseID
        self.revision = revision
        self.fromSegmentID = fromSegmentID
        self.segmentID = segmentID
        self.sourceSetVersion = sourceSetVersion
        self.sourceSet = sourceSet
        self.notBefore = notBefore
        self.startsAt = startsAt
        self.rolloverAfter = rolloverAfter
        self.expiresAt = expiresAt
        self.issuedAt = issuedAt
        self.segmentDirectoryRelativePath = segmentDirectoryRelativePath
        self.screenPartRelativePath = screenPartRelativePath
        self.screenFinalRelativePath = screenFinalRelativePath
    }
}

nonisolated struct MobileSegmentScreencastRuntimeRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let revision: Int64
    let sessionID: UUID
    let state: MobileSegmentScreencastRuntimeState
    let startedAt: Date
    let lastSeenAt: Date
    let currentSegmentID: UUID?
    let currentHandoffRevision: Int64?
    let acceptedFrameCount: Int
    let droppedFrameCount: Int

    init(
        schemaVersion: Int = 1,
        revision: Int64,
        sessionID: UUID,
        state: MobileSegmentScreencastRuntimeState,
        startedAt: Date,
        lastSeenAt: Date,
        currentSegmentID: UUID?,
        currentHandoffRevision: Int64?,
        acceptedFrameCount: Int,
        droppedFrameCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.sessionID = sessionID
        self.state = state
        self.startedAt = startedAt
        self.lastSeenAt = lastSeenAt
        self.currentSegmentID = currentSegmentID
        self.currentHandoffRevision = currentHandoffRevision
        self.acceptedFrameCount = acceptedFrameCount
        self.droppedFrameCount = droppedFrameCount
    }
}

nonisolated enum MobileSegmentScreencastRuntimeState: String, Codable, Sendable {
    case broadcastStarted
    case writerOpen
    case finishing
    case finalized
    case failed
}

nonisolated struct MobileSegmentScreencastSegmentLiveness: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sessionID: UUID
    let segmentID: UUID
    let handoffRevision: Int64
    let lastSeenAt: Date
    let acceptedFrameCount: Int
    let droppedFrameCount: Int

    init(
        schemaVersion: Int = 1,
        sessionID: UUID,
        segmentID: UUID,
        handoffRevision: Int64,
        lastSeenAt: Date,
        acceptedFrameCount: Int,
        droppedFrameCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.handoffRevision = handoffRevision
        self.lastSeenAt = lastSeenAt
        self.acceptedFrameCount = acceptedFrameCount
        self.droppedFrameCount = droppedFrameCount
    }
}

nonisolated struct MobileSegmentScreencastDiagnostic: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sessionID: UUID
    let segmentID: UUID?
    let handoffRevision: Int64?
    let reason: MobileSegmentScreencastDiagnosticReason
    let message: String
    let startedAt: Date?
    let endedAt: Date
    let acceptedFrameCount: Int
    let droppedFrameCount: Int
    let createdAt: Date

    init(
        schemaVersion: Int = 1,
        sessionID: UUID,
        segmentID: UUID?,
        handoffRevision: Int64?,
        reason: MobileSegmentScreencastDiagnosticReason,
        message: String,
        startedAt: Date?,
        endedAt: Date,
        acceptedFrameCount: Int,
        droppedFrameCount: Int,
        createdAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.segmentID = segmentID
        self.handoffRevision = handoffRevision
        self.reason = reason
        self.message = message
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.acceptedFrameCount = acceptedFrameCount
        self.droppedFrameCount = droppedFrameCount
        self.createdAt = createdAt
    }
}

nonisolated enum MobileSegmentScreencastDiagnosticReason: String, Codable, Sendable, CaseIterable {
    case noVideo = "no_video"
    case finalizeTimeout = "finalize_timeout"
    case writerFailure = "writer_failure"
    case staleOrMissingPointer = "stale_or_missing_pointer"
    case filesystemHandoffFailure = "filesystem_handoff_failure"
    case appGroupUnavailable = "app_group_unavailable"
}

nonisolated enum MobileSegmentScreencastFramePolicy {
    static let minFrameIntervalSeconds: Double = 1.0
    static let maxInFlightFrames = 2

    static func acceptsVideoFrame(
        ptsSeconds: Double,
        lastAcceptedPTSSeconds: Double?
    ) -> Bool {
        guard ptsSeconds.isFinite else { return false }
        guard let lastAcceptedPTSSeconds else { return true }
        return ptsSeconds - lastAcceptedPTSSeconds >= Self.minFrameIntervalSeconds
    }

    static func shouldDropFrame(inFlightFrameCount: Int, maxInFlightFrames: Int = Self.maxInFlightFrames) -> Bool {
        inFlightFrameCount >= maxInFlightFrames
    }
}

nonisolated enum MobileSegmentScreencastSampleKind: Sendable, Equatable {
    case video
    case audioApp
    case audioMic
    case unknown
}

nonisolated enum MobileSegmentScreencastSamplePolicy {
    static func accepts(_ kind: MobileSegmentScreencastSampleKind) -> Bool {
        kind == .video
    }
}

nonisolated enum MobileSegmentScreencastWriterConfiguration {
    static let writesAudioTrack = false
    static let movieFragmentIntervalSeconds: TimeInterval = 1
}

nonisolated enum MobileSegmentScreencastLivenessPolicy {
    static let livenessRefreshIntervalSeconds: TimeInterval = 2
    static let livenessStaleWindowSeconds: TimeInterval = 10

    static func isFresh(lastSeenAt: Date, now: Date, staleWindow: TimeInterval = Self.livenessStaleWindowSeconds) -> Bool {
        now.timeIntervalSince(lastSeenAt) <= staleWindow
    }
}

nonisolated enum MobileSegmentScreencastSampleOrientation: UInt32, Codable, Sendable {
    case up = 1
    case upMirrored = 2
    case down = 3
    case downMirrored = 4
    case leftMirrored = 5
    case right = 6
    case rightMirrored = 7
    case left = 8

    var swapsAxes: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored:
            true
        case .up, .upMirrored, .down, .downMirrored:
            false
        }
    }
}

nonisolated struct MobileSegmentScreencastCanvasDimensions: Equatable, Sendable {
    let width: Int
    let height: Int
}

nonisolated struct MobileSegmentScreencastAspectFit: Equatable, Sendable {
    let scale: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat

    var transform: CGAffineTransform {
        CGAffineTransform(translationX: self.offsetX, y: self.offsetY)
            .scaledBy(x: self.scale, y: self.scale)
    }
}

nonisolated enum MobileSegmentScreencastGeometry {
    static func outputDimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        orientation: MobileSegmentScreencastSampleOrientation
    ) -> MobileSegmentScreencastCanvasDimensions {
        let displayedWidth = orientation.swapsAxes ? sourceHeight : sourceWidth
        let displayedHeight = orientation.swapsAxes ? sourceWidth : sourceHeight
        if displayedHeight > displayedWidth {
            return MobileSegmentScreencastCanvasDimensions(width: 720, height: 1280)
        }
        return MobileSegmentScreencastCanvasDimensions(width: 1280, height: 720)
    }

    static func aspectFit(
        sourceWidth: CGFloat,
        sourceHeight: CGFloat,
        canvasWidth: CGFloat,
        canvasHeight: CGFloat
    ) -> MobileSegmentScreencastAspectFit {
        let scale = min(canvasWidth / sourceWidth, canvasHeight / sourceHeight)
        let offsetX = (canvasWidth - sourceWidth * scale) / 2
        let offsetY = (canvasHeight - sourceHeight * scale) / 2
        return MobileSegmentScreencastAspectFit(scale: scale, offsetX: offsetX, offsetY: offsetY)
    }
}

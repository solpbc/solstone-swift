// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CoreGraphics
import CryptoKit
import Foundation

nonisolated enum MobileSegmentScreencastPaths {
    static let mobileSegmentDirectoryName = "MobileSegment"
    static let screenFilename = "screen.mp4"
    static let screenPartFilename = "screen.mp4.part"
    static let screenLivenessFilename = "screen.live.json"
    static let screenWindowFilename = "screen.window.json"
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

    static func screenWindowRelativePath(segmentID: UUID) -> String {
        "\(Self.activeSegmentRelativeDirectory(segmentID: segmentID))/\(Self.screenWindowFilename)"
    }

    static func screenDiagnosticRelativePath(segmentID: UUID) -> String {
        "\(Self.activeSegmentRelativeDirectory(segmentID: segmentID))/\(Self.screenDiagnosticFilename)"
    }

    static func handoffRelativePath() -> String {
        "\(Self.mobileSegmentDirectoryName)/screencast/handoff/current.json"
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

    static func screenWindowURL(inSegmentDirectory directory: URL) -> URL {
        directory.appendingPathComponent(Self.screenWindowFilename, isDirectory: false)
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

nonisolated enum MobileSegmentScreencastIdentity {
    static func segmentID(
        sessionID: UUID,
        scheduleAnchorMs: Int64,
        windowIndex: Int,
        schedulePeriodSeconds: Int = 300
    ) -> UUID {
        let name = "screencast-window:\(sessionID.uuidString.lowercased()):\(scheduleAnchorMs):\(windowIndex):\(schedulePeriodSeconds)"
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // RFC 4122 version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func nowMs(from date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    static func windowIndex(
        nowMs: Int64,
        scheduleAnchorMs: Int64,
        schedulePeriodSeconds: Int = 300
    ) -> Int {
        max(0, Int((nowMs - scheduleAnchorMs) / Int64(schedulePeriodSeconds * 1000)))
    }

    static func windowStart(
        scheduleAnchorMs: Int64,
        windowIndex: Int,
        schedulePeriodSeconds: Int = 300
    ) -> Date {
        let ms = scheduleAnchorMs + Int64(windowIndex * schedulePeriodSeconds * 1000)
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    static func windowEnd(
        scheduleAnchorMs: Int64,
        windowIndex: Int,
        schedulePeriodSeconds: Int = 300
    ) -> Date {
        let ms = scheduleAnchorMs + Int64((windowIndex + 1) * schedulePeriodSeconds * 1000)
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
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
    let scheduleAnchorMs: Int64
    let schedulePeriodSeconds: Int
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
        desiredState: MobileSegmentScreencastDesiredState = .writing,
        scheduleAnchorMs: Int64,
        schedulePeriodSeconds: Int = 300,
        lastHostUpdateAt: Date = Date()
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
        self.scheduleAnchorMs = scheduleAnchorMs
        self.schedulePeriodSeconds = schedulePeriodSeconds
        self.lastHostUpdateAt = lastHostUpdateAt
    }

    func derivedSegmentID(at now: Date) -> UUID {
        let nowMs = MobileSegmentScreencastIdentity.nowMs(from: now)
        let windowIndex = MobileSegmentScreencastIdentity.windowIndex(
            nowMs: nowMs,
            scheduleAnchorMs: self.scheduleAnchorMs,
            schedulePeriodSeconds: self.schedulePeriodSeconds
        )
        return MobileSegmentScreencastIdentity.segmentID(
            sessionID: self.sessionID,
            scheduleAnchorMs: self.scheduleAnchorMs,
            windowIndex: windowIndex,
            schedulePeriodSeconds: self.schedulePeriodSeconds
        )
    }
}

nonisolated enum MobileSegmentScreencastDesiredState: String, Codable, Sendable {
    case writing
    case stopping
    case closed
}

nonisolated struct MobileSegmentScreencastWindowSidecar: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sessionID: UUID
    let revision: Int64
    let windowIndex: Int
    let startedAt: Date
    var endedAt: Date?
    var acceptedFrameCount: Int
    var droppedFrameCount: Int

    init(
        schemaVersion: Int = 1,
        sessionID: UUID,
        revision: Int64,
        windowIndex: Int,
        startedAt: Date,
        endedAt: Date? = nil,
        acceptedFrameCount: Int = 0,
        droppedFrameCount: Int = 0
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.revision = revision
        self.windowIndex = windowIndex
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.acceptedFrameCount = acceptedFrameCount
        self.droppedFrameCount = droppedFrameCount
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
    case filesystemHandoffFailure = "filesystem_handoff_failure"
    case appGroupUnavailable = "app_group_unavailable"
    case storageLow = "storage_low"

    var ownerSentence: String {
        MobileSegmentScreencastStopPolicy.ownerSentence(for: self)
    }
}

nonisolated enum ScreencastBroadcastWriterOutcome: Equatable, Sendable {
    case completed
    case noVideo
    case finalizeTimeout
    case writerFailure(String)
    case filesystemHandoffFailure(String)

    var diagnosticReason: MobileSegmentScreencastDiagnosticReason? {
        switch self {
        case .completed:
            nil
        case .noVideo:
            .noVideo
        case .finalizeTimeout:
            .finalizeTimeout
        case .writerFailure:
            .writerFailure
        case .filesystemHandoffFailure:
            .filesystemHandoffFailure
        }
    }
}

nonisolated enum MobileSegmentScreencastStopPolicy {
    static let errorDomain = "app.solstone.swift.screencast"

    static func shouldErrorExit(for reason: MobileSegmentScreencastDiagnosticReason) -> Bool {
        switch reason {
        case .storageLow, .appGroupUnavailable, .finalizeTimeout, .writerFailure, .filesystemHandoffFailure:
            true
        case .noVideo:
            false
        }
    }

    static func stopError(for reason: MobileSegmentScreencastDiagnosticReason) -> NSError {
        NSError(
            domain: self.errorDomain,
            code: 100,
            userInfo: [NSLocalizedDescriptionKey: self.ownerSentence(for: reason)]
        )
    }

    static func ownerSentence(for reason: MobileSegmentScreencastDiagnosticReason) -> String {
        switch reason {
        case .storageLow:
            "screen stopped. this iphone is low on storage."
        case .appGroupUnavailable:
            "screen is unavailable"
        case .noVideo:
            "no screen video was saved"
        case .finalizeTimeout:
            "screen video timed out while saving"
        case .writerFailure:
            "screen video could not be saved"
        case .filesystemHandoffFailure:
            "screen video could not be stored"
        }
    }
}

nonisolated enum MobileSegmentScreencastStoragePolicy {
    /// Refuse to open a new 5-minute screen window when important-usage
    /// capacity is below 1 GB. A window can write tens of MB of HEVC plus
    /// audio/location siblings; 1 GB leaves the OS, journal drain, and a
    /// handful of future windows room to finish without filling the volume.
    static let minimumFreeBytes: Int64 = 1_000_000_000
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

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated enum DrainSource: String, Sendable {
    case observer
    case omi
    case watch
    case location
    case share
    case aggregate
    case view
    case unknown

    static func audio(_ sourceType: String) -> DrainSource {
        switch sourceType {
        case "observer-audio":
            .observer
        case "omi-audio":
            .omi
        case "watch-audio":
            .watch
        default:
            .unknown
        }
    }
}

nonisolated enum DrainErrorCategory: String, Sendable {
    case none
    case transport
    case http
    case filesystem
    case decode
    case unavailable
    case unknown

    static func classify(_ error: any Error) -> DrainErrorCategory {
        if error is URLError {
            return .transport
        }
        if error is DecodingError {
            return .decode
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return .filesystem
        }
        return .unknown
    }
}

nonisolated enum DrainBoundary: Sendable {
    case aggregateRefresh
    case sourceSnapshotScan
    case aggregatePublication
    case countRefresh
    case uploadCompletion
    case multipartBodyBuild
    case taskCreateResume

    var name: StaticString {
        switch self {
        case .aggregateRefresh:
            "drain.aggregate_refresh"
        case .sourceSnapshotScan:
            "drain.source_snapshot_scan"
        case .aggregatePublication:
            "drain.aggregate_publication"
        case .countRefresh:
            "drain.count_refresh"
        case .uploadCompletion:
            "drain.upload_completion"
        case .multipartBodyBuild:
            "drain.multipart_body_build"
        case .taskCreateResume:
            "drain.task_create_resume"
        }
    }
}

nonisolated struct DrainFields: Sendable {
    var trigger: String?
    var status: String?
    var error: DrainErrorCategory?
    var pending: Int?
    var failed: Int?
    var items: Int?
    var bytes: Int?
    var durationMs: Double?
    var published: Bool?
    var step: String?
    var sources: Int?
    var failedSources: Int?
    var httpStatusClass: String?

    init(
        trigger: String? = nil,
        status: String? = nil,
        error: DrainErrorCategory? = nil,
        pending: Int? = nil,
        failed: Int? = nil,
        items: Int? = nil,
        bytes: Int? = nil,
        durationMs: Double? = nil,
        published: Bool? = nil,
        step: String? = nil,
        sources: Int? = nil,
        failedSources: Int? = nil,
        httpStatusClass: String? = nil
    ) {
        self.trigger = trigger
        self.status = status
        self.error = error
        self.pending = pending
        self.failed = failed
        self.items = items
        self.bytes = bytes
        self.durationMs = durationMs
        self.published = published
        self.step = step
        self.sources = sources
        self.failedSources = failedSources
        self.httpStatusClass = httpStatusClass
    }

    var publicDescription: String {
        var parts: [String] = []
        if let trigger {
            parts.append("trigger=\(trigger)")
        }
        if let status {
            parts.append("status=\(status)")
        }
        if let error {
            parts.append("error=\(error.rawValue)")
        }
        if let pending {
            parts.append("pending=\(pending)")
        }
        if let failed {
            parts.append("failed=\(failed)")
        }
        if let items {
            parts.append("items=\(items)")
        }
        if let bytes {
            parts.append("bytes=\(bytes)")
        }
        if let durationMs {
            parts.append("durationMs=\(durationMs)")
        }
        if let published {
            parts.append("published=\(published)")
        }
        if let step {
            parts.append("step=\(step)")
        }
        if let sources {
            parts.append("sources=\(sources)")
        }
        if let failedSources {
            parts.append("failedSources=\(failedSources)")
        }
        if let httpStatusClass {
            parts.append("httpStatusClass=\(httpStatusClass)")
        }
        return parts.joined(separator: " ")
    }
}

nonisolated struct DrainInterval {
    fileprivate let boundary: DrainBoundary
    fileprivate let state: OSSignpostIntervalState
}

nonisolated enum DrainSignpost {
    private static let signposter = OSSignposter(logHandle: OSLog(subsystem: "app.solstone.swift", category: "drain"))

    static func begin(
        _ boundary: DrainBoundary,
        source: DrainSource,
        fields: DrainFields = DrainFields()
    ) -> DrainInterval {
        let state = Self.signposter.beginInterval(
            boundary.name,
            "source=\(source.rawValue, privacy: .public) \(fields.publicDescription, privacy: .public)"
        )
        return DrainInterval(boundary: boundary, state: state)
    }

    static func end(
        _ interval: DrainInterval,
        source: DrainSource,
        fields: DrainFields = DrainFields()
    ) {
        Self.signposter.endInterval(
            interval.boundary.name,
            interval.state,
            "source=\(source.rawValue, privacy: .public) \(fields.publicDescription, privacy: .public)"
        )
    }

    static func event(
        _ boundary: DrainBoundary,
        source: DrainSource,
        fields: DrainFields = DrainFields()
    ) {
        Self.signposter.emitEvent(
            boundary.name,
            "source=\(source.rawValue, privacy: .public) \(fields.publicDescription, privacy: .public)"
        )
    }

    static func durationMs(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static func httpStatusClass(_ statusCode: Int) -> String {
        switch statusCode {
        case 400..<500:
            "4xx"
        case 500..<600:
            "5xx"
        default:
            "other"
        }
    }
}

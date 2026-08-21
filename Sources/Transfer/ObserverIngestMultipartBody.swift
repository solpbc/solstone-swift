// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct ObserverIngestMultipartPart: Equatable, Sendable {
    var filename: String
    var contentType: String
    var data: Data

    init(filename: String, contentType: String, data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}

nonisolated struct ObserverIngestMultipartPayload: Equatable, Sendable {
    var boundary: String
    var day: String
    var segment: String
    var source: String
    var platform: String
    var startedAt: Date
    var durationS: TimeInterval
    var sources: [String]
    var chunkIndex: Int?
    var sessionID: UUID?
    var modeRawValue: String?
    var segmentID: UUID?
    var omiMetadata: JSONValue?
    var parts: [ObserverIngestMultipartPart]

    init(
        boundary: String,
        day: String,
        segment: String,
        source: String,
        platform: String,
        startedAt: Date,
        durationS: TimeInterval,
        sources: [String],
        chunkIndex: Int? = nil,
        sessionID: UUID? = nil,
        modeRawValue: String? = nil,
        segmentID: UUID? = nil,
        omiMetadata: JSONValue? = nil,
        parts: [ObserverIngestMultipartPart]
    ) {
        self.boundary = boundary
        self.day = day
        self.segment = segment
        self.source = source
        self.platform = platform
        self.startedAt = startedAt
        self.durationS = durationS
        self.sources = sources
        self.chunkIndex = chunkIndex
        self.sessionID = sessionID
        self.modeRawValue = modeRawValue
        self.segmentID = segmentID
        self.omiMetadata = omiMetadata
        self.parts = parts
    }
}

nonisolated enum ObserverIngestMultipartBodyError: Error, Equatable, Sendable {
    case missingArtifact
}

nonisolated enum ObserverIngestMultipartBody {
    static func build(payload: ObserverIngestMultipartPayload) throws -> Data {
        guard !payload.parts.isEmpty else {
            throw ObserverIngestMultipartBodyError.missingArtifact
        }

        var body = Data()
        var metaObject: [String: Any] = [
            "platform": payload.platform,
            "started_at": ISO8601DateFormatter().string(from: payload.startedAt),
            "duration_s": payload.durationS,
            "sources": payload.sources,
        ]
        if let chunkIndex = payload.chunkIndex {
            metaObject["chunk_index"] = chunkIndex
        }
        if let sessionID = payload.sessionID {
            metaObject["session_id"] = sessionID.uuidString
        }
        if let modeRawValue = payload.modeRawValue {
            metaObject["mode"] = modeRawValue
        }
        if let segmentID = payload.segmentID {
            metaObject["segment_id"] = segmentID.uuidString
        }
        if let omiMetadata = payload.omiMetadata {
            metaObject[OmiSegmentMetadata.key] = omiMetadata.foundationObject
        }
        let envelope: [String: Any] = [
            "day": payload.day,
            "segment": payload.segment,
            "source": payload.source,
            "files": payload.parts.map { ["submitted": $0.filename] },
            "meta": metaObject,
        ]
        let envelopeData = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        body.append(self.multipartField(
            named: "envelope",
            value: String(decoding: envelopeData, as: UTF8.self),
            boundary: payload.boundary
        ))

        for part in payload.parts {
            body.append("--\(payload.boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(ObserverServerURL.filesFieldName)\"; filename=\"\(part.filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(part.contentType)\r\n\r\n".data(using: .utf8)!)
            body.append(part.data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(payload.boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    static func multipartField(named name: String, value: String, boundary: String) -> Data {
        Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
    }
}

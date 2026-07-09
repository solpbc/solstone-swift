// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct ObserverIngestMultipartInput: Equatable, Sendable {
    var boundary: String
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
    var artifacts: ObserverIngestMultipartArtifacts

    init(
        boundary: String,
        platform: String,
        segment: String,
        day: String,
        startedAt: Date,
        durationS: TimeInterval,
        sources: [String],
        chunkIndex: Int? = nil,
        sessionID: UUID? = nil,
        modeRawValue: String? = nil,
        segmentID: UUID? = nil,
        artifacts: ObserverIngestMultipartArtifacts
    ) {
        self.boundary = boundary
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
        self.artifacts = artifacts
    }
}

nonisolated struct ObserverIngestMultipartArtifacts: Equatable, Sendable {
    var audioData: Data?
    var locationJSONL: Data?
    var screenData: Data?

    init(audioData: Data? = nil, locationJSONL: Data? = nil, screenData: Data? = nil) {
        self.audioData = audioData
        self.locationJSONL = locationJSONL
        self.screenData = screenData
    }

    var isEmpty: Bool {
        self.audioData == nil && self.locationJSONL == nil && self.screenData == nil
    }
}

nonisolated enum ObserverIngestMultipartBodyError: Error, Equatable, Sendable {
    case missingArtifact
}

nonisolated enum ObserverIngestMultipartBody {
    static func build(input: ObserverIngestMultipartInput) throws -> Data {
        guard !input.artifacts.isEmpty else {
            throw ObserverIngestMultipartBodyError.missingArtifact
        }

        var body = Data()
        body.append(self.multipartField(named: "segment", value: input.segment, boundary: input.boundary))
        body.append(self.multipartField(named: "day", value: input.day, boundary: input.boundary))
        body.append(self.multipartField(named: "platform", value: input.platform, boundary: input.boundary))

        var metaObject: [String: Any] = [
            "segment": input.segment,
            "day": input.day,
            "started_at": ISO8601DateFormatter().string(from: input.startedAt),
            "duration_s": input.durationS,
            "sources": input.sources,
        ]
        if let chunkIndex = input.chunkIndex {
            metaObject["chunk_index"] = chunkIndex
        }
        if let sessionID = input.sessionID {
            metaObject["session_id"] = sessionID.uuidString
        }
        if let modeRawValue = input.modeRawValue {
            metaObject["mode"] = modeRawValue
        }
        if let segmentID = input.segmentID {
            metaObject["segment_id"] = segmentID.uuidString
        }
        let meta = try JSONSerialization.data(withJSONObject: metaObject, options: [.sortedKeys])
        body.append(self.multipartField(
            named: "meta",
            value: String(decoding: meta, as: UTF8.self),
            boundary: input.boundary
        ))

        if let audioData = input.artifacts.audioData {
            body.append("--\(input.boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(ObserverServerURL.filesFieldName)\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
            body.append(audioData)
            body.append("\r\n".data(using: .utf8)!)
        }
        if let locationJSONL = input.artifacts.locationJSONL {
            body.append("--\(input.boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(ObserverServerURL.filesFieldName)\"; filename=\"location.jsonl\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/x-ndjson\r\n\r\n".data(using: .utf8)!)
            body.append(locationJSONL)
            body.append("\r\n".data(using: .utf8)!)
        }
        if let screenData = input.artifacts.screenData {
            body.append("--\(input.boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(ObserverServerURL.filesFieldName)\"; filename=\"screen.mp4\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: video/mp4\r\n\r\n".data(using: .utf8)!)
            body.append(screenData)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(input.boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    static func multipartField(named name: String, value: String, boundary: String) -> Data {
        Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum MobileSegmentLocationWriter {
    nonisolated struct FrozenLocation: Sendable, Equatable {
        let data: Data
        let fixCount: Int
    }

    nonisolated struct LiveStateRecord: Codable, Sendable, Equatable {
        let kind: String
        let source: String
        let platform: String
        let segmentID: UUID
        let segmentStart: Date
        let tier: LocationTier
        let accuracy: LocationAccuracy
        let gap: Bool
        let recordedAt: Date

        enum CodingKeys: String, CodingKey {
            case schema
            case kind
            case source
            case platform
            case segmentID = "segment_id"
            case segmentStart = "segment_start"
            case tier
            case accuracy
            case gap
            case recordedAt = "recorded_at"
        }

        init(
            segmentID: UUID,
            segmentStart: Date,
            tier: LocationTier,
            accuracy: LocationAccuracy,
            gap: Bool,
            recordedAt: Date
        ) {
            self.kind = "state"
            self.source = "location"
            self.platform = "ios"
            self.segmentID = segmentID
            self.segmentStart = segmentStart
            self.tier = tier
            self.accuracy = accuracy
            self.gap = gap
            self.recordedAt = recordedAt
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let schema = try container.decode(String.self, forKey: .schema)
            guard schema == "solstone.location.live.state/1" else {
                throw MobileSegmentLocationLiveRecoveryError.unknownRecord(schema: schema, kind: nil)
            }
            self.kind = try container.decode(String.self, forKey: .kind)
            self.source = try container.decode(String.self, forKey: .source)
            self.platform = try container.decode(String.self, forKey: .platform)
            self.segmentID = try container.decode(UUID.self, forKey: .segmentID)
            self.segmentStart = try container.decode(Date.self, forKey: .segmentStart)
            let tierRawValue = try container.decode(String.self, forKey: .tier)
            guard let tier = LocationTier(rawValue: tierRawValue) else {
                throw MobileSegmentLocationLiveRecoveryError.corruptRecord
            }
            self.tier = tier
            let accuracyRawValue = try container.decode(String.self, forKey: .accuracy)
            guard let accuracy = LocationAccuracy(rawValue: accuracyRawValue) else {
                throw MobileSegmentLocationLiveRecoveryError.corruptRecord
            }
            self.accuracy = accuracy
            self.gap = try container.decode(Bool.self, forKey: .gap)
            self.recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("solstone.location.live.state/1", forKey: .schema)
            try container.encode(self.kind, forKey: .kind)
            try container.encode(self.source, forKey: .source)
            try container.encode(self.platform, forKey: .platform)
            try container.encode(self.segmentID, forKey: .segmentID)
            try container.encode(self.segmentStart, forKey: .segmentStart)
            try container.encode(self.tier.rawValue, forKey: .tier)
            try container.encode(self.accuracy.rawValue, forKey: .accuracy)
            try container.encode(self.gap, forKey: .gap)
            try container.encode(self.recordedAt, forKey: .recordedAt)
        }
    }

    nonisolated struct RecoveredLiveLocation: Sendable, Equatable {
        let segmentStart: Date
        let tier: LocationTier
        let accuracy: LocationAccuracy
        let fixes: [LocationFix]
        let visits: [LocationVisit]
        let gap: Bool
        let latestRecordAt: Date
        let droppedLineCount: Int

        func batch(endedAt: Date) -> LocationSegmentBatch {
            LocationSegmentBatch(
                tier: self.tier,
                accuracy: self.accuracy,
                segmentStart: self.segmentStart,
                coveredSeconds: Swift.max(0, Int(endedAt.timeIntervalSince(self.segmentStart).rounded())),
                fixes: self.fixes,
                visits: self.visits,
                gap: self.gap
            )
        }
    }

    private nonisolated struct HeaderLine: Encodable {
        let batch: LocationSegmentBatch

        enum CodingKeys: String, CodingKey {
            case schema
            case kind
            case source
            case platform
            case tier
            case accuracy
            case fixCount = "fix_count"
            case gap
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("solstone.location.segment/1", forKey: .schema)
            try container.encode("location", forKey: .kind)
            try container.encode("location", forKey: .source)
            try container.encode("ios", forKey: .platform)
            try container.encode(self.batch.tier.rawValue, forKey: .tier)
            try container.encode(self.batch.accuracy.rawValue, forKey: .accuracy)
            try container.encode(self.batch.fixes.count, forKey: .fixCount)
            try container.encode(self.batch.gap, forKey: .gap)
        }
    }

    private nonisolated struct FixLine: Codable {
        let fix: LocationFix

        enum CodingKeys: String, CodingKey {
            case schema
            case t
            case lat
            case lon
            case hAcc = "h_acc"
            case alt
            case vAcc = "v_acc"
            case speed
            case course
            case stationary
        }

        init(fix: LocationFix) {
            self.fix = fix
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let schema = try container.decode(String.self, forKey: .schema)
            guard schema == "solstone.location.fix/1" else {
                throw MobileSegmentLocationLiveRecoveryError.unknownRecord(schema: schema, kind: nil)
            }
            self.fix = LocationFix(
                t: try container.decode(Date.self, forKey: .t),
                lat: try container.decode(Double.self, forKey: .lat),
                lon: try container.decode(Double.self, forKey: .lon),
                hAcc: try container.decode(Double.self, forKey: .hAcc),
                alt: try container.decodeIfPresent(Double.self, forKey: .alt),
                vAcc: try container.decodeIfPresent(Double.self, forKey: .vAcc),
                speed: try container.decodeIfPresent(Double.self, forKey: .speed),
                course: try container.decodeIfPresent(Double.self, forKey: .course),
                stationary: try container.decode(Bool.self, forKey: .stationary)
            )
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("solstone.location.fix/1", forKey: .schema)
            try container.encode(self.fix.t, forKey: .t)
            try container.encode(self.fix.lat, forKey: .lat)
            try container.encode(self.fix.lon, forKey: .lon)
            try container.encode(self.fix.hAcc, forKey: .hAcc)
            if let alt = self.fix.alt {
                try container.encode(alt, forKey: .alt)
            } else {
                try container.encodeNil(forKey: .alt)
            }
            if let vAcc = self.fix.vAcc {
                try container.encode(vAcc, forKey: .vAcc)
            } else {
                try container.encodeNil(forKey: .vAcc)
            }
            if let speed = self.fix.speed {
                try container.encode(speed, forKey: .speed)
            } else {
                try container.encodeNil(forKey: .speed)
            }
            if let course = self.fix.course {
                try container.encode(course, forKey: .course)
            } else {
                try container.encodeNil(forKey: .course)
            }
            try container.encode(self.fix.stationary, forKey: .stationary)
        }
    }

    private nonisolated struct VisitLine: Codable {
        let visit: LocationVisit

        enum CodingKeys: String, CodingKey {
            case schema
            case arrival
            case departure
            case lat
            case lon
            case hAcc = "h_acc"
        }

        init(visit: LocationVisit) {
            self.visit = visit
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let schema = try container.decode(String.self, forKey: .schema)
            guard schema == "solstone.location.visit/1" else {
                throw MobileSegmentLocationLiveRecoveryError.unknownRecord(schema: schema, kind: nil)
            }
            self.visit = LocationVisit(
                arrival: try container.decode(Date.self, forKey: .arrival),
                departure: try container.decodeIfPresent(Date.self, forKey: .departure),
                lat: try container.decode(Double.self, forKey: .lat),
                lon: try container.decode(Double.self, forKey: .lon),
                hAcc: try container.decode(Double.self, forKey: .hAcc)
            )
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("solstone.location.visit/1", forKey: .schema)
            try container.encode(self.visit.arrival, forKey: .arrival)
            if let departure = self.visit.departure {
                try container.encode(departure, forKey: .departure)
            } else {
                try container.encodeNil(forKey: .departure)
            }
            try container.encode(self.visit.lat, forKey: .lat)
            try container.encode(self.visit.lon, forKey: .lon)
            try container.encode(self.visit.hAcc, forKey: .hAcc)
        }
    }

    nonisolated struct SnapshotHeaderLine: Decodable, Sendable, Equatable {
        let fixCount: Int

        enum CodingKeys: String, CodingKey {
            case fixCount = "fix_count"
        }
    }

    static func freeze(_ batch: LocationSegmentBatch, encoder: JSONEncoder? = nil) throws -> FrozenLocation {
        let encoder = encoder ?? Self.encoder()
        var lines = [Data]()
        lines.append(try encoder.encode(HeaderLine(batch: batch)))
        for fix in batch.fixes {
            lines.append(try encoder.encode(FixLine(fix: fix)))
        }
        for visit in batch.visits {
            lines.append(try encoder.encode(VisitLine(visit: visit)))
        }

        var data = Data()
        for line in lines {
            data.append(line)
            data.append(0x0A)
        }
        return FrozenLocation(data: data, fixCount: batch.fixes.count)
    }

    static func loadSnapshotHeader(from data: Data) throws -> SnapshotHeaderLine {
        let lineData: Data
        if let newline = data.firstIndex(of: 0x0A) {
            lineData = Data(data[..<newline])
        } else {
            lineData = data
        }
        return try JSONDecoder().decode(SnapshotHeaderLine.self, from: lineData)
    }

    static func liveStateLine(
        segmentID: UUID,
        segmentStart: Date,
        tier: LocationTier,
        accuracy: LocationAccuracy,
        gap: Bool,
        recordedAt: Date,
        encoder: JSONEncoder? = nil
    ) throws -> Data {
        try Self.lineData(
            LiveStateRecord(
                segmentID: segmentID,
                segmentStart: segmentStart,
                tier: tier,
                accuracy: accuracy,
                gap: gap,
                recordedAt: recordedAt
            ),
            encoder: encoder
        )
    }

    static func liveFixLine(_ fix: LocationFix, encoder: JSONEncoder? = nil) throws -> Data {
        try Self.lineData(FixLine(fix: fix), encoder: encoder)
    }

    static func liveVisitLine(_ visit: LocationVisit, encoder: JSONEncoder? = nil) throws -> Data {
        try Self.lineData(VisitLine(visit: visit), encoder: encoder)
    }

    static func recoverLiveLocation(segmentID: UUID, from data: Data, decoder: JSONDecoder? = nil) throws -> RecoveredLiveLocation {
        let decoder = decoder ?? Self.decoder()
        let lines = Self.completeLiveLines(from: data)
        var state: LiveStateRecord?
        var fixes: [LocationFix] = []
        var visits: [LocationVisit] = []
        var latestRecordAt: Date?
        var droppedLineCount = 0

        for line in lines {
            let probe: Probe
            do {
                probe = try Self.decodeProbe(from: line, decoder: decoder)
            } catch {
                guard state != nil else { throw error }
                droppedLineCount += 1
                continue
            }
            switch (probe.schema, probe.kind) {
            case ("solstone.location.live.state/1", "state"):
                let decoded = try decoder.decode(LiveStateRecord.self, from: line)
                guard decoded.segmentID == segmentID,
                      decoded.kind == "state",
                      decoded.source == "location",
                      decoded.platform == "ios" else {
                    continue
                }
                state = decoded
                latestRecordAt = Self.max(latestRecordAt, decoded.recordedAt)
            case ("solstone.location.fix/1", _):
                do {
                    let decoded = try decoder.decode(FixLine.self, from: line)
                    fixes.append(decoded.fix)
                    latestRecordAt = Self.max(latestRecordAt, decoded.fix.t)
                } catch {
                    guard state != nil else { throw error }
                    droppedLineCount += 1
                }
            case ("solstone.location.visit/1", _):
                do {
                    let decoded = try decoder.decode(VisitLine.self, from: line)
                    visits.append(decoded.visit)
                    latestRecordAt = Self.max(latestRecordAt, decoded.visit.departure ?? decoded.visit.arrival)
                } catch {
                    guard state != nil else { throw error }
                    droppedLineCount += 1
                }
            default:
                guard state != nil else {
                    throw MobileSegmentLocationLiveRecoveryError.unknownRecord(schema: probe.schema, kind: probe.kind)
                }
                droppedLineCount += 1
            }
        }

        guard let state else {
            throw MobileSegmentLocationLiveRecoveryError.missingState
        }

        return RecoveredLiveLocation(
            segmentStart: state.segmentStart,
            tier: state.tier,
            accuracy: state.accuracy,
            fixes: fixes,
            visits: visits,
            gap: state.gap,
            latestRecordAt: latestRecordAt ?? state.recordedAt,
            droppedLineCount: droppedLineCount
        )
    }

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

    private static func lineData<T: Encodable>(_ value: T, encoder: JSONEncoder?) throws -> Data {
        let encoder = encoder ?? Self.encoder()
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private nonisolated struct Probe: Decodable {
        let schema: String
        let kind: String?
    }

    private static func decodeProbe(from data: Data, decoder: JSONDecoder) throws -> Probe {
        do {
            return try decoder.decode(Probe.self, from: data)
        } catch {
            throw MobileSegmentLocationLiveRecoveryError.corruptRecord
        }
    }

    private static func completeLiveLines(from data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        let completeData: Data
        if data.last == 0x0A {
            completeData = data
        } else if let lastNewline = data.lastIndex(of: 0x0A) {
            completeData = Data(data[..<lastNewline])
        } else {
            return []
        }
        var lines: [Data] = []
        var start = completeData.startIndex
        while let newline = completeData[start...].firstIndex(of: 0x0A) {
            if newline > start {
                lines.append(Data(completeData[start..<newline]))
            }
            start = completeData.index(after: newline)
        }
        if start < completeData.endIndex {
            lines.append(Data(completeData[start..<completeData.endIndex]))
        }
        return lines
    }

    private static func max(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return lhs > rhs ? lhs : rhs
    }
}

nonisolated enum MobileSegmentLocationLiveRecoveryError: Error, Equatable, Sendable {
    case missingState
    case corruptRecord
    case unknownRecord(schema: String, kind: String?)
}

nonisolated struct MobileSegmentLocationSegmentLiveness: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let segmentID: UUID
    let sourceSetVersion: Int
    let lastSeenAt: Date
    let fixCount: Int
    let visitCount: Int
    let gap: Bool

    init(
        schemaVersion: Int = 1,
        segmentID: UUID,
        sourceSetVersion: Int,
        lastSeenAt: Date,
        fixCount: Int,
        visitCount: Int,
        gap: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.segmentID = segmentID
        self.sourceSetVersion = sourceSetVersion
        self.lastSeenAt = lastSeenAt
        self.fixCount = fixCount
        self.visitCount = visitCount
        self.gap = gap
    }
}

nonisolated enum MobileSegmentLocationLivenessPolicy {
    static let livenessRefreshIntervalSeconds: TimeInterval = 30
    static let livenessStaleWindowSeconds: TimeInterval = 120

    static func isFresh(lastSeenAt: Date, now: Date, staleWindow: TimeInterval = Self.livenessStaleWindowSeconds) -> Bool {
        now.timeIntervalSince(lastSeenAt) <= staleWindow
    }
}

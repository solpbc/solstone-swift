// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum MobileSegmentLocationWriter {
    nonisolated struct FrozenLocation: Sendable, Equatable {
        let data: Data
        let fixCount: Int
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

    private nonisolated struct FixLine: Encodable {
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

    private nonisolated struct VisitLine: Encodable {
        let visit: LocationVisit

        enum CodingKeys: String, CodingKey {
            case schema
            case arrival
            case departure
            case lat
            case lon
            case hAcc = "h_acc"
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

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

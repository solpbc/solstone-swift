// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
final class WatchCaptureLocationLog {
    struct FinalizedStats: Equatable, Sendable {
        let fixCount: Int
        let gap: Bool
    }

    private let url: URL
    private let fileWriter: any WatchFileWriting
    private let encoder: JSONEncoder

    init(url: URL, fileWriter: any WatchFileWriting) {
        self.url = url
        self.fileWriter = fileWriter
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
    }

    func openProvisionalHeader() throws {
        let data = try Self.segmentData(fixCount: 0, gap: true, fixLines: [], encoder: self.encoder)
        try self.fileWriter.writeData(data, to: self.url, options: .atomic)
    }

    func append(_ fix: WatchLocationFix) throws {
        try self.fileWriter.appendLine(try self.encoder.encode(FixLine(fix: fix)), to: self.url)
    }

    func finalize(armed: Bool) throws -> FinalizedStats {
        let stats = try Self.reconciledStats(
            url: self.url,
            armed: armed,
            fileWriter: self.fileWriter,
            encoder: self.encoder
        )
        return stats
    }

    static func reconcile(
        url: URL,
        armed: Bool,
        fileWriter: any WatchFileWriting
    ) throws -> FinalizedStats {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try Self.reconciledStats(url: url, armed: armed, fileWriter: fileWriter, encoder: encoder)
    }
}

private extension WatchCaptureLocationLog {
    struct HeaderLine: Encodable {
        let fixCount: Int
        let gap: Bool

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
            try container.encode("watchos", forKey: .platform)
            try container.encode("light", forKey: .tier)
            try container.encode("reduced", forKey: .accuracy)
            try container.encode(self.fixCount, forKey: .fixCount)
            try container.encode(self.gap, forKey: .gap)
        }
    }

    struct FixLine: Encodable {
        let fix: WatchLocationFix

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

    static func reconciledStats(
        url: URL,
        armed: Bool,
        fileWriter: any WatchFileWriting,
        encoder: JSONEncoder
    ) throws -> FinalizedStats {
        let fixLines = try Self.durableFixLines(url: url, fileWriter: fileWriter)
        let fixCount = fixLines.count
        let gap = armed && fixCount == 0
        let data = try Self.segmentData(fixCount: fixCount, gap: gap, fixLines: fixLines, encoder: encoder)
        try fileWriter.atomicReplaceFile(at: url, with: data)
        return FinalizedStats(fixCount: fixCount, gap: gap)
    }

    static func segmentData(
        fixCount: Int,
        gap: Bool,
        fixLines: [Data],
        encoder: JSONEncoder
    ) throws -> Data {
        var data = Data()
        data.append(try encoder.encode(HeaderLine(fixCount: fixCount, gap: gap)))
        data.append(0x0A)
        for line in fixLines {
            data.append(line)
            data.append(0x0A)
        }
        return data
    }

    static func durableFixLines(url: URL, fileWriter: any WatchFileWriting) throws -> [Data] {
        guard fileWriter.fileExists(at: url) else { return [] }
        let data = try fileWriter.readData(from: url)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard lines.count > 1 else { return [] }
        return lines.dropFirst().map { Data($0) }
    }
}

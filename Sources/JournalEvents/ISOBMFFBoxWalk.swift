// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let journalMediaLog = Logger(subsystem: "app.solstone.swift", category: "journal-events")

/// Top-level ISO-BMFF walk. Payload is the sum of `mdat` contents. A failed walk is undelimited.
nonisolated enum ISOBMFFWalkResult: Equatable, Sendable {
    case delimited(payloadBytes: Int)
    case undelimited
}

nonisolated enum ISOBMFFBoxWalk {
    static func walk(url: URL) -> ISOBMFFWalkResult {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .undelimited }
        defer { try? handle.close() }
        let end: UInt64
        do {
            end = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
        } catch {
            return .undelimited
        }
        if end == 0 { return .undelimited }

        var offset: UInt64 = 0
        var payload = 0
        let mdat = Data([0x6D, 0x64, 0x61, 0x74])
        while offset < end {
            let headerLength: UInt64
            let boxSize: UInt64
            let type: Data
            do {
                try handle.seek(toOffset: offset)
                guard let header = try handle.read(upToCount: 8), header.count == 8 else {
                    return .undelimited
                }
                let size32 = Self.u32(header, 0)
                type = header.subdata(in: 4..<8)
                if size32 == 1 {
                    guard let large = try handle.read(upToCount: 8), large.count == 8 else {
                        return .undelimited
                    }
                    headerLength = 16
                    boxSize = Self.u64(large, 0)
                } else if size32 == 0 {
                    headerLength = 8
                    boxSize = end - offset
                } else {
                    headerLength = 8
                    boxSize = UInt64(size32)
                }
            } catch {
                return .undelimited
            }
            if boxSize < headerLength || offset > UInt64.max - boxSize || offset + boxSize > end {
                return .undelimited
            }
            if type == mdat {
                let content = boxSize - headerLength
                if content > UInt64(Int.max - payload) {
                    return .delimited(payloadBytes: Int.max)
                }
                payload += Int(content)
            }
            offset += boxSize
        }
        return .delimited(payloadBytes: payload)
    }

    private static func u32(_ data: Data, _ index: Int) -> UInt32 {
        let base = data.startIndex + index
        return (UInt32(data[base]) << 24)
            | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8)
            | UInt32(data[base + 3])
    }

    private static func u64(_ data: Data, _ index: Int) -> UInt64 {
        let high = UInt64(self.u32(data, index))
        let low = UInt64(self.u32(data, index + 4))
        return (high << 32) | low
    }
}

nonisolated enum JournalMediaRule: Sendable {
    /// Phone `audio.m4a`. Payload of at least 4 bytes, or accepted frames, or an undelimited file larger than 0.
    case phoneAudio
    /// Screen `mp4` and screen-audio `m4a`. Payload of at least 1 byte, or an undelimited file larger than 0.
    case screen
}

nonisolated enum JournalFileExistence: Equatable, Sendable {
    case absent
    case unreadableSize
    case present(existed: Bool)
}

nonisolated enum JournalBoxedFile {
    static func existence(
        at url: URL,
        rule: JournalMediaRule,
        acceptedFrames: Int,
        fileManager: FileManager = .default
    ) -> JournalFileExistence {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .absent
        }
        guard let sizeNumber = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            journalMediaLog.error("journal media size unreadable name=\(url.lastPathComponent, privacy: .public)")
            return .unreadableSize
        }
        let size = sizeNumber.int64Value
        if size == 0 { return .present(existed: false) }
        let frames = max(0, acceptedFrames)
        switch ISOBMFFBoxWalk.walk(url: url) {
        case .delimited(let payload):
            switch rule {
            case .phoneAudio:
                return .present(existed: payload >= 4 || frames > 0)
            case .screen:
                return .present(existed: payload >= 1)
            }
        case .undelimited:
            return .present(existed: size > 0)
        }
    }
}

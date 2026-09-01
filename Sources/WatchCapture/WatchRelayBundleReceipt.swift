// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct WatchRelayBundleReceipt: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let filename = "relay-bundle-receipt.json"

    let version: Int
    let segmentID: UUID
    let source: WatchCaptureContentWitness
    let bundle: WatchCaptureStorageFileFingerprint

    init(
        version: Int = Self.currentVersion,
        segmentID: UUID,
        source: WatchCaptureContentWitness,
        bundle: WatchCaptureStorageFileFingerprint
    ) {
        self.version = version
        self.segmentID = segmentID
        self.source = source
        self.bundle = bundle
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(String(date.timeIntervalSince1970.bitPattern))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let encoded = try container.decode(String.self)
            guard let bitPattern = UInt64(encoded) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "invalid modification-date bit pattern"
                )
            }
            return Date(timeIntervalSince1970: Double(bitPattern: bitPattern))
        }
        return decoder
    }
}

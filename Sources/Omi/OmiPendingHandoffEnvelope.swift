// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated struct OmiPendingHandoffEnvelope: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let pathExtension = "handoff"

    let version: Int
    let itemID: UUID
    let sidecar: ChunkSidecar
    let metadata: OmiSegmentMetadata?
    let frozenTokens: [OmiSegmentMetadataToken]

    init(
        version: Int = Self.currentVersion,
        itemID: UUID,
        sidecar: ChunkSidecar,
        metadata: OmiSegmentMetadata?,
        frozenTokens: [OmiSegmentMetadataToken]
    ) {
        self.version = version
        self.itemID = itemID
        self.sidecar = sidecar
        self.metadata = metadata
        self.frozenTokens = frozenTokens
    }

    var isSupported: Bool { self.version == Self.currentVersion }
}

@MainActor
enum OmiPendingHandoffStore {
    private static let log = Logger(subsystem: "app.solstone.swift", category: "omi-handoff")

    static func url(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension(OmiPendingHandoffEnvelope.pathExtension)
    }

    static func encode(_ envelope: OmiPendingHandoffEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> OmiPendingHandoffEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OmiPendingHandoffEnvelope.self, from: Data(contentsOf: url))
    }

    static func remove(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            self.log.error("omi handoff envelope removal failed: \(String(describing: error), privacy: .public)")
        }
    }
}

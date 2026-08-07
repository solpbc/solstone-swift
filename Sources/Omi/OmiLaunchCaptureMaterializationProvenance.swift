// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct OmiLaunchCaptureMaterializationProvenance: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let pathExtension = "provenance"

    let version: Int
    let generationID: UUID
    let partitionOrdinal: Int
    let startSequence: UInt64
    let startSampleOffset: UInt64
    let itemID: UUID

    init(
        version: Int = Self.currentVersion,
        generationID: UUID,
        partitionOrdinal: Int,
        startSequence: UInt64,
        startSampleOffset: UInt64,
        itemID: UUID
    ) {
        self.version = version
        self.generationID = generationID
        self.partitionOrdinal = partitionOrdinal
        self.startSequence = startSequence
        self.startSampleOffset = startSampleOffset
        self.itemID = itemID
    }

    var isSupported: Bool { self.version == Self.currentVersion }
}

nonisolated struct OmiLaunchCaptureMaterializedArtifactPaths: Sendable {
    let audioURL: URL
    let envelopeURL: URL
    let provenanceURL: URL

    init(rootURL: URL, generationID: UUID, ordinal: Int) {
        let directory = rootURL
            .appendingPathComponent(OmiLaunchCaptureFormat.materializedDirectoryName, isDirectory: true)
            .appendingPathComponent(generationID.uuidString, isDirectory: true)
        self.audioURL = directory
            .appendingPathComponent(OmiSegmentWriter.chunkID(sessionID: generationID, index: ordinal))
            .appendingPathExtension("m4a")
        self.envelopeURL = OmiPendingHandoffStore.url(for: self.audioURL)
        self.provenanceURL = OmiLaunchCaptureMaterializationProvenanceStore.url(for: self.audioURL)
    }
}

@MainActor
enum OmiLaunchCaptureMaterializationProvenanceStore {
    nonisolated static func url(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension(OmiLaunchCaptureMaterializationProvenance.pathExtension)
    }

    static func encode(_ provenance: OmiLaunchCaptureMaterializationProvenance) throws -> Data {
        try JSONEncoder().encode(provenance)
    }

    static func decode(_ data: Data) throws -> OmiLaunchCaptureMaterializationProvenance {
        try JSONDecoder().decode(OmiLaunchCaptureMaterializationProvenance.self, from: data)
    }

    static func write(_ data: Data, to url: URL, io: any OmiLaunchCaptureIO) throws {
        try OmiPendingHandoffStore.write(data, to: url, io: io)
    }

    static func read(from url: URL) throws -> OmiLaunchCaptureMaterializationProvenance {
        try self.decode(Data(contentsOf: url))
    }
}

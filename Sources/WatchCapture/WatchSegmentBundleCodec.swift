// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum WatchSegmentBundleCodecError: Error, Equatable, Sendable {
    case invalidBundle
    case missingManifest
    case manifestIDMismatch(expected: UUID, actual: UUID)
}

nonisolated enum WatchSegmentBundleCodec {
    static let manifestFilename = "manifest.json"
    static let audioFilename = "audio.m4a"
    static let locationFilename = "location.jsonl"

    static func decode(
        bundleURL: URL,
        expectedID: UUID,
        destinationDirectory: URL,
        fileWriter: any WatchFileWriting
    ) async throws {
        let data = try await fileWriter.readData(from: bundleURL)
        guard let files = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Data] else {
            throw WatchSegmentBundleCodecError.invalidBundle
        }
        guard let manifestData = files[self.manifestFilename] else {
            throw WatchSegmentBundleCodecError.missingManifest
        }

        let manifest = try self.decodeManifest(from: manifestData)
        guard manifest.id == expectedID else {
            throw WatchSegmentBundleCodecError.manifestIDMismatch(expected: expectedID, actual: manifest.id)
        }

        try await fileWriter.createDirectory(at: destinationDirectory)
        try await fileWriter.writeData(
            manifestData,
            to: destinationDirectory.appendingPathComponent(self.manifestFilename, isDirectory: false),
            options: .atomic
        )
        if let audioData = files[self.audioFilename] {
            try await fileWriter.writeData(
                audioData,
                to: destinationDirectory.appendingPathComponent(self.audioFilename, isDirectory: false),
                options: .atomic
            )
        }
        if let locationData = files[self.locationFilename] {
            try await fileWriter.writeData(
                locationData,
                to: destinationDirectory.appendingPathComponent(self.locationFilename, isDirectory: false),
                options: .atomic
            )
        }
    }

    static func metadata(
        for manifest: WatchSegmentManifest,
        attempt: WatchRelayAttemptTag? = nil
    ) -> [String: Any] {
        var metadata: [String: Any] = [
            "id": manifest.id.uuidString,
            "day": manifest.day,
            "segment": manifest.segment,
            "duration": manifest.duration,
            "started_at": ISO8601DateFormatter().string(from: manifest.startedAt),
            "sensors": manifest.sensors.map(\.rawValue),
            "partial": manifest.partial,
            "lost": manifest.lost,
            "gap": manifest.gap,
            "fix_count": manifest.fixCount,
        ]
        if let attempt {
            metadata["generation"] = attempt.generation
            metadata["attempt_id"] = attempt.attemptID.uuidString
            metadata["attempt_started_at"] = ISO8601DateFormatter().string(from: attempt.attemptStartedAt)
        }
        return metadata
    }
}

nonisolated private extension WatchSegmentBundleCodec {
    static func decodeManifest(from data: Data) throws -> WatchSegmentManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WatchSegmentManifest.self, from: data)
    }
}

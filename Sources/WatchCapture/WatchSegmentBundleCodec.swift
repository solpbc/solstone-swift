// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum WatchSegmentBundleCodecError: Error, Equatable, Sendable {
    case invalidBundle
    case missingManifest
    case manifestIDMismatch(expected: UUID, actual: UUID)
}

@MainActor
enum WatchSegmentBundleCodec {
    static let manifestFilename = "manifest.json"
    static let audioFilename = "audio.m4a"
    static let locationFilename = "location.jsonl"

    static func writeBundle(
        segmentDirectory: URL,
        storage: WatchCaptureStorage,
        to bundleURL: URL
    ) throws {
        let data = try self.encode(segmentDirectory: segmentDirectory, storage: storage)
        try storage.fileWriter.writeData(data, to: bundleURL, options: .atomic)
    }

    static func encode(segmentDirectory: URL, storage: WatchCaptureStorage) throws -> Data {
        var files: [String: Data] = [:]
        let manifestURL = storage.manifestURL(directory: segmentDirectory)
        files[self.manifestFilename] = try storage.fileWriter.readData(from: manifestURL)

        let audioURL = storage.audioURL(directory: segmentDirectory)
        if storage.fileWriter.fileExists(at: audioURL) {
            files[self.audioFilename] = try storage.fileWriter.readData(from: audioURL)
        }

        let locationURL = storage.locationURL(directory: segmentDirectory)
        if storage.fileWriter.fileExists(at: locationURL) {
            files[self.locationFilename] = try storage.fileWriter.readData(from: locationURL)
        }

        return try PropertyListSerialization.data(
            fromPropertyList: files,
            format: .binary,
            options: 0
        )
    }

    static func decode(
        bundleURL: URL,
        expectedID: UUID,
        destinationDirectory: URL,
        fileWriter: any WatchFileWriting
    ) throws {
        let data = try fileWriter.readData(from: bundleURL)
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

        try fileWriter.createDirectory(at: destinationDirectory)
        try fileWriter.writeData(
            manifestData,
            to: destinationDirectory.appendingPathComponent(self.manifestFilename, isDirectory: false),
            options: .atomic
        )
        if let audioData = files[self.audioFilename] {
            try fileWriter.writeData(
                audioData,
                to: destinationDirectory.appendingPathComponent(self.audioFilename, isDirectory: false),
                options: .atomic
            )
        }
        if let locationData = files[self.locationFilename] {
            try fileWriter.writeData(
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

private extension WatchSegmentBundleCodec {
    static func decodeManifest(from data: Data) throws -> WatchSegmentManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WatchSegmentManifest.self, from: data)
    }
}

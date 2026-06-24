// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
final class WatchCaptureStorage {
    struct ManifestEntry: Equatable {
        let directoryURL: URL
        let manifestURL: URL
        let manifest: WatchSegmentManifest
    }

    static let rootDirectoryName = "WatchCapture"

    let rootURL: URL
    let fileWriter: any WatchFileWriting

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        rootURL: URL? = nil,
        fileWriter: any WatchFileWriting = FoundationWatchFileWriter(),
        fileManager: FileManager = .default
    ) throws {
        self.rootURL = try rootURL
            ?? AppGroupContainer.rootURL(fileManager: fileManager)
                .appendingPathComponent(Self.rootDirectoryName, isDirectory: true)
        self.fileWriter = fileWriter

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        try self.fileWriter.createDirectory(at: self.rootURL)
    }

    func dayString(for date: Date) -> String {
        Self.dayString(for: date)
    }

    func segmentString(for date: Date, durationSeconds: Double) -> String {
        Self.segmentString(for: date, durationSeconds: durationSeconds)
    }

    func provisionalSegmentString(for date: Date) -> String {
        Self.segmentString(for: date, durationSeconds: 1)
    }

    func segmentDirectoryURL(day: String, segment: String) -> URL {
        self.rootURL
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent(segment, isDirectory: true)
    }

    func audioURL(directory: URL) -> URL {
        directory.appendingPathComponent("audio.m4a", isDirectory: false)
    }

    func locationURL(directory: URL) -> URL {
        directory.appendingPathComponent("location.jsonl", isDirectory: false)
    }

    func manifestURL(directory: URL) -> URL {
        directory.appendingPathComponent("manifest.json", isDirectory: false)
    }

    func ensureSegmentDirectory(day: String, segment: String) throws -> URL {
        let directory = self.segmentDirectoryURL(day: day, segment: segment)
        if self.fileWriter.fileExists(at: directory) {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteFileExistsError,
                userInfo: [NSFilePathErrorKey: directory.path]
            )
        }
        try self.fileWriter.createDirectory(at: directory)
        return directory
    }

    func moveSegmentDirectoryIfNeeded(
        currentURL: URL,
        day: String,
        currentSegment: String,
        finalSegment: String
    ) throws -> URL {
        guard currentSegment != finalSegment else { return currentURL }
        let finalURL = self.segmentDirectoryURL(day: day, segment: finalSegment)
        try self.fileWriter.moveItem(at: currentURL, to: finalURL)
        return finalURL
    }

    func writeManifest(_ manifest: WatchSegmentManifest, in directory: URL) throws {
        let data = try self.encoder.encode(manifest)
        try self.fileWriter.writeData(data, to: self.manifestURL(directory: directory), options: .atomic)
    }

    func readManifest(from url: URL) throws -> WatchSegmentManifest {
        try self.decoder.decode(WatchSegmentManifest.self, from: self.fileWriter.readData(from: url))
    }

    func scanManifests() throws -> [ManifestEntry] {
        let dayDirectories = try self.fileWriter.contentsOfDirectory(at: self.rootURL)
            .filter { self.isDirectory($0) }
        var entries: [ManifestEntry] = []
        for dayDirectory in dayDirectories {
            let segmentDirectories = try self.fileWriter.contentsOfDirectory(at: dayDirectory)
                .filter { self.isDirectory($0) }
            for segmentDirectory in segmentDirectories {
                let manifestURL = self.manifestURL(directory: segmentDirectory)
                guard self.fileWriter.fileExists(at: manifestURL) else { continue }
                let manifest = try self.readManifest(from: manifestURL)
                entries.append(ManifestEntry(
                    directoryURL: segmentDirectory,
                    manifestURL: manifestURL,
                    manifest: manifest
                ))
            }
        }
        return entries.sorted { lhs, rhs in
            if lhs.manifest.day == rhs.manifest.day {
                return lhs.manifest.segment < rhs.manifest.segment
            }
            return lhs.manifest.day < rhs.manifest.day
        }
    }

    static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    static func segmentString(for date: Date, durationSeconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "HHmmss"
        return "\(formatter.string(from: date))_\(max(1, Int(durationSeconds.rounded())))"
    }
}

private extension WatchCaptureStorage {
    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

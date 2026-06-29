// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let mobileSegmentStoreLog = Logger(subsystem: "app.solstone.swift", category: "mobile-segment-store")

@MainActor
final class MobileSegmentStore {
    static let directoryName = "MobileSegment"
    static let appGroupRootMigrationFlag = "didMigrateMobileSegmentRootToAppGroupV1"

    let rootURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.rootURL = rootURL
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent(Self.directoryName, isDirectory: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func ensureRoot() throws {
        for url in [
            self.directoryURL(.active),
            self.directoryURL(.pending),
            self.directoryURL(.failed),
            self.tombstoneDirectory(kind: "uploaded"),
            self.tombstoneDirectory(kind: "empty"),
        ] {
            try self.fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    func directoryURL(_ lifecycle: MobileSegmentLifecycle) -> URL {
        self.rootURL.appendingPathComponent(lifecycle.rawValue, isDirectory: true)
    }

    func segmentDirectoryURL(_ lifecycle: MobileSegmentLifecycle, segmentID: UUID) -> URL {
        self.directoryURL(lifecycle).appendingPathComponent(segmentID.uuidString, isDirectory: true)
    }

    func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("manifest.json", isDirectory: false)
    }

    func audioURL(in directory: URL) -> URL {
        directory.appendingPathComponent("audio.m4a", isDirectory: false)
    }

    func locationURL(in directory: URL) -> URL {
        directory.appendingPathComponent("location.jsonl", isDirectory: false)
    }

    func screenURL(in directory: URL) -> URL {
        directory.appendingPathComponent("screen.mp4", isDirectory: false)
    }

    func screenPartURL(in directory: URL) -> URL {
        directory.appendingPathComponent("screen.mp4.part", isDirectory: false)
    }

    func artifactURL(in directory: URL, source: MobileSegmentSource) -> URL {
        switch source {
        case .audio:
            self.audioURL(in: directory)
        case .location:
            self.locationURL(in: directory)
        case .screencast:
            self.screenURL(in: directory)
        }
    }

    func requestUploadURL(in directory: URL) -> URL {
        directory.appendingPathComponent("request.upload", isDirectory: false)
    }

    func failureURL(in directory: URL) -> URL {
        directory.appendingPathComponent("failure.json", isDirectory: false)
    }

    func outcomesDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent("outcomes", isDirectory: true)
    }

    func outcomeURL(in directory: URL, source: MobileSegmentSource, state: MobileSegmentResolutionState) -> URL {
        let suffix: String
        switch state {
        case .finalizedArtifact:
            suffix = "finalized"
        case .noArtifact:
            suffix = "no-artifact"
        case .failedToFinalize:
            suffix = "failed-to-finalize"
        case .removed:
            suffix = "removed"
        case .notDeclared:
            suffix = "not-declared"
        case .unresolved:
            suffix = "unresolved"
        }
        return self.outcomesDirectory(in: directory)
            .appendingPathComponent("\(source.rawValue).\(suffix).json", isDirectory: false)
    }

    func createActive(manifest: MobileSegmentManifest) throws -> URL {
        try self.ensureRoot()
        let directory = self.segmentDirectoryURL(.active, segmentID: manifest.segmentID)
        try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try self.fileManager.createDirectory(at: self.outcomesDirectory(in: directory), withIntermediateDirectories: true)
        try self.writeManifest(manifest, in: directory)
        return directory
    }

    func readManifest(in directory: URL) throws -> MobileSegmentManifest {
        try self.decoder.decode(MobileSegmentManifest.self, from: Data(contentsOf: self.manifestURL(in: directory)))
    }

    func writeManifest(_ manifest: MobileSegmentManifest, in directory: URL) throws {
        try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try self.encoder.encode(manifest)
        try data.write(to: self.manifestURL(in: directory), options: .atomic)
    }

    func writeOutcome(
        _ resolution: MobileSegmentSourceResolution,
        source: MobileSegmentSource,
        manifest: inout MobileSegmentManifest,
        in directory: URL,
        now: Date
    ) throws {
        try self.fileManager.createDirectory(at: self.outcomesDirectory(in: directory), withIntermediateDirectories: true)
        let outcome = MobileSegmentOutcomeRecord(
            schema: MobileSegmentManifest.schemaName,
            segmentID: manifest.segmentID,
            source: source,
            resolution: resolution,
            recordedAt: now
        )
        let outcomeData = try self.encoder.encode(outcome)
        try outcomeData.write(to: self.outcomeURL(in: directory, source: source, state: resolution.state), options: .atomic)
        manifest.setResolution(resolution, for: source, now: now)
        try self.writeManifest(manifest, in: directory)
    }

    func writeFailure(_ failure: MobileSegmentFailureSidecar, in directory: URL) throws {
        let data = try self.encoder.encode(failure)
        try data.write(to: self.failureURL(in: directory), options: .atomic)
    }

    func loadFailure(in directory: URL) -> MobileSegmentFailureSidecar? {
        let url = self.failureURL(in: directory)
        guard self.fileManager.fileExists(atPath: url.path) else { return nil }
        return try? self.decoder.decode(MobileSegmentFailureSidecar.self, from: Data(contentsOf: url))
    }

    func move(segmentID: UUID, from source: MobileSegmentLifecycle, to destination: MobileSegmentLifecycle) throws -> URL {
        let sourceURL = self.segmentDirectoryURL(source, segmentID: segmentID)
        let destinationURL = self.segmentDirectoryURL(destination, segmentID: segmentID)
        try self.fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if self.fileManager.fileExists(atPath: destinationURL.path) {
            mobileSegmentStoreLog.error("mobile segment move collision \(segmentID.uuidString, privacy: .public) destination=\(destination.rawValue, privacy: .public)")
            throw MobileSegmentStoreError.destinationCollision(segmentID: segmentID, lifecycle: destination)
        }
        try self.fileManager.moveItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    func remove(_ directory: URL) throws {
        guard self.fileManager.fileExists(atPath: directory.path) else { return }
        try self.fileManager.removeItem(at: directory)
    }

    func writeTombstone(segmentID: UUID, kind: String, reason: String, now: Date) throws {
        let directory = self.tombstoneDirectory(kind: kind)
        try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let tombstone = MobileSegmentTombstone(segmentID: segmentID, reason: reason, recordedAt: now)
        let data = try self.encoder.encode(tombstone)
        try data.write(to: directory.appendingPathComponent("\(segmentID.uuidString).json", isDirectory: false), options: .atomic)
    }

    func tombstoneDirectory(kind: String) -> URL {
        self.rootURL
            .appendingPathComponent("tombstones", isDirectory: true)
            .appendingPathComponent(kind, isDirectory: true)
    }

    func list(_ lifecycle: MobileSegmentLifecycle) throws -> [URL] {
        let directory = self.directoryURL(lifecycle)
        guard self.fileManager.fileExists(atPath: directory.path) else { return [] }
        return try self.fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { self.isDirectory($0) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func findDirectory(segmentID: UUID) -> (lifecycle: MobileSegmentLifecycle, url: URL)? {
        for lifecycle in [MobileSegmentLifecycle.pending, .failed, .active] {
            let url = self.segmentDirectoryURL(lifecycle, segmentID: segmentID)
            if self.fileManager.fileExists(atPath: url.path) {
                return (lifecycle, url)
            }
        }
        return nil
    }

    func fileSize(at url: URL) -> Int64? {
        guard let size = try? self.fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    func fileExists(_ url: URL) -> Bool {
        self.fileManager.fileExists(atPath: url.path)
    }

    func moveOrReplaceItem(at source: URL, to destination: URL) throws {
        try self.fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if self.fileManager.fileExists(atPath: destination.path) {
            try self.fileManager.removeItem(at: destination)
        }
        try self.fileManager.moveItem(at: source, to: destination)
    }

    func copyOrReplaceItem(at source: URL, to destination: URL) throws {
        try self.fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if self.fileManager.fileExists(atPath: destination.path) {
            try self.fileManager.removeItem(at: destination)
        }
        try self.fileManager.copyItem(at: source, to: destination)
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try self.fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func removeIfExists(_ url: URL) {
        do {
            guard self.fileManager.fileExists(atPath: url.path) else { return }
            try self.fileManager.removeItem(at: url)
        } catch {
            mobileSegmentStoreLog.error("mobile segment remove failed stage=remove")
        }
    }

    func migrateRoot(
        fromLegacyCachesRoot legacyRoot: URL,
        defaults: UserDefaults? = .standard,
        fileManager: FileManager = .default
    ) -> [String] {
        guard defaults?.bool(forKey: Self.appGroupRootMigrationFlag) != true else { return [] }

        var diagnostics: [String] = []
        guard fileManager.fileExists(atPath: legacyRoot.path) else {
            defaults?.set(true, forKey: Self.appGroupRootMigrationFlag)
            return diagnostics
        }

        do {
            try self.ensureRoot()
        } catch {
            let diagnostic = "mobile segment root migration failed stage=ensure-root"
            diagnostics.append(diagnostic)
            mobileSegmentStoreLog.error("\(diagnostic, privacy: .public)")
            return diagnostics
        }

        for lifecycle in [MobileSegmentLifecycle.active, .pending, .failed] {
            let sourceRoot = legacyRoot.appendingPathComponent(lifecycle.rawValue, isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: sourceRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for sourceURL in entries where self.isDirectory(sourceURL) {
                guard let segmentID = UUID(uuidString: sourceURL.lastPathComponent) else { continue }
                let destinationURL = self.segmentDirectoryURL(lifecycle, segmentID: segmentID)
                diagnostics.append(contentsOf: self.migrateRootItem(
                    from: sourceURL,
                    to: destinationURL,
                    label: "lifecycle=\(lifecycle.rawValue) segment=\(segmentID.uuidString)",
                    fileManager: fileManager
                ))
            }
        }

        let legacyTombstones = legacyRoot.appendingPathComponent("tombstones", isDirectory: true)
        if let kinds = try? fileManager.contentsOfDirectory(
            at: legacyTombstones,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for kindDirectory in kinds where self.isDirectory(kindDirectory) {
                guard let tombstones = try? fileManager.contentsOfDirectory(
                    at: kindDirectory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for tombstoneURL in tombstones where tombstoneURL.pathExtension == "json" {
                    let destinationURL = self.tombstoneDirectory(kind: kindDirectory.lastPathComponent)
                        .appendingPathComponent(tombstoneURL.lastPathComponent, isDirectory: false)
                    diagnostics.append(contentsOf: self.migrateRootItem(
                        from: tombstoneURL,
                        to: destinationURL,
                        label: "tombstone=\(kindDirectory.lastPathComponent) file=\(tombstoneURL.lastPathComponent)",
                        fileManager: fileManager
                    ))
                }
            }
        }

        if diagnostics.isEmpty {
            defaults?.set(true, forKey: Self.appGroupRootMigrationFlag)
        }
        return diagnostics
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func migrateRootItem(
        from sourceURL: URL,
        to destinationURL: URL,
        label: String,
        fileManager: FileManager
    ) -> [String] {
        var diagnostics: [String] = []
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                if try self.contentsEqual(sourceURL, destinationURL, fileManager: fileManager) {
                    try fileManager.removeItem(at: sourceURL)
                } else {
                    let diagnostic = "mobile segment root migration collision \(label)"
                    diagnostics.append(diagnostic)
                    mobileSegmentStoreLog.error("\(diagnostic, privacy: .public)")
                }
                return diagnostics
            }

            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stagingURL = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".\(destinationURL.lastPathComponent).migrating", isDirectory: self.isDirectory(sourceURL))
            if fileManager.fileExists(atPath: stagingURL.path) {
                try fileManager.removeItem(at: stagingURL)
            }
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
            guard try self.contentsEqual(sourceURL, stagingURL, fileManager: fileManager) else {
                let diagnostic = "mobile segment root migration verify-failed \(label)"
                diagnostics.append(diagnostic)
                mobileSegmentStoreLog.error("\(diagnostic, privacy: .public)")
                return diagnostics
            }
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            guard try self.contentsEqual(sourceURL, destinationURL, fileManager: fileManager) else {
                let diagnostic = "mobile segment root migration verify-failed \(label)"
                diagnostics.append(diagnostic)
                mobileSegmentStoreLog.error("\(diagnostic, privacy: .public)")
                return diagnostics
            }
            try fileManager.removeItem(at: sourceURL)
        } catch {
            let diagnostic = "mobile segment root migration failed \(label)"
            diagnostics.append(diagnostic)
            mobileSegmentStoreLog.error("\(diagnostic, privacy: .public)")
        }
        return diagnostics
    }

    private struct FileSnapshotEntry: Equatable {
        let isDirectory: Bool
        let data: Data?
    }

    private func contentsEqual(_ lhs: URL, _ rhs: URL, fileManager: FileManager) throws -> Bool {
        try self.snapshot(lhs, fileManager: fileManager) == self.snapshot(rhs, fileManager: fileManager)
    }

    private func snapshot(_ url: URL, fileManager: FileManager) throws -> [String: FileSnapshotEntry] {
        if !self.isDirectory(url) {
            return [
                "": FileSnapshotEntry(
                    isDirectory: false,
                    data: try Data(contentsOf: url)
                ),
            ]
        }

        var snapshot: [String: FileSnapshotEntry] = ["": FileSnapshotEntry(isDirectory: true, data: nil)]
        let entries = try fileManager.subpathsOfDirectory(atPath: url.path)
        for relativePath in entries.sorted() {
            let entryURL = url.appendingPathComponent(relativePath)
            let isDirectory = self.isDirectory(entryURL)
            snapshot[relativePath] = FileSnapshotEntry(
                isDirectory: isDirectory,
                data: isDirectory ? nil : try Data(contentsOf: entryURL)
            )
        }
        return snapshot
    }
}

enum MobileSegmentStoreError: Error, Equatable {
    case destinationCollision(segmentID: UUID, lifecycle: MobileSegmentLifecycle)
}

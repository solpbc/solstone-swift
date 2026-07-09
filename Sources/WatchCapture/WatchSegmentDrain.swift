// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let watchSegmentDrainLog = Logger(subsystem: "app.solstone.swift", category: "watch-drain")

@MainActor
final class WatchSegmentDrain {
    private let stagingRootURL: URL
    private let ledger: WatchSegmentLedger
    private let transferEnqueuer: ObserverAudioTransferEnqueuer
    private let transferEngine: TransferEngine
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private let cooperator: MaintenanceCooperator
    private var inFlight: Set<UUID> = []

    init(
        stagingRootURL: URL? = nil,
        ledger: WatchSegmentLedger,
        transferEnqueuer: ObserverAudioTransferEnqueuer,
        transferEngine: TransferEngine,
        fileManager: FileManager = .default,
        cooperator: MaintenanceCooperator = MaintenanceCooperator()
    ) throws {
        self.stagingRootURL = try stagingRootURL
            ?? AppGroupContainer.rootURL(fileManager: fileManager)
                .appendingPathComponent(WatchRelayReceiver.rootDirectoryName, isDirectory: true)
                .appendingPathComponent(WatchRelayReceiver.stagingDirectoryName, isDirectory: true)
        self.ledger = ledger
        self.transferEnqueuer = transferEnqueuer
        self.transferEngine = transferEngine
        self.fileManager = fileManager
        self.cooperator = cooperator
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        try self.fileManager.createDirectory(at: self.stagingRootURL, withIntermediateDirectories: true)
    }

    func drain() async {
        let directories: [URL]
        do {
            directories = try self.fileManager.contentsOfDirectory(
                at: self.stagingRootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            watchSegmentDrainLog.error("watch drain enumeration failed: \(String(describing: error), privacy: .public)")
            return
        }

        for directory in directories where self.isDirectory(directory) {
            guard !Task.isCancelled else { return }
            await self.cooperator.step()
            guard !Task.isCancelled else { return }
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            if self.ledger.isTerminal(id: id) {
                self.removeStaged(id)
                continue
            }
            guard !self.inFlight.contains(id) else { continue }

            self.inFlight.insert(id)
            await self.drain(directory: directory, id: id)
        }
    }

    func removeStaged(_ id: UUID) {
        let directory = self.stagingRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try? self.fileManager.removeItem(at: directory)
        self.inFlight.remove(id)
        watchSegmentDrainLog.info("watch staged segment removed id=\(id.uuidString, privacy: .public)")
    }
}

private extension WatchSegmentDrain {
    func drain(directory: URL, id: UUID) async {
        defer {
            self.inFlight.remove(id)
        }

        do {
            let manifest = try self.loadManifest(in: directory)
            guard manifest.id == id else {
                watchSegmentDrainLog.error("watch drain manifest id mismatch id=\(id.uuidString, privacy: .public)")
                return
            }

            if await self.hasQueuedTransferItem(segmentID: id) {
                return
            }

            let audioURL = directory.appendingPathComponent(WatchSegmentBundleCodec.audioFilename, isDirectory: false)
            let locationURL = directory.appendingPathComponent(WatchSegmentBundleCodec.locationFilename, isDirectory: false)
            let audioData = self.fileManager.fileExists(atPath: audioURL.path)
                ? try Data(contentsOf: audioURL)
                : nil
            let locationData = self.fileManager.fileExists(atPath: locationURL.path)
                ? try Data(contentsOf: locationURL)
                : nil

            guard audioData != nil || locationData != nil else {
                watchSegmentDrainLog.debug("watch drain staged segment has no files id=\(id.uuidString, privacy: .public)")
                self.ledger.recordDropped(id: id)
                self.removeStaged(id)
                return
            }

            _ = try await self.transferEnqueuer.enqueueWatchSegment(
                manifest: manifest,
                audioData: audioData,
                locationData: locationData
            )
        } catch {
            watchSegmentDrainLog.error("watch drain failed id=\(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func hasQueuedTransferItem(segmentID: UUID) async -> Bool {
        let snapshots = await self.transferEngine.itemSnapshots(sourceKey: ObserverAudioTransferSource.watch)
        return snapshots.contains { snapshot in
            snapshot.manifest.observerIngest?.sessionID == segmentID
        }
    }

    func loadManifest(in directory: URL) throws -> WatchSegmentManifest {
        let url = directory.appendingPathComponent(WatchSegmentBundleCodec.manifestFilename, isDirectory: false)
        return try self.decoder.decode(WatchSegmentManifest.self, from: Data(contentsOf: url))
    }

    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

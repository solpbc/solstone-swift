// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let watchRelaySenderLog = Logger(subsystem: "app.solstone.swift", category: "watch-relay")

nonisolated enum WatchRelayACK {
    static let typeKey = "type"
    static let idKey = "id"
    static let type = "watch_segment_ack"

    static func userInfo(id: UUID) -> [String: Any] {
        [
            Self.typeKey: Self.type,
            Self.idKey: id.uuidString,
        ]
    }
}

@MainActor
final class WatchRelaySender {
    // 15 min — normal transfer→stage→ACK is seconds; 900s sits between the reducer
    // relay/handoff-stuck (600s) and orphan (1800s) thresholds so a stranded
    // .delivered self-heals before the orphan alarm without fighting a merely-slow ACK.
    // One constant, no config.
    private static let deliveredDeadline: TimeInterval = 900

    var onStateChanged: (@MainActor () -> Void)?

    private let storage: WatchCaptureStorage
    private let session: any WatchConnectivitySession
    private let clock: @MainActor @Sendable () -> Date

    init(
        storage: WatchCaptureStorage,
        session: any WatchConnectivitySession,
        clock: @escaping @MainActor @Sendable () -> Date = Date.init
    ) {
        self.storage = storage
        self.session = session
        self.clock = clock
        self.session.onReceiveUserInfo = { [weak self] userInfo in
            self?.handleUserInfo(userInfo)
        }
        self.session.onFileTransferFinished = { [weak self] id, errorDescription in
            self?.handleFileTransferFinished(id: id, errorDescription: errorDescription)
        }
    }

    func drain() {
        do {
            let entries = try self.storage.scanManifests()
            for entry in entries {
                switch entry.manifest.state {
                case .acked, .safeToDelete:
                    try self.deleteIfSafe(entry)
                case .delivered:
                    try self.refreshDeliveredDeadline(entry)
                case .captured, .persisted, .finalized, .queued, .transferring:
                    break
                }
            }

            guard self.session.activationState == .activated else { return }

            let refreshedEntries = try self.storage.scanManifests()
            let outstanding = self.groupedOutstandingFileTransfers()
            var manifestStatesByID: [UUID: WatchSegmentState] = [:]
            for entry in refreshedEntries {
                manifestStatesByID[entry.manifest.id] = entry.manifest.state
            }

            for entry in refreshedEntries {
                let group = outstanding.grouped[entry.manifest.id] ?? []
                switch entry.manifest.state {
                case .queued:
                    if group.isEmpty {
                        try self.promoteAndTransfer(entry: entry)
                    } else {
                        try self.adoptAsTransferring(entry)
                        self.cancelRedundant(group)
                    }
                case .transferring:
                    if group.isEmpty {
                        try self.transfer(directoryURL: entry.directoryURL, manifest: entry.manifest)
                    } else {
                        self.cancelRedundant(group)
                    }
                case .captured, .persisted, .finalized, .delivered, .acked, .safeToDelete:
                    break
                }
            }

            for id in outstanding.orderedIDs {
                guard let group = outstanding.grouped[id] else { continue }
                guard let id else {
                    self.cancelAll(group)
                    continue
                }
                guard let state = manifestStatesByID[id] else {
                    self.cancelAll(group)
                    continue
                }
                if state != .queued && state != .transferring {
                    self.cancelAll(group)
                }
            }
        } catch {
            watchRelaySenderLog.error("watch relay drain failed: \(String(describing: error), privacy: .public)")
        }
    }

    func bundleURL(for id: UUID) -> URL {
        self.bundleDirectoryURL()
            .appendingPathComponent("\(id.uuidString).watchrelay", isDirectory: false)
    }
}

private extension WatchRelaySender {
    func handleUserInfo(_ userInfo: [String: Any]) {
        guard userInfo[WatchRelayACK.typeKey] as? String == WatchRelayACK.type,
              let idString = userInfo[WatchRelayACK.idKey] as? String,
              let id = UUID(uuidString: idString)
        else {
            return
        }

        do {
            try self.acknowledge(id: id)
            self.drain()
        } catch {
            watchRelaySenderLog.error("watch relay ack failed: \(String(describing: error), privacy: .public)")
        }
    }

    func handleFileTransferFinished(id: UUID, errorDescription: String?) {
        do {
            let entries = try self.storage.scanManifests()
            guard let entry = entries.first(where: { $0.manifest.id == id }) else { return }
            var manifest = entry.manifest
            if let errorDescription {
                guard manifest.state == .transferring else { return }
                manifest.state = .queued
                try self.storage.writeManifest(manifest, in: entry.directoryURL)
                self.notifyStateChanged()
                watchRelaySenderLog.notice("watch relay transfer failed id=\(id.uuidString, privacy: .public): \(errorDescription, privacy: .public)")
                return
            }

            guard manifest.state == .transferring || manifest.state == .queued else { return }
            manifest.state = .delivered
            manifest.deliveredAt = self.clock()
            try self.storage.writeManifest(manifest, in: entry.directoryURL)
            self.notifyStateChanged()
        } catch {
            watchRelaySenderLog.error("watch relay finish handling failed: \(String(describing: error), privacy: .public)")
        }
    }

    func acknowledge(id: UUID) throws {
        let entries = try self.storage.scanManifests()
        guard let entry = entries.first(where: { $0.manifest.id == id }) else {
            try? self.storage.fileWriter.removeItem(at: self.bundleURL(for: id))
            return
        }

        var manifest = entry.manifest
        if manifest.state != .acked, manifest.state != .safeToDelete {
            manifest.state = .acked
            try self.storage.writeManifest(manifest, in: entry.directoryURL)
            self.notifyStateChanged()
        }

        manifest.state = .safeToDelete
        try self.storage.writeManifest(manifest, in: entry.directoryURL)
        self.notifyStateChanged()
        try self.storage.fileWriter.removeItem(at: entry.directoryURL)
        try? self.storage.fileWriter.removeItem(at: self.bundleURL(for: id))
        self.notifyStateChanged()
    }

    func deleteIfSafe(_ entry: WatchCaptureStorage.ManifestEntry) throws {
        var manifest = entry.manifest
        if manifest.state == .acked {
            manifest.state = .safeToDelete
            try self.storage.writeManifest(manifest, in: entry.directoryURL)
            self.notifyStateChanged()
        }
        try self.storage.fileWriter.removeItem(at: entry.directoryURL)
        try? self.storage.fileWriter.removeItem(at: self.bundleURL(for: manifest.id))
        self.notifyStateChanged()
    }

    func refreshDeliveredDeadline(_ entry: WatchCaptureStorage.ManifestEntry) throws {
        guard entry.manifest.state == .delivered else { return }
        var manifest = entry.manifest
        let now = self.clock()

        guard let deliveredAt = manifest.deliveredAt else {
            manifest.deliveredAt = now
            try self.storage.writeManifest(manifest, in: entry.directoryURL)
            self.notifyStateChanged()
            return
        }

        guard now.timeIntervalSince(deliveredAt) >= Self.deliveredDeadline else {
            return
        }

        manifest.state = .queued
        manifest.deliveredAt = nil
        try self.storage.writeManifest(manifest, in: entry.directoryURL)
        self.notifyStateChanged()
    }

    func promoteAndTransfer(entry: WatchCaptureStorage.ManifestEntry) throws {
        var manifest = entry.manifest
        manifest.state = .transferring
        try self.storage.writeManifest(manifest, in: entry.directoryURL)
        self.notifyStateChanged()
        try self.transfer(directoryURL: entry.directoryURL, manifest: manifest)
    }

    func adoptAsTransferring(_ entry: WatchCaptureStorage.ManifestEntry) throws {
        guard entry.manifest.state == .queued else { return }
        var manifest = entry.manifest
        manifest.state = .transferring
        try self.storage.writeManifest(manifest, in: entry.directoryURL)
        self.notifyStateChanged()
    }

    func transfer(directoryURL: URL, manifest: WatchSegmentManifest) throws {
        let bundleURL = self.bundleURL(for: manifest.id)
        try? self.storage.fileWriter.removeItem(at: bundleURL)
        try WatchSegmentBundleCodec.writeBundle(
            segmentDirectory: directoryURL,
            storage: self.storage,
            to: bundleURL
        )
        self.session.transferFile(bundleURL, metadata: WatchSegmentBundleCodec.metadata(for: manifest))
        watchRelaySenderLog.info("watch relay transfer enqueued id=\(manifest.id.uuidString, privacy: .public)")
    }

    func bundleDirectoryURL() -> URL {
        self.storage.rootURL.appendingPathComponent(".relay-bundles", isDirectory: true)
    }

    func groupedOutstandingFileTransfers() -> (
        grouped: Dictionary<UUID?, [OutstandingFileTransfer]>,
        orderedIDs: [UUID?]
    ) {
        var grouped: Dictionary<UUID?, [OutstandingFileTransfer]> = [:]
        var orderedIDs: [UUID?] = []
        for transfer in self.session.outstandingFileTransfers {
            if grouped[transfer.id] == nil {
                orderedIDs.append(transfer.id)
            }
            grouped[transfer.id, default: []].append(transfer)
        }
        return (grouped, orderedIDs)
    }

    func cancelRedundant(_ group: [OutstandingFileTransfer]) {
        guard group.count > 1 else { return }
        self.cancelAll(Array(group.dropFirst()))
    }

    func cancelAll(_ transfers: [OutstandingFileTransfer]) {
        for transfer in transfers {
            transfer.cancel()
        }
    }

    func notifyStateChanged() {
        self.onStateChanged?()
    }
}

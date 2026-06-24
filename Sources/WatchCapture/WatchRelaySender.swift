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
    static let maxInFlight = 1

    var onStateChanged: (@MainActor () -> Void)?

    private let storage: WatchCaptureStorage
    private let session: any WatchConnectivitySession

    init(storage: WatchCaptureStorage, session: any WatchConnectivitySession) {
        self.storage = storage
        self.session = session
        self.session.onReceiveUserInfo = { [weak self] userInfo in
            self?.handleUserInfo(userInfo)
        }
    }

    func drain() {
        do {
            let entries = try self.storage.scanManifests()
            for entry in entries {
                switch entry.manifest.state {
                case .acked, .safeToDelete:
                    try self.deleteIfSafe(entry)
                case .captured, .persisted, .finalized, .queued, .transferring, .delivered:
                    break
                }
            }

            let refreshedEntries = try self.storage.scanManifests()
            if let transferring = refreshedEntries.first(where: { $0.manifest.state == .transferring }) {
                try self.transfer(entry: transferring)
                return
            }

            let inFlightCount = refreshedEntries.filter { $0.manifest.state == .transferring }.count
            guard inFlightCount < Self.maxInFlight else { return }
            guard let queued = refreshedEntries.first(where: { $0.manifest.state == .queued }) else { return }
            try self.promoteAndTransfer(entry: queued)
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

    func promoteAndTransfer(entry: WatchCaptureStorage.ManifestEntry) throws {
        var manifest = entry.manifest
        manifest.state = .transferring
        try self.storage.writeManifest(manifest, in: entry.directoryURL)
        self.notifyStateChanged()
        try self.transfer(directoryURL: entry.directoryURL, manifest: manifest)
    }

    func transfer(entry: WatchCaptureStorage.ManifestEntry) throws {
        try self.transfer(directoryURL: entry.directoryURL, manifest: entry.manifest)
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

    func notifyStateChanged() {
        self.onStateChanged?()
    }
}

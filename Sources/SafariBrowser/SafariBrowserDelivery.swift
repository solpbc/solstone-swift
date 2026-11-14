// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CryptoKit
import os

actor SafariBrowserSourceGate: TransferSourceGate {
    let calendar: CalendarCapabilityGate
    let obsidian: (any TransferSourceGate)?
    let screenshots: (any TransferSourceGate)?

    init(
        calendar: CalendarCapabilityGate,
        obsidian: (any TransferSourceGate)? = nil,
        screenshots: (any TransferSourceGate)? = nil
    ) {
        self.calendar = calendar
        self.obsidian = obsidian
        self.screenshots = screenshots
    }

    func admits(manifest: TransferManifest, endpoint: TransferResolvedEndpoint) async -> Bool {
        if manifest.sourceKey == "browser" {
            do { return try SafariBrowserStore().admitsDispatch() }
            catch { return false }
        }
        if let obsidian, manifest.sourceKey == "obsidian" {
            return await obsidian.admits(manifest: manifest, endpoint: endpoint)
        }
        // Before the calendar gate: that gate admits every source it does not know.
        if let screenshots, manifest.sourceKey == ScreenshotsWire.sourceKey {
            return await screenshots.admits(manifest: manifest, endpoint: endpoint)
        }
        return await self.calendar.admits(manifest: manifest, endpoint: endpoint)
    }
}

/// Decides whether the app's Safari pass has anything to do. The app runs the pass every
/// few seconds for as long as it runs, and opening the store writes to disk even when
/// nothing has changed. So the pass opens the store only when the store's files, the
/// confirmation the app publishes, or what the send queue holds for Safari have moved
/// since the last pass that ran.
@MainActor
final class SafariPassGate {
    private struct FileState: Equatable {
        let size: Int
        let modified: Date
    }

    private struct Key: Equatable {
        let files: [FileState?]
        let confirmed: Bool
        let queued: Int
    }

    private let rootURL: () throws -> URL
    private var last: Key?

    init(rootURL: @escaping () throws -> URL = { SafariBrowserStore.root(inContainer: try AppGroupContainer.rootURL()) }) {
        self.rootURL = rootURL
    }

    /// When it answers yes, this pass becomes the one the next call compares against.
    func shouldRun(confirmed: Bool, queued: Int) -> Bool {
        guard let root = try? self.rootURL() else {
            self.last = nil
            return true
        }
        let name = SafariBrowserStore.databaseFilename
        let files = [name, name + "-wal"].map { file -> FileState? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(file).path),
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            return FileState(size: size, modified: modified)
        }
        let key = Key(files: files, confirmed: confirmed, queued: queued)
        guard key != self.last else { return false }
        self.last = key
        return true
    }

    /// A pass that failed runs again at the next call.
    func forget() {
        self.last = nil
    }
}

@MainActor
enum SafariBrowserDelivery {
    /// What the send queue still holds for Safari.
    static func queuedBytes(engine: TransferEngine) async -> Int {
        await engine.itemSnapshots(sourceKey: "browser")
            .reduce(0) { $0 + $1.manifest.payloadParts.reduce(0) { $0 + ($1.byteCount ?? 0) } }
    }

    /// Returns false when the store could not be read or written, so the caller tries again.
    @discardableResult
    static func drain(engine: TransferEngine, store suppliedStore: SafariBrowserStore? = nil,
                      beforeAdoption: (() throws -> Void)? = nil) async -> Bool {
        do {
            let store = try suppliedStore ?? SafariBrowserStore()
            for period in try store.prepareHandoffs() {
                guard let id = UUID(uuidString: period.id) else { throw SafariBrowserError.storage }
                let zone = TimeZone(identifier: period.zone) ?? TimeZone(secondsFromGMT: 0)!
                let start = Date(timeIntervalSince1970: period.started.rounded(.down))
                let duration = max(1, Int(ceil(period.ended - start.timeIntervalSince1970)))
                let dayFormat = DateFormatter()
                dayFormat.locale = Locale(identifier: "en_US_POSIX")
                dayFormat.calendar = Calendar(identifier: .gregorian)
                dayFormat.timeZone = zone
                dayFormat.dateFormat = "yyyyMMdd"
                let day = dayFormat.string(from: start)
                dayFormat.dateFormat = "HHmmss"
                let segment = "\(dayFormat.string(from: start))_\(duration)"
                let filename = "browser_pages.jsonl"
                let sha = SHA256.hash(data: period.payload).map { String(format: "%02x", $0) }.joined()
                let manifest = TransferManifest(itemID: id, source: "browser", createdAt: start,
                    priority: TransferPriorityInputs(basePriority: .low, sourceKey: "browser"),
                    payloadParts: [TransferPayloadPartDescriptor(partID: "browser", kind: .file,
                        relativePath: filename, filename: filename, contentType: "application/x-ndjson",
                        byteCount: period.payload.count, contentHash: sha)],
                    endpoint: TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest"),
                    observerIngest: TransferObserverIngestMetadata(platform: "ios", segment: segment,
                        day: day, startedAt: start, durationS: Double(duration), sources: ["browser"],
                        ingestProtocolVersion: 3, tz: zone.identifier, utcOffsetSeconds: zone.secondsFromGMT(for: start)))
                let stage = store.root.appendingPathComponent("handoff-\(period.id).jsonl")
                try period.payload.write(to: stage, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                defer { try? FileManager.default.removeItem(at: stage) }
                _ = try await engine.enqueueIfAbsent(manifest: manifest, payloadFileURLs: ["browser": stage])
                try beforeAdoption?()
                try store.adopt(id: period.id)
            }
            await engine.kick()
            // Status only: what the send queue still holds for this source.
            try store.setQueuedBytes(await self.queuedBytes(engine: engine))
            return true
        } catch {
            Logger(subsystem: "app.solstone.swift", category: "safari").error("Safari handoff waits for storage recovery")
            return false
        }
    }
}

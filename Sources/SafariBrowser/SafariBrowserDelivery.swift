// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import CryptoKit
import os

actor SafariBrowserSourceGate: TransferSourceGate {
    let calendar: CalendarCapabilityGate
    init(calendar: CalendarCapabilityGate) { self.calendar = calendar }
    func admits(sourceKey: String, endpoint: TransferResolvedEndpoint) async -> Bool {
        if sourceKey == "browser" {
            do { return try SafariBrowserStore().admitsDispatch() }
            catch { return false }
        }
        return await self.calendar.admits(sourceKey: sourceKey, endpoint: endpoint)
    }
}

@MainActor
enum SafariBrowserDelivery {
    static func drain(engine: TransferEngine, store suppliedStore: SafariBrowserStore? = nil,
                      beforeAdoption: (() throws -> Void)? = nil) async {
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
        } catch {
            Logger(subsystem: "app.solstone.swift", category: "safari").error("Safari handoff waits for storage recovery")
        }
    }
}

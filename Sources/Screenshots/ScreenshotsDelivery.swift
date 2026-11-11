// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let screenshotsDeliveryLog = Logger(subsystem: "app.solstone.swift", category: "screenshots")

nonisolated enum ScreenshotsTransfer {
    static let partID = "screenshot"

    static func manifest(for upload: ScreenshotsUpload) -> TransferManifest {
        TransferManifest(
            itemID: upload.itemID,
            source: ScreenshotsWire.sourceKey,
            createdAt: upload.created,
            priority: TransferPriorityInputs(basePriority: .low, sourceKey: ScreenshotsWire.sourceKey),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: Self.partID,
                    kind: .file,
                    relativePath: upload.filename,
                    filename: upload.filename,
                    contentType: upload.contentType,
                    byteCount: upload.bytes.count,
                    contentHash: upload.hash
                ),
            ],
            endpoint: TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest"),
            observerIngest: TransferObserverIngestMetadata(
                platform: "ios",
                segment: upload.segment,
                day: upload.day,
                startedAt: upload.created,
                durationS: 1,
                sources: [ScreenshotsWire.sourceKey],
                ingestProtocolVersion: 3,
                tz: upload.timeZoneIdentifier,
                utcOffsetSeconds: upload.offsetSeconds,
                screenshot: TransferScreenshotMeta(
                    v: 1,
                    capturedAt: upload.capturedAt,
                    takenFrom: "platform"
                )
            ),
            meta: .object([
                "local_id": .string(upload.localIdentifier),
                "sha256": .string(upload.hash),
            ]),
            appVersion: AppVersion.shortVersion
        )
    }

    static func localIdentifier(_ manifest: TransferManifest) -> String? {
        guard case .object(let fields) = manifest.meta, case .string(let value) = fields["local_id"] else { return nil }
        return value
    }

    static func hash(_ manifest: TransferManifest) -> String? {
        guard case .object(let fields) = manifest.meta, case .string(let value) = fields["sha256"] else { return nil }
        return value
    }
}

@MainActor
final class ScreenshotsTransferDelivery: ScreenshotsSending {
    private let engine: TransferEngine
    private let stagingURL: URL
    private let fileManager: FileManager

    init(engine: TransferEngine, stagingURL: URL, fileManager: FileManager = .default) {
        self.engine = engine
        self.stagingURL = stagingURL
        self.fileManager = fileManager
    }

    func send(_ upload: ScreenshotsUpload) async throws {
        try self.fileManager.createDirectory(at: self.stagingURL, withIntermediateDirectories: true)
        let url = self.stagingURL.appendingPathComponent(upload.itemID.uuidString)
        try upload.bytes.write(to: url, options: .atomic)
        defer { try? self.fileManager.removeItem(at: url) }
        _ = try await self.engine.enqueueIfAbsent(
            manifest: ScreenshotsTransfer.manifest(for: upload),
            payloadFileURLs: [ScreenshotsTransfer.partID: url]
        )
    }
}

/// Holds screenshots until the paired journal lists the capability. A failed read is not
/// "not listed". Other sources are not held.
actor ScreenshotsCapabilityGate: TransferSourceGate {
    nonisolated enum Capability: Equatable, Sendable {
        case unknown
        case listed
        case notListed
    }

    private let read: @Sendable (TransferResolvedEndpoint) async -> JournalStatusReport
    private let isCurrent: @Sendable (TransferResolvedEndpoint) async -> Bool
    private let retryDelay: Duration
    private var wake: (@Sendable () async -> Void)?
    private var publish: (@Sendable (Capability) -> Void)?
    private var endpoint: TransferResolvedEndpoint?
    private var capability: Capability = .unknown
    private var generation: UInt64 = 0
    private var reading = false
    private var retryScheduled = false
    private var journal: (identity: String?, version: String?) = (nil, nil)

    init(
        read: @escaping @Sendable (TransferResolvedEndpoint) async -> JournalStatusReport,
        isCurrent: @escaping @Sendable (TransferResolvedEndpoint) async -> Bool = { _ in true },
        retryDelay: Duration = .seconds(30)
    ) {
        self.read = read
        self.isCurrent = isCurrent
        self.retryDelay = retryDelay
    }

    func connect(wake: @escaping @Sendable () async -> Void, publish: @escaping @Sendable (Capability) -> Void) {
        self.wake = wake
        self.publish = publish
    }

    func admits(manifest: TransferManifest, endpoint: TransferResolvedEndpoint) async -> Bool {
        guard manifest.sourceKey == ScreenshotsWire.sourceKey else { return true }
        if self.endpoint != endpoint {
            self.endpoint = endpoint
            self.reset()
        }
        switch self.capability {
        case .listed:
            return true
        case .notListed:
            return false
        case .unknown:
            self.startRead()
            return false
        }
    }

    func journalChanged(identity: String?, version: String?) async {
        guard identity != self.journal.identity || version != self.journal.version else { return }
        self.journal = (identity, version)
        self.reset()
        await self.wake?()
    }

    private func reset() {
        self.generation &+= 1
        self.reading = false
        self.retryScheduled = false
        self.set(.unknown)
    }

    private func set(_ capability: Capability) {
        guard self.capability != capability else { return }
        self.capability = capability
        self.publish?(capability)
    }

    private func startRead() {
        guard !self.reading, !self.retryScheduled, let endpoint = self.endpoint else { return }
        self.reading = true
        let generation = self.generation
        let read = self.read
        Task {
            let report = await read(endpoint)
            await self.finishRead(report, endpoint: endpoint, generation: generation)
        }
    }

    private func finishRead(_ report: JournalStatusReport, endpoint: TransferResolvedEndpoint, generation: UInt64) async {
        guard generation == self.generation, endpoint == self.endpoint else { return }
        let current = await self.isCurrent(endpoint)
        guard generation == self.generation, endpoint == self.endpoint else { return }
        self.reading = false
        guard current else {
            self.scheduleRetry()
            return
        }
        switch report {
        case .failed:
            screenshotsDeliveryLog.notice("screenshots capability read failed")
            self.scheduleRetry()
        case .read:
            let listed = report.lists(ScreenshotsWire.capability)
            self.set(listed ? .listed : .notListed)
            if listed { await self.wake?() }
        }
    }

    private func scheduleRetry() {
        guard !self.retryScheduled else { return }
        self.retryScheduled = true
        let delay = self.retryDelay
        let generation = self.generation
        Task {
            try? await Task.sleep(for: delay)
            await self.retryFired(generation: generation)
        }
    }

    private func retryFired(generation: UInt64) async {
        guard generation == self.generation else { return }
        self.retryScheduled = false
        await self.wake?()
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

nonisolated private let calendarDeliveryLog = Logger(subsystem: "app.solstone.swift", category: "calendar")

nonisolated enum CalendarTransfer {
    /// The bound source a journal recognises a calendar stream by.
    static let sourceKey = ObserverAudioTransferSource.calendar
    static let partID = "calendar"
    static let contentType = "application/x-ndjson"
    /// What a journal lists in its status response when it takes calendar notes.
    static let capability = "calendar_notes"

    /// The transfer item for one calendar note file. Everything in it comes from the file, so
    /// queuing the same file again finds the item already there.
    static func manifest(for pending: CalendarPendingFile) -> TransferManifest {
        let file = pending.file
        return TransferManifest(
            itemID: file.itemID,
            source: Self.sourceKey,
            createdAt: file.window.start,
            priority: TransferPriorityInputs(basePriority: .low, sourceKey: Self.sourceKey),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: Self.partID,
                    kind: .file,
                    relativePath: file.name,
                    filename: file.name,
                    contentType: Self.contentType,
                    byteCount: file.bytes.count,
                    contentHash: file.sha256
                ),
            ],
            endpoint: TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest"),
            observerIngest: TransferObserverIngestMetadata(
                platform: "ios",
                segment: file.window.segment,
                day: file.window.day,
                startedAt: file.window.start,
                durationS: TimeInterval(CalendarWindow.length),
                sources: [Self.sourceKey],
                ingestProtocolVersion: 3,
                tz: pending.timeZoneIdentifier,
                utcOffsetSeconds: file.window.offsetSeconds
            ),
            meta: .object([
                "source": .string(Self.sourceKey),
                "notes": .int(file.lineCount),
            ]),
            appVersion: AppVersion.shortVersion
        )
    }

    static func noteCount(_ manifest: TransferManifest) -> Int {
        if case .object(let fields) = manifest.meta, case .int(let count) = fields["notes"] {
            return count
        }
        return 0
    }
}

/// Where the source's files go once a step is written.
@MainActor
protocol CalendarNoteDelivering: AnyObject {
    /// Queues one file. Queuing a file that is already queued does nothing.
    func deliver(_ file: CalendarPendingFile) async throws
    /// Calendar files queued and not yet in the journal.
    func queuedFileCount() async -> Int
    /// Removes what a kill left half-staged. Called at launch, before a step is replayed.
    func clearStaging()
}

/// Calendar files go through the transfer engine, as the watch's audio does.
@MainActor
final class CalendarTransferDelivery: CalendarNoteDelivering {
    private let engine: TransferEngine
    private let stagingURL: URL
    private let fileManager: FileManager

    init(engine: TransferEngine, stagingURL: URL, fileManager: FileManager = .default) {
        self.engine = engine
        self.stagingURL = stagingURL
        self.fileManager = fileManager
    }

    func deliver(_ pending: CalendarPendingFile) async throws {
        try self.fileManager.createDirectory(at: self.stagingURL, withIntermediateDirectories: true)
        let url = self.stagingURL.appendingPathComponent("\(UUID().uuidString)-\(pending.file.name)")
        try pending.file.bytes.write(to: url, options: .atomic)
        defer { try? self.fileManager.removeItem(at: url) }
        _ = try await self.engine.enqueueIfAbsent(
            manifest: CalendarTransfer.manifest(for: pending),
            payloadFileURLs: [CalendarTransfer.partID: url]
        )
    }

    func clearStaging() {
        guard let names = try? self.fileManager.contentsOfDirectory(atPath: self.stagingURL.path) else { return }
        for name in names {
            try? self.fileManager.removeItem(at: self.stagingURL.appendingPathComponent(name))
        }
    }

    func queuedFileCount() async -> Int {
        await self.engine.itemSnapshots(sourceKey: CalendarTransfer.sourceKey)
            .filter { $0.state != .attention }
            .count
    }
}

/// Holds calendar files on the device until the journal the phone is paired with now has said
/// it takes them. It holds only calendar items, and never holds the transfer engine as a whole,
/// so every other source keeps moving.
///
/// What the journal said counts only for the endpoint it was read from: a new connection, a
/// new pairing or a relaunch starts again from "not known", and so does a change of the
/// journal's version. A read that fails is tried again later and never counts as "not listed".
actor CalendarCapabilityGate: TransferSourceGate {
    nonisolated enum Capability: Equatable, Sendable {
        /// Not read from the current journal yet, or the last read failed.
        case unknown
        case listed
        /// A successful read from the current journal did not list calendar notes.
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
    /// Status reads made. For tests.
    private(set) var readCount = 0

    init(
        read: @escaping @Sendable (TransferResolvedEndpoint) async -> JournalStatusReport,
        isCurrent: @escaping @Sendable (TransferResolvedEndpoint) async -> Bool = { _ in true },
        retryDelay: Duration = .seconds(30)
    ) {
        self.read = read
        self.isCurrent = isCurrent
        self.retryDelay = retryDelay
    }

    /// `wake` asks the transfer engine to look at its queue again; `publish` reports what is
    /// known about the current journal.
    func connect(
        wake: @escaping @Sendable () async -> Void,
        publish: @escaping @Sendable (Capability) -> Void
    ) {
        self.wake = wake
        self.publish = publish
    }

    var currentCapability: Capability {
        self.capability
    }

    func admits(sourceKey: String, endpoint: TransferResolvedEndpoint) async -> Bool {
        guard sourceKey == CalendarTransfer.sourceKey else { return true }
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

    /// The paired journal or its version changed: read the capability again.
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

    /// One read at a time, and none while a failed read waits for its retry.
    private func startRead() {
        guard !self.reading, !self.retryScheduled, let endpoint = self.endpoint else { return }
        self.reading = true
        self.readCount += 1
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
            calendarDeliveryLog.notice("calendar capability read failed; notes wait")
            self.scheduleRetry()
        case .read:
            let listed = report.lists(CalendarTransfer.capability)
            calendarDeliveryLog.notice("calendar capability read listed=\(listed, privacy: .public)")
            self.set(listed ? .listed : .notListed)
            if listed {
                await self.wake?()
            }
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

/// The calendar source's place in the phone's counts of what is waiting.
@MainActor
@Observable
final class CalendarTransferHolder {
    let transferEngine: TransferEngine
    private let mirror: TransferStatusMirror
    /// What the paired journal said about calendar notes, as last published by the gate.
    var capability: CalendarCapabilityGate.Capability = .unknown
    /// Calendar notes in files not yet in the journal, and in files the journal turned away.
    private(set) var notesWaiting = 0
    private(set) var notesNeedingAttention = 0

    init(transferEngine: TransferEngine, mirror: TransferStatusMirror) {
        self.transferEngine = transferEngine
        self.mirror = mirror
    }

    var pendingCount: Int { self.status.queuedCount }
    var failedCount: Int { self.status.attentionCount }
    var refusalPacedCount: Int { self.status.refusalPacedCount }
    var inFlightCount: Int { self.status.inFlightCount }
    var confirmedActiveTransferCount: Int { self.status.inFlightCount }
    var recentBytesPerSecond: Double { self.status.bytesPerSecond }
    var lastUploadAt: Date? { self.status.lastDeliveredAt }
    var deliveredCount: Int { self.status.deliveredCount }

    /// Waiting files held only because the journal said it does not take calendar notes. A
    /// drain does not wait for these: nothing it does can send them. Before the journal has been
    /// read, or when a read failed, they are ordinary waiting files.
    var heldForJournalCount: Int {
        self.capability == .notListed ? max(0, self.pendingCount - self.inFlightCount) : 0
    }

    /// The journal was read and does not take calendar notes yet.
    var waitingForJournalUpdate: Bool {
        self.capability == .notListed && self.pendingCount > 0
    }

    func refreshNoteCounts() async {
        let snapshots = await self.transferEngine.itemSnapshots(sourceKey: CalendarTransfer.sourceKey)
        self.notesWaiting = snapshots.filter { $0.state != .attention }.reduce(0) { $0 + CalendarTransfer.noteCount($1.manifest) }
        self.notesNeedingAttention = snapshots.filter { $0.state == .attention }.reduce(0) { $0 + CalendarTransfer.noteCount($1.manifest) }
    }

    func syncStateDetail() async -> SourceSyncStateDetail {
        await SourceSyncStateDetail.build(from: self.transferEngine, sourceKey: CalendarTransfer.sourceKey)
    }

    func onThisPhoneSourceSnapshot() async -> OnThisPhoneSourceResult {
        let snapshots = await self.transferEngine.itemSnapshots(sourceKey: CalendarTransfer.sourceKey)
        return .loaded(items: OnThisPhoneItemSort.newestFirst(CalendarTransferHolder.items(snapshots: snapshots)))
    }

    nonisolated static func items(snapshots: [TransferItemSnapshot]) -> [OnThisPhoneItem] {
        snapshots.map { snapshot in
            let manifest = snapshot.manifest
            let part = manifest.payloadParts.first
            let attention = manifest.attention
            return OnThisPhoneItem(
                id: OnThisPhoneItemID.calendarTransferIDString(itemID: snapshot.itemID),
                sourceKind: .calendar,
                sendState: OnThisPhoneSendState(transferState: snapshot.state),
                contentType: part?.contentType,
                filename: part?.filename,
                bytes: part?.byteCount.map(Int64.init),
                originApp: nil,
                basis: nil,
                itemTime: manifest.observerIngest?.startedAt ?? manifest.createdAt,
                targetJournal: nil,
                stream: nil,
                day: manifest.observerIngest?.day,
                segment: manifest.observerIngest?.segment,
                deliveredAt: nil,
                rawFileURL: nil,
                failureReason: attention.map(\.ownerFailureReason),
                failureAttemptCount: snapshot.attempts > 0 ? snapshot.attempts : nil,
                retryAvailable: snapshot.state == .attention,
                lastAttemptAt: attention?.movedAt,
                refusalPaced: snapshot.refusalPaced
            )
        }
    }

    private var status: TransferSourceStatusSnapshot {
        self.mirror.sources[CalendarTransfer.sourceKey] ?? TransferSourceStatusSnapshot(
            queuedCount: 0,
            attentionCount: 0,
            inFlightCount: 0,
            deliveredCount: 0,
            droppedCount: 0,
            lastDeliveredAt: nil,
            lastErrorDetail: nil,
            recentErrorCount: 0,
            bytesPerSecond: 0
        )
    }
}

extension OnThisPhoneSendState {
    nonisolated init(transferState state: TransferRuntimeState) {
        switch state {
        case .queued, .held, .paused, .salvaged, .dropped, .staged:
            self = .savedOnThisPhone
        case .dispatching:
            self = .sending
        case .attention:
            self = .needsAttention
        case .delivered:
            self = .inYourJournal
        }
    }
}

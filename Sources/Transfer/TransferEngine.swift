// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let transferLog = Logger(subsystem: "app.solstone.swift", category: "transfer")
nonisolated private let transferStatusCoalescingDelay: Duration = .milliseconds(250)

typealias TransferBodyBuilder = @Sendable (TransferStoredItem, TransferSpool) async throws -> Data
typealias TransferDeliveredHook = @Sendable (TransferManifest, TransferSuccessKind) async throws -> Void

nonisolated private struct TransferDispatchLogState: Equatable, Sendable {
    var decision: TransferDispatchDecision
    var conditions: TransferDispatchConditions
    var mode: TransferPacingMode
}

nonisolated private struct TransferDispatchAssessment: Sendable {
    var decision: TransferDispatchDecision
    var logState: TransferDispatchLogState?
}

nonisolated private func transferPacingModeString(_ mode: TransferPacingMode) -> String {
    switch mode {
    case .normal:
        "normal"
    case .finishSyncing:
        "finishSyncing"
    }
}

nonisolated private func transferDispatchDelayString(_ duration: Duration) -> String {
    let components = duration.components
    let seconds = Double(components.seconds) + (Double(components.attoseconds) / 1_000_000_000_000_000_000)
    return String(format: "%.3fs", seconds)
}

nonisolated enum TransferBodyBuildError: Error, Equatable, Sendable {
    case missingObserverMetadata
    case missingPayload(String)
    case malformedManifest(String)
    case saveRequestUnsupported
}

nonisolated enum TransferPriorityBand: Int, CaseIterable, Sendable {
    case fresh = 0
    case high = 1
    case normal = 2
    case low = 3
}

nonisolated enum DefaultTransferBodyBuilder {
    static func build(item: TransferStoredItem, spool: TransferSpool) throws -> Data {
        switch item.manifest.endpoint.destinationKind {
        case .observerIngest:
            guard let ingest = item.manifest.observerIngest else {
                throw TransferBodyBuildError.missingObserverMetadata
            }
            var audioData: Data?
            var locationData: Data?
            var screenData: Data?
            for part in item.manifest.payloadParts {
                func dataIfAvailable() throws -> Data? {
                    do {
                        return try spool.payloadData(for: part, in: item)
                    } catch {
                        if part.requiredForDispatch {
                            throw TransferBodyBuildError.missingPayload(part.filename)
                        }
                        return nil
                    }
                }
                switch part.kind {
                case .audio:
                    audioData = try dataIfAvailable()
                case .location:
                    locationData = try dataIfAvailable()
                case .screen:
                    screenData = try dataIfAvailable()
                case .file, .text:
                    break
                }
            }
            return try ObserverIngestMultipartBody.build(input: ObserverIngestMultipartInput(
                boundary: TransferTransport.boundary(for: item.manifest.itemID),
                platform: ingest.platform,
                segment: ingest.segment,
                day: ingest.day,
                startedAt: ingest.startedAt,
                durationS: ingest.durationS,
                sources: ingest.sources,
                chunkIndex: ingest.chunkIndex,
                sessionID: ingest.sessionID,
                modeRawValue: ingest.modeRawValue,
                segmentID: ingest.segmentID,
                artifacts: ObserverIngestMultipartArtifacts(
                    audioData: audioData,
                    locationJSONL: locationData,
                    screenData: screenData
                )
            ))
        case .saveThenStart:
            if item.manifest.saveThenStart?.phase == .startPending {
                guard let savedPath = item.manifest.saveThenStart?.savedPath, !savedPath.isEmpty,
                      let savedTimestamp = item.manifest.saveThenStart?.savedTimestamp, !savedTimestamp.isEmpty
                else {
                    throw TransferBodyBuildError.malformedManifest("missing save result")
                }
                let body = TransferStartRequestBody(
                    path: savedPath,
                    timestamp: savedTimestamp
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                return try encoder.encode(body)
            }
            throw TransferBodyBuildError.saveRequestUnsupported
        }
    }
}

nonisolated private struct TransferStartRequestBody: Encodable {
    let path: String
    let timestamp: String
}

nonisolated private struct TransferByteSample: Equatable, Sendable {
    var bytes: Int
    var at: Date
}

nonisolated private struct TransferByteWindow: Equatable, Sendable {
    static let windowSeconds: TimeInterval = 15
    static let maxEntries = 256

    private var samples: [TransferByteSample] = []

    mutating func noteDelivered(bytes: Int, at: Date) {
        guard bytes > 0 else { return }
        self.samples.append(TransferByteSample(bytes: bytes, at: at))
        self.prune(now: at)
    }

    func bytesPerSecond(now: Date) -> Double {
        let threshold = now.addingTimeInterval(-Self.windowSeconds)
        let total = self.samples.reduce(0) { total, sample in
            sample.at > threshold ? total + sample.bytes : total
        }
        return Double(total) / Self.windowSeconds
    }

    private mutating func prune(now: Date) {
        let threshold = now.addingTimeInterval(-Self.windowSeconds)
        self.samples.removeAll { $0.at <= threshold }
        if self.samples.count > Self.maxEntries {
            self.samples.removeFirst(self.samples.count - Self.maxEntries)
        }
    }
}

nonisolated private struct TransferSourceRuntimeState: Equatable, Sendable {
    static let maxEntries = 256

    var counters = TransferCounters.empty
    var lastDeliveredAt: Date?
    var lastErrorDetail: String?
    var recentErrorTimes: [Date] = []
    var byteWindow = TransferByteWindow()

    mutating func noteError(detail: String, at: Date) {
        self.lastErrorDetail = detail
        self.recentErrorTimes.append(at)
        if self.recentErrorTimes.count > Self.maxEntries {
            self.recentErrorTimes.removeFirst(self.recentErrorTimes.count - Self.maxEntries)
        }
    }

    mutating func noteDelivered(bytes: Int, at: Date) {
        self.lastDeliveredAt = at
        self.byteWindow.noteDelivered(bytes: bytes, at: at)
    }

    func snapshot(now: Date) -> TransferSourceStatusSnapshot {
        TransferSourceStatusSnapshot(
            queuedCount: self.counters.queuedCount,
            attentionCount: self.counters.attentionCount,
            inFlightCount: self.counters.inFlightCount,
            deliveredCount: self.counters.deliveredCount,
            droppedCount: self.counters.droppedCount,
            lastDeliveredAt: self.lastDeliveredAt,
            lastErrorDetail: self.lastErrorDetail,
            recentErrorCount: self.recentErrorTimes.count,
            bytesPerSecond: self.byteWindow.bytesPerSecond(now: now)
        )
    }
}

actor TransferEngine {
    private let spool: TransferSpool
    private let transport: TransferTransport
    private let endpointResolver: any TransferEndpointResolver
    private let pacer: TransferPacer
    private let clock: any TransferClock
    private let diagnosticsSink: TransferDiagnosticSink
    private let statusMirror: TransferStatusMirror?
    private let conditions: (any TransferConditionsProviding)?
    private let dispatchPolicy: TransferDispatchPolicy
    /// Global dispatch cap across all sources. Share, mobile-segment, Omi, and
    /// watch items draw from the same in-flight budget; this is not a
    /// per-source concurrency limit. When live dispatch conditions are present,
    /// the dispatch policy owns the effective cap and this value is ignored.
    private let maxConcurrent: Int
    private let bodyBuilder: TransferBodyBuilder

    private var queuedItems: [UUID: TransferStoredItem] = [:]
    private var attentionItems: [UUID: TransferStoredItem] = [:]
    private var inFlight: Set<UUID> = []
    private var inFlightSourceKeys: [UUID: String] = [:]
    private var droppedItemIDs: Set<UUID> = []
    private var attemptCountByItemID: [UUID: Int] = [:]
    private var sourceCursorByBand: [TransferPriorityBand: Int] = [:]
    private var retrySleepTask: Task<Void, Never>?
    private var paused = false
    private var pacingMode: TransferPacingMode = .normal
    private var policyPaused = false
    private var endpointHeld = false
    private var counters = TransferCounters.empty
    private var sourceStates: [String: TransferSourceRuntimeState] = [:]
    private var aggregateByteWindow = TransferByteWindow()
    private var deliveredHooks: [String: TransferDeliveredHook] = [:]
    private var workPassScheduled = false
    private var workPassRunning = false
    private var lastEventSummary: String?
    private var lastLoggedDispatchDecision: TransferDispatchLogState?
    private var pendingStatusSnapshot: TransferStatusSnapshot?
    private var statusUpdateScheduled = false

    init(
        spool: TransferSpool,
        transport: TransferTransport,
        endpointResolver: any TransferEndpointResolver,
        pacer: TransferPacer = TransferPacer(),
        clock: any TransferClock = LiveTransferClock(),
        diagnosticsSink: @escaping TransferDiagnosticSink = { _ in },
        statusMirror: TransferStatusMirror? = nil,
        conditions: (any TransferConditionsProviding)? = nil,
        dispatchPolicy: TransferDispatchPolicy = TransferDispatchPolicy(),
        maxConcurrent: Int = 3,
        bodyBuilder: @escaping TransferBodyBuilder = DefaultTransferBodyBuilder.build
    ) {
        self.spool = spool
        self.transport = transport
        self.endpointResolver = endpointResolver
        self.pacer = pacer
        self.clock = clock
        self.diagnosticsSink = diagnosticsSink
        self.statusMirror = statusMirror
        self.conditions = conditions
        self.dispatchPolicy = dispatchPolicy
        self.maxConcurrent = max(1, maxConcurrent)
        self.bodyBuilder = bodyBuilder
    }

    func start() throws {
        let snapshot = try self.spool.initialize(now: self.clock.wallNow())
        self.queuedItems = Dictionary(uniqueKeysWithValues: snapshot.queued.map { ($0.manifest.itemID, $0) })
        self.attentionItems = Dictionary(uniqueKeysWithValues: snapshot.attention.map { ($0.manifest.itemID, $0) })
        self.inFlight = []
        self.inFlightSourceKeys = [:]
        self.droppedItemIDs = []
        self.attemptCountByItemID = [:]
        self.aggregateByteWindow = TransferByteWindow()
        self.counters = TransferCounters(
            queuedCount: snapshot.queued.count,
            attentionCount: snapshot.attention.count,
            inFlightCount: 0,
            deliveredCount: 0,
            droppedCount: 0
        )
        self.sourceStates = [:]
        for item in snapshot.queued {
            self.updateSourceState(item.manifest.sourceKey) { state in
                state.counters.queuedCount += 1
            }
        }
        for item in snapshot.attention {
            self.updateSourceState(item.manifest.sourceKey) { state in
                state.counters.attentionCount += 1
            }
        }
        for move in snapshot.recoveryMoves {
            self.emit(
                item: move.item,
                previousState: .queued,
                nextState: .attention,
                outcome: .needsAttention,
                attempt: 0,
                detail: move.detail
            )
            transferLog.notice("transfer recovery needs attention \(move.item.manifest.itemID.uuidString, privacy: .public)")
        }
        for diagnostic in snapshot.recoveryDiagnostics {
            self.emitRecoveryDiagnostic(diagnostic)
        }
        self.scheduleStatusUpdate(summary: "queued")
        self.scheduleWork()
    }

    /// Declare only parts that physically exist at enqueue time. A part that is
    /// optional by nature, such as a location file that may not exist for a
    /// given segment, is omitted from `payloadParts` for that item; it is never
    /// declared-and-missing. `requiredForDispatch` governs only what happens if
    /// a declared part's file disappears after commit: `true` blocks dispatch
    /// and moves the item to attention, `false` lets delivery proceed with that
    /// part omitted.
    @discardableResult
    func enqueue(manifest: TransferManifest, payloads: [String: Data]) throws -> UUID {
        try self.commitStagedResult(self.spool.stage(manifest: manifest, payloads: payloads))
            .manifest.itemID
    }

    /// Moves producer-owned payload files into staging without a full-file
    /// `Data` read, then commits the staged item. On success the producer's
    /// files are gone from their original URLs. On partial failure,
    /// `TransferSpoolError.partialFileMove` names the parts already consumed;
    /// those producer files are gone, remaining producer files are untouched,
    /// and the partial staging directory is salvaged on the next
    /// `TransferSpool.initialize()`.
    ///
    /// Declare only parts that physically exist at enqueue time. A part that is
    /// optional by nature, such as a location file that may not exist for a
    /// given segment, is omitted from `payloadParts` for that item; it is never
    /// declared-and-missing. `requiredForDispatch` governs only what happens if
    /// a declared part's file disappears after commit: `true` blocks dispatch
    /// and moves the item to attention, `false` lets delivery proceed with that
    /// part omitted.
    @discardableResult
    func enqueue(manifest: TransferManifest, payloadFileURLs: [String: URL]) throws -> UUID {
        try self.commitStagedResult(self.spool.stage(manifest: manifest, payloadFileURLs: payloadFileURLs))
            .manifest.itemID
    }

    @discardableResult
    func enqueueAttention(
        manifest: TransferManifest,
        payloadFileURLs: [String: URL],
        reason: String,
        detail: String
    ) throws -> UUID {
        let committed = try self.commitStagedResult(self.spool.stage(manifest: manifest, payloadFileURLs: payloadFileURLs))
        do {
            let moved = try self.spool.moveQueuedItemToAttention(
                committed,
                reason: reason,
                detail: detail,
                now: self.clock.wallNow()
            )
            self.queuedItems.removeValue(forKey: committed.manifest.itemID)
            self.attentionItems[moved.manifest.itemID] = moved
            self.counters.queuedCount -= 1
            self.counters.attentionCount += 1
            self.updateSourceState(moved.manifest.sourceKey) { state in
                state.counters.queuedCount -= 1
                state.counters.attentionCount += 1
            }
            self.emit(
                item: moved,
                previousState: .queued,
                nextState: .attention,
                outcome: .needsAttention,
                attempt: 0,
                detail: detail
            )
            self.scheduleStatusUpdate(summary: "needs attention")
            return moved.manifest.itemID
        } catch {
            self.queuedItems.removeValue(forKey: committed.manifest.itemID)
            self.counters.queuedCount -= 1
            self.updateSourceState(committed.manifest.sourceKey) { state in
                state.counters.queuedCount -= 1
            }
            try? self.spool.removeCommittedItem(committed)
            self.scheduleStatusUpdate(summary: self.lastEventSummary)
            throw error
        }
    }

    private func commitStagedResult(_ staged: TransferSpoolStageResult) throws -> TransferStoredItem {
        for diagnostic in staged.recoveryDiagnostics {
            self.emitRecoveryDiagnostic(diagnostic)
        }
        let committed = try self.spool.commitStagedItem(itemID: staged.item.manifest.itemID)
        self.queuedItems[committed.manifest.itemID] = committed
        self.counters.queuedCount += 1
        self.updateSourceState(committed.manifest.sourceKey) { state in
            state.counters.queuedCount += 1
        }
        self.emit(
            item: committed,
            previousState: .staged,
            nextState: .queued,
            outcome: .queued,
            attempt: 0,
            detail: "queued"
        )
        transferLog.notice("transfer item queued \(committed.manifest.itemID.uuidString, privacy: .public)")
        self.scheduleStatusUpdate(summary: "queued")
        self.scheduleWork()
        return committed
    }

    func pause() {
        guard !self.paused else { return }
        self.paused = true
        self.retrySleepTask?.cancel()
        self.retrySleepTask = nil
        self.emitEngineEvent(outcome: .paused, detail: "paused")
        transferLog.notice("transfer engine paused")
        self.scheduleStatusUpdate(summary: "paused")
    }

    func resume() {
        guard self.paused else { return }
        self.paused = false
        self.emitEngineEvent(outcome: .resumed, detail: "resumed")
        transferLog.notice("transfer engine resumed")
        self.scheduleStatusUpdate(summary: "resumed")
        self.scheduleWork()
    }

    func endpointAvailabilityChanged() {
        self.scheduleWork()
    }

    /// Requests a coalesced drain pass. Repeated calls while a pass is already
    /// scheduled or running collapse into the current pass plus at most one
    /// trailing pass.
    func kick() {
        self.scheduleWork()
    }

    func setPacingMode(_ mode: TransferPacingMode) {
        self.pacingMode = mode
        self.scheduleWork()
    }

    /// Registers a best-effort delivered hook for one source key. Hooks fire at
    /// most once after the delivery commit; a crash between commit and hook
    /// execution skips the hook permanently. Hooks must be idempotent and must
    /// not be a producer's only durable delivery signal. A throwing or
    /// cancelled hook is swallowed, emits a `.hookFailed` diagnostic, and never
    /// mutates engine state.
    func registerDeliveredHook(sourceKey: String, hook: @escaping TransferDeliveredHook) {
        self.deliveredHooks[sourceKey] = hook
    }

    func retryAttention(source: String? = nil) throws {
        let items = self.attentionItems.values
            .filter { source == nil || $0.manifest.sourceKey == source }
            .sorted { $0.manifest.createdAt < $1.manifest.createdAt }
        try self.moveAttentionItemsToQueued(items)
    }

    /// Moves one attention item back to queued, resets its in-memory attempts,
    /// and clears its persisted retry deadline. Missing item IDs are treated as
    /// a no-op that still kicks the engine.
    func retryAttention(itemID: UUID) throws {
        guard let item = self.attentionItems[itemID] else {
            self.scheduleStatusUpdate(summary: self.lastEventSummary)
            self.scheduleWork()
            return
        }
        try self.moveAttentionItemsToQueued([item])
    }

    private func moveAttentionItemsToQueued(_ items: [TransferStoredItem]) throws {
        for item in items {
            let moved = try self.spool.moveAttentionItemToQueued(item)
            self.attentionItems.removeValue(forKey: item.manifest.itemID)
            self.queuedItems[moved.manifest.itemID] = moved
            self.counters.attentionCount -= 1
            self.counters.queuedCount += 1
            self.updateSourceState(moved.manifest.sourceKey) { state in
                state.counters.attentionCount -= 1
                state.counters.queuedCount += 1
            }
            self.attemptCountByItemID.removeValue(forKey: moved.manifest.itemID)
            self.emit(
                item: moved,
                previousState: .attention,
                nextState: .queued,
                outcome: .queued,
                attempt: 0,
                detail: "queued"
            )
        }
        if !items.isEmpty {
            transferLog.notice("transfer attention retrying \(items.count, privacy: .public)")
        }
        self.scheduleStatusUpdate(summary: "queued")
        self.scheduleWork()
    }

    func drop(itemID: UUID) {
        self.droppedItemIDs.insert(itemID)
        if let item = self.queuedItems.removeValue(forKey: itemID) {
            self.counters.queuedCount -= 1
            self.clearInFlight(itemID: itemID, sourceKey: item.manifest.sourceKey)
            self.counters.droppedCount += 1
            self.updateSourceState(item.manifest.sourceKey) { state in
                state.counters.queuedCount -= 1
                state.counters.droppedCount += 1
            }
            try? self.spool.removeCommittedItem(item)
            self.emit(
                item: item,
                previousState: .queued,
                nextState: .dropped,
                outcome: .dropped,
                attempt: self.attemptCountByItemID[itemID, default: 0],
                detail: "dropped"
            )
            transferLog.notice("transfer item dropped \(itemID.uuidString, privacy: .public)")
        } else if let item = self.attentionItems.removeValue(forKey: itemID) {
            self.counters.attentionCount -= 1
            self.counters.droppedCount += 1
            self.updateSourceState(item.manifest.sourceKey) { state in
                state.counters.attentionCount -= 1
                state.counters.droppedCount += 1
            }
            try? self.spool.removeCommittedItem(item)
            self.emit(
                item: item,
                previousState: .attention,
                nextState: .dropped,
                outcome: .dropped,
                attempt: self.attemptCountByItemID[itemID, default: 0],
                detail: "dropped"
            )
            transferLog.notice("transfer item dropped \(itemID.uuidString, privacy: .public)")
        }
        self.scheduleStatusUpdate(summary: "dropped")
        self.scheduleWork()
    }

    func snapshot() -> TransferStatusSnapshot {
        let now = self.clock.wallNow()
        let backoff = self.backoffPending(now: now)
        return TransferStatusSnapshot(
            counters: self.counters,
            paused: self.paused,
            policyPaused: self.policyPaused,
            backoffPendingCount: backoff.count,
            soonestNextAttemptAt: backoff.soonest,
            endpointHeld: self.endpointHeld,
            lastEventSummary: self.lastEventSummary,
            lastUpdatedAt: now,
            sources: self.sourceSnapshots(now: now),
            aggregateBytesPerSecond: self.aggregateByteWindow.bytesPerSecond(now: now)
        )
    }

    /// Returns the in-memory snapshot for one queued, attention, or in-flight
    /// item. This read does not touch disk.
    func itemSnapshot(itemID: UUID) -> TransferItemSnapshot? {
        if let item = self.queuedItems[itemID] {
            return self.snapshot(for: item)
        }
        if let item = self.attentionItems[itemID] {
            return self.snapshot(for: item)
        }
        return nil
    }

    /// Returns in-memory item snapshots, optionally filtered by source key.
    /// This read does not touch disk.
    func itemSnapshots(sourceKey: String? = nil) -> [TransferItemSnapshot] {
        let queued = Array(self.queuedItems.values)
        let attention = Array(self.attentionItems.values)
        return (queued + attention)
            .filter { sourceKey == nil || $0.manifest.sourceKey == sourceKey }
            .sorted(by: self.itemSort)
            .map { self.snapshot(for: $0) }
    }

    /// Returns a currently committed payload file URL for UI-only reads.
    ///
    /// This method does not retain, pin, copy, or delay deletion of the file.
    /// The returned file may vanish at any moment because delivery deletes the
    /// committed item; consumers must tolerate a URL that stops resolving
    /// between this lookup and the read.
    func payloadFileURL(itemID: UUID, partID: String) -> URL? {
        guard let item = self.queuedItems[itemID] ?? self.attentionItems[itemID],
              let part = item.manifest.payloadParts.first(where: { $0.partID == partID })
        else {
            return nil
        }
        return try? self.spool.existingPayloadURL(for: part, in: item)
    }

    private func scheduleWork() {
        guard !self.paused else { return }
        guard !self.workPassScheduled else { return }
        self.workPassScheduled = true
        self.retrySleepTask?.cancel()
        self.retrySleepTask = nil
        guard !self.workPassRunning else { return }
        Task { await self.drainEligibleWork() }
    }

    private func drainEligibleWork() async {
        guard !self.workPassRunning else { return }
        self.workPassRunning = true
        defer { self.workPassRunning = false }
        while true {
            self.workPassScheduled = false
            guard !self.paused else { return }
            var dispatchedThisPass = false
            var stoppedForNoEligibleItem = false
            while true {
                var assessment = self.currentDispatchAssessment()
                self.logDispatchDecisionIfChanged(assessment.logState)
                var decision = assessment.decision
                self.applyPolicyPause(decision.paused)
                if decision.paused { break }
                guard self.inFlight.count < decision.maxConcurrent else { break }
                guard let item = await self.nextEligibleItem() else {
                    stoppedForNoEligibleItem = true
                    break
                }
                guard !self.paused else { break }
                if dispatchedThisPass, decision.interItemDelay > .zero {
                    await self.clock.sleep(for: decision.interItemDelay)
                    guard !self.paused else { break }
                    assessment = self.currentDispatchAssessment()
                    self.logDispatchDecisionIfChanged(assessment.logState)
                    decision = assessment.decision
                    self.applyPolicyPause(decision.paused)
                    if decision.paused { break }
                    guard self.inFlight.count < decision.maxConcurrent else { break }
                }
                await self.dispatch(item)
                dispatchedThisPass = true
            }
            if stoppedForNoEligibleItem, self.inFlight.isEmpty {
                await self.refreshEndpointHoldForBackoff(now: self.clock.wallNow())
            }
            self.scheduleRetryTimer()
            guard self.workPassScheduled else { return }
        }
    }

    private func nextEligibleItem() async -> TransferStoredItem? {
        let wallNow = self.clock.wallNow()
        for band in TransferPriorityBand.allCases {
            let bandItems = self.queuedItems.values
                .filter { self.band(for: $0.manifest, wallNow: wallNow) == band }
                .filter { !self.inFlight.contains($0.manifest.itemID) }
                .filter { !self.droppedItemIDs.contains($0.manifest.itemID) }
                .filter {
                    TransferClockMath.retryEligible(
                        nextAttemptAt: $0.manifest.nextAttemptAt,
                        wallNow: wallNow,
                        maxDelay: self.pacer.defaults.maxDelay
                    )
                }
            guard !bandItems.isEmpty else { continue }
            let grouped = Dictionary(grouping: bandItems, by: { $0.manifest.sourceKey })
            let sources = grouped.keys.sorted()
            let start = self.sourceCursorByBand[band, default: 0] % max(sources.count, 1)
            for offset in 0..<sources.count {
                let sourceIndex = (start + offset) % sources.count
                let source = sources[sourceIndex]
                guard let item = grouped[source]?.sorted(by: self.itemSort).first else { continue }
                if let missing = self.spool.validatePayloads(for: item) {
                    self.moveToAttention(item: item, reason: .missingPayload(missing), detail: missing)
                    continue
                }
                let resolution = await self.endpointResolver.resolve(item.manifest.endpoint)
                switch resolution {
                case .available:
                    self.markEndpointAvailable()
                    self.sourceCursorByBand[band] = sourceIndex + 1
                    return item
                case .unavailable(let detail):
                    self.markEndpointHeld(detail: detail)
                    continue
                }
            }
        }
        return nil
    }

    private func dispatch(_ item: TransferStoredItem) async {
        let itemID = item.manifest.itemID
        guard !self.inFlight.contains(itemID), self.queuedItems[itemID] != nil else { return }
        self.inFlight.insert(itemID)
        self.inFlightSourceKeys[itemID] = item.manifest.sourceKey
        self.counters.inFlightCount = self.inFlight.count
        self.updateSourceState(item.manifest.sourceKey) { state in
            state.counters.inFlightCount += 1
        }
        let attempt = self.attemptCountByItemID[itemID, default: 0] + 1
        self.attemptCountByItemID[itemID] = attempt
        self.emit(
            item: item,
            previousState: .queued,
            nextState: .dispatching,
            outcome: .queued,
            attempt: attempt,
            detail: "dispatching"
        )
        self.scheduleStatusUpdate(summary: "dispatching")

        let phase = self.phase(for: item.manifest)
        do {
            try self.preflightBody(item: item, phase: phase)
        } catch {
            self.handleBodyBuildFailure(error, item: item)
            return
        }

        let bodyURL: URL
        do {
            let canUseBodyCache: Bool
            switch phase {
            case .save:
                // SAVE bodies include a per-attempt observer_handle. Do not reuse body.upload for SAVE retries: the old ImportQueue called ensureRegistered() immediately before each SAVE body build, and observer handles may rotate between attempts. Rebuild cost is a second multipart encoding of the share payload; observer ingest and START bodies remain cacheable.
                canUseBodyCache = false
            case .observerIngest, .start:
                canUseBodyCache = true
            }
            if canUseBodyCache && self.spool.bodyCacheExists(for: item) {
                bodyURL = self.spool.bodyCacheURL(for: item)
            } else {
                let body = try await self.bodyBuilder(item, self.spool)
                bodyURL = try self.spool.writeBodyCache(body, for: item)
            }
        } catch {
            self.handleBodyBuildFailure(error, item: item)
            return
        }

        let resolution = await self.endpointResolver.resolve(item.manifest.endpoint)
        guard case .available(let endpoint) = resolution else {
            if case .unavailable(let detail) = resolution {
                self.markEndpointHeld(detail: detail)
            }
            self.clearInFlight(itemID: itemID, sourceKey: item.manifest.sourceKey)
            self.scheduleStatusUpdate(summary: "held")
            self.scheduleRetryTimer()
            return
        }

        Task {
            let result = await self.transport.send(item: item, bodyURL: bodyURL, endpoint: endpoint, phase: phase)
            await self.handleCompletion(itemID: itemID, result: result, phase: phase)
        }
    }

    private func handleCompletion(itemID: UUID, result: TransferHTTPResult, phase: TransferEndpointPhase) async {
        guard let item = self.queuedItems[itemID] else {
            if let sourceKey = self.inFlightSourceKeys[itemID] {
                self.clearInFlight(itemID: itemID, sourceKey: sourceKey)
            } else {
                self.counters.inFlightCount = self.inFlight.count
            }
            return
        }
        if self.droppedItemIDs.remove(itemID) != nil {
            self.clearInFlight(itemID: itemID, sourceKey: item.manifest.sourceKey)
            self.scheduleStatusUpdate(summary: "dropped")
            self.scheduleWork()
            return
        }

        let outcome = TransferHTTPClassifier.classify(result: result, endpointPhase: phase)
        switch outcome {
        case .terminalSuccess(let successKind):
            self.clearInFlight(itemID: itemID, sourceKey: item.manifest.sourceKey)
            self.queuedItems.removeValue(forKey: itemID)
            self.counters.queuedCount -= 1
            self.counters.deliveredCount += 1
            let deliveredBytes = self.deliveredByteCount(for: item)
            let deliveredAt = self.clock.wallNow()
            self.noteDelivered(bytes: deliveredBytes, sourceKey: item.manifest.sourceKey, at: deliveredAt)
            self.updateSourceState(item.manifest.sourceKey) { state in
                state.counters.queuedCount -= 1
                state.counters.deliveredCount += 1
            }
            try? self.spool.removeCommittedItem(item)
            self.emit(
                item: item,
                previousState: .dispatching,
                nextState: .delivered,
                outcome: .delivered,
                attempt: self.attemptCountByItemID[itemID, default: 0],
                detail: "delivered"
            )
            transferLog.notice("transfer item delivered \(itemID.uuidString, privacy: .public)")
            self.launchDeliveredHook(
                for: item.manifest,
                successKind: successKind,
                attempt: self.attemptCountByItemID[itemID, default: 0]
            )
        case .terminalAttention(let reason):
            self.clearInFlight(itemID: itemID, sourceKey: item.manifest.sourceKey)
            let detail = self.shortDetail(for: reason)
            self.noteError(sourceKey: item.manifest.sourceKey, detail: detail)
            self.moveToAttention(item: item, reason: reason, detail: detail)
            transferLog.notice("transfer item needs attention \(itemID.uuidString, privacy: .public)")
        case .transientRetry(let reason):
            self.clearInFlight(itemID: itemID, sourceKey: item.manifest.sourceKey)
            let attempt = self.attemptCountByItemID[itemID, default: 1]
            let decision = self.pacer.delay(for: TransferPacerInput(
                itemID: itemID,
                source: item.manifest.sourceKey,
                attemptCount: attempt,
                lastOutcome: reason
            ))
            let nextAttemptAt = self.clock.wallNow().addingTimeInterval(decision.delay)
            let updatedManifest = item.manifest.replacingNextAttemptAt(nextAttemptAt)
            var retryItem = item
            var retryDetail = "retrying"
            do {
                let updated = try self.spool.updateQueuedManifest(updatedManifest, directoryURL: item.directoryURL)
                self.queuedItems[itemID] = updated
                retryItem = updated
            } catch {
                retryItem = TransferStoredItem(manifest: updatedManifest, directoryURL: item.directoryURL)
                self.queuedItems[itemID] = retryItem
                retryDetail = "retry persistence failed"
                transferLog.notice("transfer retry persistence failed \(itemID.uuidString, privacy: .public) \(String(describing: error), privacy: .public)")
            }
            self.noteError(sourceKey: item.manifest.sourceKey, detail: retryDetail)
            self.emit(
                item: retryItem,
                previousState: .dispatching,
                nextState: .queued,
                outcome: .retrying,
                attempt: attempt,
                detail: retryDetail
            )
            transferLog.notice("transfer item retrying \(itemID.uuidString, privacy: .public)")
        case .continueWithStart(let state):
            self.clearInFlight(itemID: itemID, sourceKey: item.manifest.sourceKey)
            var manifest = item.manifest.replacingNextAttemptAt(nil)
            manifest.saveThenStart = state
            self.spool.removeBodyCache(for: item)
            if let updated = try? self.spool.updateQueuedManifest(manifest, directoryURL: item.directoryURL) {
                self.queuedItems[itemID] = updated
            }
            self.emit(
                item: item,
                previousState: .dispatching,
                nextState: .queued,
                outcome: .queued,
                attempt: self.attemptCountByItemID[itemID, default: 0],
                detail: "queued"
            )
        }
        self.scheduleStatusUpdate(summary: self.lastEventSummary)
        self.scheduleWork()
    }

    private func moveToAttention(item: TransferStoredItem, reason: TransferAttentionReason, detail: String) {
        guard self.queuedItems[item.manifest.itemID] != nil else { return }
        if let moved = try? self.spool.moveQueuedItemToAttention(
            item,
            reason: self.reasonCode(for: reason),
            detail: detail,
            now: self.clock.wallNow()
        ) {
            self.queuedItems.removeValue(forKey: item.manifest.itemID)
            self.attentionItems[moved.manifest.itemID] = moved
            self.counters.queuedCount -= 1
            self.counters.attentionCount += 1
            self.updateSourceState(moved.manifest.sourceKey) { state in
                state.counters.queuedCount -= 1
                state.counters.attentionCount += 1
            }
            self.emit(
                item: moved,
                previousState: .queued,
                nextState: .attention,
                outcome: .needsAttention,
                attempt: self.attemptCountByItemID[moved.manifest.itemID, default: 0],
                detail: detail
            )
        }
    }

    private func scheduleRetryTimer() {
        self.retrySleepTask?.cancel()
        self.retrySleepTask = nil
        guard !self.paused else { return }
        let wallNow = self.clock.wallNow()
        let backoff = self.backoffPending(now: wallNow)
        guard let soonest = backoff.soonest else { return }
        let delay = TransferClockMath.sleepDurationUntil(
            nextAttemptAt: soonest,
            wallNow: wallNow,
            maxDelay: self.pacer.defaults.maxDelay
        )
        self.retrySleepTask = Task { [clock] in
            await clock.sleep(for: .nanoseconds(Int64(delay * 1_000_000_000)))
            self.retryTimerFired()
        }
    }

    private func retryTimerFired() {
        self.retrySleepTask = nil
        self.scheduleWork()
    }

    private func phase(for manifest: TransferManifest) -> TransferEndpointPhase {
        switch manifest.endpoint.destinationKind {
        case .observerIngest:
            return .observerIngest
        case .saveThenStart:
            if manifest.saveThenStart?.phase == .startPending {
                return .start(saveResult: manifest.saveThenStart)
            }
            return .save
        }
    }
}

private extension TransferEngine {
    func updateSourceState(_ sourceKey: String, _ update: (inout TransferSourceRuntimeState) -> Void) {
        var state = self.sourceStates[sourceKey, default: TransferSourceRuntimeState()]
        update(&state)
        self.sourceStates[sourceKey] = state
    }

    /// Clears in-flight state for `itemID`. The per-source counter is
    /// decremented only if this call is the one that actually removed the item
    /// from `inFlight`, so a drop during a `dispatch()` suspension cannot
    /// double-decrement.
    func clearInFlight(itemID: UUID, sourceKey: String) {
        self.inFlightSourceKeys.removeValue(forKey: itemID)
        guard self.inFlight.remove(itemID) != nil else {
            self.counters.inFlightCount = self.inFlight.count
            return
        }
        self.counters.inFlightCount = self.inFlight.count
        self.updateSourceState(sourceKey) { state in
            state.counters.inFlightCount -= 1
        }
    }

    func sourceSnapshots(now: Date) -> [String: TransferSourceStatusSnapshot] {
        Dictionary(uniqueKeysWithValues: self.sourceStates.map { sourceKey, state in
            (sourceKey, state.snapshot(now: now))
        })
    }

    func currentDispatchDecision() -> TransferDispatchDecision {
        self.currentDispatchAssessment().decision
    }

    func currentDispatchAssessment() -> TransferDispatchAssessment {
        guard let conditions else {
            return TransferDispatchAssessment(decision: TransferDispatchDecision(
                maxConcurrent: self.maxConcurrent,
                interItemDelay: .zero,
                paused: false
            ), logState: nil)
        }
        let currentConditions = conditions.current()
        let decision = self.dispatchPolicy.decide(
            conditions: currentConditions,
            mode: self.pacingMode
        )
        return TransferDispatchAssessment(
            decision: decision,
            logState: TransferDispatchLogState(
                decision: decision,
                conditions: currentConditions,
                mode: self.pacingMode
            )
        )
    }

    func logDispatchDecisionIfChanged(_ logState: TransferDispatchLogState?) {
        guard let logState else { return }
        if self.lastLoggedDispatchDecision?.decision == logState.decision {
            self.lastLoggedDispatchDecision = logState
            return
        }
        self.lastLoggedDispatchDecision = logState
        transferLog.notice(
            """
            transfer dispatch policy thermal=\(thermalStateString(logState.conditions.thermalState), privacy: .public) \
            low-power=\(String(logState.conditions.lowPowerModeEnabled), privacy: .public) \
            expensive=\(String(logState.conditions.isExpensive), privacy: .public) \
            constrained=\(String(logState.conditions.isConstrained), privacy: .public) \
            mode=\(transferPacingModeString(logState.mode), privacy: .public) \
            max-concurrent=\(logState.decision.maxConcurrent, privacy: .public) \
            delay=\(transferDispatchDelayString(logState.decision.interItemDelay), privacy: .public) \
            paused=\(String(logState.decision.paused), privacy: .public)
            """
        )
    }

    func applyPolicyPause(_ paused: Bool) {
        guard self.policyPaused != paused else { return }
        self.policyPaused = paused
        if paused {
            let thermal = self.conditions?.current().thermalState ?? .nominal
            let detail = "thermal \(thermalStateString(thermal))"
            self.emitEngineEvent(outcome: .paused, detail: detail)
            transferLog.notice("transfer policy paused \(detail, privacy: .public)")
            self.scheduleStatusUpdate(summary: detail)
        } else {
            self.emitEngineEvent(outcome: .resumed, detail: "policy resumed")
            transferLog.notice("transfer policy resumed")
            self.scheduleStatusUpdate(summary: "policy resumed")
        }
    }

    func backoffPending(now: Date) -> (count: Int, soonest: Date?) {
        let dates = self.backoffPendingItems(now: now).compactMap { $0.manifest.nextAttemptAt }
        return (dates.count, dates.min())
    }

    func backoffPendingItems(now: Date) -> [TransferStoredItem] {
        let latestAttemptAt = now.addingTimeInterval(self.pacer.defaults.maxDelay)
        return self.queuedItems.values.compactMap { item in
            guard !self.inFlight.contains(item.manifest.itemID),
                  let next = item.manifest.nextAttemptAt,
                  next > now,
                  next <= latestAttemptAt
            else {
                return nil
            }
            return item
        }
    }

    func refreshEndpointHoldForBackoff(now: Date) async {
        guard self.inFlight.isEmpty,
              let item = self.backoffPendingItems(now: now).sorted(by: self.itemSort).first
        else {
            return
        }
        let resolution = await self.endpointResolver.resolve(item.manifest.endpoint)
        switch resolution {
        case .available:
            self.markEndpointAvailable()
        case .unavailable(let detail):
            self.markEndpointHeld(detail: detail)
        }
    }

    func snapshot(for item: TransferStoredItem) -> TransferItemSnapshot {
        let state: TransferRuntimeState
        if self.attentionItems[item.manifest.itemID] != nil {
            state = .attention
        } else if self.inFlight.contains(item.manifest.itemID) {
            state = .dispatching
        } else {
            state = .queued
        }
        return TransferItemSnapshot(
            manifest: item.manifest,
            state: state,
            attempts: self.attemptCountByItemID[item.manifest.itemID, default: 0]
        )
    }

    func noteDelivered(bytes: Int, sourceKey: String, at: Date) {
        self.aggregateByteWindow.noteDelivered(bytes: bytes, at: at)
        self.updateSourceState(sourceKey) { state in
            state.noteDelivered(bytes: bytes, at: at)
        }
    }

    func noteError(sourceKey: String, detail: String) {
        self.updateSourceState(sourceKey) { state in
            state.noteError(detail: detail, at: self.clock.wallNow())
        }
    }

    func deliveredByteCount(for item: TransferStoredItem) -> Int {
        item.manifest.payloadParts.reduce(0) { total, part in
            if let byteCount = part.byteCount {
                return total + byteCount
            }
            guard let byteCount = try? self.spool.payloadByteCount(for: part, in: item) else {
                return total
            }
            return total + byteCount
        }
    }

    func emitRecoveryDiagnostic(_ diagnostic: TransferRecoveryDiagnostic) {
        self.lastEventSummary = diagnostic.detail
        self.diagnosticsSink(TransferDiagnosticEvent(
            source: diagnostic.source,
            itemID: diagnostic.itemID,
            previousState: diagnostic.previousState,
            nextState: diagnostic.nextState,
            outcome: diagnostic.outcome,
            attempt: 0,
            shortDetail: diagnostic.detail,
            at: self.clock.wallNow()
        ))
    }

    func launchDeliveredHook(for manifest: TransferManifest, successKind: TransferSuccessKind, attempt: Int) {
        guard let hook = self.deliveredHooks[manifest.sourceKey] else { return }
        let diagnosticsSink = self.diagnosticsSink
        let at = self.clock.wallNow()
        Task.detached {
            do {
                try await hook(manifest, successKind)
            } catch {
                diagnosticsSink(TransferDiagnosticEvent(
                    source: manifest.sourceKey,
                    itemID: manifest.itemID,
                    previousState: .delivered,
                    nextState: .delivered,
                    outcome: .hookFailed,
                    attempt: attempt,
                    shortDetail: "hook failed",
                    at: at
                ))
            }
        }
    }

    func band(for manifest: TransferManifest, wallNow: Date) -> TransferPriorityBand {
        if manifest.createdAt >= wallNow.addingTimeInterval(-(15 * 60)) {
            return .fresh
        }
        switch manifest.priority.basePriority {
        case .high:
            return .high
        case .normal:
            return .normal
        case .low:
            return .low
        }
    }

    func itemSort(_ lhs: TransferStoredItem, _ rhs: TransferStoredItem) -> Bool {
        if lhs.manifest.createdAt == rhs.manifest.createdAt {
            return lhs.manifest.itemID.uuidString < rhs.manifest.itemID.uuidString
        }
        return lhs.manifest.createdAt < rhs.manifest.createdAt
    }

    func preflightBody(item: TransferStoredItem, phase: TransferEndpointPhase) throws {
        switch phase {
        case .observerIngest:
            return
        case .save:
            guard item.manifest.payloadParts.count == 1,
                  let part = item.manifest.payloadParts.first
            else {
                throw TransferBodyBuildError.malformedManifest("save requires one payload")
            }
            switch part.kind {
            case .text, .file:
                return
            case .audio, .location, .screen:
                throw TransferBodyBuildError.malformedManifest("unsupported save payload")
            }
        case .start(let state):
            guard let savedPath = state?.savedPath, !savedPath.isEmpty,
                  let savedTimestamp = state?.savedTimestamp, !savedTimestamp.isEmpty
            else {
                throw TransferBodyBuildError.malformedManifest("missing save result")
            }
        }
    }

    func handleBodyBuildFailure(_ error: Error, item: TransferStoredItem) {
        let reason = self.attentionReason(for: error)
        let detail = self.shortDetail(for: reason)
        self.moveToAttention(item: item, reason: reason, detail: detail)
        self.clearInFlight(itemID: item.manifest.itemID, sourceKey: item.manifest.sourceKey)
        self.noteError(sourceKey: item.manifest.sourceKey, detail: detail)
        transferLog.notice("transfer body unavailable \(item.manifest.itemID.uuidString, privacy: .public) \(detail, privacy: .public)")
        self.scheduleStatusUpdate(summary: "needs attention")
    }

    func markEndpointHeld(detail: String) {
        guard !self.endpointHeld else { return }
        self.endpointHeld = true
        self.emitEngineEvent(outcome: .held, detail: "held: endpoint unavailable")
        transferLog.notice("transfer endpoint unavailable \(detail, privacy: .public)")
        self.scheduleStatusUpdate(summary: "held")
    }

    func markEndpointAvailable() {
        guard self.endpointHeld else { return }
        self.endpointHeld = false
        self.emitEngineEvent(outcome: .resumed, detail: "resumed: endpoint available")
        transferLog.notice("transfer endpoint available")
        self.scheduleStatusUpdate(summary: "resumed")
    }

    func emit(
        item: TransferStoredItem,
        previousState: TransferRuntimeState,
        nextState: TransferRuntimeState,
        outcome: TransferDiagnosticOutcomeSummary,
        attempt: Int,
        detail: String
    ) {
        self.lastEventSummary = detail
        self.diagnosticsSink(TransferDiagnosticEvent(
            source: item.manifest.sourceKey,
            itemID: item.manifest.itemID,
            previousState: previousState,
            nextState: nextState,
            outcome: outcome,
            attempt: attempt,
            shortDetail: detail,
            at: self.clock.wallNow()
        ))
    }

    func emitEngineEvent(outcome: TransferDiagnosticOutcomeSummary, detail: String) {
        self.lastEventSummary = detail
        self.diagnosticsSink(TransferDiagnosticEvent(
            source: "engine",
            itemID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            previousState: .held,
            nextState: self.nextState(forEngineOutcome: outcome),
            outcome: outcome,
            attempt: 0,
            shortDetail: detail,
            at: self.clock.wallNow()
        ))
    }

    func scheduleStatusUpdate(summary: String?) {
        self.lastEventSummary = summary ?? self.lastEventSummary
        self.pendingStatusSnapshot = self.snapshot()
        guard self.statusMirror != nil, !self.statusUpdateScheduled else { return }
        self.statusUpdateScheduled = true
        Task {
            try? await Task.sleep(for: transferStatusCoalescingDelay)
            await self.flushStatusUpdate()
        }
    }

    func flushStatusUpdate() async {
        guard let snapshot = self.pendingStatusSnapshot else {
            self.statusUpdateScheduled = false
            return
        }
        self.pendingStatusSnapshot = nil
        if let statusMirror = self.statusMirror {
            await statusMirror.apply(snapshot: snapshot)
        }
        if self.pendingStatusSnapshot != nil {
            Task {
                try? await Task.sleep(for: transferStatusCoalescingDelay)
                await self.flushStatusUpdate()
            }
        } else {
            self.statusUpdateScheduled = false
        }
    }

    func nextState(forEngineOutcome outcome: TransferDiagnosticOutcomeSummary) -> TransferRuntimeState {
        switch outcome {
        case .paused:
            return .paused
        case .held:
            return .held
        default:
            return .queued
        }
    }

    func attentionReason(for error: Error) -> TransferAttentionReason {
        if let bodyError = error as? TransferBodyBuildError {
            switch bodyError {
            case .missingObserverMetadata:
                return .malformedManifest("missing observer metadata")
            case .missingPayload(let detail):
                return .missingPayload(detail)
            case .malformedManifest(let detail):
                return .malformedManifest(detail)
            case .saveRequestUnsupported:
                return .malformedManifest("save request unsupported")
            }
        }
        if error is ObserverIngestMultipartBodyError {
            return .missingPayload("observer artifact")
        }
        return .missingPayload(String(describing: error))
    }

    func reasonCode(for reason: TransferAttentionReason) -> String {
        switch reason {
        case .httpClientError:
            return "http_client_error"
        case .decodeFailed:
            return "decode_failed"
        case .missingPayload:
            return "missing_payload"
        case .malformedManifest:
            return "malformed_manifest"
        }
    }

    func shortDetail(for reason: TransferAttentionReason) -> String {
        switch reason {
        case .httpClientError(let statusCode, let detail):
            return detail ?? "http \(statusCode)"
        case .decodeFailed(let detail):
            return detail
        case .missingPayload(let detail):
            return detail
        case .malformedManifest(let detail):
            return detail
        }
    }
}

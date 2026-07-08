// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let transferLog = Logger(subsystem: "app.solstone.swift", category: "transfer")
nonisolated private let transferStatusCoalescingDelay: Duration = .milliseconds(250)

typealias TransferBodyBuilder = @Sendable (TransferStoredItem, TransferSpool) throws -> Data

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
                return try JSONEncoder().encode(body)
            }
            throw TransferBodyBuildError.saveRequestUnsupported
        }
    }
}

nonisolated private struct TransferStartRequestBody: Encodable {
    let path: String
    let timestamp: String
}

actor TransferEngine {
    private let spool: TransferSpool
    private let transport: TransferTransport
    private let endpointResolver: any TransferEndpointResolver
    private let pacer: TransferPacer
    private let clock: any TransferClock
    private let diagnosticsSink: TransferDiagnosticSink
    private let statusMirror: TransferStatusMirror?
    private let maxConcurrent: Int
    private let bodyBuilder: TransferBodyBuilder

    private var queuedItems: [UUID: TransferStoredItem] = [:]
    private var attentionItems: [UUID: TransferStoredItem] = [:]
    private var inFlight: Set<UUID> = []
    private var droppedItemIDs: Set<UUID> = []
    private var attemptCountByItemID: [UUID: Int] = [:]
    private var sourceCursorByBand: [TransferPriorityBand: Int] = [:]
    private var retrySleepTask: Task<Void, Never>?
    private var paused = false
    private var endpointHeld = false
    private var counters = TransferCounters.empty
    private var lastEventSummary: String?
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
        self.maxConcurrent = max(1, maxConcurrent)
        self.bodyBuilder = bodyBuilder
    }

    func start() throws {
        let snapshot = try self.spool.initialize(now: self.clock.wallNow())
        self.queuedItems = Dictionary(uniqueKeysWithValues: snapshot.queued.map { ($0.manifest.itemID, $0) })
        self.attentionItems = Dictionary(uniqueKeysWithValues: snapshot.attention.map { ($0.manifest.itemID, $0) })
        self.counters = TransferCounters(
            queuedCount: snapshot.queued.count,
            attentionCount: snapshot.attention.count,
            inFlightCount: 0,
            deliveredCount: 0
        )
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
        self.scheduleStatusUpdate(summary: "queued")
        self.scheduleWork()
    }

    @discardableResult
    func enqueue(manifest: TransferManifest, payloads: [String: Data]) throws -> UUID {
        let staged = try self.spool.stage(manifest: manifest, payloads: payloads)
        let committed = try self.spool.commitStagedItem(itemID: staged.manifest.itemID)
        self.queuedItems[committed.manifest.itemID] = committed
        self.counters.queuedCount += 1
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
        return committed.manifest.itemID
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

    func retryAttention(source: String? = nil) throws {
        let items = self.attentionItems.values
            .filter { source == nil || $0.manifest.sourceKey == source }
            .sorted { $0.manifest.createdAt < $1.manifest.createdAt }
        for item in items {
            let moved = try self.spool.moveAttentionItemToQueued(item)
            self.attentionItems.removeValue(forKey: item.manifest.itemID)
            self.queuedItems[moved.manifest.itemID] = moved
            self.counters.attentionCount -= 1
            self.counters.queuedCount += 1
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
            self.inFlight.remove(itemID)
            self.counters.inFlightCount = self.inFlight.count
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
        TransferStatusSnapshot(
            counters: self.counters,
            paused: self.paused,
            lastEventSummary: self.lastEventSummary,
            lastUpdatedAt: self.clock.wallNow()
        )
    }

    private func scheduleWork() {
        guard !self.paused else { return }
        self.retrySleepTask?.cancel()
        self.retrySleepTask = nil
        Task { await self.drainEligibleWork() }
    }

    private func drainEligibleWork() async {
        guard !self.paused else { return }
        while self.inFlight.count < self.maxConcurrent {
            guard let item = await self.nextEligibleItem() else { break }
            await self.dispatch(item)
        }
        self.scheduleRetryTimer()
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
        self.counters.inFlightCount = self.inFlight.count
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
            try self.preflightBody(phase: phase)
        } catch {
            self.handleBodyBuildFailure(error, item: item)
            return
        }

        let bodyURL: URL
        do {
            if self.spool.bodyCacheExists(for: item) {
                bodyURL = self.spool.bodyCacheURL(for: item)
            } else {
                let body = try self.bodyBuilder(item, self.spool)
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
            self.inFlight.remove(itemID)
            self.counters.inFlightCount = self.inFlight.count
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
            self.inFlight.remove(itemID)
            self.counters.inFlightCount = self.inFlight.count
            return
        }
        if self.droppedItemIDs.remove(itemID) != nil {
            self.inFlight.remove(itemID)
            self.counters.inFlightCount = self.inFlight.count
            self.scheduleStatusUpdate(summary: "dropped")
            self.scheduleWork()
            return
        }

        let outcome = TransferHTTPClassifier.classify(result: result, endpointPhase: phase)
        switch outcome {
        case .terminalSuccess:
            self.inFlight.remove(itemID)
            self.counters.inFlightCount = self.inFlight.count
            self.queuedItems.removeValue(forKey: itemID)
            self.counters.queuedCount -= 1
            self.counters.deliveredCount += 1
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
        case .terminalAttention(let reason):
            self.inFlight.remove(itemID)
            self.counters.inFlightCount = self.inFlight.count
            self.moveToAttention(item: item, reason: reason, detail: self.shortDetail(for: reason))
            transferLog.notice("transfer item needs attention \(itemID.uuidString, privacy: .public)")
        case .transientRetry(let reason):
            self.inFlight.remove(itemID)
            self.counters.inFlightCount = self.inFlight.count
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
            self.inFlight.remove(itemID)
            self.counters.inFlightCount = self.inFlight.count
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
        let futureDates = self.queuedItems.values.compactMap { item -> Date? in
            guard !self.inFlight.contains(item.manifest.itemID),
                  let next = item.manifest.nextAttemptAt,
                  next > wallNow,
                  next <= wallNow.addingTimeInterval(self.pacer.defaults.maxDelay)
            else {
                return nil
            }
            return next
        }
        guard let soonest = futureDates.min() else { return }
        let delay = TransferClockMath.sleepDurationUntil(
            nextAttemptAt: soonest,
            wallNow: wallNow,
            maxDelay: self.pacer.defaults.maxDelay
        )
        self.retrySleepTask = Task { [clock] in
            await clock.sleep(for: .nanoseconds(Int64(delay * 1_000_000_000)))
            await self.retryTimerFired()
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

    func preflightBody(phase: TransferEndpointPhase) throws {
        switch phase {
        case .observerIngest:
            return
        case .save:
            throw TransferBodyBuildError.saveRequestUnsupported
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
        self.inFlight.remove(item.manifest.itemID)
        self.counters.inFlightCount = self.inFlight.count
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

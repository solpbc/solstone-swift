// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import os

@MainActor
final class OmiLaunchCaptureCommitCoordinator {
    // These are the asynchronous boundaries in owner settlement and cutover.
    // Observing them keeps ordering testable without changing the Transfer APIs.
    enum ReconciliationPhase: Equatable, Hashable, Sendable {
        case afterCutIntentCommittedBeforeRouteSwap
        case afterSealedOwnerGatedEnqueued
        case afterSealedOwnershipVerified
        case afterSealedCursorAcknowledged
        case afterSealedEnvelopeCleaned
        case beforeSealedOwnerReleased
        case afterSealedOwnerReleased
        case afterFinalMarkerCommittedBeforeReservedMaterialization
        case beforeReservedOwnerReleased
        case afterReservedOwnerReleased
    }

    enum SettlementAction: Equatable, Sendable {
        case release
        case gateConversion
    }

    private struct LinkedHandoff {
        let rootURL: URL
        let generationID: UUID
        let itemID: UUID
        let envelopeURL: URL
        let partitionOrdinal: UInt64
        let captureStartedAtUnixMicros: Int64
    }

    private enum EnumerationResult {
        case scannedWithLinkedIDs([LinkedHandoff])
        case scannedNothingLinked
        case unknown
    }

    private enum GenerationOutcome {
        case settled(OmiLaunchCaptureMaterializationResult, OmiLaunchCaptureLeaseReader)
        case retryRequired(OmiLaunchCaptureMaterializationResult, OmiLaunchCaptureLeaseReader)
        case retryDelayed(OmiLaunchCaptureMaterializationResult, OmiLaunchCaptureLeaseReader)
        case held
        case boundary
        case failed
    }

    private enum PendingSuccessor {
        case immediate
        case delayed
    }

    private struct PendingOwner {
        let partition: OmiLaunchCaptureMaterializedPartition
        let token: TransferGateToken
    }

    private struct SettlementHandoff {
        let generationID: UUID
        let envelopeURL: URL
        let partitionOrdinal: UInt64
        let captureStartedAtUnixMicros: Int64
    }

    private struct SettlementOwner {
        let itemID: UUID
        let token: TransferGateToken
        let handoffs: [SettlementHandoff]
        let isAcknowledged: Bool
    }

    private enum CutLifecycle: Equatable {
        case ordinary
        case sealedSettlement(OmiLaunchCaptureCutReservation)
        case reservedSettlement(OmiLaunchCaptureCutReservation, OmiLaunchCaptureCutFinal)
        case defect

        var intent: OmiLaunchCaptureCutReservation? {
            switch self {
            case .sealedSettlement(let intent), .reservedSettlement(let intent, _): intent
            case .ordinary, .defect: nil
            }
        }
    }

    private enum CoordinatorGateOwner {
        case attached(TransferGateToken)
        case registered(PendingOwner)

        var token: TransferGateToken {
            switch self {
            case .attached(let token): token
            case .registered(let owner): owner.token
            }
        }
    }

    private enum CoordinatorHoldReason {
        case explicitResume
        case conservative
        case settlementRetry
    }

    private enum OwnerReleaseOutcome {
        case released
        case disabled(TransferGateToken)
        case failed
    }

    private var rootURL: URL?
    private let engine: TransferEngine
    private let sourceManager: OmiSourceManager
    private let io: any OmiLaunchCaptureIO
    private let clock: any ObserverClock
    private let onReconciliationPhase: (@MainActor @Sendable (ReconciliationPhase) async -> Void)?
    private let onSettlementAction: (@MainActor @Sendable (UUID, SettlementAction) -> TransferGateSettlementOutcome?)?
    private let log = Logger(subsystem: "app.solstone.swift", category: "omi-launch-capture")
    private var reconciliationRequested = false
    private var successorTask: Task<Void, Never>?
    private var isReconciling = false
    private var pendingSuccessor: PendingSuccessor?
    private var cutLifecycle: CutLifecycle = .ordinary
    private var cutReservationProbeFailed = false
    private var pendingCutFinalDefect: OmiLaunchCaptureCutReservationDefect?
    private var cutoverArmFailureCount = 0
    private var cutoverArmRetryExhausted = false
    // Last writer wins: the call that creates a lifetime hold owns its resume policy.
    // Explicit holds resume only from the explicit-enable path; conservative and retry
    // holds require a successful attached-handoff scan.
    private var coordinatorHoldReasonsByItemID: [UUID: CoordinatorHoldReason] = [:]
    private var isResumingAfterExplicitEnable = false
    private var pendingGateOwnersByItemID: [UUID: CoordinatorGateOwner] = [:]
    private var enumeratedHandoffs: [LinkedHandoff] = []
    private var materializerSession: (rootURL: URL, generationID: UUID, materializer: OmiLaunchCaptureMaterializer)?
    private static let reconciliationNoProgressDelay: Duration = .seconds(1)
    private static let cutoverArmRetryLimit = 3

    init(
        rootURL: URL?,
        engine: TransferEngine,
        sourceManager: OmiSourceManager,
        io: any OmiLaunchCaptureIO = FoundationOmiLaunchCaptureIO(),
        clock: any ObserverClock = SystemObserverClock(),
        onReconciliationPhase: (@MainActor @Sendable (ReconciliationPhase) async -> Void)? = nil,
        onSettlementAction: (@MainActor @Sendable (UUID, SettlementAction) -> TransferGateSettlementOutcome?)? = nil
    ) {
        self.rootURL = rootURL
        self.engine = engine
        self.sourceManager = sourceManager
        self.io = io
        self.clock = clock
        self.onReconciliationPhase = onReconciliationPhase
        self.onSettlementAction = onSettlementAction
        self.refreshCutReservationState()
    }

    func reconcile(rootURL: URL? = nil) async {
        if let rootURL {
            self.rootURL = rootURL
            self.refreshCutReservationState()
        }
        guard !self.isReconciling else { return }
        guard let rootURL = self.rootURL else {
            await self.holdPendingGateOwners()
            await self.conservativelyGateOmi()
            return
        }
        guard !self.cutReservationProbeFailed else {
            await self.holdPendingGateOwners()
            await self.conservativelyGateOmi()
            return
        }
        self.isReconciling = true
        defer {
            self.isReconciling = false
            if let pendingSuccessor {
                self.pendingSuccessor = nil
                self.armReconciliationSuccessor(delayed: pendingSuccessor == .delayed)
            }
        }
        guard self.sourceManager.isLaunchCaptureRecoveryEnabled else {
            await self.holdPendingGateOwners()
            await self.conservativelyGateOmi()
            return
        }

        guard await self.beginCutIfNeeded() else {
            await self.holdPendingGateOwners()
            await self.conservativelyGateOmi()
            return
        }
        guard self.cutLifecycle != .defect else {
            await self.holdPendingGateOwners()
            await self.conservativelyGateOmi()
            if let defect = self.pendingCutFinalDefect {
                await self.commitCutFinalDefect(defect)
            }
            return
        }

        self.enumeratedHandoffs = []
        let reconciliationRoots: [URL]
        switch self.cutLifecycle {
        case .reservedSettlement:
            reconciliationRoots = [rootURL, OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: rootURL)]
        case .ordinary, .sealedSettlement, .defect:
            reconciliationRoots = [rootURL]
        }
        let enumeration = self.enumerateLinkedIDs(rootURLs: reconciliationRoots)
        switch enumeration {
        case .unknown:
            await self.holdPendingGateOwners()
            await self.conservativelyGateOmi()
            return
        case .scannedNothingLinked:
            await self.releaseCleanUnlinkedCoordinatorHolds(attachedItemIDs: [])
            break
        case .scannedWithLinkedIDs(let handoffs):
            self.enumeratedHandoffs = handoffs
            await self.restoreCoordinatorHolds(for: handoffs)
            await self.registerExistingOwners(handoffs)
            await self.releaseCleanUnlinkedCoordinatorHolds(attachedItemIDs: Set(handoffs.map(\.itemID)))
        }

        guard var generationIDs = self.generationIDs(rootURL: rootURL) else {
            await self.holdPendingGateOwners()
            await self.conservativelyGateOmi()
            return
        }
        let activeGenerationID = self.sourceManager.activeLaunchCaptureGenerationID
        let sealedGenerationID = self.cutLifecycle.intent?.sealedGenerationID ?? activeGenerationID
        if let sealedGenerationID {
            generationIDs.insert(sealedGenerationID)
        }

        var activeResult: (result: OmiLaunchCaptureMaterializationResult, reader: OmiLaunchCaptureLeaseReader)?
        var settledReaders: [(rootURL: URL, generationID: UUID, reader: OmiLaunchCaptureLeaseReader)] = []
        var shouldRetry = false
        var shouldDelayRetry = false
        var sawBoundary = false
        var failed = false
        let ordering = self.generationsInCaptureOrder(generationIDs, rootURL: rootURL)
        guard !ordering.hasUnreadableHeader else {
            await self.holdPendingGateOwners()
            await self.conservativelyGateOmi()
            return
        }
        for generationID in ordering.generationIDs {
            switch await self.reconcile(generationID: generationID, rootURL: rootURL) {
            case .settled(let result, let reader):
                self.deliverReplayMarkers(result.markers, reader: reader)
                settledReaders.append((rootURL, generationID, reader))
                if generationID == sealedGenerationID {
                    activeResult = (result, reader)
                }
                self.dropMaterializerSession(reason: "settled")
            case .retryRequired(let result, let reader):
                self.deliverReplayMarkers(result.markers, reader: reader)
                shouldRetry = true
            case .retryDelayed(let result, let reader):
                self.deliverReplayMarkers(result.markers, reader: reader)
                shouldRetry = true
                shouldDelayRetry = true
            case .held:
                // A held owner leaves the durable frontier unchanged. Discard the
                // in-memory tail so an explicit resume re-derives its deterministic
                // artifact and owner from that frontier.
                self.dropMaterializerSession(reason: "held")
            case .boundary:
                sawBoundary = true
                self.dropMaterializerSession(reason: "boundary")
            case .failed:
                failed = true
                self.dropMaterializerSession(reason: "terminal failure")
            }
        }

        if case .reservedSettlement(let intent, _) = self.cutLifecycle {
            let reservedRoot = OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: rootURL)
            guard let reservedIDs = self.generationIDs(rootURL: reservedRoot) else {
                await self.holdPendingGateOwners()
                await self.conservativelyGateOmi()
                return
            }
            for generationID in self.generationsInCaptureOrder(reservedIDs, rootURL: reservedRoot).generationIDs {
                switch await self.reconcile(generationID: generationID, rootURL: reservedRoot) {
                case .settled(let result, let reader):
                    self.deliverReplayMarkers(result.markers, reader: reader)
                    settledReaders.append((reservedRoot, generationID, reader))
                    self.dropMaterializerSession(reason: "reserved settled")
                case .retryRequired, .retryDelayed:
                    shouldRetry = true
                case .held, .boundary, .failed:
                    failed = true
                }
            }
            _ = intent
        }

        let unsettledLinkedGenerationIDs = await self.settleAcknowledgedAttachedHandoffs()
        await self.holdPendingGateOwners()

        // Retirement is post-settlement maintenance. A handoff owner may need its cursor
        // as durable acknowledgment evidence until its gate has been released or held.
        for reader in settledReaders where !unsettledLinkedGenerationIDs.contains(reader.generationID) {
            // An intent/final record names the sealed capture as recovery evidence;
            // it must outlive settlement until the retention follow-up can retire it.
            if reader.generationID != self.cutLifecycle.intent?.sealedGenerationID {
                _ = reader.reader.retireIfEligible(activeGenerationID: activeGenerationID)
            }
            if reader.generationID != activeGenerationID, reader.generationID != self.cutLifecycle.intent?.sealedGenerationID {
                self.dropMaterializerSession(reason: "retired")
            }
        }

        guard !failed, !sawBoundary else { return }
        guard !shouldRetry else {
            self.requestReconciliation(delayed: shouldDelayRetry)
            return
        }
        guard let activeResult else { return }
        await self.finishCutoverIfCurrent(result: activeResult.result, reader: activeResult.reader)
    }

    func resumeAfterExplicitEnable() async {
        guard self.sourceManager.isLaunchCaptureRecoveryEnabled,
              !self.isReconciling,
              self.cutLifecycle != .defect
        else { return }
        self.isResumingAfterExplicitEnable = true
        await self.reconcile()
        self.isResumingAfterExplicitEnable = false
    }

    func conservativelyGateOmi() async {
        for item in await self.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi) {
            // A successful restoration proves a different subsystem already owns this
            // lifetime hold. Put it back without recording a coordinator reason.
            switch await self.engine.restoreGateFromHold(itemID: item.itemID) {
            case .gated(let existingHold):
                switch await self.engine.convertGateToHold(existingHold) {
                case .settled, .alreadyConverted:
                    break
                case .alreadyReleased, .unknownToken, .mismatchedToken:
                    // The restoration issued this process-local token. Retain it for
                    // retry rather than leaving an active gate without an owner.
                    self.pendingGateOwnersByItemID[item.itemID] = .attached(existingHold)
                }
                continue
            case .alreadyGated:
                continue
            case .notHeld, .engineNotInitialized:
                break
            }
            switch await self.engine.gateExisting(itemID: item.itemID) {
            case .gated(let token):
                if !(await self.convertGateToHold(token, itemID: item.itemID, reason: .conservative)) {
                    self.pendingGateOwnersByItemID[item.itemID] = .attached(token)
                }
            case .alreadyGated:
                continue
            case .dispatchAlreadyEnabled:
                await self.engine.hold(itemID: item.itemID)
                self.coordinatorHoldReasonsByItemID[item.itemID] = .conservative
            case .engineNotInitialized:
                await self.engine.hold(itemID: item.itemID)
            }
        }
    }

    private func reconcile(generationID: UUID, rootURL: URL) async -> GenerationOutcome {
        let reader = OmiLaunchCaptureLeaseReader(rootURL: rootURL, generationID: generationID, io: self.io)
        let scan = OmiLaunchCaptureRecovery(rootURL: rootURL, generationID: generationID, io: self.io).recover()
        // A recovery read failure verifies no prefix. Do not let a second read race
        // past that failure and create an owner from an unverified capture.
        if scan.boundaryReason == .readFailed, scan.boundarySequence == nil {
            await self.conservativelyGateOmi()
            return .failed
        }
        if case .unavailable(let reason) = reader.lease() {
            await self.conservativelyGateOmi()
            if reason == .cursorUnreadable, let defect = reader.cursorDefect() {
                // Re-read deliberately to confirm the defect persists; a transient failure gates without a permanent signal.
                // The reader stays stateless, and a later reconcile retries normally.
                await self.commitUnreadableCursor(defect: defect, generationID: generationID)
            }
            return .failed
        }

        guard let decoder = try? OmiOpusAudioDecoder() else {
            self.log.error("launch capture decoder unavailable")
            await self.conservativelyGateOmi()
            return .failed
        }
        let materializer: OmiLaunchCaptureMaterializer
        if let session = self.materializerSession, session.generationID == generationID, session.rootURL == rootURL {
            materializer = session.materializer
        } else {
            self.dropMaterializerSession(reason: "generation changed")
            // Materializer diagnostics stay test-only: coordinator converts returned
            // failures to the durable transfer attention item below.
            materializer = OmiLaunchCaptureMaterializer(
                rootURL: rootURL,
                generationID: generationID,
                io: self.io,
                decode: { decoder.decode($0) }
            )
            self.materializerSession = (rootURL, generationID, materializer)
        }
        let result = materializer.materializeNextBatch()

        guard await self.commitOrphanRepairFailures(result.orphanRepairFailures, generationID: generationID) else {
            await self.conservativelyGateOmi()
            return .failed
        }
        guard result.orphanRepairFailures.isEmpty else { return .failed }

        if let failure = result.failure {
            guard await self.commitMaterializationFailure(failure, generationID: generationID) else {
                await self.conservativelyGateOmi()
                return .failed
            }
            guard let pending = await self.registerPendingOwners(for: result.partitions) else {
                return self.sourceManager.isLaunchCaptureRecoveryEnabled ? .failed : .held
            }
            let outcome = await self.finishMaterializationFailure(
                pending: pending,
                reader: reader,
                coveredThroughSequence: result.coveredThroughSequence,
                generationID: generationID,
                rootURL: rootURL
            )
            if case .held = outcome { return outcome }
            // A failed materialization may have durably persisted an earlier
            // partition from this lease. Its acknowledged and materialized
            // prefixes moved together only after the owner was gated, so the
            // retry resumes from that settled boundary.
            self.dropMaterializerSession(reason: "materialization retry")
            return .retryDelayed(result, reader)
        }

        guard let pending = await self.registerPendingOwners(for: result.partitions) else {
            return self.sourceManager.isLaunchCaptureRecoveryEnabled ? .failed : .held
        }

        guard !pending.isEmpty else {
            if let frontier = result.materializedFrontier,
               !self.commitSettled(
                    reader: reader,
                    throughSequence: frontier.throughSequence,
                    nextPartitionOrdinal: frontier.nextPartitionOrdinal,
                    nextSampleOffset: frontier.nextSampleOffset
               ) {
                await self.conservativelyGateOmi()
                return .failed
            }
            if scan.boundaryReason != nil {
                return await self.commitBoundary(scan: scan, generationID: generationID) ? .boundary : .failed
            }
            guard case .empty = reader.lease() else {
                if result.materializedFrontier == nil, result.coveredThroughSequence == nil {
                    guard await self.commitNoProgress(generationID: generationID, reader: reader) else {
                        await self.conservativelyGateOmi()
                        return .failed
                    }
                    return .retryDelayed(result, reader)
                }
                return .retryRequired(result, reader)
            }
            return .settled(result, reader)
        }
        guard let coveredThroughSequence = result.coveredThroughSequence,
              pending.last?.partition.endsAtSourceFrameBoundary == true
        else {
            await self.hold(pending)
            return .failed
        }
        if self.isSealed(generationID) { await self.observe(.afterSealedOwnershipVerified) }
        guard self.sourceManager.isLaunchCaptureRecoveryEnabled else {
            await self.hold(pending, retainForExplicitResume: true)
            return .held
        }
        guard let partition = pending.last?.partition,
              self.commitSettled(
                reader: reader,
                throughSequence: coveredThroughSequence,
                nextPartitionOrdinal: partition.nextPartitionOrdinal,
                nextSampleOffset: partition.nextSampleOffset
              )
        else {
            await self.hold(pending)
            await self.commitSettlementAttention(
                pending,
                generationID: generationID,
                rootURL: rootURL,
                action: "acknowledgment"
            )
            return .failed
        }
        if self.isSealed(generationID) { await self.observe(.afterSealedCursorAcknowledged) }
        guard (await self.settleOwners(
            self.settlementOwners(for: pending, generationID: generationID, rootURL: rootURL)
        )).isEmpty else { return .failed }

        if scan.boundaryReason != nil {
            return await self.commitBoundary(scan: scan, generationID: generationID) ? .boundary : .failed
        }
        guard case .empty = reader.lease() else { return .retryRequired(result, reader) }
        return .settled(result, reader)
    }

    private func registerPendingOwners(for partitions: [OmiLaunchCaptureMaterializedPartition]) async -> [PendingOwner]? {
        var pending: [PendingOwner] = []
        for partition in partitions {
            guard let token = await self.registerOwner(for: partition) else {
                self.log.error("launch capture owner settlement registration failed")
                await self.holdPendingGateOwners()
                return nil
            }
            let owner = PendingOwner(partition: partition, token: token)
            pending.append(owner)
            self.pendingGateOwnersByItemID[partition.itemID] = .registered(owner)
            guard self.sourceManager.isLaunchCaptureRecoveryEnabled else {
                await self.hold(pending, retainForExplicitResume: true)
                return nil
            }
        }
        return pending
    }

    private func commitSettled(
        reader: OmiLaunchCaptureLeaseReader,
        throughSequence: UInt64,
        nextPartitionOrdinal: UInt64,
        nextSampleOffset: UInt64
    ) -> Bool {
        switch reader.commitSettled(
            throughSequence: throughSequence,
            nextPartitionOrdinal: nextPartitionOrdinal,
            nextSampleOffset: nextSampleOffset
        ) {
        case .advanced, .noOp:
            return true
        case .refused:
            return false
        }
    }

    private func finishMaterializationFailure(
        pending: [PendingOwner],
        reader: OmiLaunchCaptureLeaseReader,
        coveredThroughSequence: UInt64?,
        generationID: UUID,
        rootURL: URL
    ) async -> GenerationOutcome {
        guard !pending.isEmpty else { return .failed }
        guard let coveredThroughSequence,
              pending.last?.partition.endsAtSourceFrameBoundary == true
        else {
            await self.hold(pending)
            return .failed
        }
        if self.isSealed(generationID) { await self.observe(.afterSealedOwnershipVerified) }
        guard self.sourceManager.isLaunchCaptureRecoveryEnabled else {
            await self.hold(pending, retainForExplicitResume: true)
            return .failed
        }
        guard let partition = pending.last?.partition,
              self.commitSettled(
                reader: reader,
                throughSequence: coveredThroughSequence,
                nextPartitionOrdinal: partition.nextPartitionOrdinal,
                nextSampleOffset: partition.nextSampleOffset
              )
        else {
            await self.hold(pending)
            await self.commitSettlementAttention(
                pending,
                generationID: generationID,
                rootURL: rootURL,
                action: "acknowledgment"
            )
            return .failed
        }
        if self.isSealed(generationID) { await self.observe(.afterSealedCursorAcknowledged) }
        guard (await self.settleOwners(
            self.settlementOwners(for: pending, generationID: generationID, rootURL: rootURL)
        )).isEmpty else { return .failed }
        return .failed
    }

    private func restoreCoordinatorHolds(for handoffs: [LinkedHandoff]) async {
        let attachedIDs = Set(handoffs.map(\.itemID))
        for itemID in attachedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let reason = self.coordinatorHoldReasonsByItemID[itemID], reason != .explicitResume else { continue }
            switch await self.engine.restoreGateFromHold(itemID: itemID) {
            case .gated(let token):
                self.pendingGateOwnersByItemID[itemID] = .attached(token)
            case .notHeld, .alreadyGated, .engineNotInitialized:
                await self.engine.hold(itemID: itemID)
                self.coordinatorHoldReasonsByItemID[itemID] = reason
            }
        }
    }

    /// A successful capture scan proves coordinator-owned holds with no durable
    /// handoff are already beyond capture settlement. This also closes the
    /// restart window after the final settlement marker is removed but before
    /// Transfer dispatches the item. Holds owned by another subsystem never
    /// appear in `coordinatorHoldReasonsByItemID` and remain untouched.
    private func releaseCleanUnlinkedCoordinatorHolds(attachedItemIDs: Set<UUID>) async {
        let itemIDs = self.coordinatorHoldReasonsByItemID.keys
            .filter { !attachedItemIDs.contains($0) }
            .sorted { $0.uuidString < $1.uuidString }
        for itemID in itemIDs {
            switch await self.engine.restoreGateFromHold(itemID: itemID) {
            case .gated(let token):
                switch await self.release(token, itemID: itemID) {
                case .released:
                    self.pendingGateOwnersByItemID.removeValue(forKey: itemID)
                case .disabled(let retainedToken):
                    if await self.convertGateToHold(retainedToken, itemID: itemID, reason: .explicitResume) {
                        self.pendingGateOwnersByItemID.removeValue(forKey: itemID)
                    } else {
                        self.pendingGateOwnersByItemID[itemID] = .attached(retainedToken)
                    }
                case .failed:
                    self.pendingGateOwnersByItemID.removeValue(forKey: itemID)
                }
            case .notHeld:
                self.coordinatorHoldReasonsByItemID.removeValue(forKey: itemID)
            case .alreadyGated, .engineNotInitialized:
                break
            }
        }
    }

    private func registerExistingOwners(_ handoffs: [LinkedHandoff]) async {
        for itemID in Set(handoffs.map(\.itemID)).sorted(by: { $0.uuidString < $1.uuidString }) {
            let itemHandoffs = handoffs.filter { $0.itemID == itemID }
            if let readyHandoff = itemHandoffs.first(where: { OmiPendingHandoffStore.isSettlementURL($0.envelopeURL) }) {
                guard let envelope = try? OmiPendingHandoffStore.read(from: readyHandoff.envelopeURL), envelope.isSupported else {
                    await self.engine.hold(itemID: itemID)
                    self.coordinatorHoldReasonsByItemID[itemID] = .conservative
                    continue
                }
                let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(
                    itemID: itemID,
                    sidecar: envelope.sidecar,
                    metadata: envelope.metadata
                )
                let ownership = try? await self.engine.verifyOwnership(
                    expectedManifest: manifest,
                    expectedPayloadSourceURLs: [:]
                )
                switch ownership {
                case .notFound:
                    // The durable marker proves capture settlement completed.
                    // If Transfer no longer owns the item, delivery/retirement
                    // already crossed the terminal side of the handoff.
                    for handoff in itemHandoffs {
                        try? self.io.removeItem(at: handoff.envelopeURL)
                    }
                    self.coordinatorHoldReasonsByItemID.removeValue(forKey: itemID)
                    continue
                case .ownedInQueued, .ownedInAttention:
                    break
                case .stagingOnly, .salvageOnly, .conflict, .none:
                    await self.engine.hold(itemID: itemID)
                    self.coordinatorHoldReasonsByItemID[itemID] = .conservative
                    continue
                }
            }
            if self.isResumingAfterExplicitEnable,
               self.coordinatorHoldReasonsByItemID[itemID] == .explicitResume {
                switch await self.engine.restoreGateFromHold(itemID: itemID) {
                case .gated(let token):
                    self.pendingGateOwnersByItemID[itemID] = .attached(token)
                case .notHeld, .alreadyGated, .engineNotInitialized:
                    await self.engine.hold(itemID: itemID)
                    self.coordinatorHoldReasonsByItemID[itemID] = .explicitResume
                }
                continue
            }
            // Hold restoration above already issued the only live token this
            // coordinator may settle. Do not re-register and re-hold it.
            if self.pendingGateOwnersByItemID[itemID] != nil { continue }
            switch await self.engine.gateExisting(itemID: itemID) {
            case .gated(let token):
                self.pendingGateOwnersByItemID[itemID] = .attached(token)
            case .alreadyGated:
                continue
            case .dispatchAlreadyEnabled:
                await self.engine.hold(itemID: itemID)
                switch await self.engine.restoreGateFromHold(itemID: itemID) {
                case .gated(let token):
                    self.pendingGateOwnersByItemID[itemID] = .attached(token)
                case .notHeld, .alreadyGated, .engineNotInitialized:
                    self.coordinatorHoldReasonsByItemID[itemID] = .settlementRetry
                }
            case .engineNotInitialized:
                self.log.error("launch capture gate unavailable")
                await self.engine.hold(itemID: itemID)
            }
        }
    }

    private func registerOwner(for partition: OmiLaunchCaptureMaterializedPartition) async -> TransferGateToken? {
        guard let envelope = try? OmiPendingHandoffStore.read(from: partition.envelopeURL), envelope.isSupported else {
            await self.conservativelyGateOmi()
            return nil
        }
        let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: partition.itemID, sidecar: envelope.sidecar, metadata: envelope.metadata)
        let expectedURLs = partition.isExistingOwner ? [:] : ["audio": partition.audioURL]
        let ownership = try? await self.engine.verifyOwnership(expectedManifest: manifest, expectedPayloadSourceURLs: expectedURLs)
        switch ownership {
        case .ownedInQueued, .ownedInAttention:
            if let owner = self.pendingGateOwnersByItemID[partition.itemID] {
                switch owner {
                case .attached(let token):
                    return token
                case .registered(let pending):
                    return pending.token
                }
            }
            await self.engine.hold(itemID: partition.itemID)
            return nil
        case .notFound:
            guard !partition.isExistingOwner else {
                await self.engine.hold(itemID: partition.itemID)
                return nil
            }
            let token: TransferGateToken
            do {
                token = try await self.engine.enqueueGated(manifest: manifest, payloadFileURLs: ["audio": partition.audioURL])
            } catch {
                self.log.error("launch capture gated enqueue failed")
                await self.conservativelyGateOmi()
                return nil
            }
            guard (try? self.io.fileExists(at: partition.audioURL)) == false else {
                if !(await self.convertGateToHold(token, itemID: partition.itemID, reason: .settlementRetry)) {
                    self.pendingGateOwnersByItemID[partition.itemID] = .attached(token)
                }
                return nil
            }
            if let generationID = self.materializerSession?.generationID, self.isSealed(generationID) {
                await self.observe(.afterSealedOwnerGatedEnqueued)
            }
            return token
        case .stagingOnly, .salvageOnly, .conflict, .none:
            await self.engine.hold(itemID: partition.itemID)
            return nil
        }
    }

    private func settlementOwners(
        for pending: [PendingOwner],
        generationID: UUID,
        rootURL: URL
    ) -> [SettlementOwner] {
        let captureStartedAtUnixMicros = OmiLaunchCaptureLeaseReader(
            rootURL: rootURL,
            generationID: generationID,
            io: self.io
        ).captureStartTime() ?? Int64.max
        return pending.map { owner in
            SettlementOwner(
                itemID: owner.partition.itemID,
                token: owner.token,
                handoffs: [
                    SettlementHandoff(
                        generationID: generationID,
                        envelopeURL: owner.partition.envelopeURL,
                        partitionOrdinal: owner.partition.nextPartitionOrdinal == 0
                            ? 0
                            : owner.partition.nextPartitionOrdinal - 1,
                        captureStartedAtUnixMicros: captureStartedAtUnixMicros
                    ),
                ],
                isAcknowledged: true
            )
        }
    }

    /// Settles every owner in capture order. A failed owner is held or retained
    /// for retry, but never short-circuits settlement of later owners.
    private func settleOwners(_ owners: [SettlementOwner]) async -> Set<UUID> {
        var unsettledGenerationIDs: Set<UUID> = []
        for owner in owners.sorted(by: self.settlementOwnerPrecedes) {
            let generationIDs = Set(owner.handoffs.map(\.generationID))
            guard self.sourceManager.isLaunchCaptureRecoveryEnabled else {
                unsettledGenerationIDs.formUnion(generationIDs)
                await self.retainForExplicitResume(owner)
                continue
            }
            guard owner.isAcknowledged else {
                unsettledGenerationIDs.formUnion(generationIDs)
                if !(await self.convertGateToHold(owner.token, itemID: owner.itemID, reason: .settlementRetry)) {
                    self.pendingGateOwnersByItemID[owner.itemID] = .attached(owner.token)
                    await self.commitSettlementAttention(owner, action: "gate_conversion")
                } else {
                    self.pendingGateOwnersByItemID.removeValue(forKey: owner.itemID)
                }
                continue
            }

            guard let preparedHandoffs = self.prepareSettlementHandoffs(owner.handoffs) else {
                unsettledGenerationIDs.formUnion(generationIDs)
                if !(await self.convertGateToHold(owner.token, itemID: owner.itemID, reason: .settlementRetry)) {
                    self.pendingGateOwnersByItemID[owner.itemID] = .attached(owner.token)
                    await self.commitSettlementAttention(owner, action: "gate_conversion")
                } else {
                    self.pendingGateOwnersByItemID.removeValue(forKey: owner.itemID)
                }
                await self.commitSettlementAttention(owner, action: "cleanup")
                continue
            }

            let preparedOwner = SettlementOwner(
                itemID: owner.itemID,
                token: owner.token,
                handoffs: preparedHandoffs,
                isAcknowledged: owner.isAcknowledged
            )

            if preparedOwner.handoffs.contains(where: { self.isSealed($0.generationID) }) {
                await self.observe(.afterSealedEnvelopeCleaned)
            }
            if preparedOwner.handoffs.contains(where: { self.isSealed($0.generationID) }) {
                await self.observe(.beforeSealedOwnerReleased)
            } else if !preparedOwner.handoffs.isEmpty {
                await self.observe(.beforeReservedOwnerReleased)
            }
            guard self.sourceManager.isLaunchCaptureRecoveryEnabled else {
                unsettledGenerationIDs.formUnion(generationIDs)
                await self.retainForExplicitResume(preparedOwner)
                continue
            }

            switch await self.release(preparedOwner.token, itemID: preparedOwner.itemID) {
            case .released:
                if !self.removeSettlementHandoffs(preparedOwner.handoffs) {
                    unsettledGenerationIDs.formUnion(generationIDs)
                    await self.commitSettlementAttention(preparedOwner, action: "cleanup")
                    self.requestReconciliation(delayed: true)
                }
                if preparedOwner.handoffs.contains(where: { self.isSealed($0.generationID) }) {
                    await self.observe(.afterSealedOwnerReleased)
                    self.requestReconciliation(delayed: true)
                } else if !preparedOwner.handoffs.isEmpty {
                    await self.observe(.afterReservedOwnerReleased)
                }
                self.pendingGateOwnersByItemID.removeValue(forKey: preparedOwner.itemID)
            case .disabled(let retainedToken):
                unsettledGenerationIDs.formUnion(generationIDs)
                await self.retainForExplicitResume(
                    SettlementOwner(
                        itemID: preparedOwner.itemID,
                        token: retainedToken,
                        handoffs: preparedOwner.handoffs,
                        isAcknowledged: preparedOwner.isAcknowledged
                    )
                )
            case .failed:
                unsettledGenerationIDs.formUnion(generationIDs)
                self.pendingGateOwnersByItemID[preparedOwner.itemID] = .attached(preparedOwner.token)
                await self.commitSettlementAttention(preparedOwner, action: "release")
            }
        }
        return unsettledGenerationIDs
    }

    /// Installs a durable settlement marker before removing each live handoff.
    /// At every crash point, at least one file still carries the owner identity
    /// needed to rebuild its gate before Transfer dispatch opens.
    private func prepareSettlementHandoffs(_ handoffs: [SettlementHandoff]) -> [SettlementHandoff]? {
        var preparedByURL: [URL: SettlementHandoff] = [:]
        var transitioned: [(originalURL: URL, markerURL: URL, data: Data)] = []
        for handoff in handoffs.sorted(by: { $0.envelopeURL.path < $1.envelopeURL.path }) {
            if OmiPendingHandoffStore.isSettlementURL(handoff.envelopeURL) {
                guard let envelope = try? OmiPendingHandoffStore.read(from: handoff.envelopeURL), envelope.isSupported else {
                    _ = self.rollbackSettlementHandoffs(transitioned)
                    return nil
                }
                preparedByURL[handoff.envelopeURL] = handoff
                continue
            }
            do {
                let envelope = try OmiPendingHandoffStore.read(from: handoff.envelopeURL)
                guard envelope.isSupported else { throw CocoaError(.fileReadCorruptFile) }
                let data = try OmiPendingHandoffStore.encode(envelope)
                let markerURL = OmiPendingHandoffStore.settlementURL(for: handoff.envelopeURL)
                try OmiPendingHandoffStore.write(data, to: markerURL, io: self.io)
                transitioned.append((handoff.envelopeURL, markerURL, data))
                try self.io.removeItem(at: handoff.envelopeURL)
                preparedByURL[markerURL] = SettlementHandoff(
                    generationID: handoff.generationID,
                    envelopeURL: markerURL,
                    partitionOrdinal: handoff.partitionOrdinal,
                    captureStartedAtUnixMicros: handoff.captureStartedAtUnixMicros
                )
            } catch {
                if !self.rollbackSettlementHandoffs(transitioned) {
                    self.log.error("launch capture settlement marker rollback failed")
                }
                return nil
            }
        }
        return preparedByURL.values.sorted(by: { $0.envelopeURL.path < $1.envelopeURL.path })
    }

    private func rollbackSettlementHandoffs(_ transitioned: [(originalURL: URL, markerURL: URL, data: Data)]) -> Bool {
        var restored = true
        for transition in transitioned.reversed() {
            do {
                if try !self.io.fileExists(at: transition.originalURL) {
                    try OmiPendingHandoffStore.write(transition.data, to: transition.originalURL, io: self.io)
                }
                if try self.io.fileExists(at: transition.markerURL) {
                    try self.io.removeItem(at: transition.markerURL)
                }
            } catch {
                restored = false
            }
        }
        return restored
    }

    private func removeSettlementHandoffs(_ handoffs: [SettlementHandoff]) -> Bool {
        var removed = true
        for handoff in handoffs {
            do {
                if try self.io.fileExists(at: handoff.envelopeURL) {
                    try self.io.removeItem(at: handoff.envelopeURL)
                }
            } catch {
                removed = false
                self.log.error("launch capture settlement marker removal failed")
            }
        }
        return removed
    }

    private func settlementOwnerPrecedes(_ lhs: SettlementOwner, _ rhs: SettlementOwner) -> Bool {
        let left = lhs.handoffs.min(by: Self.settlementHandoffPrecedes)
        let right = rhs.handoffs.min(by: Self.settlementHandoffPrecedes)
        switch (left, right) {
        case (.some(let left), .some(let right)):
            if left.captureStartedAtUnixMicros != right.captureStartedAtUnixMicros {
                return left.captureStartedAtUnixMicros < right.captureStartedAtUnixMicros
            }
            if left.partitionOrdinal != right.partitionOrdinal {
                return left.partitionOrdinal < right.partitionOrdinal
            }
            return lhs.itemID.uuidString < rhs.itemID.uuidString
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs.itemID.uuidString < rhs.itemID.uuidString
        }
    }

    private static func settlementHandoffPrecedes(_ lhs: SettlementHandoff, _ rhs: SettlementHandoff) -> Bool {
        if lhs.captureStartedAtUnixMicros != rhs.captureStartedAtUnixMicros {
            return lhs.captureStartedAtUnixMicros < rhs.captureStartedAtUnixMicros
        }
        if lhs.partitionOrdinal != rhs.partitionOrdinal {
            return lhs.partitionOrdinal < rhs.partitionOrdinal
        }
        return lhs.envelopeURL.path < rhs.envelopeURL.path
    }

    private func retainForExplicitResume(_ owner: SettlementOwner) async {
        if await self.convertGateToHold(owner.token, itemID: owner.itemID, reason: .explicitResume) {
            self.pendingGateOwnersByItemID.removeValue(forKey: owner.itemID)
        } else {
            self.pendingGateOwnersByItemID[owner.itemID] = .attached(owner.token)
        }
    }

    private func release(_ token: TransferGateToken, itemID: UUID) async -> OwnerReleaseOutcome {
        let outcome: TransferGateSettlementOutcome?
        if let injected = self.onSettlementAction?(itemID, .release) {
            outcome = injected
        } else {
            let sourceManager = self.sourceManager
            outcome = await self.engine.releaseGate(
                token,
                if: { sourceManager.isLaunchCaptureRecoveryEnabledForSettlement() }
            )
        }
        guard let outcome else { return .disabled(token) }
        switch outcome {
        case .settled, .alreadyReleased:
            guard self.coordinatorHoldReasonsByItemID[itemID] != nil else { return .released }
            switch await self.engine.restoreGateFromHold(itemID: itemID) {
            case .gated(let restored):
                let restoredOutcome: TransferGateSettlementOutcome?
                if let injected = self.onSettlementAction?(itemID, .release) {
                    restoredOutcome = injected
                } else {
                    let sourceManager = self.sourceManager
                    restoredOutcome = await self.engine.releaseGate(
                        restored,
                        if: { sourceManager.isLaunchCaptureRecoveryEnabledForSettlement() }
                    )
                }
                guard let restoredOutcome else { return .disabled(restored) }
                switch restoredOutcome {
                case .settled, .alreadyReleased:
                    self.coordinatorHoldReasonsByItemID.removeValue(forKey: itemID)
                    return .released
                case .alreadyConverted, .unknownToken, .mismatchedToken:
                    await self.engine.hold(itemID: itemID)
                    self.coordinatorHoldReasonsByItemID[itemID] = .settlementRetry
                    return .failed
                }
            case .notHeld:
                self.coordinatorHoldReasonsByItemID.removeValue(forKey: itemID)
                return .released
            case .alreadyGated, .engineNotInitialized:
                await self.engine.hold(itemID: itemID)
                self.coordinatorHoldReasonsByItemID[itemID] = .settlementRetry
                return .failed
            }
        case .alreadyConverted, .unknownToken, .mismatchedToken:
            await self.engine.hold(itemID: itemID)
            self.coordinatorHoldReasonsByItemID[itemID] = .settlementRetry
            return .failed
        }
    }

    private func hold(_ pending: [PendingOwner], retainForExplicitResume: Bool = false) async {
        let reason: CoordinatorHoldReason = retainForExplicitResume ? .explicitResume : .settlementRetry
        for owner in pending.sorted(by: { $0.partition.itemID.uuidString < $1.partition.itemID.uuidString }) {
            if await self.convertGateToHold(owner.token, itemID: owner.partition.itemID, reason: reason) {
                self.pendingGateOwnersByItemID.removeValue(forKey: owner.partition.itemID)
            } else {
                self.pendingGateOwnersByItemID[owner.partition.itemID] = .registered(owner)
            }
        }
    }

    private func convertGateToHold(_ token: TransferGateToken, itemID: UUID, reason: CoordinatorHoldReason) async -> Bool {
        let outcome: TransferGateSettlementOutcome
        if let injected = self.onSettlementAction?(itemID, .gateConversion) {
            outcome = injected
        } else {
            outcome = await self.engine.convertGateToHold(token)
        }
        switch outcome {
        case .settled, .alreadyConverted:
            self.coordinatorHoldReasonsByItemID[itemID] = reason
            return true
        case .alreadyReleased, .unknownToken, .mismatchedToken:
            await self.engine.hold(itemID: itemID)
            self.coordinatorHoldReasonsByItemID[itemID] = reason
            return false
        }
    }

    private func settleAcknowledgedAttachedHandoffs() async -> Set<UUID> {
        guard self.rootURL != nil else { return Set(self.enumeratedHandoffs.map(\.generationID)) }
        let attachedOwners = self.pendingGateOwnersByItemID.compactMap { itemID, owner -> (UUID, TransferGateToken)? in
            switch owner {
            case .attached(let token): (itemID, token)
            case .registered: nil
            }
        }.sorted { $0.0.uuidString < $1.0.uuidString }
        var owners: [SettlementOwner] = []
        for (itemID, token) in attachedOwners {
            let handoffs = self.enumeratedHandoffs
                .filter { $0.itemID == itemID }
                .sorted { lhs, rhs in
                    if lhs.captureStartedAtUnixMicros != rhs.captureStartedAtUnixMicros {
                        return lhs.captureStartedAtUnixMicros < rhs.captureStartedAtUnixMicros
                    }
                    if lhs.partitionOrdinal != rhs.partitionOrdinal {
                        return lhs.partitionOrdinal < rhs.partitionOrdinal
                    }
                    return lhs.envelopeURL.path < rhs.envelopeURL.path
                }
            guard !handoffs.isEmpty else { continue }
            var acknowledged = true
            for handoff in handoffs {
                let reader = OmiLaunchCaptureLeaseReader(rootURL: handoff.rootURL, generationID: handoff.generationID, io: self.io)
                guard let envelope = try? OmiPendingHandoffStore.read(from: handoff.envelopeURL),
                      envelope.isSupported
                else {
                    acknowledged = false
                    continue
                }
                if !OmiPendingHandoffStore.isSettlementURL(handoff.envelopeURL) {
                    guard reader.hasDurableAcknowledgment(), case .empty = reader.lease() else {
                        acknowledged = false
                        continue
                    }
                }
                let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: handoff.itemID, sidecar: envelope.sidecar, metadata: envelope.metadata)
                guard let ownership = try? await self.engine.verifyOwnership(expectedManifest: manifest, expectedPayloadSourceURLs: [:]),
                      ownership == .ownedInQueued || ownership == .ownedInAttention
                else {
                    acknowledged = false
                    continue
                }
            }
            owners.append(
                SettlementOwner(
                    itemID: itemID,
                    token: token,
                    handoffs: handoffs.map {
                        SettlementHandoff(
                            generationID: $0.generationID,
                            envelopeURL: $0.envelopeURL,
                            partitionOrdinal: $0.partitionOrdinal,
                            captureStartedAtUnixMicros: $0.captureStartedAtUnixMicros
                        )
                    },
                    isAcknowledged: acknowledged
                )
            )
        }
        return await self.settleOwners(owners)
    }

    private func holdPendingGateOwners() async {
        let owners = self.pendingGateOwnersByItemID.sorted { $0.key.uuidString < $1.key.uuidString }
        for (itemID, owner) in owners {
            if await self.convertGateToHold(owner.token, itemID: itemID, reason: .settlementRetry) {
                self.pendingGateOwnersByItemID.removeValue(forKey: itemID)
            } else if let settlementOwner = self.settlementOwner(itemID: itemID, owner: owner) {
                await self.commitSettlementAttention(settlementOwner, action: "gate_conversion")
            }
        }
    }

    private func settlementOwner(itemID: UUID, owner: CoordinatorGateOwner) -> SettlementOwner? {
        switch owner {
        case .registered(let pending):
            guard let session = self.materializerSession else { return nil }
            return self.settlementOwners(
                for: [pending],
                generationID: session.generationID,
                rootURL: session.rootURL
            )[0]
        case .attached(let token):
            let handoffs = self.enumeratedHandoffs
                .filter { $0.itemID == itemID }
                .map {
                    SettlementHandoff(
                        generationID: $0.generationID,
                        envelopeURL: $0.envelopeURL,
                        partitionOrdinal: $0.partitionOrdinal,
                        captureStartedAtUnixMicros: $0.captureStartedAtUnixMicros
                    )
                }
            guard !handoffs.isEmpty else { return nil }
            return SettlementOwner(itemID: itemID, token: token, handoffs: handoffs, isAcknowledged: false)
        }
    }

    private func commitSettlementAttention(
        _ owners: [PendingOwner],
        generationID: UUID,
        rootURL: URL,
        action: String
    ) async {
        for owner in self.settlementOwners(for: owners, generationID: generationID, rootURL: rootURL) {
            await self.commitSettlementAttention(owner, action: action)
        }
    }

    private func commitSettlementAttention(_ owner: SettlementOwner, action: String) async {
        for handoff in owner.handoffs.sorted(by: { $0.envelopeURL.path < $1.envelopeURL.path }) {
            await self.commitSettlementAttention(handoff, ownerItemID: owner.itemID, action: action)
        }
    }

    private func commitSettlementAttention(_ handoff: SettlementHandoff, ownerItemID: UUID, action: String) async {
        let itemID = Self.settlementFailureItemID(
            generationID: handoff.generationID,
            ordinal: handoff.partitionOrdinal,
            ownerItemID: ownerItemID,
            action: action
        )
        let startedAt = Date(timeIntervalSince1970: 0)
        let sidecar = ChunkSidecar(
            segment: ObserverSegmentNaming.segmentString(for: startedAt, durationSeconds: 0),
            day: ObserverSegmentNaming.dayString(for: startedAt),
            chunkIndex: Int(handoff.partitionOrdinal),
            startedAt: startedAt,
            durationS: 0,
            sessionID: handoff.generationID,
            mode: .meeting,
            locationJSONL: nil
        )
        var manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar)
        manifest.payloadParts = []
        manifest.diskState = .attention
        let ownership = try? await self.engine.verifyOwnership(expectedManifest: manifest, expectedPayloadSourceURLs: [:])
        switch ownership {
        case .ownedInQueued, .ownedInAttention:
            return
        case .notFound:
            do {
                _ = try await self.engine.enqueueAttention(
                    manifest: manifest,
                    payloadFileURLs: [:],
                    reason: "launch_capture_settlement_\(action)_failed",
                    detail: "generation=\(handoff.generationID.uuidString.lowercased()) partition=\(handoff.partitionOrdinal) item=\(ownerItemID.uuidString.lowercased()) action=\(action)"
                )
            } catch {
                self.log.error("launch capture settlement attention failed")
            }
        case .stagingOnly, .salvageOnly, .conflict, .none:
            self.log.error("launch capture settlement attention ownership failed")
        }
    }

    private func deliverReplayMarkers(_ markers: [OmiLaunchCaptureMarkerObservation], reader: OmiLaunchCaptureLeaseReader?) {
        guard !markers.isEmpty else { return }
        let filtered: [OmiLaunchCaptureMarkerObservation]
        if let cursor = reader?.cursor() {
            filtered = markers.filter { marker in
                guard let sequence = marker.sequence else { return true }
                return sequence >= cursor.replayMarkerNextSequence
            }
        } else {
            filtered = markers
        }
        self.sourceManager.observeRecoveredLaunchCaptureMarkers(filtered)
        let sequencedMarkers = filtered.compactMap { $0.sequence }
        if let reader, let last = sequencedMarkers.max() {
            // Delivery precedes this durable high-water mark. A crash in this window
            // may replay the marker, but OmiDiagnostics makes replay effects idempotent.
            _ = reader.advanceReplayMarkers(through: last)
        }
    }

    /// Claims the named reserved generation before changing the in-memory route.  The
    /// intent has no frontier, so a failed arm leaves the sealed writer safe to append.
    private func beginCutIfNeeded() async -> Bool {
        guard self.sourceManager.isLaunchCaptureRecoveryEnabled, let rootURL else { return true }
        let intent: OmiLaunchCaptureCutReservation
        switch self.cutLifecycle {
        case .ordinary:
            guard let sealedGenerationID = self.sourceManager.activeLaunchCaptureGenerationID else { return true }
            intent = OmiLaunchCaptureCutReservation(
                sealedGenerationID: sealedGenerationID,
                reservedGenerationID: UUID()
            )
            switch OmiLaunchCaptureCutReservationStore(rootURL: rootURL, io: self.io).commit(intent) {
            case .refused(let reason):
                self.log.error("omi cut intent commit refused: \(String(describing: reason), privacy: .public)")
                return false
            case .committed:
                self.cutLifecycle = .sealedSettlement(intent)
            }
        case .sealedSettlement(let existing):
            intent = existing
        case .reservedSettlement, .defect:
            return true
        }
        if self.sourceManager.activeLaunchCaptureGenerationID == intent.reservedGenerationID {
            self.cutoverArmFailureCount = 0
            self.cutoverArmRetryExhausted = false
            return true
        }
        if self.cutoverArmRetryExhausted {
            _ = await self.commitCutoverArmFailure(intent)
            return false
        }
        if let onReconciliationPhase { await onReconciliationPhase(.afterCutIntentCommittedBeforeRouteSwap) }
        let ingress = OmiLaunchCaptureIngress(
            captureRoot: { OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: rootURL) },
            generationID: intent.reservedGenerationID,
            clock: self.clock,
            io: self.io
        )
        guard self.sourceManager.completeLaunchCaptureCutover(intent, ingress: ingress) else {
            // Retain the intent and retry the same named reserved generation
            // in-process without scanning a writer that is still accepting input.
            self.cutoverArmFailureCount += 1
            if self.cutoverArmFailureCount >= Self.cutoverArmRetryLimit {
                self.cutoverArmRetryExhausted = true
                _ = await self.commitCutoverArmFailure(intent)
            } else {
                self.requestReconciliation(delayed: true)
            }
            return false
        }
        self.cutoverArmFailureCount = 0
        self.cutoverArmRetryExhausted = false
        self.dropMaterializerSession(reason: "sealed ingress frozen")
        return true
    }

    private func finishCutoverIfCurrent(result: OmiLaunchCaptureMaterializationResult, reader: OmiLaunchCaptureLeaseReader) async {
        guard case .sealedSettlement(let intent) = self.cutLifecycle,
              let rootURL,
              await self.finalEvidenceIsSatisfied(intent: intent, result: result, reader: reader)
        else { return }
        let cursor = reader.cursor()!
        let final = OmiLaunchCaptureCutFinal(
            sealedGenerationID: intent.sealedGenerationID,
            sealedNextSequence: cursor.acknowledgedPrefixNextSequence,
            sealedEndOffset: cursor.acknowledgedPrefixEndOffset,
            reservedGenerationID: intent.reservedGenerationID
        )
        switch OmiLaunchCaptureCutFinalStore(rootURL: rootURL, io: self.io).commit(final) {
        case .committed:
            self.cutLifecycle = .reservedSettlement(intent, final)
            if let onReconciliationPhase { await onReconciliationPhase(.afterFinalMarkerCommittedBeforeReservedMaterialization) }
            self.requestReconciliation()
        case .refused(let reason):
            self.log.error("omi cut final commit refused: \(String(describing: reason), privacy: .public)")
        }
    }

    private func requestReconciliation(delayed: Bool = false) {
        if self.isReconciling {
            guard self.pendingSuccessor == nil else { return }
            self.pendingSuccessor = delayed ? .delayed : .immediate
            return
        }
        self.armReconciliationSuccessor(delayed: delayed)
    }

    private func armReconciliationSuccessor(delayed: Bool) {
        guard !self.reconciliationRequested else { return }
        self.reconciliationRequested = true
        if delayed {
            let clock = self.clock
            self.successorTask = Task { @MainActor [weak self, clock] in
                try? await clock.sleep(for: Self.reconciliationNoProgressDelay)
                guard let self else { return }
                await self.runReconciliationSuccessor()
            }
        } else {
            // An immediate successor retains the coordinator only until it runs. This
            // keeps a caller that has just requested reconciliation alive through the
            // next drain batch without retaining a delayed task across teardown.
            self.successorTask = Task { @MainActor in
                await self.runReconciliationSuccessor()
            }
        }
    }

    private func runReconciliationSuccessor() async {
        guard !Task.isCancelled else {
            self.reconciliationRequested = false
            self.successorTask = nil
            return
        }
        self.reconciliationRequested = false
        self.successorTask = nil
        await self.reconcile()
    }

    private func refreshCutReservationState() {
        guard let rootURL else { return }
        let reservationURL = OmiLaunchCaptureCutReservationFormat.fileURL(rootURL: rootURL)
        let entries: [URL]
        do {
            entries = try self.io.contentsOfDirectory(at: rootURL)
        } catch {
            self.cutLifecycle = .defect
            self.cutReservationProbeFailed = true
            self.pendingCutFinalDefect = nil
            return
        }
        guard entries.contains(reservationURL) else {
            self.cutLifecycle = .ordinary
            self.cutReservationProbeFailed = false
            self.pendingCutFinalDefect = nil
            return
        }
        self.cutReservationProbeFailed = false
        switch OmiLaunchCaptureCutReservationStore(rootURL: rootURL, io: self.io).read() {
        case .valid(let intent):
            switch OmiLaunchCaptureCutFinalStore(rootURL: rootURL, io: self.io).read() {
            case .absent:
                self.cutLifecycle = .sealedSettlement(intent)
                self.pendingCutFinalDefect = nil
            case .valid(let final) where final.sealedGenerationID == intent.sealedGenerationID && final.reservedGenerationID == intent.reservedGenerationID:
                guard self.finalMatchesSealedCapture(final, rootURL: rootURL) else {
                    self.cutLifecycle = .defect
                    self.pendingCutFinalDefect = Self.finalMismatchDefect(final)
                    self.sourceManager.markCutReservationDefect()
                    return
                }
                self.cutLifecycle = .reservedSettlement(intent, final)
                self.pendingCutFinalDefect = nil
            case .valid(let final):
                self.cutLifecycle = .defect
                self.pendingCutFinalDefect = Self.finalMismatchDefect(final)
                self.sourceManager.markCutReservationDefect()
                return
            case .unreadable(let defect):
                self.cutLifecycle = .defect
                self.pendingCutFinalDefect = defect
                self.sourceManager.markCutReservationDefect()
                return
            }
            self.sourceManager.restoreCommittedCutReservation(intent, rootURL: rootURL, io: self.io)
        case .absent:
            self.cutLifecycle = .ordinary
            self.pendingCutFinalDefect = nil
        case .unreadable(let defect):
            self.cutLifecycle = .defect
            self.pendingCutFinalDefect = nil
            self.sourceManager.markCutReservationDefect()
            Task { @MainActor [weak self] in
                await self?.commitUnreadableCutReservation(defect)
            }
        }
    }

    private func finalEvidenceIsSatisfied(
        intent: OmiLaunchCaptureCutReservation,
        result: OmiLaunchCaptureMaterializationResult,
        reader: OmiLaunchCaptureLeaseReader
    ) async -> Bool {
        guard let rootURL else { return false }
        let scan = OmiLaunchCaptureRecovery(rootURL: rootURL, generationID: intent.sealedGenerationID, io: self.io).recover()
        guard case .empty = reader.lease(),
              let cursor = reader.cursor(),
              cursor.acknowledgedPrefixNextSequence == cursor.materializedPrefixNextSequence,
              cursor.acknowledgedPrefixEndOffset == cursor.materializedPrefixEndOffset,
              result.verifiedPrefixEndOffset == cursor.acknowledgedPrefixEndOffset,
              scan.boundaryReason == nil,
              scan.verifiedPrefixNextSequence == cursor.acknowledgedPrefixNextSequence,
              scan.verifiedPrefixEndOffset == cursor.acknowledgedPrefixEndOffset
        else { return false }
        guard let provenanceIDs = self.sealedProvenanceIDs(rootURL: rootURL, generationID: intent.sealedGenerationID) else { return false }
        let directory = rootURL.appendingPathComponent(OmiLaunchCaptureFormat.materializedDirectoryName, isDirectory: true)
            .appendingPathComponent(intent.sealedGenerationID.uuidString, isDirectory: true)
        guard let files = try? self.io.contentsOfDirectory(at: directory), !files.contains(where: { $0.pathExtension == OmiPendingHandoffEnvelope.pathExtension }) else { return false }
        let snapshotIDs = Set((await self.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)).map(\.itemID))
        // Snapshot absence is the approved spool bar, not delivery evidence.  An
        // out-of-band post-release drop also removes an item; this wave intentionally
        // does not distinguish that user/API discard from terminal delivery.
        return provenanceIDs.isDisjoint(with: snapshotIDs)
    }

    private func finalMatchesSealedCapture(_ final: OmiLaunchCaptureCutFinal, rootURL: URL) -> Bool {
        let scan = OmiLaunchCaptureRecovery(rootURL: rootURL, generationID: final.sealedGenerationID, io: self.io).recover()
        return scan.boundaryReason == nil
            && scan.verifiedPrefixNextSequence == final.sealedNextSequence
            && scan.verifiedPrefixEndOffset == final.sealedEndOffset
    }

    private func sealedProvenanceIDs(rootURL: URL, generationID: UUID) -> Set<UUID>? {
        let directory = rootURL.appendingPathComponent(OmiLaunchCaptureFormat.materializedDirectoryName, isDirectory: true)
            .appendingPathComponent(generationID.uuidString, isDirectory: true)
        guard let files = try? self.io.contentsOfDirectory(at: directory) else { return Set() }
        var ids: Set<UUID> = []
        for file in files where file.pathExtension == OmiLaunchCaptureMaterializationProvenance.pathExtension {
            guard let provenance = try? OmiLaunchCaptureMaterializationProvenanceStore.read(from: file),
                  provenance.isSupported,
                  provenance.generationID == generationID,
                  provenance.partitionOrdinal >= 0,
                  provenance.itemID == OmiLaunchCaptureMaterializationIdentity.itemID(
                    generationID: generationID,
                    partitionOrdinal: provenance.partitionOrdinal,
                    startSequence: provenance.startSequence,
                    startSampleOffset: provenance.startSampleOffset
                  ),
                  ids.insert(provenance.itemID).inserted
            else { return nil }
        }
        return ids
    }

    deinit {
        self.successorTask?.cancel()
    }

    private func isSealed(_ generationID: UUID) -> Bool {
        if case .ordinary = self.cutLifecycle { return true }
        return self.cutLifecycle.intent?.sealedGenerationID == generationID
    }

    private func observe(_ phase: ReconciliationPhase) async {
        if let onReconciliationPhase { await onReconciliationPhase(phase) }
    }

    private func dropMaterializerSession(reason: String) {
        guard let session = self.materializerSession else { return }
        session.materializer.discardSession()
        self.materializerSession = nil
        self.log.debug("launch capture materializer session dropped: \(reason, privacy: .public)")
    }

    private func commitBoundary(scan: OmiLaunchCaptureScanResult, generationID: UUID) async -> Bool {
        guard let boundarySequence = scan.boundarySequence else {
            await self.conservativelyGateOmi()
            return false
        }
        let itemID = Self.boundaryItemID(generationID: generationID, sequence: boundarySequence, offset: scan.boundaryOffset ?? scan.verifiedPrefixEndOffset)
        let startedAt = Date(timeIntervalSince1970: 0)
        let sidecar = ChunkSidecar(
            segment: ObserverSegmentNaming.segmentString(for: startedAt, durationSeconds: 0),
            day: ObserverSegmentNaming.dayString(for: startedAt),
            chunkIndex: Int.max,
            startedAt: startedAt,
            durationS: 0,
            sessionID: generationID,
            mode: .meeting,
            locationJSONL: nil
        )
        var manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar)
        manifest.payloadParts = []
        manifest.diskState = .attention
        let ownership = try? await self.engine.verifyOwnership(expectedManifest: manifest, expectedPayloadSourceURLs: [:])
        switch ownership {
        case .ownedInQueued, .ownedInAttention:
            return true
        case .notFound:
            let reason = scan.boundaryReason?.rawValue ?? "unknown"
            do {
                _ = try await self.engine.enqueueAttention(
                    manifest: manifest,
                    payloadFileURLs: [:],
                    reason: "launch_capture_boundary",
                    detail: "generation=\(generationID.uuidString.lowercased()) boundary_sequence=\(boundarySequence) reason=\(reason)"
                )
                return true
            } catch {
                self.log.error("launch capture boundary attention failed")
                await self.conservativelyGateOmi()
                return false
            }
        case .stagingOnly, .salvageOnly, .conflict, .none:
            await self.conservativelyGateOmi()
            return false
        }
    }

    private func commitUnreadableCursor(defect: OmiLaunchCaptureCursorDefect, generationID: UUID) async {
        let itemID = Self.unreadableCursorItemID(generationID: generationID, defect: defect)
        let startedAt = Date(timeIntervalSince1970: 0)
        let sidecar = ChunkSidecar(
            segment: ObserverSegmentNaming.segmentString(for: startedAt, durationSeconds: 0),
            day: ObserverSegmentNaming.dayString(for: startedAt),
            chunkIndex: Int.max,
            startedAt: startedAt,
            durationS: 0,
            sessionID: generationID,
            mode: .meeting,
            locationJSONL: nil
        )
        var manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar)
        manifest.payloadParts = []
        manifest.diskState = .attention
        let ownership = try? await self.engine.verifyOwnership(expectedManifest: manifest, expectedPayloadSourceURLs: [:])
        switch ownership {
        case .ownedInQueued, .ownedInAttention:
            return
        case .notFound:
            do {
                _ = try await self.engine.enqueueAttention(
                    manifest: manifest,
                    payloadFileURLs: [:],
                    reason: "launch_capture_cursor_unreadable",
                    detail: "generation=\(generationID.uuidString.lowercased()) cursor_defect=\(defect.reason.rawValue)"
                )
            } catch {
                self.log.error("launch capture cursor unreadable attention failed")
            }
        case .stagingOnly, .salvageOnly, .conflict, .none:
            self.log.error("launch capture cursor unreadable ownership failed")
        }
    }

    private func commitUnreadableCutReservation(_ defect: OmiLaunchCaptureCutReservationDefect) async {
        let itemID = Self.unreadableCutReservationItemID(defect: defect)
        let startedAt = Date(timeIntervalSince1970: 0)
        let sidecar = ChunkSidecar(
            segment: ObserverSegmentNaming.segmentString(for: startedAt, durationSeconds: 0),
            day: ObserverSegmentNaming.dayString(for: startedAt),
            chunkIndex: Int.max,
            startedAt: startedAt,
            durationS: 0,
            sessionID: itemID,
            mode: .meeting,
            locationJSONL: nil
        )
        var manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar)
        manifest.payloadParts = []
        manifest.diskState = .attention
        let ownership = try? await self.engine.verifyOwnership(expectedManifest: manifest, expectedPayloadSourceURLs: [:])
        switch ownership {
        case .ownedInQueued, .ownedInAttention:
            return
        case .notFound:
            do {
                _ = try await self.engine.enqueueAttention(
                    manifest: manifest,
                    payloadFileURLs: [:],
                    reason: "launch_capture_cut_reservation_unreadable",
                    detail: "cut_reservation_defect=\(defect.reason.rawValue)"
                )
            } catch {
                self.log.error("launch capture cut reservation unreadable attention failed")
            }
        case .stagingOnly, .salvageOnly, .conflict, .none:
            self.log.error("launch capture cut reservation unreadable ownership failed")
        }
    }

    private func commitCutFinalDefect(_ defect: OmiLaunchCaptureCutReservationDefect) async {
        let itemID = Self.cutFinalDefectItemID(defect: defect)
        let startedAt = Date(timeIntervalSince1970: 0)
        let sidecar = ChunkSidecar(
            segment: ObserverSegmentNaming.segmentString(for: startedAt, durationSeconds: 0),
            day: ObserverSegmentNaming.dayString(for: startedAt),
            chunkIndex: Int.max,
            startedAt: startedAt,
            durationS: 0,
            sessionID: itemID,
            mode: .meeting,
            locationJSONL: nil
        )
        var manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar)
        manifest.payloadParts = []
        manifest.diskState = .attention
        let ownership = try? await self.engine.verifyOwnership(expectedManifest: manifest, expectedPayloadSourceURLs: [:])
        switch ownership {
        case .ownedInQueued, .ownedInAttention:
            return
        case .notFound:
            do {
                _ = try await self.engine.enqueueAttention(
                    manifest: manifest,
                    payloadFileURLs: [:],
                    reason: "launch_capture_cut_final_invalid",
                    detail: "cut_final_defect=\(defect.reason.rawValue)"
                )
            } catch {
                self.log.error("launch capture cut final attention failed")
            }
        case .stagingOnly, .salvageOnly, .conflict, .none:
            self.log.error("launch capture cut final ownership failed")
        }
    }

    private func commitCutoverArmFailure(_ intent: OmiLaunchCaptureCutReservation) async -> Bool {
        let itemID = Self.cutoverArmFailureItemID(intent: intent)
        let startedAt = Date(timeIntervalSince1970: 0)
        let sidecar = ChunkSidecar(
            segment: ObserverSegmentNaming.segmentString(for: startedAt, durationSeconds: 0),
            day: ObserverSegmentNaming.dayString(for: startedAt),
            chunkIndex: Int.max,
            startedAt: startedAt,
            durationS: 0,
            sessionID: intent.reservedGenerationID,
            mode: .meeting,
            locationJSONL: nil
        )
        var manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar)
        manifest.payloadParts = []
        manifest.diskState = .attention
        let ownership = try? await self.engine.verifyOwnership(expectedManifest: manifest, expectedPayloadSourceURLs: [:])
        switch ownership {
        case .ownedInQueued, .ownedInAttention:
            return true
        case .notFound:
            do {
                _ = try await self.engine.enqueueAttention(
                    manifest: manifest,
                    payloadFileURLs: [:],
                    reason: "launch_capture_cut_reservation_arm_failed",
                    detail: "sealed_generation=\(intent.sealedGenerationID.uuidString.lowercased()) reserved_generation=\(intent.reservedGenerationID.uuidString.lowercased()) attempts=\(Self.cutoverArmRetryLimit)"
                )
                return true
            } catch {
                self.log.error("launch capture cut reservation arm attention failed")
                return false
            }
        case .stagingOnly, .salvageOnly, .conflict, .none:
            self.log.error("launch capture cut reservation arm attention ownership failed")
            return false
        }
    }

    private func commitOrphanRepairFailures(_ failures: [OmiLaunchCaptureOrphanRepairFailure], generationID: UUID) async -> Bool {
        for failure in failures {
            let startedAt = Date(timeIntervalSince1970: 0)
            let attentionID = Self.orphanRepairFailureItemID(generationID: generationID, ordinal: failure.ordinal, itemID: failure.itemID)
            let sidecar = ChunkSidecar(
                segment: ObserverSegmentNaming.segmentString(for: startedAt, durationSeconds: 0),
                day: ObserverSegmentNaming.dayString(for: startedAt),
                chunkIndex: failure.ordinal,
                startedAt: startedAt,
                durationS: 0,
                sessionID: generationID,
                mode: .meeting,
                locationJSONL: nil
            )
            var manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: attentionID, sidecar: sidecar)
            manifest.payloadParts = []
            manifest.diskState = .attention
            let ownership = try? await self.engine.verifyOwnership(expectedManifest: manifest, expectedPayloadSourceURLs: [:])
            switch ownership {
            case .ownedInQueued, .ownedInAttention:
                continue
            case .notFound:
                do {
                    _ = try await self.engine.enqueueAttention(
                        manifest: manifest,
                        payloadFileURLs: [:],
                        reason: "launch_capture_orphan_repair_failed",
                        detail: "generation=\(generationID.uuidString.lowercased()) ordinal=\(failure.ordinal) item=\(failure.itemID.uuidString.lowercased())"
                    )
                } catch {
                    self.log.error("launch capture orphan repair attention failed")
                    return false
                }
            case .stagingOnly, .salvageOnly, .conflict, .none:
                self.log.error("launch capture orphan repair ownership failed")
                return false
            }
        }
        return true
    }

    private func commitMaterializationFailure(_ failure: OmiLaunchCaptureMaterializationFailure, generationID: UUID) async -> Bool {
        let startedAt = Date(timeIntervalSince1970: 0)
        let itemID = Self.materializationFailureItemID(generationID: generationID, ordinal: failure.partitionOrdinal)
        let sidecar = ChunkSidecar(
            segment: ObserverSegmentNaming.segmentString(for: startedAt, durationSeconds: 0),
            day: ObserverSegmentNaming.dayString(for: startedAt),
            chunkIndex: failure.partitionOrdinal,
            startedAt: startedAt,
            durationS: 0,
            sessionID: generationID,
            mode: .meeting,
            locationJSONL: nil
        )
        var manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar)
        manifest.payloadParts = []
        manifest.diskState = .attention
        let ownership = try? await self.engine.verifyOwnership(expectedManifest: manifest, expectedPayloadSourceURLs: [:])
        switch ownership {
        case .ownedInQueued, .ownedInAttention:
            return true
        case .notFound:
            do {
                _ = try await self.engine.enqueueAttention(
                    manifest: manifest,
                    payloadFileURLs: [:],
                    reason: "launch_capture_materialization_failed",
                    detail: "generation=\(generationID.uuidString.lowercased()) partition=\(failure.partitionOrdinal) cause=\(failure.reason)"
                )
                return true
            } catch {
                self.log.error("launch capture materialization attention failed")
                return false
            }
        case .stagingOnly, .salvageOnly, .conflict, .none:
            self.log.error("launch capture materialization ownership failed")
            return false
        }
    }

    private func commitNoProgress(generationID: UUID, reader: OmiLaunchCaptureLeaseReader) async -> Bool {
        guard let cursor = reader.cursor() else { return false }
        let itemID = Self.noProgressItemID(
            generationID: generationID,
            sequence: cursor.materializedPrefixNextSequence,
            offset: cursor.materializedPrefixEndOffset
        )
        let startedAt = Date(timeIntervalSince1970: 0)
        let sidecar = ChunkSidecar(
            segment: ObserverSegmentNaming.segmentString(for: startedAt, durationSeconds: 0),
            day: ObserverSegmentNaming.dayString(for: startedAt),
            chunkIndex: Int.max,
            startedAt: startedAt,
            durationS: 0,
            sessionID: generationID,
            mode: .meeting,
            locationJSONL: nil
        )
        var manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar)
        manifest.payloadParts = []
        manifest.diskState = .attention
        let ownership = try? await self.engine.verifyOwnership(expectedManifest: manifest, expectedPayloadSourceURLs: [:])
        switch ownership {
        case .ownedInQueued, .ownedInAttention:
            return true
        case .notFound:
            do {
                _ = try await self.engine.enqueueAttention(
                    manifest: manifest,
                    payloadFileURLs: [:],
                    reason: "launch_capture_no_progress",
                    detail: "generation=\(generationID.uuidString.lowercased()) sequence=\(cursor.materializedPrefixNextSequence)"
                )
                return true
            } catch {
                self.log.error("launch capture no-progress attention failed")
                return false
            }
        case .stagingOnly, .salvageOnly, .conflict, .none:
            self.log.error("launch capture no-progress ownership failed")
            return false
        }
    }

    private func enumerateLinkedIDs(rootURLs: [URL]) -> EnumerationResult {
        var handoffs: [LinkedHandoff] = []
        for rootURL in rootURLs {
            let directory = rootURL.appendingPathComponent(OmiLaunchCaptureFormat.materializedDirectoryName, isDirectory: true)
            do {
                guard try self.io.fileExists(at: directory) else { continue }
            } catch { return .unknown }
            guard let generations = try? self.io.contentsOfDirectory(at: directory) else { return .unknown }
            for generation in generations {
                guard let generationID = UUID(uuidString: generation.lastPathComponent),
                      let files = try? self.io.contentsOfDirectory(at: generation)
                else { return .unknown }
                let captureStartedAtUnixMicros = OmiLaunchCaptureLeaseReader(
                    rootURL: rootURL,
                    generationID: generationID,
                    io: self.io
                ).captureStartTime() ?? Int64.max
                for file in files where file.pathExtension == OmiPendingHandoffEnvelope.pathExtension {
                    guard let envelope = try? OmiPendingHandoffStore.read(from: file), envelope.isSupported else { return .unknown }
                    handoffs.append(
                        LinkedHandoff(
                            rootURL: rootURL,
                            generationID: generationID,
                            itemID: envelope.itemID,
                            envelopeURL: file,
                            partitionOrdinal: UInt64(max(envelope.sidecar.chunkIndex, 0)),
                            captureStartedAtUnixMicros: captureStartedAtUnixMicros
                        )
                    )
                }
                for file in files where file.pathExtension == "m4a" {
                    let envelopeURL = OmiPendingHandoffStore.url(for: file)
                    if (try? self.io.fileExists(at: envelopeURL)) == true { continue }
                    let provenanceURL = OmiLaunchCaptureMaterializationProvenanceStore.url(for: file)
                    guard let provenance = try? OmiLaunchCaptureMaterializationProvenanceStore.read(from: provenanceURL), provenance.isSupported else { return .unknown }
                }
            }
        }
        return handoffs.isEmpty ? .scannedNothingLinked : .scannedWithLinkedIDs(handoffs)
    }

    private func generationIDs(rootURL: URL) -> Set<UUID>? {
        let files: [URL]
        do {
            guard try self.io.fileExists(at: rootURL) else { return [] }
            files = try self.io.contentsOfDirectory(at: rootURL)
        } catch {
            return nil
        }
        let prefix = OmiLaunchCaptureFormat.filePrefix
        return Set(files.compactMap { url in
            guard url.pathExtension == OmiLaunchCaptureFormat.fileExtension,
                  url.lastPathComponent.hasPrefix(prefix)
            else { return nil }
            return UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst(prefix.count)))
        })
    }

    private func generationsInCaptureOrder(_ generationIDs: Set<UUID>, rootURL: URL) -> (generationIDs: [UUID], hasUnreadableHeader: Bool) {
        // Read each first header once before sorting.  UUID provides the stable
        // tie-breaker when capture times match or a header is unavailable.
        let startTimes = Dictionary(uniqueKeysWithValues: generationIDs.map { generationID in
            let start = OmiLaunchCaptureLeaseReader(rootURL: rootURL, generationID: generationID, io: self.io)
                .captureStartTime()
            return (generationID, start ?? Int64.max)
        })
        let ordered = generationIDs.sorted {
            let left = startTimes[$0] ?? Int64.max
            let right = startTimes[$1] ?? Int64.max
            return left == right ? $0.uuidString < $1.uuidString : left < right
        }
        return (ordered, startTimes.values.contains(Int64.max))
    }

    private static func boundaryItemID(generationID: UUID, sequence: UInt64, offset: Int) -> UUID {
        var data = Data("omi-launch-capture-boundary-v1".utf8)
        data.append(uuidBytes: generationID)
        data.appendLittleEndian(sequence)
        data.appendLittleEndian(UInt64(max(offset, 0)))
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func unreadableCursorItemID(generationID: UUID, defect: OmiLaunchCaptureCursorDefect) -> UUID {
        // Identity is intentionally bounded to the first cursor format plus one byte; changes beyond that prefix dedupe.
        var data = Data("omi-launch-capture-cursor-unreadable-v1".utf8)
        data.append(uuidBytes: generationID)
        data.append(Data(defect.reason.rawValue.utf8))
        data.append(defect.contentDigest)
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func unreadableCutReservationItemID(defect: OmiLaunchCaptureCutReservationDefect) -> UUID {
        var data = Data("omi-launch-capture-cut-reservation-unreadable-v1".utf8)
        data.append(Data(defect.reason.rawValue.utf8))
        data.append(defect.contentDigest)
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func finalMismatchDefect(_ final: OmiLaunchCaptureCutFinal) -> OmiLaunchCaptureCutReservationDefect {
        OmiLaunchCaptureCutReservationDefect(
            reason: .finalMismatch,
            contentDigest: OmiLaunchCaptureDigest.truncated(final.encoded())
        )
    }

    private static func cutFinalDefectItemID(defect: OmiLaunchCaptureCutReservationDefect) -> UUID {
        var data = Data("omi-launch-capture-cut-final-invalid-v1".utf8)
        data.append(Data(defect.reason.rawValue.utf8))
        data.append(defect.contentDigest)
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func cutoverArmFailureItemID(intent: OmiLaunchCaptureCutReservation) -> UUID {
        var data = Data("omi-launch-capture-cut-reservation-arm-failed-v1".utf8)
        data.append(uuidBytes: intent.sealedGenerationID)
        data.append(uuidBytes: intent.reservedGenerationID)
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func orphanRepairFailureItemID(generationID: UUID, ordinal: Int, itemID: UUID) -> UUID {
        var data = Data("omi-launch-capture-orphan-repair-failed-v1".utf8)
        data.append(uuidBytes: generationID)
        data.appendLittleEndian(UInt64(ordinal))
        data.append(uuidBytes: itemID)
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func materializationFailureItemID(generationID: UUID, ordinal: Int) -> UUID {
        var data = Data("omi-launch-capture-materialization-failed-v1".utf8)
        data.append(uuidBytes: generationID)
        data.appendLittleEndian(UInt64(ordinal))
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func noProgressItemID(generationID: UUID, sequence: UInt64, offset: Int) -> UUID {
        var data = Data("omi-launch-capture-no-progress-v1".utf8)
        data.append(uuidBytes: generationID)
        data.appendLittleEndian(sequence)
        data.appendLittleEndian(UInt64(max(offset, 0)))
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func settlementFailureItemID(generationID: UUID, ordinal: UInt64, ownerItemID: UUID, action: String) -> UUID {
        var data = Data("omi-launch-capture-settlement-failed-v1".utf8)
        data.append(uuidBytes: generationID)
        data.appendLittleEndian(ordinal)
        data.append(uuidBytes: ownerItemID)
        data.append(Data(action.utf8))
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

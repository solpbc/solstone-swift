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
        case afterSealedOwnerAdopted
        case afterSealedOwnershipVerified
        case afterSealedCursorAcknowledged
        case afterSealedEnvelopeCleaned
        case beforeSealedOwnerReleased
        case afterSealedOwnerReleased
        case afterFinalMarkerCommittedBeforeReservedMaterialization
        case beforeReservedOwnerReleased
        case afterReservedOwnerReleased
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

    private struct SettlementHandoff {
        let generationID: UUID
        let envelopeURL: URL
        let partitionOrdinal: UInt64
        let captureStartedAtUnixMicros: Int64
    }

    private struct SettlementOwner {
        let itemID: UUID
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

    private var rootURL: URL?
    private let engine: TransferEngine
    private let sourceManager: OmiSourceManager
    private let io: any OmiLaunchCaptureIO
    private let clock: any ObserverClock
    private let onReconciliationPhase: (@MainActor @Sendable (ReconciliationPhase) async -> Void)?
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
        onReconciliationPhase: (@MainActor @Sendable (ReconciliationPhase) async -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.engine = engine
        self.sourceManager = sourceManager
        self.io = io
        self.clock = clock
        self.onReconciliationPhase = onReconciliationPhase
        self.refreshCutReservationState()
    }

    func uncommitLeftovers(rootURL: URL? = nil) async {
        if let rootURL {
            self.rootURL = rootURL
            self.refreshCutReservationState()
        }
        await self.uncommitLaunchCaptureLeftovers()
    }

    func reconcile(rootURL: URL? = nil) async {
        if let rootURL {
            self.rootURL = rootURL
            self.refreshCutReservationState()
        }
        guard !self.isReconciling else { return }
        await self.uncommitLaunchCaptureLeftovers()
        guard let rootURL = self.rootURL else { return }
        guard !self.cutReservationProbeFailed else { return }
        self.isReconciling = true
        defer {
            self.isReconciling = false
            if let pendingSuccessor {
                self.pendingSuccessor = nil
                self.armReconciliationSuccessor(delayed: pendingSuccessor == .delayed)
            }
        }
        guard self.sourceManager.isLaunchCaptureRecoveryEnabled else { return }

        guard await self.beginCutIfNeeded() else { return }
        guard self.cutLifecycle != .defect else {
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
            return
        case .scannedNothingLinked:
            break
        case .scannedWithLinkedIDs(let handoffs):
            self.enumeratedHandoffs = handoffs
        }

        guard var generationIDs = self.generationIDs(rootURL: rootURL) else { return }
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
        guard !ordering.hasUnreadableHeader else { return }
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
            guard let reservedIDs = self.generationIDs(rootURL: reservedRoot) else { return }
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

        let unsettledLinkedGenerationIDs = await self.settleAttachedHandoffs()

        // Retirement is post-settlement maintenance. A handoff owner may need its cursor
        // as durable acknowledgment evidence until adopt has finished.
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
        await self.reconcile()
    }

    private func reconcile(generationID: UUID, rootURL: URL) async -> GenerationOutcome {
        let reader = OmiLaunchCaptureLeaseReader(rootURL: rootURL, generationID: generationID, io: self.io)
        let scan = OmiLaunchCaptureRecovery(rootURL: rootURL, generationID: generationID, io: self.io).recover()
        // A recovery read failure verifies no prefix. Do not let a second read race
        // past that failure and create an owner from an unverified capture.
        if scan.boundaryReason == .readFailed, scan.boundarySequence == nil {
            return .failed
        }
        if case .unavailable(let reason) = reader.lease() {
            if reason == .cursorUnreadable, let defect = reader.cursorDefect() {
                // Re-read deliberately to confirm the defect persists; a transient failure skips adopt without a permanent signal.
                // The reader stays stateless, and a later reconcile retries normally.
                await self.commitUnreadableCursor(defect: defect, generationID: generationID)
            }
            return .failed
        }

        guard let decoder = try? OmiOpusAudioDecoder() else {
            self.log.error("launch capture decoder unavailable")
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
            return .failed
        }
        guard result.orphanRepairFailures.isEmpty else { return .failed }

        if let failure = result.failure {
            guard await self.commitMaterializationFailure(failure, generationID: generationID) else {
                return .failed
            }
            let outcome = await self.finishMaterializationFailure(
                partitions: result.partitions,
                reader: reader,
                coveredThroughSequence: result.coveredThroughSequence,
                generationID: generationID,
                rootURL: rootURL
            )
            if case .held = outcome { return outcome }
            self.dropMaterializerSession(reason: "materialization retry")
            return .retryDelayed(result, reader)
        }

        guard !result.partitions.isEmpty else {
            if let frontier = result.materializedFrontier,
               case .refused = self.commitSettled(
                    reader: reader,
                    throughSequence: frontier.throughSequence,
                    nextPartitionOrdinal: frontier.nextPartitionOrdinal,
                    nextSampleOffset: frontier.nextSampleOffset
               ) {
                return .failed
            }
            if scan.boundaryReason != nil {
                return await self.commitBoundary(scan: scan, generationID: generationID) ? .boundary : .failed
            }
            guard case .empty = reader.lease() else {
                if result.materializedFrontier == nil, result.coveredThroughSequence == nil {
                    guard await self.commitNoProgress(generationID: generationID, reader: reader) else {
                        return .failed
                    }
                    return .retryDelayed(result, reader)
                }
                return .retryRequired(result, reader)
            }
            return .settled(result, reader)
        }

        let settled = await self.adoptSettledPartitions(
            result.partitions,
            reader: reader,
            coveredThroughSequence: result.coveredThroughSequence,
            generationID: generationID,
            rootURL: rootURL
        )
        switch settled {
        case .held:
            return .held
        case .failed:
            return .failed
        case .adopted:
            break
        }

        if scan.boundaryReason != nil {
            return await self.commitBoundary(scan: scan, generationID: generationID) ? .boundary : .failed
        }
        guard case .empty = reader.lease() else { return .retryRequired(result, reader) }
        return .settled(result, reader)
    }

    private enum AdoptSettledOutcome {
        case adopted
        case held
        case failed
    }

    private func adoptSettledPartitions(
        _ partitions: [OmiLaunchCaptureMaterializedPartition],
        reader: OmiLaunchCaptureLeaseReader,
        coveredThroughSequence: UInt64?,
        generationID: UUID,
        rootURL: URL
    ) async -> AdoptSettledOutcome {
        guard !partitions.isEmpty else { return .failed }
        guard let coveredThroughSequence,
              partitions.last?.endsAtSourceFrameBoundary == true
        else { return .failed }
        if self.isSealed(generationID) { await self.observe(.afterSealedOwnershipVerified) }
        guard self.sourceManager.isLaunchCaptureRecoveryEnabled else { return .held }
        guard let partition = partitions.last else { return .failed }
        switch self.commitSettled(
            reader: reader,
            throughSequence: coveredThroughSequence,
            nextPartitionOrdinal: partition.nextPartitionOrdinal,
            nextSampleOffset: partition.nextSampleOffset
        ) {
        case .refused:
            await self.commitSettlementAttention(
                partitions,
                generationID: generationID,
                rootURL: rootURL,
                action: "acknowledgment"
            )
            return .failed
        case .alreadySettled:
            // This range's commit was already decided in an earlier pass. Adopting
            // these freshly re-materialized files would risk sending content a
            // second time if the original commit already reached and left
            // TransferEngine; discarding them would risk losing the only copy if the
            // original adopt never actually completed. Neither is safe to assume —
            // fail closed and flag for attention without touching the files.
            await self.commitSettlementAttention(
                partitions,
                generationID: generationID,
                rootURL: rootURL,
                action: "redundant_materialization"
            )
            return .failed
        case .advanced:
            break
        }
        if self.isSealed(generationID) { await self.observe(.afterSealedCursorAcknowledged) }
        var adoptedAny = false
        for partition in partitions {
            guard self.sourceManager.isLaunchCaptureRecoveryEnabled else {
                if adoptedAny { await self.uncommitLaunchCaptureLeftovers() }
                return .held
            }
            let handoffs = self.settlementHandoffs(for: [partition], generationID: generationID, rootURL: rootURL)
            guard let prepared = self.prepareSettlementHandoffs(handoffs) else {
                await self.commitSettlementAttention(
                    [partition],
                    generationID: generationID,
                    rootURL: rootURL,
                    action: "cleanup"
                )
                continue
            }
            if prepared.contains(where: { self.isSealed($0.generationID) }) {
                await self.observe(.afterSealedEnvelopeCleaned)
                await self.observe(.beforeSealedOwnerReleased)
            } else if !prepared.isEmpty {
                await self.observe(.beforeReservedOwnerReleased)
            }
            // Policy may have flipped during the settlement-handoff I/O above and its
            // observation points; a settlement marker left behind here is a fully
            // recoverable staged state, picked up again by settleAttachedHandoffs on a
            // later reconcile. Re-check right at the commit boundary so decide-then-commit
            // holds all the way to the actual TransferEngine call, not just at loop entry.
            guard self.sourceManager.isLaunchCaptureRecoveryEnabled else {
                if adoptedAny { await self.uncommitLaunchCaptureLeftovers() }
                return .held
            }
            guard await self.adoptOwner(for: partition) else { return adoptedAny ? .adopted : .failed }
            if self.isSealed(generationID) { await self.observe(.afterSealedOwnerAdopted) }
            adoptedAny = true
            if !self.removeSettlementHandoffs(prepared) {
                await self.commitSettlementAttention(
                    [partition],
                    generationID: generationID,
                    rootURL: rootURL,
                    action: "cleanup"
                )
                self.requestReconciliation(delayed: true)
            } else if prepared.contains(where: { self.isSealed($0.generationID) }) {
                await self.observe(.afterSealedOwnerReleased)
                self.requestReconciliation(delayed: true)
            } else if !prepared.isEmpty {
                await self.observe(.afterReservedOwnerReleased)
            }
        }
        return adoptedAny ? .adopted : .failed
    }

    private enum CommitSettledOutcome {
        case advanced
        /// The cursor was already at or past this range — an earlier pass (this
        /// process or a prior one) already committed it. The materializer can
        /// statelessly reproduce the same partition from raw capture data after a
        /// restart even though its original commit may already be delivered, and
        /// TransferEngine cannot distinguish "already delivered" from "never
        /// adopted" once an item is gone — so callers must not treat this the same
        /// as a fresh `.advanced` decision.
        case alreadySettled
        case refused
    }

    private func commitSettled(
        reader: OmiLaunchCaptureLeaseReader,
        throughSequence: UInt64,
        nextPartitionOrdinal: UInt64,
        nextSampleOffset: UInt64
    ) -> CommitSettledOutcome {
        switch reader.commitSettled(
            throughSequence: throughSequence,
            nextPartitionOrdinal: nextPartitionOrdinal,
            nextSampleOffset: nextSampleOffset
        ) {
        case .advanced:
            return .advanced
        case .noOp:
            return .alreadySettled
        case .refused:
            return .refused
        }
    }

    private func finishMaterializationFailure(
        partitions: [OmiLaunchCaptureMaterializedPartition],
        reader: OmiLaunchCaptureLeaseReader,
        coveredThroughSequence: UInt64?,
        generationID: UUID,
        rootURL: URL
    ) async -> GenerationOutcome {
        switch await self.adoptSettledPartitions(
            partitions,
            reader: reader,
            coveredThroughSequence: coveredThroughSequence,
            generationID: generationID,
            rootURL: rootURL
        ) {
        case .held:
            return .held
        case .adopted, .failed:
            return .failed
        }
    }

    private func adoptOwner(for partition: OmiLaunchCaptureMaterializedPartition) async -> Bool {
        await self.adoptOwner(itemID: partition.itemID, audioURL: partition.audioURL, envelopeURL: partition.envelopeURL)
    }

    private func adoptOwner(itemID: UUID, audioURL: URL, envelopeURL: URL) async -> Bool {
        let readableEnvelopeURL: URL
        if (try? self.io.fileExists(at: envelopeURL)) == true {
            readableEnvelopeURL = envelopeURL
        } else if !OmiPendingHandoffStore.isSettlementURL(envelopeURL) {
            let marker = OmiPendingHandoffStore.settlementURL(for: envelopeURL)
            guard (try? self.io.fileExists(at: marker)) == true else {
                self.log.error("launch capture adopt failed: unreadable envelope")
                return false
            }
            readableEnvelopeURL = marker
        } else {
            self.log.error("launch capture adopt failed: unreadable envelope")
            return false
        }
        guard let envelope = try? OmiPendingHandoffStore.read(from: readableEnvelopeURL), envelope.isSupported else {
            self.log.error("launch capture adopt failed: unreadable envelope")
            return false
        }
        let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: itemID,
            sidecar: envelope.sidecar,
            metadata: envelope.metadata
        )
        let outcome: TransferEnqueueIfAbsentOutcome
        do {
            outcome = try await self.engine.enqueueIfAbsent(
                manifest: manifest,
                equivalentObserverSegmentID: nil,
                payloadFileURLs: ["audio": audioURL]
            )
        } catch {
            self.log.error("launch capture adopt failed")
            return false
        }
        switch outcome {
        case .enqueued:
            if (try? self.io.fileExists(at: audioURL)) == true {
                self.log.error("launch capture adopt left producer audio")
                return false
            }
            return true
        case .alreadyPresent:
            if (try? self.io.fileExists(at: audioURL)) == true {
                try? self.io.removeItem(at: audioURL)
            }
            return true
        }
    }

    private func settlementHandoffs(
        for partitions: [OmiLaunchCaptureMaterializedPartition],
        generationID: UUID,
        rootURL: URL
    ) -> [SettlementHandoff] {
        let captureStartedAtUnixMicros = OmiLaunchCaptureLeaseReader(
            rootURL: rootURL,
            generationID: generationID,
            io: self.io
        ).captureStartTime() ?? Int64.max
        return partitions.map { partition in
            SettlementHandoff(
                generationID: generationID,
                envelopeURL: partition.envelopeURL,
                partitionOrdinal: partition.nextPartitionOrdinal == 0
                    ? 0
                    : partition.nextPartitionOrdinal - 1,
                captureStartedAtUnixMicros: captureStartedAtUnixMicros
            )
        }
    }

    @discardableResult
    private func settleAttachedHandoffs() async -> Set<UUID> {
        guard self.sourceManager.isLaunchCaptureRecoveryEnabled else {
            return Set(self.enumeratedHandoffs.map(\.generationID))
        }
        var unsettled: Set<UUID> = []
        let itemIDs = Set(self.enumeratedHandoffs.map(\.itemID)).sorted { $0.uuidString < $1.uuidString }
        for itemID in itemIDs {
            let handoffs = self.enumeratedHandoffs.filter { $0.itemID == itemID }
            guard let first = handoffs.first else { continue }
            let settlement = handoffs.first(where: { OmiPendingHandoffStore.isSettlementURL($0.envelopeURL) })
            let live = handoffs.first(where: { !OmiPendingHandoffStore.isSettlementURL($0.envelopeURL) })
            let liveExists = live.map { (try? self.io.fileExists(at: $0.envelopeURL)) == true } ?? false
            let settlementURL = settlement?.envelopeURL ?? live.map { OmiPendingHandoffStore.settlementURL(for: $0.envelopeURL) }
            let settlementExists = settlementURL.map { (try? self.io.fileExists(at: $0)) == true } ?? false
            if !liveExists, !settlementExists {
                continue
            }
            let envelopeURL = settlementExists ? (settlementURL ?? first.envelopeURL) : first.envelopeURL
            let audioURL = self.audioURL(forEnvelope: envelopeURL)
            let settlementHandoffs = handoffs.map {
                SettlementHandoff(
                    generationID: $0.generationID,
                    envelopeURL: $0.envelopeURL,
                    partitionOrdinal: $0.partitionOrdinal,
                    captureStartedAtUnixMicros: $0.captureStartedAtUnixMicros
                )
            }
            let attachedOwner = SettlementOwner(itemID: itemID, handoffs: settlementHandoffs, isAcknowledged: true)
            if settlementExists, let settlementURL {
                let audioExists = (try? self.io.fileExists(at: audioURL)) == true
                if audioExists {
                    guard await self.adoptOwner(itemID: itemID, audioURL: audioURL, envelopeURL: envelopeURL) else {
                        unsettled.formUnion(handoffs.map(\.generationID))
                        await self.commitSettlementAttention(attachedOwner, action: "cleanup")
                        continue
                    }
                }
                if !self.removeSettlementHandoffs([
                    SettlementHandoff(
                        generationID: first.generationID,
                        envelopeURL: settlementURL,
                        partitionOrdinal: first.partitionOrdinal,
                        captureStartedAtUnixMicros: first.captureStartedAtUnixMicros
                    )
                ]) {
                    unsettled.formUnion(handoffs.map(\.generationID))
                    await self.commitSettlementAttention(attachedOwner, action: "cleanup")
                }
                continue
            }
            let reader = OmiLaunchCaptureLeaseReader(rootURL: first.rootURL, generationID: first.generationID, io: self.io)
            guard reader.hasDurableAcknowledgment(), case .empty = reader.lease() else { continue }
            guard await self.adoptOwner(itemID: itemID, audioURL: audioURL, envelopeURL: envelopeURL) else {
                unsettled.formUnion(handoffs.map(\.generationID))
                await self.commitSettlementAttention(attachedOwner, action: "cleanup")
                continue
            }
            let prepared = self.prepareSettlementHandoffs(settlementHandoffs)
            if let prepared {
                if !self.removeSettlementHandoffs(prepared) {
                    unsettled.formUnion(handoffs.map(\.generationID))
                    await self.commitSettlementAttention(attachedOwner, action: "cleanup")
                }
            } else {
                unsettled.formUnion(handoffs.map(\.generationID))
                await self.commitSettlementAttention(attachedOwner, action: "cleanup")
            }
        }
        return unsettled
    }

    private func audioURL(forEnvelope envelopeURL: URL) -> URL {
        var url = envelopeURL.deletingPathExtension()
        if url.pathExtension == "settlement" {
            url = url.deletingPathExtension()
        }
        return url.appendingPathExtension("m4a")
    }

    private func uncommitLaunchCaptureLeftovers() async {
        guard let rootURL else { return }
        let fileManager = FileManager.default
        var roots = [rootURL]
        let reserved = OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: rootURL)
        if fileManager.fileExists(atPath: reserved.path) {
            roots.append(reserved)
        }
        for scanRoot in roots {
            let materialized = scanRoot.appendingPathComponent(OmiLaunchCaptureFormat.materializedDirectoryName, isDirectory: true)
            guard fileManager.fileExists(atPath: materialized.path),
                  let generations = try? fileManager.contentsOfDirectory(
                    at: materialized,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                  )
            else { continue }
            for generation in generations {
                guard let files = try? fileManager.contentsOfDirectory(
                    at: generation,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for file in files where file.pathExtension == OmiPendingHandoffEnvelope.pathExtension {
                    await self.uncommitIfMatched(envelopeURL: file, fileManager: fileManager)
                }
            }
        }
    }

    private func uncommitIfMatched(envelopeURL: URL, fileManager: FileManager) async {
        guard let envelope = try? OmiPendingHandoffStore.read(from: envelopeURL), envelope.isSupported else { return }
        let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: envelope.itemID,
            sidecar: envelope.sidecar,
            metadata: envelope.metadata
        )
        let ownership = try? await self.engine.verifyOwnership(
            expectedManifest: manifest,
            expectedPayloadSourceURLs: [:]
        )
        switch ownership {
        case .ownedInQueued, .ownedInAttention:
            break
        default:
            return
        }
        let liveURL: URL
        if OmiPendingHandoffStore.isSettlementURL(envelopeURL) {
            liveURL = envelopeURL.deletingPathExtension().deletingPathExtension().appendingPathExtension(OmiPendingHandoffEnvelope.pathExtension)
        } else {
            liveURL = envelopeURL
        }
        let audioURL = liveURL.deletingPathExtension().appendingPathExtension("m4a")
        if !fileManager.fileExists(atPath: audioURL.path),
           let payload = await self.engine.payloadFileURL(itemID: envelope.itemID, partID: "audio") {
            do {
                let data = try Data(contentsOf: payload)
                try OmiPendingHandoffStore.write(data, to: audioURL)
            } catch {
                self.log.error("launch capture leftover audio restore failed")
                return
            }
        }
        if OmiPendingHandoffStore.isSettlementURL(envelopeURL) {
            do {
                let data = try OmiPendingHandoffStore.encode(envelope)
                if !fileManager.fileExists(atPath: liveURL.path) {
                    try OmiPendingHandoffStore.write(data, to: liveURL)
                }
                if envelopeURL != liveURL, fileManager.fileExists(atPath: envelopeURL.path) {
                    try fileManager.removeItem(at: envelopeURL)
                }
            } catch {
                self.log.error("launch capture leftover envelope restore failed")
                return
            }
        }
        await self.engine.relinquish(itemID: envelope.itemID)
    }

    /// Installs a durable settlement marker before removing each live handoff.
    /// At every crash point, at least one file still carries the owner identity
    /// needed to finish adopt without treating delivery as a fresh partition.
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

    private func commitSettlementAttention(
        _ partitions: [OmiLaunchCaptureMaterializedPartition],
        generationID: UUID,
        rootURL: URL,
        action: String
    ) async {
        let owner = SettlementOwner(
            itemID: partitions[0].itemID,
            handoffs: self.settlementHandoffs(for: partitions, generationID: generationID, rootURL: rootURL),
            isAcknowledged: true
        )
        await self.commitSettlementAttention(owner, action: action)
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
                return false
            }
        case .stagingOnly, .salvageOnly, .conflict, .none:
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

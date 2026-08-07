// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation
import os

@MainActor
final class OmiLaunchCaptureCommitCoordinator {
    // These are the only two asynchronous boundaries in an owner settlement.
    // Observing them keeps ordering testable without changing the Transfer APIs.
    enum ReconciliationPhase: Equatable, Sendable {
        case afterNewOwnerGated
        case afterOwnerRegisteredBeforeAcknowledgment
    }

    private struct LinkedHandoff {
        let generationID: UUID
        let itemID: UUID
        let envelopeURL: URL
    }

    private enum EnumerationResult {
        case scannedWithLinkedIDs([LinkedHandoff])
        case scannedNothingLinked
        case unknown
    }

    private enum GenerationOutcome {
        case settled(OmiLaunchCaptureMaterializationResult, OmiLaunchCaptureLeaseReader)
        case retryRequired(OmiLaunchCaptureMaterializationResult)
        case boundary
        case failed
    }

    private struct PendingOwner {
        let partition: OmiLaunchCaptureMaterializedPartition
        let token: TransferGateToken
    }

    private var rootURL: URL?
    private let engine: TransferEngine
    private let sourceManager: OmiSourceManager
    private let io: any OmiLaunchCaptureIO
    private let onReconciliationPhase: (@MainActor @Sendable (ReconciliationPhase) async -> Void)?
    private let log = Logger(subsystem: "app.solstone.swift", category: "omi-launch-capture")
    private var reconciliationRequested = false
    private var isReconciling = false
    private var didCutOver = false
    private var heldForExplicitResumeIDs: Set<UUID> = []
    private var isResumingAfterExplicitEnable = false
    private var preRegisteredGateTokens: [UUID: TransferGateToken] = [:]
    private var enumeratedHandoffs: [LinkedHandoff] = []
    private var markersAwaitingCutover: [OmiLaunchCaptureMarkerObservation] = []

    init(
        rootURL: URL?,
        engine: TransferEngine,
        sourceManager: OmiSourceManager,
        io: any OmiLaunchCaptureIO = FoundationOmiLaunchCaptureIO(),
        onReconciliationPhase: (@MainActor @Sendable (ReconciliationPhase) async -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.engine = engine
        self.sourceManager = sourceManager
        self.io = io
        self.onReconciliationPhase = onReconciliationPhase
    }

    func reconcile(rootURL: URL? = nil) async {
        if let rootURL {
            self.rootURL = rootURL
        }
        guard !self.isReconciling, !self.didCutOver else { return }
        guard let rootURL = self.rootURL else {
            await self.conservativelyGateOmi()
            return
        }
        self.isReconciling = true
        defer { self.isReconciling = false }
        guard self.sourceManager.isLaunchCaptureRecoveryEnabled else {
            await self.conservativelyGateOmi()
            return
        }

        self.enumeratedHandoffs = []
        let enumeration = self.enumerateLinkedIDs()
        switch enumeration {
        case .unknown:
            await self.conservativelyGateOmi()
            return
        case .scannedNothingLinked:
            break
        case .scannedWithLinkedIDs(let handoffs):
            self.enumeratedHandoffs = handoffs
            await self.registerExistingOwners(handoffs)
        }

        guard var generationIDs = self.generationIDs() else {
            await self.holdPreRegisteredOwners()
            await self.conservativelyGateOmi()
            return
        }
        let activeGenerationID = self.sourceManager.activeLaunchCaptureGenerationID
        if let activeGenerationID {
            generationIDs.insert(activeGenerationID)
        }

        var activeResult: (result: OmiLaunchCaptureMaterializationResult, reader: OmiLaunchCaptureLeaseReader)?
        var settledReaders: [(generationID: UUID, reader: OmiLaunchCaptureLeaseReader)] = []
        var shouldRetry = false
        var sawBoundary = false
        var failed = false
        for generationID in self.generationsInCaptureOrder(generationIDs, rootURL: rootURL) {
            switch await self.reconcile(generationID: generationID) {
            case .settled(let result, let reader):
                self.appendReplayMarkers(result.markers)
                settledReaders.append((generationID, reader))
                if generationID == activeGenerationID {
                    activeResult = (result, reader)
                }
            case .retryRequired(let result):
                self.appendReplayMarkers(result.markers)
                shouldRetry = true
            case .boundary:
                sawBoundary = true
            case .failed:
                failed = true
            }
        }

        let unsettledLinkedGenerationIDs = await self.settleAcknowledgedLinkedHandoffs()
        await self.holdPreRegisteredOwners()

        // Retirement is post-settlement maintenance. A handoff owner may need its cursor
        // as durable acknowledgment evidence until its gate has been released or held.
        for reader in settledReaders where !unsettledLinkedGenerationIDs.contains(reader.generationID) {
            _ = reader.reader.retireIfEligible(activeGenerationID: activeGenerationID)
        }

        guard !failed, !sawBoundary else { return }
        guard !shouldRetry else {
            self.requestReconciliation()
            return
        }
        guard let activeResult else { return }
        self.finishCutoverIfCurrent(result: activeResult.result, reader: activeResult.reader)
    }

    func resumeAfterExplicitEnable() async {
        guard self.sourceManager.isLaunchCaptureRecoveryEnabled,
              !self.isReconciling,
              !self.didCutOver
        else { return }
        self.isResumingAfterExplicitEnable = true
        await self.reconcile()
        self.isResumingAfterExplicitEnable = false
    }

    func conservativelyGateOmi() async {
        for item in await self.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi) {
            switch await self.engine.gateExisting(itemID: item.itemID) {
            case .gated(let token):
                _ = await self.convertGateToHold(token, itemID: item.itemID)
            case .alreadyGated:
                await self.engine.hold(itemID: item.itemID)
            case .dispatchAlreadyEnabled, .engineNotInitialized:
                await self.engine.hold(itemID: item.itemID)
            }
        }
    }

    private func reconcile(generationID: UUID) async -> GenerationOutcome {
        guard let rootURL else { return .failed }
        let reader = OmiLaunchCaptureLeaseReader(rootURL: rootURL, generationID: generationID, io: self.io)
        let scan = OmiLaunchCaptureRecovery(rootURL: rootURL, generationID: generationID, io: self.io).recover()
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
        let result = OmiLaunchCaptureMaterializer(
            rootURL: rootURL,
            generationID: generationID,
            io: self.io,
            decode: { decoder.decode($0) }
        ).materialize()

        var pending: [PendingOwner] = []
        var coveredThroughSequence: UInt64?
        for partition in result.partitions {
            guard let token = await self.registerOwner(for: partition) else {
                self.log.error("launch capture owner settlement registration failed")
                return .failed
            }
            pending.append(PendingOwner(partition: partition, token: token))
            guard self.sourceManager.isLaunchCaptureRecoveryEnabled else {
                await self.hold(pending, retainForExplicitResume: true)
                return .failed
            }
            guard partition.endsAtSourceFrameBoundary,
                  let throughSequence = partition.coveredThroughSequence
            else { continue }
            coveredThroughSequence = throughSequence
        }

        guard !pending.isEmpty else {
            if scan.boundaryReason != nil {
                return await self.commitBoundary(scan: scan, generationID: generationID) ? .boundary : .failed
            }
            guard case .empty = reader.lease() else { return .retryRequired(result) }
            return .settled(result, reader)
        }
        guard let coveredThroughSequence,
              pending.last?.partition.endsAtSourceFrameBoundary == true
        else {
            await self.hold(pending)
            return .failed
        }
        if let onReconciliationPhase {
            await onReconciliationPhase(.afterOwnerRegisteredBeforeAcknowledgment)
        }
        guard self.sourceManager.isLaunchCaptureRecoveryEnabled else {
            await self.hold(pending, retainForExplicitResume: true)
            return .failed
        }
        guard self.acknowledge(reader: reader, throughSequence: coveredThroughSequence) else {
            await self.hold(pending)
            return .failed
        }
        guard await self.cleanup(pending) else { return .failed }
        guard await self.release(pending) else { return .failed }

        if scan.boundaryReason != nil {
            return await self.commitBoundary(scan: scan, generationID: generationID) ? .boundary : .failed
        }
        guard case .empty = reader.lease() else { return .retryRequired(result) }
        return .settled(result, reader)
    }

    private func registerExistingOwners(_ handoffs: [LinkedHandoff]) async {
        for itemID in Set(handoffs.map(\.itemID)).sorted(by: { $0.uuidString < $1.uuidString }) {
            if self.isResumingAfterExplicitEnable,
               self.heldForExplicitResumeIDs.contains(itemID) {
                switch await self.engine.restoreGateFromHold(itemID: itemID) {
                case .gated(let token):
                    self.preRegisteredGateTokens[itemID] = token
                case .notHeld, .alreadyGated, .engineNotInitialized:
                    await self.engine.hold(itemID: itemID)
                }
                continue
            }
            switch await self.engine.gateExisting(itemID: itemID) {
            case .gated(let token):
                self.preRegisteredGateTokens[itemID] = token
            case .alreadyGated:
                await self.engine.hold(itemID: itemID)
            case .dispatchAlreadyEnabled:
                await self.engine.hold(itemID: itemID)
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
            if let token = self.preRegisteredGateTokens.removeValue(forKey: partition.itemID) {
                return token
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
                _ = await self.convertGateToHold(token, itemID: partition.itemID)
                return nil
            }
            if let onReconciliationPhase {
                await onReconciliationPhase(.afterNewOwnerGated)
            }
            return token
        case .stagingOnly, .salvageOnly, .conflict, .none:
            await self.engine.hold(itemID: partition.itemID)
            return nil
        }
    }

    private func acknowledge(reader: OmiLaunchCaptureLeaseReader, throughSequence: UInt64) -> Bool {
        switch reader.acknowledge(throughSequence: throughSequence) {
        case .advanced, .noOp:
            return true
        case .refused:
            return false
        }
    }

    private func cleanup(_ pending: [PendingOwner]) async -> Bool {
        for owner in pending {
            do {
                if try self.io.fileExists(at: owner.partition.envelopeURL) {
                    try self.io.removeItem(at: owner.partition.envelopeURL)
                }
            } catch {
                _ = await self.convertGateToHold(owner.token, itemID: owner.partition.itemID)
                return false
            }
        }
        return true
    }

    private func release(_ pending: [PendingOwner]) async -> Bool {
        for owner in pending {
            guard await self.release(owner.token, itemID: owner.partition.itemID) else { return false }
        }
        return true
    }

    private func release(_ token: TransferGateToken, itemID: UUID) async -> Bool {
        switch await self.engine.releaseGate(token) {
        case .settled, .alreadyReleased:
            self.heldForExplicitResumeIDs.remove(itemID)
            return true
        case .alreadyConverted, .unknownToken, .mismatchedToken:
            await self.engine.hold(itemID: itemID)
            return false
        }
    }

    private func hold(_ pending: [PendingOwner], retainForExplicitResume: Bool = false) async {
        for owner in pending {
            _ = await self.convertGateToHold(owner.token, itemID: owner.partition.itemID)
            if retainForExplicitResume {
                self.heldForExplicitResumeIDs.insert(owner.partition.itemID)
            }
        }
    }

    private func convertGateToHold(_ token: TransferGateToken, itemID: UUID) async -> Bool {
        switch await self.engine.convertGateToHold(token) {
        case .settled, .alreadyConverted:
            return true
        case .alreadyReleased, .unknownToken, .mismatchedToken:
            await self.engine.hold(itemID: itemID)
            return false
        }
    }

    private func settleAcknowledgedLinkedHandoffs() async -> Set<UUID> {
        guard let rootURL else { return Set(self.enumeratedHandoffs.map(\.generationID)) }
        var unsettledGenerationIDs: Set<UUID> = []
        for (itemID, token) in self.preRegisteredGateTokens {
            let handoffs = self.enumeratedHandoffs.filter { $0.itemID == itemID }
            guard !handoffs.isEmpty else { continue }
            var settled = true
            for handoff in handoffs {
                let reader = OmiLaunchCaptureLeaseReader(rootURL: rootURL, generationID: handoff.generationID, io: self.io)
                guard reader.hasDurableAcknowledgment(), case .empty = reader.lease(),
                      let envelope = try? OmiPendingHandoffStore.read(from: handoff.envelopeURL), envelope.isSupported
                else {
                    settled = false
                    break
                }
                let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: handoff.itemID, sidecar: envelope.sidecar, metadata: envelope.metadata)
                guard let ownership = try? await self.engine.verifyOwnership(expectedManifest: manifest, expectedPayloadSourceURLs: [:]),
                      ownership == .ownedInQueued || ownership == .ownedInAttention
                else {
                    settled = false
                    break
                }
                do {
                    if try self.io.fileExists(at: handoff.envelopeURL) {
                        try self.io.removeItem(at: handoff.envelopeURL)
                    }
                } catch {
                    settled = false
                    break
                }
            }
            guard settled, await self.release(token, itemID: itemID) else {
                unsettledGenerationIDs.formUnion(handoffs.map(\.generationID))
                continue
            }
            self.preRegisteredGateTokens.removeValue(forKey: itemID)
        }
        return unsettledGenerationIDs
    }

    private func holdPreRegisteredOwners() async {
        let owners = self.preRegisteredGateTokens
        self.preRegisteredGateTokens.removeAll()
        for (itemID, token) in owners {
            _ = await self.convertGateToHold(token, itemID: itemID)
        }
    }

    private func appendReplayMarkers(_ markers: [OmiLaunchCaptureMarkerObservation]) {
        for marker in markers where !self.markersAwaitingCutover.contains(marker) {
            self.markersAwaitingCutover.append(marker)
        }
    }

    private func finishCutoverIfCurrent(result: OmiLaunchCaptureMaterializationResult, reader: OmiLaunchCaptureLeaseReader) {
        guard self.sourceManager.isLaunchCaptureRecoveryEnabled else {
            self.requestReconciliation()
            return
        }
        let hasCurrentCapture: Bool
        do {
            hasCurrentCapture = try self.io.fileExists(at: reader.fileURL)
        } catch {
            self.requestReconciliation()
            return
        }
        guard case .empty = reader.lease() else {
            self.requestReconciliation()
            return
        }
        if hasCurrentCapture {
            guard (try? self.io.fileSize(at: reader.fileURL)) == result.verifiedPrefixEndOffset else {
                self.requestReconciliation()
                return
            }
        }
        self.sourceManager.completeLaunchCaptureCutover(markers: self.markersAwaitingCutover)
        self.markersAwaitingCutover.removeAll()
        self.didCutOver = true
    }

    private func requestReconciliation() {
        guard !self.reconciliationRequested else { return }
        self.reconciliationRequested = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reconciliationRequested = false
            await self.reconcile()
        }
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

    private func enumerateLinkedIDs() -> EnumerationResult {
        guard let rootURL else { return .unknown }
        let directory = rootURL.appendingPathComponent(OmiLaunchCaptureFormat.materializedDirectoryName, isDirectory: true)
        do {
            guard try self.io.fileExists(at: directory) else { return .scannedNothingLinked }
        } catch {
            return .unknown
        }
        guard let generations = try? self.io.contentsOfDirectory(at: directory) else { return .unknown }
        var handoffs: [LinkedHandoff] = []
        for generation in generations {
            guard let generationID = UUID(uuidString: generation.lastPathComponent),
                  let files = try? self.io.contentsOfDirectory(at: generation)
            else { return .unknown }
            for file in files where file.pathExtension == OmiPendingHandoffEnvelope.pathExtension {
                guard let envelope = try? OmiPendingHandoffStore.read(from: file), envelope.isSupported else { return .unknown }
                handoffs.append(LinkedHandoff(generationID: generationID, itemID: envelope.itemID, envelopeURL: file))
            }
            for file in files where file.pathExtension == "m4a" {
                let envelopeURL = OmiPendingHandoffStore.url(for: file)
                guard (try? self.io.fileExists(at: envelopeURL)) == true else { return .unknown }
            }
        }
        return handoffs.isEmpty ? .scannedNothingLinked : .scannedWithLinkedIDs(handoffs)
    }

    private func generationIDs() -> Set<UUID>? {
        guard let rootURL else { return nil }
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

    private func generationsInCaptureOrder(_ generationIDs: Set<UUID>, rootURL: URL) -> [UUID] {
        // Acknowledged records never replay markers, so order only the outstanding lease
        // that can still contribute to this cutover. UUID provides a stable tie-breaker.
        generationIDs.sorted {
            let left = self.captureStartTime(generationID: $0, rootURL: rootURL)
            let right = self.captureStartTime(generationID: $1, rootURL: rootURL)
            return left == right ? $0.uuidString < $1.uuidString : left < right
        }
    }

    private func captureStartTime(generationID: UUID, rootURL: URL) -> Int64 {
        let reader = OmiLaunchCaptureLeaseReader(rootURL: rootURL, generationID: generationID, io: self.io)
        guard case .lease(let lease) = reader.lease(), let first = lease.records.first else {
            return Int64.max
        }
        return first.acquiredAtUnixMicros
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
}

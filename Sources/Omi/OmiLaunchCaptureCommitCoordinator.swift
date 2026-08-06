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
        case afterOwnerCleanupBeforeAcknowledgment
    }
    enum EnumerationResult {
        case scannedWithLinkedIDs(Set<UUID>)
        case scannedNothingLinked
        case unknown
    }

    private struct PendingOwner {
        let partition: OmiLaunchCaptureMaterializedPartition
        let token: TransferGateToken
    }

    private let rootURL: URL
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

    init(
        rootURL: URL,
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

    func reconcile() async {
        guard !self.isReconciling, !self.didCutOver else { return }
        self.isReconciling = true
        defer { self.isReconciling = false }
        guard self.sourceManager.isLaunchCaptureRecoveryEnabled else {
            await self.conservativelyGateOmi()
            return
        }
        let enumeration = self.enumerateLinkedIDs()
        if case .unknown = enumeration {
            await self.conservativelyGateOmi()
            return
        }
        for generationID in self.generationIDs() {
            await self.reconcile(generationID: generationID)
        }
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
                _ = await self.engine.convertGateToHold(token)
            case .alreadyGated:
                await self.engine.hold(itemID: item.itemID)
            case .dispatchAlreadyEnabled, .engineNotInitialized:
                await self.engine.hold(itemID: item.itemID)
            }
        }
    }

    private func reconcile(generationID: UUID) async {
        let reader = OmiLaunchCaptureLeaseReader(rootURL: self.rootURL, generationID: generationID, io: self.io)
        let recovery = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generationID, io: self.io)
        let scan = recovery.recover()
        if scan.boundaryReason != nil {
            await self.commitBoundary(scan: scan, generationID: generationID)
            return
        }

        guard let decoder = try? OmiOpusAudioDecoder() else {
            self.log.error("launch capture decoder unavailable")
            await self.conservativelyGateOmi()
            return
        }
        let result = OmiLaunchCaptureMaterializer(
            rootURL: self.rootURL,
            generationID: generationID,
            io: self.io,
            decode: { decoder.decode($0) }
        ).materialize()

        var pending: [PendingOwner] = []
        for partition in result.partitions {
            guard let token = await self.registerOwner(for: partition) else { return }
            pending.append(PendingOwner(partition: partition, token: token))
            guard self.sourceManager.isLaunchCaptureRecoveryEnabled else {
                await self.hold(pending, retainForExplicitResume: true)
                return
            }
            guard await self.cleanup(pending) else { return }
            if let onReconciliationPhase {
                await onReconciliationPhase(.afterOwnerCleanupBeforeAcknowledgment)
            }
            guard partition.endsAtSourceFrameBoundary,
                  let throughSequence = partition.coveredThroughSequence
            else { continue }
            guard self.acknowledge(reader: reader, throughSequence: throughSequence) else {
                await self.hold(pending)
                return
            }
            guard await self.release(pending) else { return }
            pending.removeAll()
        }
        guard pending.isEmpty else {
            await self.hold(pending)
            return
        }
        _ = reader.retireIfEligible(activeGenerationID: generationID)
        self.finishCutoverIfCurrent(result: result, reader: reader)
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
            switch await self.engine.gateExisting(itemID: partition.itemID) {
            case .gated(let token): return token
            case .alreadyGated:
                await self.engine.hold(itemID: partition.itemID)
                return nil
            case .dispatchAlreadyEnabled:
                if self.isResumingAfterExplicitEnable,
                   self.heldForExplicitResumeIDs.contains(partition.itemID),
                   case .gated(let token) = await self.engine.restoreGateFromHold(itemID: partition.itemID) {
                    return token
                }
                await self.engine.hold(itemID: partition.itemID)
                return nil
            case .engineNotInitialized:
                self.log.error("launch capture gate unavailable")
                await self.engine.hold(itemID: partition.itemID)
                return nil
            }
        case .notFound:
            guard !partition.isExistingOwner,
                  let token = try? await self.engine.enqueueGated(manifest: manifest, payloadFileURLs: ["audio": partition.audioURL])
            else { return nil }
            guard (try? self.io.fileExists(at: partition.audioURL)) == false else {
                _ = await self.engine.convertGateToHold(token)
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
                try self.io.removeItem(at: owner.partition.envelopeURL)
            } catch {
                _ = await self.engine.convertGateToHold(owner.token)
                return false
            }
        }
        return true
    }

    private func release(_ pending: [PendingOwner]) async -> Bool {
        for owner in pending {
            switch await self.engine.releaseGate(owner.token) {
            case .settled, .alreadyReleased:
                self.heldForExplicitResumeIDs.remove(owner.partition.itemID)
                break
            case .alreadyConverted, .unknownToken, .mismatchedToken:
                await self.engine.hold(itemID: owner.partition.itemID)
                return false
            }
        }
        return true
    }

    private func hold(_ pending: [PendingOwner], retainForExplicitResume: Bool = false) async {
        for owner in pending {
            _ = await self.engine.convertGateToHold(owner.token)
            if retainForExplicitResume {
                self.heldForExplicitResumeIDs.insert(owner.partition.itemID)
            }
        }
    }

    private func finishCutoverIfCurrent(result: OmiLaunchCaptureMaterializationResult, reader: OmiLaunchCaptureLeaseReader) {
        guard self.sourceManager.isLaunchCaptureRecoveryEnabled,
              case .empty = reader.lease(),
              let size = try? self.io.fileSize(at: reader.fileURL),
              size == result.verifiedPrefixEndOffset
        else {
            self.requestReconciliation()
            return
        }
        self.sourceManager.completeLaunchCaptureCutover(markers: result.markers)
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

    private func commitBoundary(scan: OmiLaunchCaptureScanResult, generationID: UUID) async {
        guard let boundarySequence = scan.boundarySequence else {
            await self.conservativelyGateOmi()
            return
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
        if case .notFound = ownership {
            let reason = scan.boundaryReason?.rawValue ?? "unknown"
            _ = try? await self.engine.enqueueAttention(
                manifest: manifest,
                payloadFileURLs: [:],
                reason: "launch_capture_boundary",
                detail: "generation=\(generationID.uuidString.lowercased()) boundary_sequence=\(boundarySequence) boundary_offset=\(scan.boundaryOffset ?? scan.verifiedPrefixEndOffset) reason=\(reason)"
            )
        }
        await self.conservativelyGateOmi()
    }

    private func enumerateLinkedIDs() -> EnumerationResult {
        let directory = self.rootURL.appendingPathComponent("Materialized", isDirectory: true)
        do {
            guard try self.io.fileExists(at: directory) else { return .scannedNothingLinked }
        } catch {
            return .unknown
        }
        guard let generations = try? self.io.contentsOfDirectory(at: directory) else { return .unknown }
        var ids: Set<UUID> = []
        for generation in generations {
            guard let files = try? self.io.contentsOfDirectory(at: generation) else { return .unknown }
            for file in files where file.pathExtension == OmiPendingHandoffEnvelope.pathExtension {
                guard let envelope = try? OmiPendingHandoffStore.read(from: file), envelope.isSupported else { return .unknown }
                ids.insert(envelope.itemID)
            }
            for file in files where file.pathExtension == "m4a" {
                let envelopeURL = OmiPendingHandoffStore.url(for: file)
                guard (try? self.io.fileExists(at: envelopeURL)) == true else { return .unknown }
            }
        }
        return ids.isEmpty ? .scannedNothingLinked : .scannedWithLinkedIDs(ids)
    }

    private func generationIDs() -> Set<UUID> {
        guard let files = try? self.io.contentsOfDirectory(at: self.rootURL) else { return [] }
        let prefix = OmiLaunchCaptureFormat.filePrefix
        return Set(files.compactMap { url in
            guard url.pathExtension == OmiLaunchCaptureFormat.fileExtension,
                  url.lastPathComponent.hasPrefix(prefix)
            else { return nil }
            return UUID(uuidString: String(url.deletingPathExtension().lastPathComponent.dropFirst(prefix.count)))
        })
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
}

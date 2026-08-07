// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Foundation
import Opus
import XCTest

nonisolated private struct CommitCoordinatorAvailableEndpointResolver: TransferEndpointResolver {
    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        .available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))
    }
}

private actor CommitCoordinatorBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isWaiting = false

    func suspend() async {
        self.isWaiting = true
        await withCheckedContinuation { self.continuation = $0 }
    }

    func waiting() -> Bool { self.isWaiting }

    func resume() {
        self.continuation?.resume()
        self.continuation = nil
    }
}

@MainActor
private final class SettlementInjectionState {
    var isEnabled = true
    let itemID: UUID
    let action: OmiLaunchCaptureCommitCoordinator.SettlementAction

    init(itemID: UUID, action: OmiLaunchCaptureCommitCoordinator.SettlementAction) {
        self.itemID = itemID
        self.action = action
    }
}

private protocol FixtureOwnerSet {
    var ownerIDs: Set<UUID> { get }
}

final class OmiLaunchCaptureCommitCoordinatorTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiLaunchCaptureCommitCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        TransferURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.rootURL)
    }

    @MainActor func testExistingOwnerRegistrationBlocksOnlyLinkedOwnerUntilBootstrapGateCompletes() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("transfer", isDirectory: true)
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = try self.seedCapture(rootURL: captureRoot)
        let partition = try XCTUnwrap(self.materialize(rootURL: captureRoot, generation: generation, io: io).partitions.first)
        let spool = TransferSpool(rootURL: transferRoot)
        let envelope = try OmiPendingHandoffStore.read(from: partition.envelopeURL)
        _ = try spool.commitStagedItem(itemID: spool.stage(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: partition.itemID, sidecar: envelope.sidecar),
            payloads: ["audio": Data(contentsOf: partition.audioURL)]
        ).item.manifest.itemID)
        let unrelatedID = UUID()
        _ = try spool.commitStagedItem(itemID: spool.stage(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: unrelatedID, sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 9, startedAt: Date())),
            payloads: ["audio": Data("unrelated".utf8)]
        ).item.manifest.itemID)
        io.failNext(.remove)
        let harness = self.makeHarness(rootURL: transferRoot)
        let manager = self.makeManager()
        let barrier = CommitCoordinatorBarrier()
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: manager,
            io: io,
            onReconciliationPhase: { phase in
                if phase == .afterOwnerRegisteredBeforeAcknowledgment { await barrier.suspend() }
            }
        )
        var opened = false
        let bootstrap = Task { @MainActor in
            try await harness.engine.initialize()
            await coordinator.reconcile()
            opened = true
            await harness.engine.enableDispatch()
        }
        try await transferTestWaitFor("bootstrap gate") { await barrier.waiting() }
        XCTAssertFalse(opened)
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        let registration = await harness.engine.gateExisting(itemID: partition.itemID)
        XCTAssertEqual(registration, .alreadyGated)
        await barrier.resume()
        try await bootstrap.value
        try await transferTestWaitFor("unrelated delivery") { TransferURLProtocol.requests.count == 1 }
        XCTAssertEqual(transferTestBoundaryItemID(from: try XCTUnwrap(TransferURLProtocol.requests.first)), unrelatedID)
        XCTAssertEqual(TransferURLProtocol.requests.filter { transferTestBoundaryItemID(from: $0) == partition.itemID }.count, 0)
    }

    @MainActor func testRestartFaultRemovedCleansReleasesAndSendsExactlyOnce() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("transfer", isDirectory: true)
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = try self.seedCapture(rootURL: captureRoot)
        let harness = self.makeHarness(rootURL: transferRoot)
        let manager = self.makeManager()
        try await harness.engine.initialize()
        io.failNext(.remove)
        await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: manager, io: io).reconcile()
        await harness.engine.enableDispatch()
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)

        let restarted = self.makeHarness(rootURL: transferRoot)
        try await restarted.engine.initialize()
        await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: restarted.engine, sourceManager: self.makeManager(), io: io).reconcile()
        await restarted.engine.enableDispatch()
        try await transferTestWaitFor("recovered delivery") { TransferURLProtocol.requests.count == 1 }
        let reader = OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: generation, io: io)
        XCTAssertEqual(reader.lease(), .empty)
    }

    @MainActor func testRestartRetainedCleanupFaultRestoresLifetimeHoldAndSendsZero() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("transfer", isDirectory: true)
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = try self.seedCapture(rootURL: captureRoot)
        _ = try self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO())
        let first = self.makeHarness(rootURL: transferRoot)
        try await first.engine.initialize()
        io.failNext(.remove)
        await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: first.engine, sourceManager: self.makeManager(), io: io).reconcile()
        await first.engine.enableDispatch()

        let restarted = self.makeHarness(rootURL: transferRoot)
        try await restarted.engine.initialize()
        io.failNext(.remove)
        await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: restarted.engine, sourceManager: self.makeManager(), io: io).reconcile()
        await restarted.engine.enableDispatch()
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
    }

    @MainActor func testUnsettledAcknowledgedExistingOwnerRetainsCursorUntilCleanupSucceeds() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("transfer", isDirectory: true)
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = try self.seedCapture(rootURL: captureRoot)
        let partition = try XCTUnwrap(self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO()).partitions.first)
        let envelope = try OmiPendingHandoffStore.read(from: partition.envelopeURL)
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        _ = try await harness.engine.enqueue(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: partition.itemID, sidecar: envelope.sidecar),
            payloads: ["audio": Data(contentsOf: partition.audioURL)]
        )
        let reader = OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: generation, io: io)
        XCTAssertEqual(reader.acknowledge(throughSequence: 0), .advanced)
        io.failNext(.remove)
        await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager(), io: io).reconcile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: reader.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reader.cursorURL.path))

        let restarted = self.makeHarness(rootURL: transferRoot)
        try await restarted.engine.initialize()
        await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: restarted.engine, sourceManager: self.makeManager(), io: io).reconcile()
        await restarted.engine.enableDispatch()
        try await transferTestWaitFor("settled existing owner") { TransferURLProtocol.requests.count == 1 }
    }

    @MainActor func testNewOwnerAtomicGatedCommitBlocksEagerTransportUntilCleanupSettlement() async throws {
        let barrier = CommitCoordinatorBarrier()
        let captureRoot = self.rootURL.appendingPathComponent("success-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("success-transfer", isDirectory: true)
        _ = try self.seedCapture(rootURL: captureRoot)
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        await harness.engine.enableDispatch()
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager(),
            onReconciliationPhase: { phase in
                if phase == .afterNewOwnerGated { await barrier.suspend() }
            }
        )
        let task = Task { @MainActor in await coordinator.reconcile() }
        try await transferTestWaitFor("gated owner") { await barrier.waiting() }
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        await barrier.resume()
        await task.value
        try await transferTestWaitFor("released new owner") { TransferURLProtocol.requests.count == 1 }
        XCTAssertEqual(TransferURLProtocol.requests.filter { transferTestBoundaryItemID(from: $0) == snapshots[0].itemID }.count, 1)

        TransferURLProtocol.reset()
        let heldCaptureRoot = self.rootURL.appendingPathComponent("held-capture", isDirectory: true)
        let heldTransferRoot = self.rootURL.appendingPathComponent("held-transfer", isDirectory: true)
        let io = FaultInjectingOmiLaunchCaptureIO()
        _ = try self.seedCapture(rootURL: heldCaptureRoot)
        let heldHarness = self.makeHarness(rootURL: heldTransferRoot)
        try await heldHarness.engine.initialize()
        await heldHarness.engine.enableDispatch()
        io.failNext(.remove)
        await OmiLaunchCaptureCommitCoordinator(rootURL: heldCaptureRoot, engine: heldHarness.engine, sourceManager: self.makeManager(), io: io).reconcile()
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        let heldSnapshots = await heldHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(heldSnapshots.filter { $0.manifest.payloadParts.isEmpty == false }.count, 1)
        XCTAssertEqual(heldSnapshots.filter { $0.manifest.attention?.reason == "launch_capture_settlement_cleanup_failed" }.count, 1)
    }

    @MainActor func testInjectedSettlementFailuresKeepOwnerIneligibleAndDoNotBlockUnrelatedWork() async throws {
        for (name, injectedAction, cleanupFault) in [
            ("release", OmiLaunchCaptureCommitCoordinator.SettlementAction.release, false),
            ("conversion", OmiLaunchCaptureCommitCoordinator.SettlementAction.gateConversion, true),
        ] {
            TransferURLProtocol.reset()
            let captureRoot = self.rootURL.appendingPathComponent("\(name)-capture", isDirectory: true)
            let transferRoot = self.rootURL.appendingPathComponent("\(name)-transfer", isDirectory: true)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let generation = try self.seedCapture(rootURL: captureRoot)
            let ownerID = OmiLaunchCaptureMaterializationIdentity.itemID(
                generationID: generation,
                partitionOrdinal: 0,
                startSequence: 0,
                startSampleOffset: 0
            )
            if cleanupFault {
                let paths = OmiLaunchCaptureMaterializedArtifactPaths(rootURL: captureRoot, generationID: generation, ordinal: 0)
                io.failRemove(at: paths.envelopeURL, fromCall: 1)
            }
            let harness = self.makeHarness(rootURL: transferRoot)
            try await harness.engine.initialize()
            let unrelatedID = UUID()
            _ = try await harness.engine.enqueue(
                manifest: self.unrelatedManifest(itemID: unrelatedID),
                payloads: ["audio": Data("unrelated".utf8)]
            )
            let coordinator = OmiLaunchCaptureCommitCoordinator(
                rootURL: captureRoot,
                engine: harness.engine,
                sourceManager: self.makeManager(),
                io: io,
                onSettlementAction: { _, action in
                    action == injectedAction ? .unknownToken : nil
                }
            )

            await coordinator.reconcile()
            await harness.engine.enableDispatch()
            try await transferTestWaitFor("unrelated \(name) delivery") { TransferURLProtocol.requests.count == 1 }
            XCTAssertEqual(transferTestBoundaryItemID(from: try XCTUnwrap(TransferURLProtocol.requests.first)), unrelatedID, name)
            XCTAssertFalse(TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == ownerID }, name)
            let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
            XCTAssertEqual(snapshots.filter { $0.itemID == ownerID }.count, 1, name)
            XCTAssertEqual(
                snapshots.filter { $0.manifest.attention?.reason == "launch_capture_settlement_\(injectedAction == .release ? "release" : "gate_conversion")_failed" }.count,
                1,
                name
            )
        }
    }

    @MainActor func testCleanupFailureAtAnyOwnerPositionSettlesEveryOtherOwner() async throws {
        for position in 0..<3 {
            TransferURLProtocol.reset()
            let captureRoot = self.rootURL.appendingPathComponent("cleanup-\(position)-capture", isDirectory: true)
            let transferRoot = self.rootURL.appendingPathComponent("cleanup-\(position)-transfer", isDirectory: true)
            let fixture = try self.seedThreeOwnerCapture(rootURL: captureRoot)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let harness = self.makeHarness(rootURL: transferRoot)
            try await harness.engine.initialize()
            try await self.stageThreeOwnerFixture(fixture, rootURL: captureRoot, engine: harness.engine)
            let settledOwnerID = fixture.orderedOwnerIDs[position]
            let paths = OmiLaunchCaptureMaterializedArtifactPaths(
                rootURL: captureRoot,
                generationID: fixture.generationID,
                ordinal: fixture.ordinal(for: settledOwnerID)
            )
            io.failRemove(at: paths.envelopeURL, fromCall: 1)
            let unrelatedID = UUID()
            _ = try await harness.engine.enqueue(manifest: self.unrelatedManifest(itemID: unrelatedID), payloads: ["audio": Data("unrelated".utf8)])

            let coordinator = OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager(), io: io)
            await coordinator.reconcile()
            await harness.engine.enableDispatch()
            try await transferTestWaitFor("cleanup peers \(settledOwnerID)") {
                TransferURLProtocol.requests.count == 3
            }
            XCTAssertTrue(TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == unrelatedID })
            await self.assertFixtureOwnerSettlement(fixture, engine: harness.engine, requests: TransferURLProtocol.requests)
        }
    }

    @MainActor func testConservativeEnumerationHoldRestoresAttachedOwnersWithoutRestart() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("conservative-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("conservative-transfer", isDirectory: true)
        let fixture = try self.seedThreeOwnerCapture(rootURL: captureRoot)
        let io = FaultInjectingOmiLaunchCaptureIO()
        let materialized = try self.materialize(rootURL: captureRoot, generation: fixture.generationID, io: FoundationOmiLaunchCaptureIO())
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        for partition in materialized.partitions {
            let envelope = try OmiPendingHandoffStore.read(from: partition.envelopeURL)
            _ = try await harness.engine.enqueue(
                manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: partition.itemID, sidecar: envelope.sidecar, metadata: envelope.metadata),
                payloads: ["audio": Data(contentsOf: partition.audioURL)]
            )
        }
        let unrelatedID = UUID()
        _ = try await harness.engine.enqueue(manifest: self.unrelatedManifest(itemID: unrelatedID), payloads: ["audio": Data("unrelated".utf8)])
        let coordinator = OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager(), io: io)

        io.failNext(.listDirectory)
        await coordinator.reconcile()
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("unrelated while conservative held") {
            TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == unrelatedID }
        }
        XCTAssertFalse(TransferURLProtocol.requests.contains { fixture.ownerIDs.contains(transferTestBoundaryItemID(from: $0) ?? UUID()) })

        io.clearFaults()
        await coordinator.reconcile()
        try await transferTestWaitFor("restored attached owners") {
            Set(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:))).isSuperset(of: fixture.ownerIDs)
        }
        await self.assertFixtureOwnerSettlement(fixture, engine: harness.engine, requests: TransferURLProtocol.requests)
        XCTAssertEqual(TransferURLProtocol.requests.filter { fixture.ownerIDs.contains(transferTestBoundaryItemID(from: $0) ?? UUID()) }.count, 3)
    }

    @MainActor func testOnlyAttachedCoordinatorHoldsRestoreAndProofGatePrecedesDispatch() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("proof-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("proof-transfer", isDirectory: true)
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = try self.seedCapture(rootURL: captureRoot)
        let partition = try XCTUnwrap(self.materialize(rootURL: captureRoot, generation: generation, io: io).partitions.first)
        let envelope = try OmiPendingHandoffStore.read(from: partition.envelopeURL)
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        _ = try await harness.engine.enqueue(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: partition.itemID, sidecar: envelope.sidecar),
            payloads: ["audio": Data(contentsOf: partition.audioURL)]
        )
        let foreignHeldID = UUID()
        _ = try await harness.engine.enqueue(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: foreignHeldID, sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 44, startedAt: Date())),
            payloads: ["audio": Data("foreign".utf8)]
        )
        await harness.engine.hold(itemID: foreignHeldID)
        let unrelatedID = UUID()
        _ = try await harness.engine.enqueue(manifest: self.unrelatedManifest(itemID: unrelatedID), payloads: ["audio": Data("unrelated".utf8)])
        let barrier = CommitCoordinatorBarrier()
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager(),
            io: io,
            onReconciliationPhase: { phase in
                if phase == .afterOwnerRegisteredBeforeAcknowledgment { await barrier.suspend() }
            }
        )

        io.failNext(.listDirectory)
        await coordinator.reconcile()
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("unrelated sends") { TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == unrelatedID } }
        io.clearFaults()
        let reconciliation = Task { @MainActor in await coordinator.reconcile() }
        try await transferTestWaitFor("proof gate") { await barrier.waiting() }
        XCTAssertFalse(TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == partition.itemID })
        XCTAssertFalse(TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == foreignHeldID })
        await barrier.resume()
        await reconciliation.value
        try await transferTestWaitFor("attached owner sends") { TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == partition.itemID } }
        XCTAssertFalse(TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == foreignHeldID })
    }

    @MainActor func testSettlementAttentionReasonsArePayloadFreeAndDeduped() async throws {
        let expectedReasons: Set<String> = [
            "launch_capture_settlement_acknowledgment_failed",
            "launch_capture_settlement_cleanup_failed",
            "launch_capture_settlement_release_failed",
            "launch_capture_settlement_gate_conversion_failed",
        ]
        for (name, configure) in [
            ("acknowledgment", { (io: FaultInjectingOmiLaunchCaptureIO, reader: OmiLaunchCaptureLeaseReader, _: OmiLaunchCaptureMaterializedArtifactPaths) in
                io.failReplace(at: reader.cursorURL, fromCall: 1)
            }),
            ("cleanup", { (io: FaultInjectingOmiLaunchCaptureIO, _: OmiLaunchCaptureLeaseReader, paths: OmiLaunchCaptureMaterializedArtifactPaths) in
                io.failRemove(at: paths.envelopeURL, fromCall: 1)
            }),
        ] {
            TransferURLProtocol.reset()
            let captureRoot = self.rootURL.appendingPathComponent("attention-\(name)-capture", isDirectory: true)
            let transferRoot = self.rootURL.appendingPathComponent("attention-\(name)-transfer", isDirectory: true)
            let generation = try self.seedCapture(rootURL: captureRoot)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let reader = OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: generation, io: io)
            let paths = OmiLaunchCaptureMaterializedArtifactPaths(rootURL: captureRoot, generationID: generation, ordinal: 0)
            configure(io, reader, paths)
            let harness = self.makeHarness(rootURL: transferRoot)
            try await harness.engine.initialize()
            let coordinator = OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager(), io: io)
            await coordinator.reconcile()
            await coordinator.reconcile()
            let attention = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
                .filter { $0.manifest.attention?.reason.hasPrefix("launch_capture_settlement_") == true }
            XCTAssertEqual(attention.count, 1, name)
            let item = try XCTUnwrap(attention.first, name)
            XCTAssertTrue(item.manifest.payloadParts.isEmpty, name)
            XCTAssertTrue(expectedReasons.contains(item.manifest.attention?.reason ?? ""), name)
            XCTAssertEqual(item.manifest.attention?.reason, "launch_capture_settlement_\(name)_failed", name)
        }

        // Existing spool owners take the attached-handoff path. Exercise every
        // settlement action that can occur after their durable acknowledgment.
        for action in [
            OmiLaunchCaptureCommitCoordinator.SettlementAction.release,
            .gateConversion,
        ] {
            TransferURLProtocol.reset()
            let name = action == .release ? "release" : "gate_conversion"
            let captureRoot = self.rootURL.appendingPathComponent("attached-attention-\(name)-capture", isDirectory: true)
            let transferRoot = self.rootURL.appendingPathComponent("attached-attention-\(name)-transfer", isDirectory: true)
            let fixture = try self.seedThreeOwnerCapture(rootURL: captureRoot)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let harness = self.makeHarness(rootURL: transferRoot)
            try await harness.engine.initialize()
            try await self.stageThreeOwnerFixture(fixture, rootURL: captureRoot, engine: harness.engine)
            let ownerID = fixture.orderedOwnerIDs[0]
            if action == .gateConversion {
                let paths = OmiLaunchCaptureMaterializedArtifactPaths(
                    rootURL: captureRoot,
                    generationID: fixture.generationID,
                    ordinal: fixture.ordinal(for: ownerID)
                )
                io.failRemove(at: paths.envelopeURL, fromCall: 1)
            }
            let injection = SettlementInjectionState(itemID: ownerID, action: action)
            let coordinator = OmiLaunchCaptureCommitCoordinator(
                rootURL: captureRoot,
                engine: harness.engine,
                sourceManager: self.makeManager(),
                io: io,
                onSettlementAction: { itemID, candidate in
                    injection.isEnabled && itemID == injection.itemID && candidate == injection.action ? .unknownToken : nil
                }
            )
            await coordinator.reconcile()
            await coordinator.reconcile()
            let attention = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
                .filter { $0.manifest.attention?.reason == "launch_capture_settlement_\(name)_failed" }
            XCTAssertEqual(attention.count, 1, "attached \(name)")
            XCTAssertTrue(try XCTUnwrap(attention.first, "attached \(name)").manifest.payloadParts.isEmpty, "attached \(name)")
        }

        TransferURLProtocol.reset()
        do {
            let captureRoot = self.rootURL.appendingPathComponent("attached-attention-cleanup-capture", isDirectory: true)
            let transferRoot = self.rootURL.appendingPathComponent("attached-attention-cleanup-transfer", isDirectory: true)
            let fixture = try self.seedThreeOwnerCapture(rootURL: captureRoot)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let harness = self.makeHarness(rootURL: transferRoot)
            try await harness.engine.initialize()
            try await self.stageThreeOwnerFixture(fixture, rootURL: captureRoot, engine: harness.engine)
            let ownerID = fixture.orderedOwnerIDs[0]
            let paths = OmiLaunchCaptureMaterializedArtifactPaths(
                rootURL: captureRoot,
                generationID: fixture.generationID,
                ordinal: fixture.ordinal(for: ownerID)
            )
            io.failRemove(at: paths.envelopeURL, fromCall: 1)
            let coordinator = OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager(), io: io)
            await coordinator.reconcile()
            await coordinator.reconcile()
            let attention = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
                .filter { $0.manifest.attention?.reason == "launch_capture_settlement_cleanup_failed" }
            XCTAssertEqual(attention.count, 1, "attached cleanup")
            XCTAssertTrue(try XCTUnwrap(attention.first, "attached cleanup").manifest.payloadParts.isEmpty, "attached cleanup")
        }

        let healthyCaptureRoot = self.rootURL.appendingPathComponent("attention-healthy-capture", isDirectory: true)
        let healthyTransferRoot = self.rootURL.appendingPathComponent("attention-healthy-transfer", isDirectory: true)
        _ = try self.seedCapture(rootURL: healthyCaptureRoot)
        let healthy = self.makeHarness(rootURL: healthyTransferRoot)
        try await healthy.engine.initialize()
        await OmiLaunchCaptureCommitCoordinator(rootURL: healthyCaptureRoot, engine: healthy.engine, sourceManager: self.makeManager()).reconcile()
        let healthySnapshots = await healthy.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertFalse(healthySnapshots.contains {
            $0.manifest.attention?.reason.hasPrefix("launch_capture_settlement_") == true
        })
    }

    @MainActor func testAcknowledgmentFailureAtEveryOwnerPositionRetriesWithoutDuplicateDelivery() async throws {
        for position in 0..<3 {
            TransferURLProtocol.reset()
            let captureRoot = self.rootURL.appendingPathComponent("ack-\(position)-capture", isDirectory: true)
            let transferRoot = self.rootURL.appendingPathComponent("ack-\(position)-transfer", isDirectory: true)
            let fixture = try self.seedThreeGenerationCapture(rootURL: captureRoot)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let failedGenerationID = fixture.orderedGenerationIDs[position]
            let reader = OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: failedGenerationID, io: io)
            io.failReplace(at: reader.cursorURL, fromCall: 1)
            let harness = self.makeHarness(rootURL: transferRoot)
            try await harness.engine.initialize()
            let unrelatedID = UUID()
            _ = try await harness.engine.enqueue(manifest: self.unrelatedManifest(itemID: unrelatedID), payloads: ["audio": Data("unrelated".utf8)])
            let coordinator = OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager(), io: io)

            await coordinator.reconcile()
            await harness.engine.enableDispatch()
            try await transferTestWaitFor("unrelated after acknowledgment failure \(position)") {
                TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == unrelatedID }
            }
            XCTAssertFalse(TransferURLProtocol.requests.contains {
                transferTestBoundaryItemID(from: $0) == fixture.ownerID(for: failedGenerationID)
            })

            io.clearFaults()
            await coordinator.reconcile()
            await self.assertFixtureOwnerSettlement(
                fixture,
                engine: harness.engine,
                requests: TransferURLProtocol.requests,
                requireConvergence: true
            )
            try await transferTestWaitFor("ack retry \(position)") {
                Set(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:))).isSuperset(of: fixture.ownerIDs)
            }
            await self.assertFixtureOwnerSettlement(fixture, engine: harness.engine, requests: TransferURLProtocol.requests)
            XCTAssertEqual(TransferURLProtocol.requests.filter { fixture.ownerIDs.contains(transferTestBoundaryItemID(from: $0) ?? UUID()) }.count, 3)
        }
    }

    @MainActor func testReleaseAndConversionFailuresAtEveryOwnerPositionRetryWithoutDuplicates() async throws {
        for action in [OmiLaunchCaptureCommitCoordinator.SettlementAction.release, .gateConversion] {
            for position in 0..<3 {
                TransferURLProtocol.reset()
                let captureRoot = self.rootURL.appendingPathComponent("\(String(describing: action))-\(position)-capture", isDirectory: true)
                let transferRoot = self.rootURL.appendingPathComponent("\(String(describing: action))-\(position)-transfer", isDirectory: true)
                let fixture = try self.seedThreeOwnerCapture(rootURL: captureRoot)
                let unsafeOwner = fixture.orderedOwnerIDs[position]
                let io = FaultInjectingOmiLaunchCaptureIO()
                let harness = self.makeHarness(rootURL: transferRoot)
                try await harness.engine.initialize()
                try await self.stageThreeOwnerFixture(fixture, rootURL: captureRoot, engine: harness.engine)
                if action == .gateConversion {
                    let paths = OmiLaunchCaptureMaterializedArtifactPaths(
                        rootURL: captureRoot,
                        generationID: fixture.generationID,
                        ordinal: fixture.ordinal(for: unsafeOwner)
                    )
                    io.failRemove(at: paths.envelopeURL, fromCall: 1)
                }
                let unrelatedID = UUID()
                _ = try await harness.engine.enqueue(manifest: self.unrelatedManifest(itemID: unrelatedID), payloads: ["audio": Data("unrelated".utf8)])
                let injection = SettlementInjectionState(itemID: unsafeOwner, action: action)
                let coordinator = OmiLaunchCaptureCommitCoordinator(
                    rootURL: captureRoot,
                    engine: harness.engine,
                    sourceManager: self.makeManager(),
                    io: io,
                    onSettlementAction: { itemID, candidate in
                        injection.isEnabled && itemID == injection.itemID && candidate == injection.action ? .unknownToken : nil
                    }
                )

                await coordinator.reconcile()
                await harness.engine.enableDispatch()
                try await transferTestWaitFor("unrelated \(position)") { TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == unrelatedID } }
                await self.assertFixtureOwnerSettlement(fixture, engine: harness.engine, requests: TransferURLProtocol.requests)

                injection.isEnabled = false
                io.clearFaults()
                await coordinator.reconcile()
                await self.assertFixtureOwnerSettlement(
                    fixture,
                    engine: harness.engine,
                    requests: TransferURLProtocol.requests,
                    requireConvergence: true
                )
                try await transferTestWaitFor("settled \(position)") { Set(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:))).isSuperset(of: fixture.ownerIDs) }
                await self.assertFixtureOwnerSettlement(fixture, engine: harness.engine, requests: TransferURLProtocol.requests)
                XCTAssertEqual(TransferURLProtocol.requests.filter { fixture.ownerIDs.contains(transferTestBoundaryItemID(from: $0) ?? UUID()) }.count, 3)
            }
        }
    }

    @MainActor func testRestartAfterEachCleanupWindowReconstructsOwnersBeforeDispatch() async throws {
        for position in 0..<3 {
            TransferURLProtocol.reset()
            let captureRoot = self.rootURL.appendingPathComponent("restart-\(position)-capture", isDirectory: true)
            let transferRoot = self.rootURL.appendingPathComponent("restart-\(position)-transfer", isDirectory: true)
            let fixture = try self.seedThreeOwnerCapture(rootURL: captureRoot)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let first = self.makeHarness(rootURL: transferRoot)
            try await first.engine.initialize()
            try await self.stageThreeOwnerFixture(fixture, rootURL: captureRoot, engine: first.engine)
            let heldOwner = fixture.orderedOwnerIDs[position]
            let paths = OmiLaunchCaptureMaterializedArtifactPaths(
                rootURL: captureRoot,
                generationID: fixture.generationID,
                ordinal: fixture.ordinal(for: heldOwner)
            )
            io.failRemove(at: paths.envelopeURL, fromCall: 1)
            let unrelatedID = UUID()
            _ = try await first.engine.enqueue(manifest: self.unrelatedManifest(itemID: unrelatedID), payloads: ["audio": Data("unrelated".utf8)])
            let firstCoordinator = OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: first.engine, sourceManager: self.makeManager(), io: io)
            await firstCoordinator.reconcile()
            try io.restoreLastSynchronizedState()

            io.clearFaults()
            let restarted = self.makeHarness(rootURL: transferRoot)
            try await restarted.engine.initialize()
            let restartedCoordinator = OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: restarted.engine, sourceManager: self.makeManager(), io: io)
            await restartedCoordinator.reconcile()
            await restarted.engine.enableDispatch()
            try await transferTestWaitFor("restart owners \(position)") { Set(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:))).isSuperset(of: fixture.ownerIDs) }
            XCTAssertTrue(TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == unrelatedID })
            await self.assertFixtureOwnerSettlement(fixture, engine: restarted.engine, requests: TransferURLProtocol.requests)
            XCTAssertEqual(TransferURLProtocol.requests.filter { fixture.ownerIDs.contains(transferTestBoundaryItemID(from: $0) ?? UUID()) }.count, 3)
        }
    }

    @MainActor func testRestartBeforeAcknowledgmentRegatesOwnersBeforeDispatch() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("restart-before-ack-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("restart-before-ack-transfer", isDirectory: true)
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = try self.seedCapture(rootURL: captureRoot)
        let partition = try XCTUnwrap(self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO()).partitions.first)
        let envelope = try OmiPendingHandoffStore.read(from: partition.envelopeURL)
        let first = self.makeHarness(rootURL: transferRoot)
        try await first.engine.initialize()
        _ = try await first.engine.enqueueGated(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(
                itemID: partition.itemID,
                sidecar: envelope.sidecar,
                metadata: envelope.metadata
            ),
            payloadFileURLs: ["audio": partition.audioURL]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: partition.audioURL.path))
        let unrelatedID = UUID()
        _ = try await first.engine.enqueue(manifest: self.unrelatedManifest(itemID: unrelatedID), payloads: ["audio": Data("unrelated".utf8)])
        try io.restoreLastSynchronizedState()

        let restarted = self.makeHarness(rootURL: transferRoot)
        try await restarted.engine.initialize()
        let barrier = CommitCoordinatorBarrier()
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: restarted.engine,
            sourceManager: self.makeManager(),
            io: io,
            onReconciliationPhase: { phase in
                if phase == .afterOwnerRegisteredBeforeAcknowledgment {
                    await barrier.suspend()
                }
            }
        )
        let reconciliation = Task { @MainActor in await coordinator.reconcile() }
        try await transferTestWaitFor("re-gated owner before acknowledgment") { await barrier.waiting() }
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        await restarted.engine.enableDispatch()
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        await barrier.resume()
        await reconciliation.value
        try await transferTestWaitFor("unacknowledged restart owners") {
            TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == partition.itemID }
        }
        XCTAssertTrue(TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == unrelatedID })
        XCTAssertEqual(TransferURLProtocol.requests.filter { transferTestBoundaryItemID(from: $0) == partition.itemID }.count, 1)
    }

    @MainActor func testRestartAfterAcknowledgmentCleansAndReleasesEveryAttachedOwner() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("restart-after-ack-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("restart-after-ack-transfer", isDirectory: true)
        let fixture = try self.seedThreeOwnerCapture(rootURL: captureRoot)
        let io = FaultInjectingOmiLaunchCaptureIO()
        let first = self.makeHarness(rootURL: transferRoot)
        try await first.engine.initialize()
        try await self.stageThreeOwnerFixture(fixture, rootURL: captureRoot, engine: first.engine)
        let unrelatedID = UUID()
        _ = try await first.engine.enqueue(manifest: self.unrelatedManifest(itemID: unrelatedID), payloads: ["audio": Data("unrelated".utf8)])
        try io.restoreLastSynchronizedState()

        let restarted = self.makeHarness(rootURL: transferRoot)
        try await restarted.engine.initialize()
        let coordinator = OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: restarted.engine, sourceManager: self.makeManager(), io: io)
        await coordinator.reconcile()
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        await restarted.engine.enableDispatch()
        try await transferTestWaitFor("acknowledged restart owners") {
            Set(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:))).isSuperset(of: fixture.ownerIDs)
        }
        XCTAssertTrue(TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == unrelatedID })
        await self.assertFixtureOwnerSettlement(fixture, engine: restarted.engine, requests: TransferURLProtocol.requests)
        XCTAssertEqual(TransferURLProtocol.requests.filter { fixture.ownerIDs.contains(transferTestBoundaryItemID(from: $0) ?? UUID()) }.count, 3)
    }

    @MainActor func testRestartAfterCleanupBeforeReleaseDeliversProvenOwnersOnce() async throws {
        for position in 0..<3 {
            TransferURLProtocol.reset()
            let captureRoot = self.rootURL.appendingPathComponent("restart-before-release-\(position)-capture", isDirectory: true)
            let transferRoot = self.rootURL.appendingPathComponent("restart-before-release-\(position)-transfer", isDirectory: true)
            let fixture = try self.seedThreeOwnerCapture(rootURL: captureRoot)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let first = self.makeHarness(rootURL: transferRoot)
            try await first.engine.initialize()
            try await self.stageThreeOwnerFixture(fixture, rootURL: captureRoot, engine: first.engine)
            let ownerID = fixture.orderedOwnerIDs[position]
            let injection = SettlementInjectionState(itemID: ownerID, action: .release)
            let unrelatedID = UUID()
            _ = try await first.engine.enqueue(manifest: self.unrelatedManifest(itemID: unrelatedID), payloads: ["audio": Data("unrelated".utf8)])
            let firstCoordinator = OmiLaunchCaptureCommitCoordinator(
                rootURL: captureRoot,
                engine: first.engine,
                sourceManager: self.makeManager(),
                io: io,
                onSettlementAction: { itemID, action in
                    injection.isEnabled && itemID == injection.itemID && action == injection.action ? .unknownToken : nil
                }
            )
            await firstCoordinator.reconcile()

            let paths = OmiLaunchCaptureMaterializedArtifactPaths(
                rootURL: captureRoot,
                generationID: fixture.generationID,
                ordinal: fixture.ordinal(for: ownerID)
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.envelopeURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.audioURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.provenanceURL.path))
            let storedAudioURL = await first.engine.payloadFileURL(itemID: ownerID, partID: "audio")
            let spoolAudioURL = try XCTUnwrap(storedAudioURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: spoolAudioURL.path))
            try io.restoreLastSynchronizedState()

            let restarted = self.makeHarness(rootURL: transferRoot)
            try await restarted.engine.initialize()
            var registeredAttachedOwner = false
            let restartedCoordinator = OmiLaunchCaptureCommitCoordinator(
                rootURL: captureRoot,
                engine: restarted.engine,
                sourceManager: self.makeManager(),
                io: io,
                onReconciliationPhase: { phase in
                    if phase == .afterOwnerRegisteredBeforeAcknowledgment {
                        registeredAttachedOwner = true
                    }
                }
            )
            await restartedCoordinator.reconcile()
            XCTAssertFalse(registeredAttachedOwner)
            XCTAssertEqual(TransferURLProtocol.requests.count, 0)
            await restarted.engine.enableDispatch()
            try await transferTestWaitFor("cleanup-before-release restart \(position)") {
                Set(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:))).isSuperset(of: fixture.ownerIDs)
            }
            XCTAssertTrue(TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == unrelatedID })
            await self.assertFixtureOwnerSettlement(fixture, engine: restarted.engine, requests: TransferURLProtocol.requests)
            XCTAssertEqual(TransferURLProtocol.requests.filter { fixture.ownerIDs.contains(transferTestBoundaryItemID(from: $0) ?? UUID()) }.count, 3)
        }
    }

    @MainActor func testAcknowledgmentIsRequiredBeforeOwnerRelease() async throws {
        let barrier = CommitCoordinatorBarrier()
        let captureRoot = self.rootURL.appendingPathComponent("success-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("success-transfer", isDirectory: true)
        _ = try self.seedCapture(rootURL: captureRoot)
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        await harness.engine.enableDispatch()
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager(),
            onReconciliationPhase: { phase in
                if phase == .afterOwnerRegisteredBeforeAcknowledgment { await barrier.suspend() }
            }
        )
        let task = Task { @MainActor in await coordinator.reconcile() }
        try await transferTestWaitFor("owner registration before acknowledgment") { await barrier.waiting() }
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        await barrier.resume()
        await task.value
        try await transferTestWaitFor("acknowledged owner") { TransferURLProtocol.requests.count == 1 }

        for operation in [OmiLaunchCaptureInjectedOperation.openForReading, .replace] {
            TransferURLProtocol.reset()
            let failureCaptureRoot = self.rootURL.appendingPathComponent("failure-capture-\(String(describing: operation))", isDirectory: true)
            let failureTransferRoot = self.rootURL.appendingPathComponent("failure-transfer-\(String(describing: operation))", isDirectory: true)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let generation = try self.seedCapture(rootURL: failureCaptureRoot)
            let audioURL = failureCaptureRoot
                .appendingPathComponent(OmiLaunchCaptureFormat.materializedDirectoryName, isDirectory: true)
                .appendingPathComponent(generation.uuidString, isDirectory: true)
                .appendingPathComponent(OmiSegmentWriter.chunkID(sessionID: generation, index: 0))
                .appendingPathExtension("m4a")
            let envelopeURL = OmiPendingHandoffStore.url(for: audioURL)
            let failureHarness = self.makeHarness(rootURL: failureTransferRoot)
            try await failureHarness.engine.initialize()
            await failureHarness.engine.enableDispatch()
            let failureCoordinator = OmiLaunchCaptureCommitCoordinator(
                rootURL: failureCaptureRoot,
                engine: failureHarness.engine,
                sourceManager: self.makeManager(),
                io: io,
                onReconciliationPhase: { phase in
                    if phase == .afterOwnerRegisteredBeforeAcknowledgment {
                        XCTAssertTrue(FileManager.default.fileExists(atPath: envelopeURL.path))
                        io.failNext(operation)
                    }
                }
            )
            await failureCoordinator.reconcile()
            XCTAssertEqual(TransferURLProtocol.requests.count, 0)
            let failureSnapshots = await failureHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
            XCTAssertEqual(failureSnapshots.filter { $0.manifest.payloadParts.isEmpty == false }.count, 1)
            XCTAssertEqual(failureSnapshots.filter { $0.manifest.attention?.reason == "launch_capture_settlement_acknowledgment_failed" }.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: envelopeURL.path))
            let repeated = try self.materialize(rootURL: failureCaptureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO())
            XCTAssertEqual(repeated.partitions.count, 1)
            XCTAssertEqual(repeated.partitions.first?.itemID, failureSnapshots.first { $0.manifest.payloadParts.isEmpty == false }?.itemID)
        }
    }

    @MainActor func testUnknownEnumerationGatesEveryOmiOwnerButNotUnrelatedWork() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("transfer", isDirectory: true)
        let io = FaultInjectingOmiLaunchCaptureIO()
        let harness = self.makeHarness(rootURL: transferRoot)
        let spool = TransferSpool(rootURL: transferRoot)
        try FileManager.default.createDirectory(at: captureRoot.appendingPathComponent("Materialized", isDirectory: true), withIntermediateDirectories: true)
        let omiIDs = [UUID(), UUID()]
        for (index, id) in omiIDs.enumerated() {
            _ = try spool.commitStagedItem(itemID: spool.stage(manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: id, sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: index, startedAt: Date())), payloads: ["audio": Data("omi".utf8)]).item.manifest.itemID)
        }
        let unrelatedID = UUID()
        var unrelated = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: unrelatedID,
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 8, startedAt: Date())
        )
        unrelated.source = "unrelated"
        unrelated.priority.sourceKey = "unrelated"
        _ = try spool.commitStagedItem(itemID: spool.stage(manifest: unrelated, payloads: ["audio": Data([0])]).item.manifest.itemID)
        try await harness.engine.initialize()
        io.failNext(.listDirectory)
        await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager(), io: io).reconcile()
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        let gatedBeforeDispatch = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(Set(gatedBeforeDispatch.map(\.itemID)), Set(omiIDs))
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("unrelated dispatch") { TransferURLProtocol.requests.count == 1 }
        XCTAssertEqual(transferTestBoundaryItemID(from: try XCTUnwrap(TransferURLProtocol.requests.first)), unrelatedID)
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(Set(snapshots.map(\.itemID)), Set(omiIDs))
        XCTAssertEqual(snapshots.count, omiIDs.count)
        XCTAssertEqual(TransferURLProtocol.requests.filter { transferTestBoundaryItemID(from: $0) != unrelatedID }.count, 0)
    }

    @MainActor func testRepeatedRestartKeepsOneStableOwnerAndOneSendPerPartition() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("transfer", isDirectory: true)
        let generation = try self.seedTwoPartitionCapture(rootURL: captureRoot)
        let expectedPartitions = [
            (
                itemID: OmiLaunchCaptureMaterializationIdentity.itemID(
                    generationID: generation,
                    partitionOrdinal: 0,
                    startSequence: 0,
                    startSampleOffset: 0
                ),
                coveredThroughSequence: UInt64(0)
            ),
            (
                itemID: OmiLaunchCaptureMaterializationIdentity.itemID(
                    generationID: generation,
                    partitionOrdinal: 1,
                    startSequence: 1,
                    startSampleOffset: 320
                ),
                coveredThroughSequence: UInt64(1)
            ),
        ]
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        await harness.engine.enableDispatch()
        let barrier = CommitCoordinatorBarrier()
        var gatedOwners = 0
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager(),
            onReconciliationPhase: { phase in
                guard phase == .afterNewOwnerGated else { return }
                gatedOwners += 1
                if gatedOwners == 2 { await barrier.suspend() }
            }
        )
        let abandonedPass = Task { @MainActor in await coordinator.reconcile() }
        try await transferTestWaitFor("second owner committed") { await barrier.waiting() }
        let crashSnapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(
            Set(crashSnapshots.map(\.itemID)),
            Set(expectedPartitions.map(\.itemID))
        )
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)

        // This pass is intentionally abandoned at the second owner commit to model a process crash.
        let restarted = self.makeHarness(rootURL: transferRoot)
        try await restarted.engine.initialize()
        let rematerialized = try self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO())
        XCTAssertEqual(rematerialized.partitions.count, expectedPartitions.count)
        XCTAssertEqual(rematerialized.partitions.map(\.itemID), expectedPartitions.map(\.itemID))
        XCTAssertEqual(Set(rematerialized.partitions.map(\.itemID)), Set(expectedPartitions.map(\.itemID)))
        XCTAssertTrue(rematerialized.partitions.allSatisfy { $0.endsAtSourceFrameBoundary && $0.coveredThroughSequence != nil })
        for partition in rematerialized.partitions {
            let envelope = try OmiPendingHandoffStore.read(from: partition.envelopeURL)
            let ownership = try await restarted.engine.verifyOwnership(
                expectedManifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: partition.itemID, sidecar: envelope.sidecar, metadata: envelope.metadata),
                expectedPayloadSourceURLs: [:]
            )
            XCTAssertEqual(
                ownership,
                .ownedInQueued
            )
        }
        var reachedAcknowledgment = false
        let restartedCoordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: restarted.engine,
            sourceManager: self.makeManager(),
            onReconciliationPhase: { phase in
                if phase == .afterOwnerRegisteredBeforeAcknowledgment {
                    reachedAcknowledgment = true
                }
            }
        )
        await restartedCoordinator.reconcile()
        XCTAssertTrue(reachedAcknowledgment)
        await restarted.engine.enableDispatch()
        try await transferTestWaitFor("both partition deliveries") { TransferURLProtocol.requests.count >= 2 }
        XCTAssertEqual(TransferURLProtocol.requests.count, 2)
        XCTAssertEqual(
            Set(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:))),
            Set(expectedPartitions.map(\.itemID))
        )
        XCTAssertEqual(expectedPartitions.map(\.coveredThroughSequence), [0, 1])

        let secondRestart = self.makeHarness(rootURL: transferRoot)
        try await secondRestart.engine.initialize()
        await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: secondRestart.engine, sourceManager: self.makeManager()).reconcile()
        await secondRestart.engine.enableDispatch()
        XCTAssertEqual(TransferURLProtocol.requests.count, 2)
        XCTAssertTrue(try self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO()).partitions.isEmpty)
        _ = abandonedPass
    }

    @MainActor func testIOFaultsConvergeFailClosedWithoutBlockingUnrelatedWork() async throws {
        for operation in [OmiLaunchCaptureInjectedOperation.listDirectory, .remove, .replace, .openForReading, .exists] {
            TransferURLProtocol.reset()
            let captureRoot = self.rootURL.appendingPathComponent("fault-\(String(describing: operation))", isDirectory: true)
            let transferRoot = self.rootURL.appendingPathComponent("transfer-\(String(describing: operation))", isDirectory: true)
            let io = FaultInjectingOmiLaunchCaptureIO()
            _ = try self.seedCapture(rootURL: captureRoot)
            try FileManager.default.createDirectory(at: captureRoot.appendingPathComponent("Materialized", isDirectory: true), withIntermediateDirectories: true)
            let harness = self.makeHarness(rootURL: transferRoot)
            let unrelatedID = UUID()
            try await harness.engine.initialize()
            _ = try await harness.engine.enqueue(
                manifest: self.unrelatedManifest(itemID: unrelatedID),
                payloads: ["audio": Data("unrelated".utf8)]
            )
            io.failNext(operation)
            await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager(), io: io).reconcile()
            await harness.engine.enableDispatch()
            try await transferTestWaitFor("unrelated fault-matrix delivery") { TransferURLProtocol.requests.count == 1 }
            XCTAssertEqual(transferTestBoundaryItemID(from: try XCTUnwrap(TransferURLProtocol.requests.first)), unrelatedID)
        }
    }

    @MainActor func testNonIOOwnerRegistrationAndGatedEnqueueFailuresStayFailClosed() async throws {
        let existingCaptureRoot = self.rootURL.appendingPathComponent("existing-capture", isDirectory: true)
        let existingTransferRoot = self.rootURL.appendingPathComponent("existing-transfer", isDirectory: true)
        let existingGeneration = try self.seedCapture(rootURL: existingCaptureRoot)
        let existingPartition = try XCTUnwrap(self.materialize(rootURL: existingCaptureRoot, generation: existingGeneration, io: FoundationOmiLaunchCaptureIO()).partitions.first)
        let existingEnvelope = try OmiPendingHandoffStore.read(from: existingPartition.envelopeURL)
        let existingHarness = self.makeHarness(rootURL: existingTransferRoot)
        try await existingHarness.engine.initialize()
        _ = try await existingHarness.engine.enqueue(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: existingPartition.itemID, sidecar: existingEnvelope.sidecar),
            payloads: ["audio": Data(contentsOf: existingPartition.audioURL)]
        )
        guard case .gated = await existingHarness.engine.gateExisting(itemID: existingPartition.itemID) else {
            return XCTFail("expected pre-existing gate")
        }
        await existingHarness.engine.hold(itemID: existingPartition.itemID)
        let existingUnrelatedID = UUID()
        _ = try await existingHarness.engine.enqueue(manifest: self.unrelatedManifest(itemID: existingUnrelatedID), payloads: ["audio": Data("unrelated".utf8)])
        await OmiLaunchCaptureCommitCoordinator(rootURL: existingCaptureRoot, engine: existingHarness.engine, sourceManager: self.makeManager()).reconcile()
        await existingHarness.engine.enableDispatch()
        try await transferTestWaitFor("unrelated delivery after existing-owner gate conflict") { TransferURLProtocol.requests.count == 1 }
        XCTAssertEqual(transferTestBoundaryItemID(from: try XCTUnwrap(TransferURLProtocol.requests.first)), existingUnrelatedID)
        XCTAssertEqual(TransferURLProtocol.requests.filter { transferTestBoundaryItemID(from: $0) == existingPartition.itemID }.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingPartition.envelopeURL.path))

        TransferURLProtocol.reset()
        let enqueueCaptureRoot = self.rootURL.appendingPathComponent("enqueue-capture", isDirectory: true)
        let enqueueTransferRoot = self.rootURL.appendingPathComponent("enqueue-transfer", isDirectory: true)
        let enqueueGeneration = try self.seedCapture(rootURL: enqueueCaptureRoot)
        let enqueuePartition = try XCTUnwrap(self.materialize(rootURL: enqueueCaptureRoot, generation: enqueueGeneration, io: FoundationOmiLaunchCaptureIO()).partitions.first)
        let enqueueHarness = self.makeHarness(rootURL: enqueueTransferRoot)
        try await enqueueHarness.engine.initialize()
        guard case .gated = await enqueueHarness.engine.gateExisting(itemID: enqueuePartition.itemID) else {
            return XCTFail("expected conflicting gate")
        }
        let enqueueUnrelatedID = UUID()
        _ = try await enqueueHarness.engine.enqueue(manifest: self.unrelatedManifest(itemID: enqueueUnrelatedID), payloads: ["audio": Data("unrelated".utf8)])
        await OmiLaunchCaptureCommitCoordinator(rootURL: enqueueCaptureRoot, engine: enqueueHarness.engine, sourceManager: self.makeManager()).reconcile()
        await enqueueHarness.engine.enableDispatch()
        try await transferTestWaitFor("unrelated delivery after gated-enqueue conflict") { TransferURLProtocol.requests.count == 1 }
        XCTAssertEqual(transferTestBoundaryItemID(from: try XCTUnwrap(TransferURLProtocol.requests.first)), enqueueUnrelatedID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: enqueuePartition.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: enqueuePartition.envelopeURL.path))
        let enqueueSnapshots = await enqueueHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertTrue(enqueueSnapshots.isEmpty)
    }

    @MainActor func testBoundaryAcknowledgesOnlyVerifiedPrefixCreatesOnePayloadFreeAttentionAndRefusesCutover() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("transfer", isDirectory: true)
        let generation = UUID()
        let writer = OmiLaunchCaptureWriter(rootURL: captureRoot, generationID: generation)
        self.append(Self.packet(0, body: try Self.opusFrame()), to: writer)
        XCTAssertEqual(writer.reserveGap(), .visibleGap(sequence: 1, .intentionalGap))
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        let coordinator = OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager())
        await coordinator.reconcile()
        await coordinator.reconcile()
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.filter { $0.manifest.diskState == .queued }.count, 1)
        let attention = try XCTUnwrap(snapshots.first { $0.manifest.diskState == .attention })
        XCTAssertEqual(attention.manifest.payloadParts, [])
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: generation).lease(), .empty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.fileURL.path))
    }

    @MainActor func testUnreadableCursorAttentionDeduplicatesAcrossRestarts() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("transfer", isDirectory: true)
        let generation = try self.seedCapture(rootURL: captureRoot)
        let reader = OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: generation)
        let cursorData = Self.invalidMagicCursor(generationID: generation, mutation: 0x01)
        try cursorData.write(to: reader.cursorURL)

        var expectedItemID: UUID?
        for restart in 0..<3 {
            let harness = self.makeHarness(rootURL: transferRoot)
            try await harness.engine.initialize()
            await OmiLaunchCaptureCommitCoordinator(
                rootURL: captureRoot,
                engine: harness.engine,
                sourceManager: self.makeManager()
            ).reconcile()
            let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
            XCTAssertEqual(snapshots.filter { $0.state == .attention }.count, 1, "restart=\(restart)")
            let attention = try XCTUnwrap(snapshots.first)
            XCTAssertEqual(attention.state, .attention, "restart=\(restart)")
            XCTAssertTrue(attention.manifest.payloadParts.isEmpty, "restart=\(restart)")
            XCTAssertEqual(attention.manifest.attention?.reason, "launch_capture_cursor_unreadable", "restart=\(restart)")
            if let expectedItemID {
                XCTAssertEqual(attention.itemID, expectedItemID, "restart=\(restart)")
            } else {
                expectedItemID = attention.itemID
            }
            XCTAssertEqual(TransferURLProtocol.requests.count, 0, "restart=\(restart)")
            await harness.engine.enableDispatch()
            XCTAssertEqual(TransferURLProtocol.requests.count, 0, "restart=\(restart)")
        }
        XCTAssertEqual(try Data(contentsOf: reader.cursorURL), cursorData)
    }

    @MainActor func testUnreadableCursorAttentionUsesObservablePrefixIdentityInProductionComposition() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("transfer", isDirectory: true)
        let firstGeneration = try self.seedCapture(rootURL: captureRoot)
        let secondGeneration = try self.seedCapture(rootURL: captureRoot)
        let firstReader = OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: firstGeneration)
        let secondReader = OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: secondGeneration)
        let firstCursor = Self.invalidMagicCursor(generationID: firstGeneration, mutation: 0x01)
        let secondCursor = Self.invalidMagicCursor(generationID: secondGeneration, mutation: 0x01)
        try firstCursor.write(to: firstReader.cursorURL)
        try secondCursor.write(to: secondReader.cursorURL)
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager()
        )

        await coordinator.reconcile()
        await coordinator.reconcile()
        var snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertTrue(snapshots.allSatisfy { $0.state == .attention && $0.manifest.payloadParts.isEmpty })
        XCTAssertTrue(snapshots.allSatisfy { $0.manifest.attention?.reason == "launch_capture_cursor_unreadable" })
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        await harness.engine.enableDispatch()
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)

        let rewrittenFirstCursor = Self.invalidMagicCursor(generationID: firstGeneration, mutation: 0x02)
        XCTAssertNotEqual(OmiLaunchCaptureDigest.truncated(firstCursor), OmiLaunchCaptureDigest.truncated(rewrittenFirstCursor))
        try rewrittenFirstCursor.write(to: firstReader.cursorURL)
        await coordinator.reconcile()
        snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(snapshots.filter { $0.manifest.payloadParts.isEmpty && $0.state == .attention }.count, 3)

        for name in ["absent", "valid"] {
            let controlCaptureRoot = self.rootURL.appendingPathComponent("\(name)-capture", isDirectory: true)
            let controlTransferRoot = self.rootURL.appendingPathComponent("\(name)-transfer", isDirectory: true)
            let generation = try self.seedCapture(rootURL: controlCaptureRoot)
            let controlReader = OmiLaunchCaptureLeaseReader(rootURL: controlCaptureRoot, generationID: generation)
            if name == "valid" {
                try OmiLaunchCaptureCursor(generationID: generation, acknowledgedPrefixNextSequence: 0, acknowledgedPrefixEndOffset: 0).encoded().write(to: controlReader.cursorURL)
            }
            let controlHarness = self.makeHarness(rootURL: controlTransferRoot)
            try await controlHarness.engine.initialize()
            await OmiLaunchCaptureCommitCoordinator(
                rootURL: controlCaptureRoot,
                engine: controlHarness.engine,
                sourceManager: self.makeManager()
            ).reconcile()
            let controlSnapshots = await controlHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
            XCTAssertFalse(controlSnapshots.contains { $0.manifest.attention?.reason == "launch_capture_cursor_unreadable" }, name)
        }
    }

    @MainActor func testMaterializationFailureAcknowledgesOnlyFrontierAndNeverSettlesSuffixOwner() async throws {
        let frame = try Self.opusFrame()
        for (name, stageThenRemoveSuffix) in [("never-staged", false), ("staged-then-removed", true)] {
            TransferURLProtocol.reset()
            let captureRoot = self.rootURL.appendingPathComponent("\(name)-capture", isDirectory: true)
            let referenceRoot = self.rootURL.appendingPathComponent("\(name)-reference", isDirectory: true)
            let transferRoot = self.rootURL.appendingPathComponent("\(name)-transfer", isDirectory: true)
            let generation = UUID()
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let captureClock = MockObserverClock(now: start)
            let capture = OmiLaunchCaptureWriter(rootURL: captureRoot, generationID: generation, clock: captureClock, io: io)
            let referenceClock = MockObserverClock(now: start)
            let reference = OmiLaunchCaptureWriter(rootURL: referenceRoot, generationID: generation, clock: referenceClock)
            for packet in 0..<4 {
                self.append(Self.packet(UInt16(packet), body: frame), to: capture)
                self.append(Self.packet(UInt16(packet), body: frame), to: reference)
                captureClock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
                referenceClock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
            }

            let frontierItemID = OmiLaunchCaptureMaterializationIdentity.itemID(
                generationID: generation,
                partitionOrdinal: 0,
                startSequence: 0,
                startSampleOffset: 0
            )
            let suffixItemID = OmiLaunchCaptureMaterializationIdentity.itemID(
                generationID: generation,
                partitionOrdinal: 2,
                startSequence: 2,
                startSampleOffset: 640
            )
            let referenceResult = try self.materialize(rootURL: referenceRoot, generation: generation, io: FoundationOmiLaunchCaptureIO())
            let referenceSuffix = try XCTUnwrap(referenceResult.partitions.dropFirst(2).first, name)
            XCTAssertEqual(referenceSuffix.itemID, suffixItemID, name)

            if stageThenRemoveSuffix {
                let envelope = try OmiPendingHandoffStore.read(from: referenceSuffix.envelopeURL)
                let spool = TransferSpool(rootURL: transferRoot)
                let staged = try spool.stage(
                    manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(
                        itemID: suffixItemID,
                        sidecar: envelope.sidecar,
                        metadata: envelope.metadata
                    ),
                    payloads: ["audio": Data(contentsOf: referenceSuffix.audioURL)]
                )
                let committed = try spool.commitStagedItem(itemID: staged.item.manifest.itemID)
                XCTAssertEqual(committed.manifest.itemID, suffixItemID, name)
                try spool.removeCommittedItem(committed)
                XCTAssertFalse(FileManager.default.fileExists(atPath: committed.directoryURL.path), name)
            }

            let failedPaths = OmiLaunchCaptureMaterializedArtifactPaths(rootURL: captureRoot, generationID: generation, ordinal: 1)
            io.failReplace(at: failedPaths.audioURL, fromCall: 1)
            let harness = self.makeHarness(rootURL: transferRoot)
            try await harness.engine.initialize()
            await harness.engine.enableDispatch()

            let coordinator = OmiLaunchCaptureCommitCoordinator(
                rootURL: captureRoot,
                engine: harness.engine,
                sourceManager: self.makeManager(),
                io: io
            )
            await coordinator.reconcile()

            try await transferTestWaitFor("frontier delivery \(name)") {
                TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == frontierItemID }
            }
            let suffixSnapshot = await harness.engine.itemSnapshot(itemID: suffixItemID)
            XCTAssertNil(suffixSnapshot, name)
            XCTAssertFalse(TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == suffixItemID }, name)

            let reader = OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: generation, io: io)
            let position = try XCTUnwrap(reader.acknowledgedPosition(), name)
            XCTAssertEqual(position.nextSequence, 1, name)
            XCTAssertEqual(reader.cursor()?.nextPartitionOrdinal, 1, name)
            XCTAssertEqual(reader.cursor()?.nextSampleOffset, 320, name)
            if case .lease(let lease) = reader.lease() {
                XCTAssertEqual(lease.startSequence, 1, name)
            } else {
                XCTFail("failure suffix must remain unacknowledged: \(name)")
            }
        }
    }

    @MainActor func testRestartSettlesLegacyMaterializedUnacknowledgedPrefix() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("legacy-frontier-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("legacy-frontier-transfer", isDirectory: true)
        let generation = UUID()
        let writer = OmiLaunchCaptureWriter(rootURL: captureRoot, generationID: generation)
        self.append(Data([0, 0, 0xff, 0, 0, 0, 0]), to: writer)
        let reader = OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: generation)
        guard case .lease(let lease) = reader.lease() else { return XCTFail("expected marker lease") }

        // This is the durable state left by the former two-write path if the
        // process stopped after the materialized write and before acknowledgement.
        let interrupted = OmiLaunchCaptureCursor(
            generationID: generation,
            acknowledgedPrefixNextSequence: 0,
            acknowledgedPrefixEndOffset: 0,
            materializedPrefixNextSequence: lease.throughSequence + 1,
            materializedPrefixEndOffset: lease.endOffset
        )
        try interrupted.encoded().write(to: reader.cursorURL)

        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        let defaults = UserDefaults(suiteName: "OmiLaunchCaptureCommitCoordinatorTests-\(UUID().uuidString)")!
        defaults.set(true, forKey: OmiSourceManager.enabledKey)
        let ingress = OmiLaunchCaptureIngress(appGroupRoot: { captureRoot }, generationID: generation)
        let manager = OmiSourceManager(
            defaults: defaults,
            clock: MockObserverClock(),
            bluetoothPort: MockOmiBluetoothPort(),
            launchCaptureIngress: ingress
        )
        manager.enable()
        await OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: manager
        ).reconcile()

        let restarted = OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: generation)
        XCTAssertEqual(restarted.lease(), .empty)
        let cursor = try XCTUnwrap(restarted.cursor())
        XCTAssertEqual(cursor.acknowledgedPrefixNextSequence, lease.throughSequence + 1)
        XCTAssertEqual(cursor.materializedPrefixNextSequence, cursor.acknowledgedPrefixNextSequence)
    }

    @MainActor func testMaterializationFailureAttentionDeduplicatesAcrossRestarts() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("transfer", isDirectory: true)
        let generation = try self.seedCapture(rootURL: captureRoot)
        let io = FaultInjectingOmiLaunchCaptureIO()
        let paths = OmiLaunchCaptureMaterializedArtifactPaths(rootURL: captureRoot, generationID: generation, ordinal: 0)
        io.failReplace(at: paths.audioURL, fromCall: 1)

        let first = self.makeHarness(rootURL: transferRoot)
        try await first.engine.initialize()
        await OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: first.engine,
            sourceManager: self.makeManager(),
            io: io
        ).reconcile()
        var snapshots = await first.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.count, 1)
        let firstAttention = try XCTUnwrap(snapshots.first { $0.state == .attention && $0.manifest.payloadParts.isEmpty })
        XCTAssertEqual(firstAttention.manifest.attention?.reason, "launch_capture_materialization_failed")

        let restarted = self.makeHarness(rootURL: transferRoot)
        try await restarted.engine.initialize()
        await OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: restarted.engine,
            sourceManager: self.makeManager(),
            io: io
        ).reconcile()
        snapshots = await restarted.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.count, 1)
        let restartedAttention = try XCTUnwrap(snapshots.first { $0.state == .attention && $0.manifest.payloadParts.isEmpty })
        XCTAssertEqual(restartedAttention.manifest.attention?.reason, "launch_capture_materialization_failed")
        XCTAssertEqual(restartedAttention.itemID, firstAttention.itemID)
    }

    @MainActor func testHealthyEmptyLaunchCaptureCreatesNoAttention() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("transfer", isDirectory: true)
        let generation = UUID()
        let writer = OmiLaunchCaptureWriter(rootURL: captureRoot, generationID: generation)
        XCTAssertTrue(writer.arm())
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()

        await OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager()
        ).reconcile()

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertFalse(snapshots.contains { $0.manifest.attention?.reason == "launch_capture_materialization_failed" })
    }

    @MainActor func testCrashWindowsKeepDurableArtifactsReusableAndFrontierContiguous() async throws {
        for window in ["before-output", "after-output-before-settlement", "after-settlement-before-return", "before-next-batch"] {
            let captureRoot = self.rootURL.appendingPathComponent(window, isDirectory: true)
            let transferRoot = self.rootURL.appendingPathComponent("\(window)-transfer", isDirectory: true)
            let generation = try self.seedCapture(rootURL: captureRoot)
            let paths = OmiLaunchCaptureMaterializedArtifactPaths(rootURL: captureRoot, generationID: generation, ordinal: 0)
            let harness = self.makeHarness(rootURL: transferRoot)
            try await harness.engine.initialize()

            switch window {
            case "before-output":
                let io = FaultInjectingOmiLaunchCaptureIO()
                io.failReplace(at: paths.audioURL, fromCall: 1)
                await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager(), io: io).reconcile()
                XCTAssertFalse(FileManager.default.fileExists(atPath: paths.audioURL.path), window)
                io.clearFaults()
                await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager(), io: io).reconcile()

            case "after-output-before-settlement":
                let crashing = CrashAfterFinalAudioReplaceIO()
                await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager(), io: crashing).reconcile()
                XCTAssertFalse(FileManager.default.fileExists(atPath: paths.envelopeURL.path), window)
                await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager()).reconcile()

            case "after-settlement-before-return":
                let barrier = CommitCoordinatorBarrier()
                let coordinator = OmiLaunchCaptureCommitCoordinator(
                    rootURL: captureRoot,
                    engine: harness.engine,
                    sourceManager: self.makeManager(),
                    onReconciliationPhase: { phase in
                        if phase == .afterOwnerRegisteredBeforeAcknowledgment { await barrier.suspend() }
                    }
                )
                let reconciliation = Task { @MainActor in await coordinator.reconcile() }
                try await transferTestWaitFor("owner registration") { await barrier.waiting() }
                let beforeCommit = try XCTUnwrap(OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: generation).cursor(), window)
                XCTAssertEqual(beforeCommit.materializedPrefixNextSequence, beforeCommit.acknowledgedPrefixNextSequence, window)
                await barrier.resume()
                await reconciliation.value
                // A fresh coordinator represents a process loss after the atomic
                // settlement write but before any later successor can run.
                await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager()).reconcile()

            default:
                await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager()).reconcile()
                // Restart before a later batch is requested; a settled one-record
                // generation must not rediscover or duplicate its owner.
                await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager()).reconcile()
            }

            let reader = OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: generation)
            let cursor = try XCTUnwrap(reader.cursor(), window)
            XCTAssertEqual(cursor.materializedPrefixNextSequence, cursor.acknowledgedPrefixNextSequence, window)
            XCTAssertEqual(cursor.materializedPrefixEndOffset, cursor.acknowledgedPrefixEndOffset, window)
            XCTAssertEqual(reader.lease(), .empty, window)
            let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
            XCTAssertEqual(snapshots.filter { $0.manifest.payloadParts.isEmpty == false }.count, 1, window)
        }
    }

    @MainActor func testNoProgressUsesOneClockDelayedSuccessorAndDeduplicatesAttention() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("no-progress-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("no-progress-transfer", isDirectory: true)
        let io = FaultInjectingOmiLaunchCaptureIO()
        let clock = MockObserverClock()
        let generation = UUID()
        let writer = OmiLaunchCaptureWriter(rootURL: captureRoot, generationID: generation, clock: clock, io: io)
        self.append(Self.packet(0, body: try Self.opusFrame()), to: writer)
        let paths = OmiLaunchCaptureMaterializedArtifactPaths(rootURL: captureRoot, generationID: generation, ordinal: 0)
        io.failReplace(at: paths.audioURL, fromCall: 1)
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager(),
            io: io,
            clock: clock
        )

        await coordinator.reconcile()
        await Task.yield()
        XCTAssertEqual(clock.pendingSleeperCount, 1)
        let firstSnapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(firstSnapshots.filter { $0.manifest.attention?.reason == "launch_capture_materialization_failed" }.count, 1)
        let callsWhileDelayed = io.performedIOCallCount
        await Task.yield()
        XCTAssertEqual(io.performedIOCallCount, callsWhileDelayed, "no immediate successor may spin while the clock delay is armed")

        // A second state-changing trigger performs one more faulted attempt, but
        // coalesces onto the already armed delayed successor.
        await coordinator.reconcile()
        XCTAssertEqual(clock.pendingSleeperCount, 1)
        let repeatedSnapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(repeatedSnapshots.filter { $0.manifest.attention?.reason == "launch_capture_materialization_failed" }.count, 1)

        io.clearFaults()
        clock.advance(by: 1)
        let reader = OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: generation, io: io)
        try await transferTestWaitFor("clock-delayed recovery") {
            await MainActor.run { reader.lease() == .empty }
        }
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.filter { $0.manifest.attention?.reason == "launch_capture_materialization_failed" }.count, 1)
    }

    @MainActor func testOrphanRepairFailureAttentionDeduplicatesAcrossRestarts() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("transfer", isDirectory: true)
        let generation = try self.seedCapture(rootURL: captureRoot)
        let crashIO = CrashAfterFinalAudioReplaceIO()
        let crashDecoder = try OmiOpusAudioDecoder()
        XCTAssertTrue(OmiLaunchCaptureMaterializer(rootURL: captureRoot, generationID: generation, io: crashIO, decode: { crashDecoder.decode($0) }).materializeForTests().partitions.isEmpty)
        let paths = OmiLaunchCaptureMaterializedArtifactPaths(rootURL: captureRoot, generationID: generation, ordinal: 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.provenanceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.envelopeURL.path))

        let faultingIO = FaultInjectingOmiLaunchCaptureIO()
        faultingIO.failBarrier(onCall: 1)
        let first = self.makeHarness(rootURL: transferRoot)
        try await first.engine.initialize()
        await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: first.engine, sourceManager: self.makeManager(), io: faultingIO).reconcile()
        var snapshots = await first.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.filter { $0.state == .attention }.count, 1)
        XCTAssertEqual(snapshots.first?.manifest.attention?.reason, "launch_capture_orphan_repair_failed")
        XCTAssertTrue(snapshots.first?.manifest.payloadParts.isEmpty == true)
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)

        let restarted = self.makeHarness(rootURL: transferRoot)
        try await restarted.engine.initialize()
        await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: restarted.engine, sourceManager: self.makeManager()).reconcile()
        snapshots = await restarted.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.filter { $0.state == .attention }.count, 1)
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        await restarted.engine.enableDispatch()
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
    }

    @MainActor func testUnprovenCollocatedAACKeepsBackedOrphanFailClosed() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("transfer", isDirectory: true)
        let generation = try self.seedCapture(rootURL: captureRoot)
        let crashDecoder = try OmiOpusAudioDecoder()
        XCTAssertTrue(OmiLaunchCaptureMaterializer(rootURL: captureRoot, generationID: generation, io: CrashAfterFinalAudioReplaceIO(), decode: { crashDecoder.decode($0) }).materializeForTests().partitions.isEmpty)
        let paths = OmiLaunchCaptureMaterializedArtifactPaths(rootURL: captureRoot, generationID: generation, ordinal: 0)
        let unrelatedURL = paths.audioURL.deletingLastPathComponent().appendingPathComponent("unrelated.m4a")
        try Data("unrelated".utf8).write(to: unrelatedURL)
        let liveChunkURL = self.rootURL
            .appendingPathComponent("OmiObserver", isDirectory: true)
            .appendingPathComponent("live.m4a")
        try FileManager.default.createDirectory(at: liveChunkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let liveChunkBytes = Data("live".utf8)
        try liveChunkBytes.write(to: liveChunkURL)
        let before = try FileManager.default.contentsOfDirectory(at: paths.audioURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .reduce(into: [String: Data]()) { $0[$1.lastPathComponent] = try Data(contentsOf: $1) }
        let reader = OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: generation)
        let cursorBytes = try? Data(contentsOf: reader.cursorURL)
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()

        await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager()).reconcile()

        let after = try FileManager.default.contentsOfDirectory(at: paths.audioURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .reduce(into: [String: Data]()) { $0[$1.lastPathComponent] = try Data(contentsOf: $1) }
        XCTAssertEqual(after, before)
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertEqual(try? Data(contentsOf: reader.cursorURL), cursorBytes)
        XCTAssertEqual(try Data(contentsOf: liveChunkURL), liveChunkBytes)
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
    }

    @MainActor func testProvenanceBackedCollocatedTwinKeepsFailClosed() async throws {
        for mismatch in ["generation", "source-range", "item"] {
            TransferURLProtocol.reset()
            let captureRoot = self.rootURL.appendingPathComponent("\(mismatch)-capture", isDirectory: true)
            let transferRoot = self.rootURL.appendingPathComponent("\(mismatch)-transfer", isDirectory: true)
            let generation = try self.seedCapture(rootURL: captureRoot)
            let crashDecoder = try OmiOpusAudioDecoder()
            XCTAssertTrue(OmiLaunchCaptureMaterializer(rootURL: captureRoot, generationID: generation, io: CrashAfterFinalAudioReplaceIO(), decode: { crashDecoder.decode($0) }).materializeForTests().partitions.isEmpty, mismatch)
            let paths = OmiLaunchCaptureMaterializedArtifactPaths(rootURL: captureRoot, generationID: generation, ordinal: 0)
            let itemID = OmiLaunchCaptureMaterializationIdentity.itemID(generationID: generation, partitionOrdinal: 0, startSequence: 0, startSampleOffset: 0)
            let twin = OmiLaunchCaptureMaterializationProvenance(
                generationID: mismatch == "generation" ? UUID() : generation,
                partitionOrdinal: 0,
                startSequence: mismatch == "source-range" ? 1 : 0,
                startSampleOffset: 0,
                itemID: mismatch == "item" ? UUID() : itemID
            )
            try OmiLaunchCaptureMaterializationProvenanceStore.write(
                try OmiLaunchCaptureMaterializationProvenanceStore.encode(twin),
                to: paths.provenanceURL,
                io: FoundationOmiLaunchCaptureIO()
            )
            let before = try FileManager.default.contentsOfDirectory(at: paths.audioURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                .reduce(into: [String: Data]()) { $0[$1.lastPathComponent] = try Data(contentsOf: $1) }
            let reader = OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: generation)
            let cursorBytes = try? Data(contentsOf: reader.cursorURL)
            let harness = self.makeHarness(rootURL: transferRoot)
            try await harness.engine.initialize()

            await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager()).reconcile()

            let after = try FileManager.default.contentsOfDirectory(at: paths.audioURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                .reduce(into: [String: Data]()) { $0[$1.lastPathComponent] = try Data(contentsOf: $1) }
            XCTAssertEqual(after, before, mismatch)
            let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
            XCTAssertEqual(snapshots.count, 1, mismatch)
            let attention = try XCTUnwrap(snapshots.first { $0.state == .attention && $0.manifest.payloadParts.isEmpty }, mismatch)
            XCTAssertEqual(attention.manifest.attention?.reason, "launch_capture_materialization_failed", mismatch)
            XCTAssertEqual(try? Data(contentsOf: reader.cursorURL), cursorBytes, mismatch)
            XCTAssertEqual(TransferURLProtocol.requests.count, 0, mismatch)
        }
    }

    @MainActor private func makeHarness(rootURL: URL) -> (engine: TransferEngine, mirror: TransferStatusMirror, enqueuer: ObserverAudioTransferEnqueuer, omi: OmiUploaderHolder, watch: WatchUploaderHolder) {
        TransferURLProtocol.handler = { request, _ in (transferTestResponse(for: request, statusCode: 204), Data()) }
        return makeTransferCutoverHarness(rootURL: rootURL, sessionConfiguration: makeTransferTestURLSessionConfiguration(), endpointResolver: CommitCoordinatorAvailableEndpointResolver())
    }

    @MainActor private func makeManager(enabled: Bool = true) -> OmiSourceManager {
        let name = "OmiLaunchCaptureCommitCoordinatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(enabled, forKey: OmiSourceManager.enabledKey)
        return OmiSourceManager(defaults: defaults, clock: MockObserverClock(), bluetoothPort: MockOmiBluetoothPort())
    }

    @MainActor private func seedCapture(rootURL: URL) throws -> UUID {
        let generation = UUID()
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: MockObserverClock())
        self.append(Self.packet(0, body: try Self.opusFrame()), to: writer)
        return generation
    }

    @MainActor private func seedTwoPartitionCapture(rootURL: URL) throws -> UUID {
        let generation = UUID()
        let clock = MockObserverClock()
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: clock)
        self.append(Self.packet(0, body: try Self.opusFrame()), to: writer)
        clock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
        self.append(Self.packet(1, body: try Self.opusFrame()), to: writer)
        return generation
    }

    private struct ThreeOwnerFixture: FixtureOwnerSet {
        let generationID: UUID

        var ownerIDs: Set<UUID> {
            [self.ownerID(at: 0), self.ownerID(at: 1), self.ownerID(at: 2)]
        }

        var orderedOwnerIDs: [UUID] {
            self.ownerIDs.sorted { $0.uuidString < $1.uuidString }
        }

        func ownerID(at ordinal: Int) -> UUID {
            OmiLaunchCaptureMaterializationIdentity.itemID(
                generationID: self.generationID,
                partitionOrdinal: ordinal,
                startSequence: UInt64(ordinal),
                startSampleOffset: UInt64(ordinal * 320)
            )
        }

        func ordinal(for itemID: UUID) -> Int {
            precondition((0..<3).contains { self.ownerID(at: $0) == itemID })
            return (0..<3).first { self.ownerID(at: $0) == itemID }!
        }
    }

    private struct ThreeGenerationFixture: FixtureOwnerSet {
        let orderedGenerationIDs: [UUID]

        var ownerIDs: Set<UUID> {
            Set(self.orderedGenerationIDs.map(self.ownerID(for:)))
        }

        func ownerID(for generationID: UUID) -> UUID {
            OmiLaunchCaptureMaterializationIdentity.itemID(
                generationID: generationID,
                partitionOrdinal: 0,
                startSequence: 0,
                startSampleOffset: 0
            )
        }
    }

    @MainActor private func seedThreeOwnerCapture(rootURL: URL) throws -> ThreeOwnerFixture {
        let generationID = UUID()
        let clock = MockObserverClock()
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generationID, clock: clock)
        for sequence in 0..<3 {
            self.append(Self.packet(UInt16(sequence), body: try Self.opusFrame()), to: writer)
            clock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
        }
        return ThreeOwnerFixture(generationID: generationID)
    }

    @MainActor private func seedThreeGenerationCapture(rootURL: URL) throws -> ThreeGenerationFixture {
        let clock = MockObserverClock()
        var generationIDs: [UUID] = []
        for _ in 0..<3 {
            let generationID = UUID()
            let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generationID, clock: clock)
            self.append(Self.packet(0, body: try Self.opusFrame()), to: writer)
            generationIDs.append(generationID)
            clock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
        }
        return ThreeGenerationFixture(orderedGenerationIDs: generationIDs)
    }

    @MainActor private func stageThreeOwnerFixture(
        _ fixture: ThreeOwnerFixture,
        rootURL: URL,
        engine: TransferEngine,
        acknowledged: Bool = true,
        releaseGates: Bool = true
    ) async throws {
        let result = try self.materialize(rootURL: rootURL, generation: fixture.generationID, io: FoundationOmiLaunchCaptureIO())
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.partitions.count, 3)
        XCTAssertEqual(Set(result.partitions.map(\.itemID)), fixture.ownerIDs)
        XCTAssertEqual(Set(result.partitions.map(\.audioURL)).count, 3)
        XCTAssertEqual(Set(result.partitions.map(\.envelopeURL)).count, 3)

        for partition in result.partitions.sorted(by: { $0.itemID.uuidString < $1.itemID.uuidString }) {
            let envelope = try OmiPendingHandoffStore.read(from: partition.envelopeURL)
            let token = try await engine.enqueueGated(
                manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(
                    itemID: partition.itemID,
                    sidecar: envelope.sidecar,
                    metadata: envelope.metadata
                ),
                payloadFileURLs: ["audio": partition.audioURL]
            )
            if releaseGates {
                let release = await engine.releaseGate(token)
                XCTAssertEqual(release, .settled)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: partition.audioURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: partition.envelopeURL.path))
            let paths = OmiLaunchCaptureMaterializedArtifactPaths(
                rootURL: rootURL,
                generationID: fixture.generationID,
                ordinal: fixture.ordinal(for: partition.itemID)
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.provenanceURL.path))
        }

        guard acknowledged else { return }
        let last = try XCTUnwrap(result.partitions.last)
        let reader = OmiLaunchCaptureLeaseReader(rootURL: rootURL, generationID: fixture.generationID)
        XCTAssertEqual(
            reader.commitSettled(
                throughSequence: try XCTUnwrap(result.coveredThroughSequence),
                nextPartitionOrdinal: last.nextPartitionOrdinal,
                nextSampleOffset: last.nextSampleOffset
            ),
            .advanced
        )
    }

    @MainActor private func assertFixtureOwnerSettlement<Fixture: FixtureOwnerSet>(
        _ fixture: Fixture,
        engine: TransferEngine,
        requests: [URLRequest],
        requireConvergence: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let originalOwners = fixture.ownerIDs
        var released = Set(requests.compactMap(transferTestBoundaryItemID(from:))).intersection(originalOwners)
        let settlementAttention = await engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
            .compactMap { $0.manifest.attention }
            .filter { $0.reason.hasPrefix("launch_capture_settlement_") }
        var lifetimeHeld: Set<UUID> = []
        var trackedPending: Set<UUID> = []
        for itemID in originalOwners.subtracting(released) {
            switch await engine.restoreGateFromHold(itemID: itemID) {
            case .gated(let token):
                lifetimeHeld.insert(itemID)
                let outcome = await engine.convertGateToHold(token)
                XCTAssertEqual(outcome, .settled, file: file, line: line)
            case .alreadyGated:
                trackedPending.insert(itemID)
            case .notHeld:
                // A live gate is intentionally opaque outside TransferEngine. A
                // settlement attention record is its durable, observable retry
                // witness when a seam has left that gate active.
                if !requireConvergence && settlementAttention.contains(where: {
                    $0.shortDetail.contains("item=\(itemID.uuidString.lowercased())")
                }) {
                    trackedPending.insert(itemID)
                } else {
                    released.insert(itemID)
                }
            case .engineNotInitialized:
                break
            }
        }
        XCTAssertEqual(
            originalOwners,
            released.union(lifetimeHeld).union(trackedPending),
            "fixture owner settlement set equality",
            file: file,
            line: line
        )
        XCTAssertTrue(released.isDisjoint(with: lifetimeHeld), file: file, line: line)
        XCTAssertTrue(released.isDisjoint(with: trackedPending), file: file, line: line)
        XCTAssertTrue(lifetimeHeld.isDisjoint(with: trackedPending), file: file, line: line)
        if requireConvergence {
            let pendingIDs = trackedPending
                .map(\.uuidString)
                .sorted()
                .joined(separator: ", ")
            XCTAssertTrue(
                trackedPending.isEmpty && originalOwners == released.union(lifetimeHeld),
                "owners never converged: \(pendingIDs)",
                file: file,
                line: line
            )
        }
        let unsafeOwners = lifetimeHeld.union(trackedPending)
        XCTAssertFalse(TransferURLProtocol.requests.contains { request in
            guard let itemID = transferTestBoundaryItemID(from: request) else { return false }
            return unsafeOwners.contains(itemID)
        }, file: file, line: line)
    }

    @MainActor private func unrelatedManifest(itemID: UUID) -> TransferManifest {
        var manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: itemID,
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 99, startedAt: Date())
        )
        manifest.source = "unrelated"
        manifest.priority.sourceKey = "unrelated"
        return manifest
    }

    @MainActor private func materialize(rootURL: URL, generation: UUID, io: any OmiLaunchCaptureIO) throws -> OmiLaunchCaptureMaterializationResult {
        let decoder = try OmiOpusAudioDecoder()
        return OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, io: io, decode: { decoder.decode($0) }).materializeForTests()
    }

    @MainActor private func append(_ payload: Data, to writer: OmiLaunchCaptureWriter) {
        guard case .retained = writer.append(payload) else { XCTFail("fixture append failed"); return }
    }

    private static func packet(_ number: UInt16, body: Data) -> Data {
        Data([UInt8(number & 0xff), UInt8(number >> 8), 0]) + body
    }

    private static func opusFrame() throws -> Data {
        let format = try XCTUnwrap(AVAudioFormat(opusPCMFormat: .int16, sampleRate: OmiAudioChunkFormat.sampleRate, channels: OmiAudioChunkFormat.channelCount))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
        buffer.frameLength = 320
        for index in 0..<320 { buffer.int16ChannelData![0][index] = Int16(index % 128) }
        let encoder = try Opus.Encoder(format: format)
        var encoded = Data(repeating: 0, count: 512)
        _ = try encoder.encode(buffer, to: &encoded)
        return encoded
    }

    private static func invalidMagicCursor(generationID: UUID, mutation: UInt8) -> Data {
        var data = OmiLaunchCaptureCursor(
            generationID: generationID,
            acknowledgedPrefixNextSequence: 0,
            acknowledgedPrefixEndOffset: 0
        ).encoded()
        data[data.startIndex] ^= mutation
        let digestOffset = data.count - OmiLaunchCaptureCursorFormat.digestByteCount
        data.replaceSubrange(digestOffset..<data.count, with: OmiLaunchCaptureDigest.truncated(data.prefix(digestOffset)))
        return data
    }
}

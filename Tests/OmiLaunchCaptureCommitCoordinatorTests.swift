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
        let harness = self.makeHarness(rootURL: transferRoot)
        let manager = self.makeManager()
        let barrier = CommitCoordinatorBarrier()
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: manager,
            io: io,
            onReconciliationPhase: { phase in
                if phase == .afterSealedCursorAcknowledged {
                    io.failNext(.replace)
                }
                if phase == .afterSealedOwnershipVerified { await barrier.suspend() }
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
        let pendingOwner = await harness.engine.itemSnapshot(itemID: partition.itemID)
        XCTAssertNil(pendingOwner)
        await barrier.resume()
        try await bootstrap.value
        try await transferTestWaitFor("unrelated delivery") {
            TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == unrelatedID }
        }
        // `partition.itemID` was already a committed TransferEngine item before the
        // coordinator ever ran (staged directly via the spool, above), so once the
        // bootstrap gate opens it dispatches like any other already-committed item —
        // the coordinator's own redundant settlement pass for it (which the injected
        // `.replace` fault fails closed) has no bearing on TransferEngine's dispatch
        // eligibility. It sends exactly once, not zero times.
        try await transferTestWaitFor("existing owner sends once bootstrap opens") {
            TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == partition.itemID }
        }
        XCTAssertEqual(TransferURLProtocol.requests.filter { transferTestBoundaryItemID(from: $0) == partition.itemID }.count, 1)
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

    /// A one-shot settlement-prepare fault armed right at cursor-acknowledgment no
    /// longer produces a permanently blocked owner: the fresh-adopt attempt fails
    /// closed (creating a transient attention record) but the same reconcile pass's
    /// attached-handoff rescan (`settleAttachedHandoffs`) finds the still-live
    /// envelope and completes adoption, since the injected fault was already
    /// consumed. The item settles and sends exactly once, not zero times.
    @MainActor func testRestartRetriesTransientCleanupFaultAndSendsExactlyOnce() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("transfer", isDirectory: true)
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = try self.seedCapture(rootURL: captureRoot)
        let partition = try XCTUnwrap(self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO()).partitions.first)
        let first = self.makeHarness(rootURL: transferRoot)
        try await first.engine.initialize()
        await OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: first.engine,
            sourceManager: self.makeManager(),
            io: io,
            onReconciliationPhase: { phase in
                if phase == .afterSealedCursorAcknowledged { io.failNext(.replace) }
            }
        ).reconcile()
        await first.engine.enableDispatch()

        let restarted = self.makeHarness(rootURL: transferRoot)
        try await restarted.engine.initialize()
        await OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: restarted.engine,
            sourceManager: self.makeManager(),
            io: io,
            onReconciliationPhase: { phase in
                if phase == .afterSealedCursorAcknowledged { io.failNext(.replace) }
            }
        ).reconcile()
        await restarted.engine.enableDispatch()
        try await transferTestWaitFor("self-healed transient cleanup fault") {
            TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == partition.itemID }
        }
        XCTAssertEqual(TransferURLProtocol.requests.filter { transferTestBoundaryItemID(from: $0) == partition.itemID }.count, 1)
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
                if phase == .afterSealedOwnerAdopted { await barrier.suspend() }
            }
        )
        let task = Task { @MainActor in await coordinator.reconcile() }
        try await transferTestWaitFor("gated owner") { await barrier.waiting() }
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.filter { $0.manifest.payloadParts.isEmpty == false }.count, 1)
        await barrier.resume()
        await task.value
        try await transferTestWaitFor("released new owner") { TransferURLProtocol.requests.count == 1 }
        XCTAssertEqual(TransferURLProtocol.requests.filter { transferTestBoundaryItemID(from: $0) == snapshots.first?.itemID }.count, 1)

        // A one-shot settlement-prepare fault at cursor-acknowledgment fails the
        // fresh-adopt attempt closed (leaving a transient attention record), but the
        // same reconcile pass's attached-handoff rescan finds the still-live envelope
        // and completes adoption immediately after, since the fault was already
        // consumed. This is not a permanent hold — the owner still settles and sends
        // exactly once, just via the rescan rather than the fresh-adopt path.
        TransferURLProtocol.reset()
        let selfHealCaptureRoot = self.rootURL.appendingPathComponent("self-heal-capture", isDirectory: true)
        let selfHealTransferRoot = self.rootURL.appendingPathComponent("self-heal-transfer", isDirectory: true)
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = try self.seedCapture(rootURL: selfHealCaptureRoot)
        let partition = try XCTUnwrap(self.materialize(rootURL: selfHealCaptureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO()).partitions.first)
        let selfHealHarness = self.makeHarness(rootURL: selfHealTransferRoot)
        try await selfHealHarness.engine.initialize()
        await selfHealHarness.engine.enableDispatch()
        await OmiLaunchCaptureCommitCoordinator(
            rootURL: selfHealCaptureRoot,
            engine: selfHealHarness.engine,
            sourceManager: self.makeManager(),
            io: io,
            onReconciliationPhase: { phase in
                if phase == .afterSealedCursorAcknowledged { io.failNext(.replace) }
            }
        ).reconcile()
        let selfHealSnapshots = await selfHealHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(selfHealSnapshots.filter { $0.manifest.payloadParts.isEmpty == false }.count, 1)
        XCTAssertEqual(selfHealSnapshots.filter { $0.manifest.attention?.reason == "launch_capture_settlement_cleanup_failed" }.count, 1)
        try await transferTestWaitFor("self-healed owner sends once") {
            TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == partition.itemID }
        }
        XCTAssertEqual(TransferURLProtocol.requests.filter { transferTestBoundaryItemID(from: $0) == partition.itemID }.count, 1)
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
            io.failReplace(at: OmiPendingHandoffStore.settlementURL(for: paths.envelopeURL), fromCall: 1)
            let unrelatedID = UUID()
            _ = try await harness.engine.enqueue(manifest: self.unrelatedManifest(itemID: unrelatedID), payloads: ["audio": Data("unrelated".utf8)])

            let coordinator = OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager(), io: io)
            await coordinator.reconcile()
            await harness.engine.enableDispatch()
            try await transferTestWaitFor("cleanup peers \(settledOwnerID)") {
                Set(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:)))
                    .isSuperset(of: fixture.ownerIDs.union([unrelatedID]))
            }
            XCTAssertTrue(TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == unrelatedID })
            await self.assertFixtureOwnerSettlement(fixture, engine: harness.engine)
        }
    }

    @MainActor func testMultiOwnerSettlementReleasesInCaptureOrder() async throws {
        TransferURLProtocol.reset()
        let captureRoot = self.rootURL.appendingPathComponent("capture-order-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("capture-order-transfer", isDirectory: true)
        let fixture = try self.seedThreeOwnerCapture(rootURL: captureRoot)
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        await harness.engine.enableDispatch()

        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager()
        )
        await coordinator.reconcile()
        try await transferTestWaitFor("capture-ordered owner release") {
            TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:)).count == 3
        }

        let requestIDs = TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:))
        XCTAssertEqual(requestIDs, fixture.orderedOwnerIDs)
        for itemID in fixture.orderedOwnerIDs {
            XCTAssertEqual(requestIDs.filter { $0 == itemID }.count, 1)
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
        await self.assertFixtureOwnerSettlement(fixture, engine: harness.engine)
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
        let foreignID = UUID()
        _ = try await harness.engine.enqueue(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: foreignID, sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 44, startedAt: Date())),
            payloads: ["audio": Data("foreign".utf8)]
        )
        let unrelatedID = UUID()
        _ = try await harness.engine.enqueue(manifest: self.unrelatedManifest(itemID: unrelatedID), payloads: ["audio": Data("unrelated".utf8)])
        let barrier = CommitCoordinatorBarrier()
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager(),
            io: io,
            onReconciliationPhase: { phase in
                if phase == .afterSealedOwnershipVerified { await barrier.suspend() }
            }
        )

        io.failNext(.listDirectory)
        await coordinator.reconcile()
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("unrelated sends") { TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == unrelatedID } }
        XCTAssertTrue(TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == foreignID })
        io.clearFaults()
        let reconciliation = Task { @MainActor in await coordinator.reconcile() }
        try await transferTestWaitFor("proof gate") { await barrier.waiting() }
        XCTAssertFalse(TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == partition.itemID })
        await barrier.resume()
        await reconciliation.value
        try await transferTestWaitFor("attached owner sends") { TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == partition.itemID } }
    }

    @MainActor func testSettlementAttentionReasonsArePayloadFreeAndDeduped() async throws {
        let expectedReasons: Set<String> = [
            "launch_capture_settlement_acknowledgment_failed",
            "launch_capture_settlement_cleanup_failed",
        ]
        for (name, configure) in [
            ("acknowledgment", { (io: FaultInjectingOmiLaunchCaptureIO, reader: OmiLaunchCaptureLeaseReader, _: OmiLaunchCaptureMaterializedArtifactPaths) in
                io.failReplace(at: reader.cursorURL, fromCall: 1)
            }),
            ("cleanup", { (io: FaultInjectingOmiLaunchCaptureIO, _: OmiLaunchCaptureLeaseReader, paths: OmiLaunchCaptureMaterializedArtifactPaths) in
                io.failReplace(at: OmiPendingHandoffStore.settlementURL(for: paths.envelopeURL), fromCall: 1)
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
            io.failReplace(at: OmiPendingHandoffStore.settlementURL(for: paths.envelopeURL), fromCall: 1)
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
            await self.assertFixtureOwnerSettlement(fixture, engine: harness.engine)
            try await transferTestWaitFor("ack retry \(position)") {
                Set(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:))).isSuperset(of: fixture.ownerIDs)
            }
            await self.assertFixtureOwnerSettlement(fixture, engine: harness.engine)
            XCTAssertEqual(TransferURLProtocol.requests.filter { fixture.ownerIDs.contains(transferTestBoundaryItemID(from: $0) ?? UUID()) }.count, 3)
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
            io.failReplace(at: OmiPendingHandoffStore.settlementURL(for: paths.envelopeURL), fromCall: 1)
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
            await self.assertFixtureOwnerSettlement(fixture, engine: restarted.engine)
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
        _ = try await first.engine.enqueueIfAbsent(
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
                if phase == .afterSealedOwnershipVerified {
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
        await self.assertFixtureOwnerSettlement(fixture, engine: restarted.engine)
        XCTAssertEqual(TransferURLProtocol.requests.filter { fixture.ownerIDs.contains(transferTestBoundaryItemID(from: $0) ?? UUID()) }.count, 3)
    }

    @MainActor func testRestartAfterReleaseFailureRestoresOwnerLinkAndDeliversProvenOwnersOnce() async throws {
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
            let unrelatedID = UUID()
            _ = try await first.engine.enqueue(manifest: self.unrelatedManifest(itemID: unrelatedID), payloads: ["audio": Data("unrelated".utf8)])
            let paths = OmiLaunchCaptureMaterializedArtifactPaths(
                rootURL: captureRoot,
                generationID: fixture.generationID,
                ordinal: fixture.ordinal(for: ownerID)
            )
            let settlementURL = OmiPendingHandoffStore.settlementURL(for: paths.envelopeURL)
            io.failRemove(at: settlementURL, fromCall: 1)
            let firstCoordinator = OmiLaunchCaptureCommitCoordinator(
                rootURL: captureRoot,
                engine: first.engine,
                sourceManager: self.makeManager(),
                io: io
            )
            await firstCoordinator.reconcile()
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.envelopeURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: settlementURL.path))
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
                    if phase == .afterSealedOwnershipVerified {
                        registeredAttachedOwner = true
                    }
                }
            )
            await restartedCoordinator.reconcile()
            XCTAssertFalse(registeredAttachedOwner)
            XCTAssertEqual(TransferURLProtocol.requests.count, 0)
            await restarted.engine.enableDispatch()
            try await transferTestWaitFor("restored-owner-link restart \(position)") {
                Set(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:))).isSuperset(of: fixture.ownerIDs)
            }
            XCTAssertTrue(TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == unrelatedID })
            await self.assertFixtureOwnerSettlement(fixture, engine: restarted.engine)
            XCTAssertEqual(TransferURLProtocol.requests.filter { fixture.ownerIDs.contains(transferTestBoundaryItemID(from: $0) ?? UUID()) }.count, 3)
        }
    }

    @MainActor func testSettlementMarkerRetriesAfterCaptureEvidenceIsGone() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("marker-only-retry-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("marker-only-retry-transfer", isDirectory: true)
        let generation = try self.seedCapture(rootURL: captureRoot)
        let paths = OmiLaunchCaptureMaterializedArtifactPaths(rootURL: captureRoot, generationID: generation, ordinal: 0)
        let settlementURL = OmiPendingHandoffStore.settlementURL(for: paths.envelopeURL)
        let io = FaultInjectingOmiLaunchCaptureIO()
        io.failRemove(at: settlementURL, fromCall: 1)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let first = self.makeHarness(rootURL: transferRoot)
        try await first.engine.initialize()

        await OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: first.engine,
            sourceManager: self.makeManager(),
            io: io,
            clock: clock
        ).reconcile()

        XCTAssertTrue(FileManager.default.fileExists(atPath: settlementURL.path))

        // The marker is itself post-acknowledgment evidence, so a fully-adopted
        // generation is eagerly retired even though this marker's own removal is
        // still pending — the underlying audio already lives safely in TE's spool,
        // so the raw capture file is no longer needed for recovery. Retirement may
        // have already deleted it here; either way, prove restart does not depend
        // on the original capture or cursor surviving until the marker retries.
        let captureURL = OmiLaunchCaptureFormat.fileURL(rootURL: captureRoot, generationID: generation)
        try? FileManager.default.removeItem(at: captureURL)
        let reader = OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: generation, io: io)
        try? FileManager.default.removeItem(at: reader.cursorURL)
        io.clearFaults()

        let restarted = self.makeHarness(rootURL: transferRoot)
        try await restarted.engine.initialize()
        await OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: restarted.engine,
            sourceManager: self.makeManager(),
            io: io,
            clock: clock
        ).reconcile()

        XCTAssertFalse(FileManager.default.fileExists(atPath: settlementURL.path))
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
                if phase == .afterSealedOwnershipVerified { await barrier.suspend() }
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
                    if phase == .afterSealedOwnershipVerified {
                        XCTAssertTrue(FileManager.default.fileExists(atPath: envelopeURL.path))
                        io.failNext(operation)
                    }
                }
            )
            await failureCoordinator.reconcile()
            XCTAssertEqual(TransferURLProtocol.requests.count, 0)
            let failureSnapshots = await failureHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
            XCTAssertEqual(failureSnapshots.filter { $0.manifest.payloadParts.isEmpty == false }.count, 0)
            XCTAssertEqual(failureSnapshots.filter { $0.manifest.attention?.reason == "launch_capture_settlement_acknowledgment_failed" }.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: envelopeURL.path))
            let repeated = try self.materialize(rootURL: failureCaptureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO())
            XCTAssertEqual(repeated.partitions.count, 1)
        }
    }

    @MainActor func testUnknownEnumerationGatesEveryOmiOwnerButNotUnrelatedWork() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("transfer", isDirectory: true)
        let io = FaultInjectingOmiLaunchCaptureIO()
        let harness = self.makeHarness(rootURL: transferRoot)
        let spool = TransferSpool(rootURL: transferRoot)
        let generation = try self.seedCapture(rootURL: captureRoot)
        let stagedPartition = try XCTUnwrap(self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO()).partitions.first)
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
        let before = await harness.engine.itemSnapshot(itemID: omiIDs[0])
        io.failNext(.listDirectory)
        await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager(), io: io).reconcile()
        let after = await harness.engine.itemSnapshot(itemID: omiIDs[0])
        XCTAssertEqual(before?.itemID, after?.itemID)
        XCTAssertEqual(before?.manifest.diskState, after?.manifest.diskState)
        let stagedSnapshot = await harness.engine.itemSnapshot(itemID: stagedPartition.itemID)
        XCTAssertNil(stagedSnapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedPartition.envelopeURL.path))
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("live omi and unrelated dispatch") { TransferURLProtocol.requests.count == 3 }
        XCTAssertEqual(
            Set(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:))),
            Set(omiIDs + [unrelatedID])
        )
        XCTAssertFalse(TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == stagedPartition.itemID })
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
        let barrier = CommitCoordinatorBarrier()
        var gatedOwners = 0
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager(),
            onReconciliationPhase: { phase in
                guard phase == .afterSealedOwnerAdopted else { return }
                gatedOwners += 1
                if gatedOwners == 2 { await barrier.suspend() }
            }
        )
        let abandonedPass = Task { @MainActor in await coordinator.reconcile() }
        try await transferTestWaitFor("second owner committed") {
            if await barrier.waiting() { return true }
            let owned = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
            return owned.filter { $0.manifest.payloadParts.isEmpty == false }.count == 2
        }
        if await barrier.waiting() == false {
            await barrier.resume()
        }
        let crashSnapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(
            Set(crashSnapshots.map(\.itemID)),
            Set(expectedPartitions.map(\.itemID))
        )
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)

        // This pass is intentionally abandoned at the second owner commit to model a process crash.
        let restarted = self.makeHarness(rootURL: transferRoot)
        try await restarted.engine.initialize()
        for snapshot in crashSnapshots {
            let ownership = try await restarted.engine.verifyOwnership(
                expectedManifest: snapshot.manifest,
                expectedPayloadSourceURLs: [:]
            )
            XCTAssertEqual(ownership, .ownedInQueued)
        }
        // Both partitions are already TE owners with unresolved leftover envelopes at
        // this point, so restart resolves them via the leftover-uncommit/attached-settle
        // path, not the fresh-materialization path — no `ReconciliationPhase` fires here.
        // The real guarantee this test proves is below: exactly one delivery per
        // partition after restart, with no duplicates.
        let restartedCoordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: restarted.engine,
            sourceManager: self.makeManager()
        )
        await restartedCoordinator.reconcile()
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
        await barrier.resume()
        await abandonedPass.value
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
                        if phase == .afterSealedOwnershipVerified { await barrier.suspend() }
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

    @MainActor func testDisabledRecoveryNeverTouchesTransferEngineForStagedOwners() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("disabled-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("disabled-transfer", isDirectory: true)
        let generation = try self.seedCapture(rootURL: captureRoot)
        let partition = try XCTUnwrap(self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO()).partitions.first)
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        let unrelatedID = UUID()
        _ = try await harness.engine.enqueue(manifest: self.unrelatedManifest(itemID: unrelatedID), payloads: ["audio": Data("unrelated".utf8)])
        await OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager(enabled: false)
        ).reconcile()
        let stagedOwner = await harness.engine.itemSnapshot(itemID: partition.itemID)
        XCTAssertNil(stagedOwner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partition.envelopeURL.path))
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("unrelated while staged") { TransferURLProtocol.requests.count == 1 }
        XCTAssertEqual(transferTestBoundaryItemID(from: try XCTUnwrap(TransferURLProtocol.requests.first)), unrelatedID)
    }

    @MainActor func testLeftoverUncommitRestoresStagedEnvelopeThenReadoptsOnce() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("uncommit-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("uncommit-transfer", isDirectory: true)
        let generation = try self.seedCapture(rootURL: captureRoot)
        let partition = try XCTUnwrap(self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO()).partitions.first)
        let envelope = try OmiPendingHandoffStore.read(from: partition.envelopeURL)
        let originalAudioBytes = try Data(contentsOf: partition.audioURL)
        XCTAssertFalse(originalAudioBytes.isEmpty)
        let first = self.makeHarness(rootURL: transferRoot)
        try await first.engine.initialize()
        _ = try await first.engine.enqueueIfAbsent(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: partition.itemID, sidecar: envelope.sidecar, metadata: envelope.metadata),
            payloadFileURLs: ["audio": partition.audioURL]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: partition.audioURL.path))
        let owned = await first.engine.itemSnapshot(itemID: partition.itemID)
        XCTAssertNotNil(owned)

        let restarted = self.makeHarness(rootURL: transferRoot)
        try await restarted.engine.initialize()
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: restarted.engine,
            sourceManager: self.makeManager()
        )
        await coordinator.uncommitLeftovers()
        let afterUncommit = await restarted.engine.itemSnapshot(itemID: partition.itemID)
        XCTAssertNil(afterUncommit)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partition.envelopeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partition.audioURL.path))
        // The incident this migration fixes was a genuinely-stuck recording — prove the
        // restored bytes are the exact captured audio, not just a file at the right path.
        XCTAssertEqual(try Data(contentsOf: partition.audioURL), originalAudioBytes)
        await coordinator.uncommitLeftovers()
        let afterSecondUncommit = await restarted.engine.itemSnapshot(itemID: partition.itemID)
        XCTAssertNil(afterSecondUncommit)

        await coordinator.reconcile()
        await restarted.engine.enableDispatch()
        try await transferTestWaitFor("readopted leftover") { TransferURLProtocol.requests.count == 1 }
        XCTAssertEqual(transferTestBoundaryItemID(from: try XCTUnwrap(TransferURLProtocol.requests.first)), partition.itemID)
    }

    @MainActor func testOmiObserverHandoffIsOutsideUncommitScan() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("scan-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("scan-transfer", isDirectory: true)
        let appGroup = self.rootURL.appendingPathComponent("group", isDirectory: true)
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        let itemID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 0, startedAt: Date())
        _ = try await harness.engine.enqueue(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar),
            payloads: ["audio": Data("live".utf8)]
        )
        let observerDir = appGroup.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("in-progress", isDirectory: true)
        try FileManager.default.createDirectory(at: observerDir, withIntermediateDirectories: true)
        let envelopeURL = observerDir.appendingPathComponent("chunk.handoff")
        try OmiPendingHandoffStore.write(
            try OmiPendingHandoffStore.encode(OmiPendingHandoffEnvelope(itemID: itemID, sidecar: sidecar, metadata: nil, frozenTokens: [])),
            to: envelopeURL
        )
        await OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager()
        ).uncommitLeftovers()
        let stillOwned = await harness.engine.itemSnapshot(itemID: itemID)
        XCTAssertNotNil(stillOwned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelopeURL.path))
    }

    @MainActor func testSyncStateSummaryEmitsStandaloneStagedLine() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("summary-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("summary-transfer", isDirectory: true)
        let generation = try self.seedCapture(rootURL: captureRoot)
        _ = try self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO())
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        let mobileStore = MobileSegmentStore(rootURL: self.rootURL.appendingPathComponent("summary-mobile", isDirectory: true))
        let mobile = MobileSegmentTransferHolder(
            transferEngine: harness.engine,
            mirror: harness.mirror,
            uploader: MobileSegmentUploader(transferEngine: harness.engine, store: mobileStore)
        )
        let share = ShareTransferHolder(
            transferEngine: harness.engine,
            mirror: harness.mirror,
            store: ShareImportStore(cacheRootURL: self.rootURL.appendingPathComponent("summary-share", isDirectory: true))
        )
        let stagedLines = await syncStateSummaryLines(
            mobileSegment: mobile,
            omi: harness.omi,
            watch: harness.watch,
            share: share,
            transferEngine: harness.engine,
            launchCaptureRootURL: captureRoot
        )
        XCTAssertTrue(stagedLines.contains { $0.hasPrefix("omi pendant staged: staged=") })
        XCTAssertTrue(stagedLines.contains { $0.hasPrefix("omi pendant staged: staged=") && !$0.contains("pending=") })
        XCTAssertFalse(stagedLines.contains { $0.hasPrefix("omi pendant:") && $0.contains("pending=") && !$0.contains("staged") })

        await OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager()
        ).reconcile()
        let adoptedLines = await syncStateSummaryLines(
            mobileSegment: mobile,
            omi: harness.omi,
            watch: harness.watch,
            share: share,
            transferEngine: harness.engine,
            launchCaptureRootURL: captureRoot
        )
        XCTAssertFalse(adoptedLines.contains { $0.hasPrefix("omi pendant staged: staged=") && !$0.hasSuffix("staged=0") })
        let pending = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
            .filter { $0.manifest.payloadParts.isEmpty == false }
        XCTAssertEqual(pending.count, 1)
    }

    @MainActor func testIncompleteBatchNeverTouchesTransferEngine() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("incomplete-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("incomplete-transfer", isDirectory: true)
        let generation = try self.seedCapture(rootURL: captureRoot)
        let io = FaultInjectingOmiLaunchCaptureIO()
        let paths = OmiLaunchCaptureMaterializedArtifactPaths(rootURL: captureRoot, generationID: generation, ordinal: 0)
        io.failReplace(at: paths.audioURL, fromCall: 1)
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        let unrelatedID = UUID()
        _ = try await harness.engine.enqueue(manifest: self.unrelatedManifest(itemID: unrelatedID), payloads: ["audio": Data("unrelated".utf8)])
        let itemID = OmiLaunchCaptureMaterializationIdentity.itemID(
            generationID: generation,
            partitionOrdinal: 0,
            startSequence: 0,
            startSampleOffset: 0
        )
        await OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager(),
            io: io
        ).reconcile()
        let incompleteOwner = await harness.engine.itemSnapshot(itemID: itemID)
        XCTAssertNil(incompleteOwner)
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("unrelated while incomplete") { TransferURLProtocol.requests.count == 1 }
        XCTAssertEqual(transferTestBoundaryItemID(from: try XCTUnwrap(TransferURLProtocol.requests.first)), unrelatedID)
        XCTAssertFalse(TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == itemID })
    }

    @MainActor func testConflictDuringAdoptStaysStagedAndDoesNotSend() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("conflict-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("conflict-transfer", isDirectory: true)
        let generation = try self.seedCapture(rootURL: captureRoot)
        let partition = try XCTUnwrap(self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO()).partitions.first)
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        _ = try await harness.engine.enqueue(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(
                itemID: partition.itemID,
                sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 99, startedAt: Date())
            ),
            payloads: ["audio": Data("conflict".utf8)]
        )
        let unrelatedID = UUID()
        _ = try await harness.engine.enqueue(manifest: self.unrelatedManifest(itemID: unrelatedID), payloads: ["audio": Data("unrelated".utf8)])
        await OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager()
        ).reconcile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: partition.envelopeURL.path) || FileManager.default.fileExists(atPath: OmiPendingHandoffStore.settlementURL(for: partition.envelopeURL).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partition.audioURL.path))
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("unrelated despite conflict") {
            TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == unrelatedID }
        }
        let conflictSnapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(conflictSnapshots.filter { $0.itemID == partition.itemID }.count, 1)
        XCTAssertFalse(transferTestPathExists(
            containing: partition.itemID.uuidString,
            under: transferRoot.appendingPathComponent(TransferSpool.stagingDirectoryName, isDirectory: true)
        ))
    }

    @MainActor func testSettlementMarkerLeftoverUncommitsToLiveHandoffThenReadoptsOnce() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("settlement-leftover-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("settlement-leftover-transfer", isDirectory: true)
        let generation = try self.seedCapture(rootURL: captureRoot)
        let partition = try XCTUnwrap(self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO()).partitions.first)
        let envelope = try OmiPendingHandoffStore.read(from: partition.envelopeURL)
        let originalAudioBytes = try Data(contentsOf: partition.audioURL)
        XCTAssertFalse(originalAudioBytes.isEmpty)
        let spool = TransferSpool(rootURL: transferRoot)
        let staged = try spool.stage(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: partition.itemID, sidecar: envelope.sidecar, metadata: envelope.metadata),
            payloads: ["audio": Data(contentsOf: partition.audioURL)]
        )
        _ = try spool.commitStagedItem(itemID: staged.item.manifest.itemID)
        try FileManager.default.removeItem(at: partition.audioURL)
        let marker = OmiPendingHandoffStore.settlementURL(for: partition.envelopeURL)
        try OmiPendingHandoffStore.write(try OmiPendingHandoffStore.encode(envelope), to: marker)
        try FileManager.default.removeItem(at: partition.envelopeURL)

        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager()
        )
        await coordinator.uncommitLeftovers()
        let afterUncommit = await harness.engine.itemSnapshot(itemID: partition.itemID)
        XCTAssertNil(afterUncommit)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partition.envelopeURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partition.audioURL.path))
        // Reconstructed solely from the spool's committed copy — the local materialized
        // audio was deleted above, so this proves recovery, not a coincidental leftover.
        XCTAssertEqual(try Data(contentsOf: partition.audioURL), originalAudioBytes)
        await coordinator.uncommitLeftovers()
        let afterSecondUncommit = await harness.engine.itemSnapshot(itemID: partition.itemID)
        XCTAssertNil(afterSecondUncommit)
        await coordinator.reconcile()
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("settlement leftover readopt") { TransferURLProtocol.requests.count == 1 }
        XCTAssertEqual(transferTestBoundaryItemID(from: try XCTUnwrap(TransferURLProtocol.requests.first)), partition.itemID)
    }

    @MainActor func testUncommitCrashWindowBeforeRelinquishFinishesOnSecondPass() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("before-relinquish-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("before-relinquish-transfer", isDirectory: true)
        let generation = try self.seedCapture(rootURL: captureRoot)
        let partition = try XCTUnwrap(self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO()).partitions.first)
        let envelope = try OmiPendingHandoffStore.read(from: partition.envelopeURL)
        let spool = TransferSpool(rootURL: transferRoot)
        let staged = try spool.stage(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: partition.itemID, sidecar: envelope.sidecar, metadata: envelope.metadata),
            payloads: ["audio": Data(contentsOf: partition.audioURL)]
        )
        let committed = try spool.commitStagedItem(itemID: staged.item.manifest.itemID)
        try FileManager.default.removeItem(at: partition.audioURL)
        let payload = try XCTUnwrap(
            FileManager.default.enumerator(at: committed.directoryURL, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .first { $0.pathExtension == "m4a" }
        )
        try Data(contentsOf: payload).write(to: partition.audioURL, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partition.envelopeURL.path))

        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        let ownedBefore = await harness.engine.itemSnapshot(itemID: partition.itemID)
        XCTAssertNotNil(ownedBefore)
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager()
        )
        await coordinator.uncommitLeftovers()
        let afterUncommit = await harness.engine.itemSnapshot(itemID: partition.itemID)
        XCTAssertNil(afterUncommit)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partition.audioURL.path))
        await coordinator.uncommitLeftovers()
        let afterSecond = await harness.engine.itemSnapshot(itemID: partition.itemID)
        XCTAssertNil(afterSecond)
    }

    @MainActor func testCrashAfterAdoptBeforeMarkerRemovalUncommitsThenReadoptsOnce() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("window-3-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("window-3-transfer", isDirectory: true)
        let generation = try self.seedCapture(rootURL: captureRoot)
        let partition = try XCTUnwrap(self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO()).partitions.first)
        let envelope = try OmiPendingHandoffStore.read(from: partition.envelopeURL)
        let first = self.makeHarness(rootURL: transferRoot)
        try await first.engine.initialize()
        _ = try await first.engine.enqueueIfAbsent(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: partition.itemID, sidecar: envelope.sidecar, metadata: envelope.metadata),
            payloadFileURLs: ["audio": partition.audioURL]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: partition.audioURL.path))
        let marker = OmiPendingHandoffStore.settlementURL(for: partition.envelopeURL)
        try OmiPendingHandoffStore.write(try OmiPendingHandoffStore.encode(envelope), to: marker)
        try FileManager.default.removeItem(at: partition.envelopeURL)

        let restarted = self.makeHarness(rootURL: transferRoot)
        try await restarted.engine.initialize()
        let leftoverOwner = await restarted.engine.itemSnapshot(itemID: partition.itemID)
        XCTAssertNotNil(leftoverOwner)
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: restarted.engine,
            sourceManager: self.makeManager()
        )
        await coordinator.reconcile()
        await restarted.engine.enableDispatch()
        try await transferTestWaitFor("window 3 before 4 one send") { TransferURLProtocol.requests.count == 1 }
        XCTAssertEqual(transferTestBoundaryItemID(from: try XCTUnwrap(TransferURLProtocol.requests.first)), partition.itemID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    @MainActor func testUnreadableCursorDoesNotMutateLiveOmiOwner() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("cursor-live-capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("cursor-live-transfer", isDirectory: true)
        let generation = try self.seedCapture(rootURL: captureRoot)
        let partition = try XCTUnwrap(self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO()).partitions.first)
        let reader = OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: generation)
        try Self.invalidMagicCursor(generationID: generation, mutation: 0x01).write(to: reader.cursorURL)
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        let liveID = UUID()
        _ = try await harness.engine.enqueue(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(
                itemID: liveID,
                sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 3, startedAt: Date())
            ),
            payloads: ["audio": Data("live".utf8)]
        )
        let beforeOptional = await harness.engine.itemSnapshot(itemID: liveID)
        let before = try XCTUnwrap(beforeOptional)
        await OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: self.makeManager()
        ).reconcile()
        let afterOptional = await harness.engine.itemSnapshot(itemID: liveID)
        let after = try XCTUnwrap(afterOptional)
        XCTAssertEqual(before.itemID, after.itemID)
        XCTAssertEqual(before.manifest.diskState, after.manifest.diskState)
        let stagedOwner = await harness.engine.itemSnapshot(itemID: partition.itemID)
        XCTAssertNil(stagedOwner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partition.envelopeURL.path))
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("live omi still dispatches") {
            TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == liveID }
        }
        XCTAssertFalse(TransferURLProtocol.requests.contains { transferTestBoundaryItemID(from: $0) == partition.itemID })
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
            (0..<3).map { self.ownerID(at: $0) }
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
        acknowledged: Bool = true
    ) async throws {
        let result = try self.materialize(rootURL: rootURL, generation: fixture.generationID, io: FoundationOmiLaunchCaptureIO())
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.partitions.count, 3)
        XCTAssertEqual(Set(result.partitions.map(\.itemID)), fixture.ownerIDs)
        XCTAssertEqual(Set(result.partitions.map(\.audioURL)).count, 3)
        XCTAssertEqual(Set(result.partitions.map(\.envelopeURL)).count, 3)

        for partition in result.partitions.sorted(by: { $0.itemID.uuidString < $1.itemID.uuidString }) {
            let envelope = try OmiPendingHandoffStore.read(from: partition.envelopeURL)
            let outcome = try await engine.enqueueIfAbsent(
                manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(
                    itemID: partition.itemID,
                    sidecar: envelope.sidecar,
                    metadata: envelope.metadata
                ),
                payloadFileURLs: ["audio": partition.audioURL]
            )
            XCTAssertEqual(outcome, .enqueued)
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

    /// These fixtures (`stageThreeOwnerFixture` / direct `engine.enqueue`) always
    /// pre-commit every owner to TransferEngine before the coordinator runs, so
    /// under decide-then-commit there is no valid "still staged, not yet decided"
    /// state left to wait for — an already-committed item dispatches once
    /// `enableDispatch()` fires regardless of whether the coordinator's own
    /// envelope-cleanup bookkeeping for that owner succeeds or fails. The only
    /// thing worth proving here is that every owner was dispatched exactly once,
    /// with no owner skipped and no owner double-sent — independent of how the
    /// mock's response body classifies (this harness returns an empty 204 body,
    /// which the real classifier treats as `decode_failed`/attention rather than
    /// `delivered`; that is a mock-fidelity detail unrelated to this scope).
    @MainActor private func assertFixtureOwnerSettlement<Fixture: FixtureOwnerSet>(
        _ fixture: Fixture,
        engine: TransferEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let originalOwners = fixture.ownerIDs
        var released: Set<UUID> = []
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            released = Set(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:))).intersection(originalOwners)
            if released == originalOwners {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        XCTAssertEqual(released, originalOwners, file: file, line: line)
        for owner in originalOwners {
            let count = TransferURLProtocol.requests.filter { transferTestBoundaryItemID(from: $0) == owner }.count
            XCTAssertEqual(count, 1, "owner \(owner) dispatched \(count) times", file: file, line: line)
        }
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

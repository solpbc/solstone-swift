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
        XCTAssertEqual(heldSnapshots.count, 1)
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
            XCTAssertEqual(failureSnapshots.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: envelopeURL.path))
            let repeated = try self.materialize(rootURL: failureCaptureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO())
            XCTAssertEqual(repeated.partitions.count, 1)
            XCTAssertEqual(repeated.partitions.first?.itemID, failureSnapshots.first?.itemID)
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
        return OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, io: io, decode: { decoder.decode($0) }).materialize()
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

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
        let coordinator = OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: manager, io: io)
        let barrier = CommitCoordinatorBarrier()
        var opened = false
        let bootstrap = Task { @MainActor in
            try await harness.engine.initialize()
            await barrier.suspend()
            await coordinator.reconcile()
            opened = true
            await harness.engine.enableDispatch()
        }
        try await transferTestWaitFor("bootstrap gate") { await barrier.waiting() }
        XCTAssertFalse(opened)
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
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
                if phase == .afterOwnerCleanupBeforeAcknowledgment { await barrier.suspend() }
            }
        )
        let task = Task { @MainActor in await coordinator.reconcile() }
        try await transferTestWaitFor("cleanup before acknowledgment") { await barrier.waiting() }
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        await barrier.resume()
        await task.value
        try await transferTestWaitFor("acknowledged owner") { TransferURLProtocol.requests.count == 1 }

        for operation in [OmiLaunchCaptureInjectedOperation.openForReading, .replace] {
            TransferURLProtocol.reset()
            let failureCaptureRoot = self.rootURL.appendingPathComponent("failure-capture-\(String(describing: operation))", isDirectory: true)
            let failureTransferRoot = self.rootURL.appendingPathComponent("failure-transfer-\(String(describing: operation))", isDirectory: true)
            let io = FaultInjectingOmiLaunchCaptureIO()
            _ = try self.seedCapture(rootURL: failureCaptureRoot)
            let failureHarness = self.makeHarness(rootURL: failureTransferRoot)
            try await failureHarness.engine.initialize()
            await failureHarness.engine.enableDispatch()
            let failureCoordinator = OmiLaunchCaptureCommitCoordinator(
                rootURL: failureCaptureRoot,
                engine: failureHarness.engine,
                sourceManager: self.makeManager(),
                io: io,
                onReconciliationPhase: { phase in
                    if phase == .afterOwnerCleanupBeforeAcknowledgment { io.failNext(operation) }
                }
            )
            await failureCoordinator.reconcile()
            XCTAssertEqual(TransferURLProtocol.requests.count, 0)
            let failureSnapshots = await failureHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
            XCTAssertEqual(failureSnapshots.count, 1)
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
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("unrelated dispatch") { TransferURLProtocol.requests.count == 1 }
        XCTAssertEqual(transferTestBoundaryItemID(from: try XCTUnwrap(TransferURLProtocol.requests.first)), unrelatedID)
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(Set(snapshots.map(\.itemID)), Set(omiIDs))
        XCTAssertEqual(snapshots.count, omiIDs.count)
    }

    @MainActor func testRepeatedRestartKeepsOneStableOwnerAndOneSendPerPartition() async throws {
        let captureRoot = self.rootURL.appendingPathComponent("capture", isDirectory: true)
        let transferRoot = self.rootURL.appendingPathComponent("transfer", isDirectory: true)
        let generation = try self.seedTwoPartitionCapture(rootURL: captureRoot)
        let beforeAcknowledgment = try self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO()).partitions
        XCTAssertEqual(beforeAcknowledgment.count, 2)
        let harness = self.makeHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        await harness.engine.enableDispatch()
        let coordinator = OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: self.makeManager())
        await coordinator.reconcile()
        let afterFirstAcknowledgment = try self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO()).partitions
        XCTAssertEqual(afterFirstAcknowledgment.count, 1)
        XCTAssertEqual(afterFirstAcknowledgment.first?.coveredThroughSequence, 1)
        XCTAssertNotEqual(afterFirstAcknowledgment.first?.itemID, beforeAcknowledgment.first?.itemID)
        await coordinator.reconcile()
        try await transferTestWaitFor("two partition deliveries") { TransferURLProtocol.requests.count == 2 }
        XCTAssertEqual(
            Set(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:))),
            Set([beforeAcknowledgment[0].itemID, try XCTUnwrap(afterFirstAcknowledgment.first).itemID])
        )

        let restarted = self.makeHarness(rootURL: transferRoot)
        try await restarted.engine.initialize()
        await restarted.engine.enableDispatch()
        let restartedCoordinator = OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: restarted.engine, sourceManager: self.makeManager())
        await restartedCoordinator.reconcile()
        XCTAssertEqual(TransferURLProtocol.requests.count, 2)
        let repeated = try self.materialize(rootURL: captureRoot, generation: generation, io: FoundationOmiLaunchCaptureIO())
        XCTAssertTrue(repeated.partitions.isEmpty)
    }

    @MainActor func testFaultMatrixConvergesFailClosedWithoutBlockingUnrelatedWork() async throws {
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
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.manifest.diskState, .attention)
        XCTAssertEqual(snapshots.first?.manifest.payloadParts, [])
        if case .empty = OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: generation).lease() {
            XCTFail("boundary must remain available for attention")
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
}

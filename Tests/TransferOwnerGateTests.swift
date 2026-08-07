// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated private struct OwnerGateAvailableEndpointResolver: TransferEndpointResolver {
    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        .available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))
    }
}

private actor OwnerGateLaunchBarrier {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isWaitingForResume = false

    func suspend() async {
        self.isWaitingForResume = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waiting() -> Bool { self.isWaitingForResume }

    func resume() {
        self.continuation?.resume()
        self.continuation = nil
    }
}

@MainActor
final class TransferOwnerGateTests: XCTestCase {
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferOwnerGateTests-\(UUID().uuidString)", isDirectory: true)
        TransferURLProtocol.reset()
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.rootURL)
        self.rootURL = nil
        super.tearDown()
    }

    func testGatedEnqueueReleaseAndConvertAreOneShot() async throws {
        let events = OSAllocatedUnfairLock<[TransferDiagnosticEvent]>(initialState: [])
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let harness = self.makeHarness(diagnosticsSink: { event in events.withLock { $0.append(event) } })
        try await harness.engine.initialize()
        await harness.engine.enableDispatch()

        let releasedID = UUID()
        let convertedID = UUID()
        let unrelatedID = UUID()
        let releasedToken = try await harness.engine.enqueueGated(
            manifest: self.manifest(itemID: releasedID, chunkIndex: 0),
            payloadFileURLs: try self.payloadFileURLs(contents: "released")
        )
        let convertedToken = try await harness.engine.enqueueGated(
            manifest: self.manifest(itemID: convertedID, chunkIndex: 1),
            payloadFileURLs: try self.payloadFileURLs(contents: "converted")
        )
        _ = try await harness.engine.enqueue(
            manifest: self.manifest(itemID: unrelatedID, chunkIndex: 2),
            payloads: ["audio": Data("unrelated".utf8)]
        )

        try await transferTestWaitFor("unrelated gated-enqueue control") {
            TransferURLProtocol.requests.count == 1
        }
        XCTAssertEqual(self.sentItemIDs(), [unrelatedID])

        let released = await harness.engine.releaseGate(releasedToken)
        XCTAssertEqual(released, .settled)
        let releasedAgain = await harness.engine.releaseGate(releasedToken)
        XCTAssertEqual(releasedAgain, .alreadyReleased)
        try await transferTestWaitFor("released gate dispatch") {
            TransferURLProtocol.requests.count == 2
        }
        XCTAssertEqual(self.sentItemIDs(), [unrelatedID, releasedID])

        let converted = await harness.engine.convertGateToHold(convertedToken)
        XCTAssertEqual(converted, .settled)
        let convertedAgain = await harness.engine.convertGateToHold(convertedToken)
        XCTAssertEqual(convertedAgain, .alreadyConverted)
        let releaseConverted = await harness.engine.releaseGate(convertedToken)
        XCTAssertEqual(releaseConverted, .alreadyConverted)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(TransferURLProtocol.requests.count, 2)
        let convertedSnapshot = await harness.engine.itemSnapshot(itemID: convertedID)
        XCTAssertNotNil(convertedSnapshot)

        let convertedEvents = events.withLock {
            $0.filter { $0.itemID == convertedID && $0.outcome == .held }
        }
        XCTAssertEqual(convertedEvents.map(\.shortDetail), ["reason=owner gate converted"])
        XCTAssertTrue(convertedEvents.allSatisfy { !$0.shortDetail.contains("/") })
    }

    func testConditionalGateReleaseLeavesTokenActiveUntilPermissionIsGranted() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let harness = self.makeHarness()
        try await harness.engine.initialize()
        await harness.engine.enableDispatch()
        let itemID = UUID()
        let token = try await harness.engine.enqueueGated(
            manifest: self.manifest(itemID: itemID, chunkIndex: 0),
            payloadFileURLs: try self.payloadFileURLs(contents: "conditional")
        )

        let refused = await harness.engine.releaseGate(token, if: { false })
        XCTAssertNil(refused)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(TransferURLProtocol.requests.isEmpty)

        let released = await harness.engine.releaseGate(token, if: { true })
        XCTAssertEqual(released, .settled)
        try await transferTestWaitFor("conditionally released gate dispatch") {
            TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:)) == [itemID]
        }
    }

    func testZeroPayloadAttentionSurvivesRestartAndQueuedCopyIsRejected() async throws {
        let spool = TransferSpool(rootURL: self.rootURL)
        var attentionManifest = self.manifest(itemID: UUID(), chunkIndex: 90)
        attentionManifest.payloadParts = []
        let attentionStaged = try spool.stage(manifest: attentionManifest, payloadFileURLs: [:])
        let attentionCommitted = try spool.commitStagedItem(itemID: attentionStaged.item.manifest.itemID)
        _ = try spool.moveQueuedItemToAttention(attentionCommitted, reason: "boundary", detail: "reason=boundary", now: Date())

        var queuedManifest = self.manifest(itemID: UUID(), chunkIndex: 91)
        queuedManifest.payloadParts = []
        let queuedStaged = try spool.stage(manifest: queuedManifest, payloadFileURLs: [:])
        _ = try spool.commitStagedItem(itemID: queuedStaged.item.manifest.itemID)

        let snapshot = try spool.initialize()
        XCTAssertEqual(snapshot.attention.map(\.manifest.itemID), [attentionManifest.itemID])
        XCTAssertFalse(snapshot.queued.contains { $0.manifest.itemID == queuedManifest.itemID })

        let unrelatedID = UUID()
        let harness = self.makeHarness()
        try await harness.engine.initialize()
        _ = try await harness.engine.enqueue(manifest: self.manifest(itemID: unrelatedID, chunkIndex: 92), payloads: ["audio": Data("unrelated".utf8)])
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("queued control dispatch") { TransferURLProtocol.requests.count == 1 }
        XCTAssertEqual(self.sentItemIDs(), [unrelatedID])
        let restartedSnapshot = await harness.engine.itemSnapshots()
        XCTAssertTrue(restartedSnapshot.contains { $0.itemID == attentionManifest.itemID && $0.manifest.diskState == .attention })
        XCTAssertFalse(self.sentItemIDs().contains(attentionManifest.itemID))
    }

    func testGateExistingBlocksRestartedItemUntilReleased() async throws {
        let targetID = UUID()
        let unrelatedID = UUID()
        let first = makeTransferCutoverHarness(rootURL: self.rootURL)
        try await first.engine.initialize()
        _ = try await first.engine.enqueueGated(
            manifest: self.manifest(itemID: targetID, chunkIndex: 0),
            payloadFileURLs: try self.payloadFileURLs(contents: "target")
        )
        _ = try await first.engine.enqueue(
            manifest: self.manifest(itemID: unrelatedID, chunkIndex: 1),
            payloads: ["audio": Data("unrelated".utf8)]
        )

        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let second = self.makeHarness()
        try await second.engine.initialize()
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        let registration = await second.engine.gateExisting(itemID: targetID)
        let token = self.gatedToken(registration)
        let duplicateRegistration = await second.engine.gateExisting(itemID: targetID)
        XCTAssertEqual(duplicateRegistration, .alreadyGated)
        await second.engine.enableDispatch()

        try await transferTestWaitFor("restarted unrelated dispatch") {
            TransferURLProtocol.requests.count == 1
        }
        XCTAssertEqual(self.sentItemIDs(), [unrelatedID])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(TransferURLProtocol.requests.count, 1)

        let released = await second.engine.releaseGate(token)
        XCTAssertEqual(released, .settled)
        try await transferTestWaitFor("restarted gated item dispatch") {
            TransferURLProtocol.requests.count == 2
        }
        XCTAssertEqual(self.sentItemIDs(), [unrelatedID, targetID])
    }

    func testGateExistingRejectsAfterDispatchOpensWithoutBlockingEagerItems() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let harness = self.makeHarness()
        try await harness.engine.initialize()
        await harness.engine.enableDispatch()

        let registration = await harness.engine.gateExisting(itemID: UUID())
        XCTAssertEqual(registration, .dispatchAlreadyEnabled)
        let targetID = UUID()
        let unrelatedID = UUID()
        _ = try await harness.engine.enqueue(
            manifest: self.manifest(itemID: targetID, chunkIndex: 0),
            payloads: ["audio": Data("target".utf8)]
        )
        _ = try await harness.engine.enqueue(
            manifest: self.manifest(itemID: unrelatedID, chunkIndex: 1),
            payloads: ["audio": Data("unrelated".utf8)]
        )

        try await transferTestWaitFor("eager target and unrelated dispatch") {
            TransferURLProtocol.requests.count == 2
        }
        XCTAssertEqual(Set(self.sentItemIDs()), Set([targetID, unrelatedID]))
    }

    func testBootstrapAwaitsGateExistingBeforeEnableDispatch() async throws {
        let targetID = UUID()
        let unrelatedID = UUID()
        let spool = TransferSpool(rootURL: self.rootURL)
        _ = try spool.commitStagedItem(itemID: spool.stage(
            manifest: self.manifest(itemID: targetID, chunkIndex: 0),
            payloads: ["audio": Data("target".utf8)]
        ).item.manifest.itemID)
        _ = try spool.commitStagedItem(itemID: spool.stage(
            manifest: self.manifest(itemID: unrelatedID, chunkIndex: 1),
            payloads: ["audio": Data("unrelated".utf8)]
        ).item.manifest.itemID)
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let harness = self.makeHarness()
        let gate = OwnerGateLaunchBarrier()
        var didEnableDispatch = false
        let bootstrap = Task { @MainActor in
            await SolstoneSwiftApp.bootstrapTransfer(
                initialize: { try await harness.engine.initialize() },
                appGroupRoot: { self.rootURL },
                cachesRootURL: nil,
                migrate: { _, _ in
                    await gate.suspend()
                    guard case .gated = await harness.engine.gateExisting(itemID: targetID) else {
                        XCTFail("expected target gate")
                        return
                    }
                },
                reconcile: { _ in },
                enableDispatch: {
                    didEnableDispatch = true
                    await harness.engine.enableDispatch()
                },
                openOmiReadiness: {},
                reportFailure: { _, _ in XCTFail("bootstrap should not fail") }
            )
        }

        try await transferTestWaitFor("gate registration suspension") { await gate.waiting() }
        XCTAssertFalse(didEnableDispatch)
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        await gate.resume()
        await bootstrap.value

        try await transferTestWaitFor("bootstrap unrelated dispatch") {
            TransferURLProtocol.requests.count == 1
        }
        XCTAssertEqual(self.sentItemIDs(), [unrelatedID])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(TransferURLProtocol.requests.count, 1)
    }

    func testStaleAndForeignGateTokensCannotAffectCurrentRegistration() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let harness = self.makeHarness()
        try await harness.engine.initialize()
        await harness.engine.enableDispatch()

        let targetID = UUID()
        let unrelatedID = UUID()
        let firstToken = try await harness.engine.enqueueGated(
            manifest: self.manifest(itemID: targetID, chunkIndex: 0),
            payloadFileURLs: try self.payloadFileURLs(contents: "first")
        )
        _ = try await harness.engine.enqueue(
            manifest: self.manifest(itemID: unrelatedID, chunkIndex: 1),
            payloads: ["audio": Data("unrelated".utf8)]
        )
        try await transferTestWaitFor("stale-token unrelated dispatch") {
            TransferURLProtocol.requests.count == 1
        }
        let firstRelease = await harness.engine.releaseGate(firstToken)
        XCTAssertEqual(firstRelease, .settled)
        try await transferTestWaitFor("first gated item dispatch") {
            TransferURLProtocol.requests.count == 2
        }

        let secondToken = try await harness.engine.enqueueGated(
            manifest: self.manifest(itemID: targetID, chunkIndex: 2),
            payloadFileURLs: try self.payloadFileURLs(contents: "second")
        )
        let staleRelease = await harness.engine.releaseGate(firstToken)
        XCTAssertEqual(staleRelease, .mismatchedToken)
        let staleConversion = await harness.engine.convertGateToHold(firstToken)
        XCTAssertEqual(staleConversion, .mismatchedToken)
        let foreign = makeTransferCutoverHarness(rootURL: self.rootURL.appendingPathComponent("foreign", isDirectory: true))
        try await foreign.engine.initialize()
        let foreignRegistration = await foreign.engine.gateExisting(itemID: UUID())
        let foreignToken = self.gatedToken(foreignRegistration)
        let foreignRelease = await harness.engine.releaseGate(foreignToken)
        XCTAssertEqual(foreignRelease, .unknownToken)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(self.sentItemIDs().filter { $0 == targetID }.count, 1)

        let secondRelease = await harness.engine.releaseGate(secondToken)
        XCTAssertEqual(secondRelease, .settled)
        try await transferTestWaitFor("second gated item dispatch") {
            TransferURLProtocol.requests.count == 3
        }
    }

    func testFailedGatedEnqueueLeavesNoActiveGate() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let harness = self.makeHarness()
        try await harness.engine.initialize()
        await harness.engine.enableDispatch()

        let stageFailureID = UUID()
        do {
            _ = try await harness.engine.enqueueGated(
                manifest: self.manifest(itemID: stageFailureID, chunkIndex: 0),
                payloadFileURLs: [:]
            )
            XCTFail("expected staged enqueue failure")
        } catch {}
        let stageUnrelatedID = UUID()
        _ = try await harness.engine.enqueue(
            manifest: self.manifest(itemID: stageFailureID, chunkIndex: 0),
            payloads: ["audio": Data("target".utf8)]
        )
        _ = try await harness.engine.enqueue(
            manifest: self.manifest(itemID: stageUnrelatedID, chunkIndex: 1),
            payloads: ["audio": Data("unrelated".utf8)]
        )
        try await transferTestWaitFor("stage-failure target and unrelated dispatch") {
            TransferURLProtocol.requests.count == 2
        }

        TransferURLProtocol.reset()
        let collisionRoot = self.rootURL.appendingPathComponent("collision", isDirectory: true)
        let collisionID = UUID()
        let collisionUnrelatedID = UUID()
        let spool = TransferSpool(rootURL: collisionRoot)
        _ = try spool.commitStagedItem(itemID: spool.stage(
            manifest: self.manifest(itemID: collisionID, chunkIndex: 2),
            payloads: ["audio": Data("target".utf8)]
        ).item.manifest.itemID)
        _ = try spool.commitStagedItem(itemID: spool.stage(
            manifest: self.manifest(itemID: collisionUnrelatedID, chunkIndex: 3),
            payloads: ["audio": Data("unrelated".utf8)]
        ).item.manifest.itemID)
        let collisionHarness = makeTransferCutoverHarness(
            rootURL: collisionRoot,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: OwnerGateAvailableEndpointResolver()
        )
        try await collisionHarness.engine.initialize()
        do {
            _ = try await collisionHarness.engine.enqueueGated(
                manifest: self.manifest(itemID: collisionID, chunkIndex: 2),
                payloadFileURLs: try self.payloadFileURLs(contents: "collision")
            )
            XCTFail("expected commit collision")
        } catch {}
        await collisionHarness.engine.enableDispatch()
        try await transferTestWaitFor("commit-failure target and unrelated dispatch") {
            TransferURLProtocol.requests.count == 2
        }
        XCTAssertEqual(Set(self.sentItemIDs()), Set([collisionID, collisionUnrelatedID]))
    }

    func testGatedEnqueueRejectsActiveGateWithoutReplacingIt() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let harness = self.makeHarness()
        try await harness.engine.initialize()
        await harness.engine.enableDispatch()

        let targetID = UUID()
        let token = try await harness.engine.enqueueGated(
            manifest: self.manifest(itemID: targetID, chunkIndex: 0),
            payloadFileURLs: try self.payloadFileURLs(contents: "target")
        )
        do {
            _ = try await harness.engine.enqueueGated(
                manifest: self.manifest(itemID: targetID, chunkIndex: 1),
                payloadFileURLs: try self.payloadFileURLs(contents: "replacement")
            )
            XCTFail("expected active gate error")
        } catch let error as TransferGateError {
            XCTAssertEqual(error, .itemAlreadyGated)
        } catch {
            XCTFail("unexpected active gate error: \(error)")
        }

        let unrelatedID = UUID()
        _ = try await harness.engine.enqueue(
            manifest: self.manifest(itemID: unrelatedID, chunkIndex: 2),
            payloads: ["audio": Data("unrelated".utf8)]
        )
        try await transferTestWaitFor("active-gate unrelated dispatch") {
            TransferURLProtocol.requests.count == 1
        }
        XCTAssertEqual(self.sentItemIDs(), [unrelatedID])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(TransferURLProtocol.requests.count, 1)

        let released = await harness.engine.releaseGate(token)
        XCTAssertEqual(released, .settled)
        try await transferTestWaitFor("original gate dispatch") {
            TransferURLProtocol.requests.count == 2
        }
        XCTAssertEqual(self.sentItemIDs(), [unrelatedID, targetID])
    }

    func testGatedOperationsRejectBeforeInitializationWithoutLeakingState() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let harness = self.makeHarness()
        let targetID = UUID()
        do {
            _ = try await harness.engine.enqueueGated(
                manifest: self.manifest(itemID: targetID, chunkIndex: 0),
                payloadFileURLs: [:]
            )
            XCTFail("expected uninitialized gate error")
        } catch let error as TransferGateError {
            XCTAssertEqual(error, .engineNotInitialized)
        } catch {
            XCTFail("unexpected uninitialized gate error: \(error)")
        }
        let registration = await harness.engine.gateExisting(itemID: targetID)
        XCTAssertEqual(registration, .engineNotInitialized)

        try await harness.engine.initialize()
        _ = try await harness.engine.enqueue(
            manifest: self.manifest(itemID: targetID, chunkIndex: 0),
            payloads: ["audio": Data("target".utf8)]
        )
        let unrelatedID = UUID()
        _ = try await harness.engine.enqueue(
            manifest: self.manifest(itemID: unrelatedID, chunkIndex: 1),
            payloads: ["audio": Data("unrelated".utf8)]
        )
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("uninitialized gate recovery dispatch") {
            TransferURLProtocol.requests.count == 2
        }
        XCTAssertEqual(Set(self.sentItemIDs()), Set([targetID, unrelatedID]))
    }

    func testTransientAndLifetimeGatesResistDispatchTriggers() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let clock = FakeTransferClock(wall: Date())
        let harness = makeTransferCutoverHarness(
            rootURL: self.rootURL,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: OwnerGateAvailableEndpointResolver(),
            clock: clock
        )
        try await harness.engine.initialize()

        let queuedGateID = UUID()
        let convertedID = UUID()
        let attentionGateID = UUID()
        let retryAttentionID = UUID()
        let unrelatedID = UUID()
        let backedOffID = UUID()
        _ = try await harness.engine.enqueueGated(
            manifest: self.manifest(itemID: queuedGateID, chunkIndex: 0),
            payloadFileURLs: try self.payloadFileURLs(contents: "queued gate")
        )
        let convertedToken = try await harness.engine.enqueueGated(
            manifest: self.manifest(itemID: convertedID, chunkIndex: 1),
            payloadFileURLs: try self.payloadFileURLs(contents: "converted")
        )
        let converted = await harness.engine.convertGateToHold(convertedToken)
        XCTAssertEqual(converted, .settled)
        _ = try await harness.engine.enqueueAttention(
            manifest: self.manifest(itemID: attentionGateID, chunkIndex: 2),
            payloadFileURLs: try self.payloadFileURLs(contents: "attention gate"),
            reason: "test",
            detail: "test"
        )
        let attentionRegistration = await harness.engine.gateExisting(itemID: attentionGateID)
        _ = self.gatedToken(attentionRegistration)
        _ = try await harness.engine.enqueueAttention(
            manifest: self.manifest(itemID: retryAttentionID, chunkIndex: 3),
            payloadFileURLs: try self.payloadFileURLs(contents: "retry attention"),
            reason: "test",
            detail: "test"
        )
        _ = try await harness.engine.enqueue(
            manifest: self.manifest(itemID: unrelatedID, chunkIndex: 4),
            payloads: ["audio": Data("unrelated".utf8)]
        )
        var backedOff = self.manifest(itemID: backedOffID, chunkIndex: 5)
        backedOff = backedOff.replacingNextAttemptAt(clock.wallNow().addingTimeInterval(1))
        _ = try await harness.engine.enqueue(manifest: backedOff, payloads: ["audio": Data("backed off".utf8)])

        try await harness.engine.retryAttention(itemID: attentionGateID)
        try await harness.engine.retryAttention(source: ObserverAudioTransferSource.omi)
        await harness.engine.drop(itemID: queuedGateID)
        await harness.engine.drop(itemID: convertedID)
        await harness.engine.drop(itemID: attentionGateID)
        await harness.engine.endpointAvailabilityChanged()
        await harness.engine.kick()
        await harness.engine.setPacingMode(.finishSyncing)
        await harness.engine.pause()
        await harness.engine.resume()
        await harness.engine.enableDispatch()

        try await transferTestWaitFor("trigger sweep unrelated dispatch") {
            TransferURLProtocol.requests.count == 2
        }
        XCTAssertEqual(Set(self.sentItemIDs()), Set([unrelatedID, retryAttentionID]))
        let queuedGateSnapshot = await harness.engine.itemSnapshot(itemID: queuedGateID)
        let convertedSnapshot = await harness.engine.itemSnapshot(itemID: convertedID)
        let attentionGateSnapshot = await harness.engine.itemSnapshot(itemID: attentionGateID)
        XCTAssertNotNil(queuedGateSnapshot)
        XCTAssertNotNil(convertedSnapshot)
        XCTAssertNotNil(attentionGateSnapshot)

        clock.advanceWall(by: 2)
        clock.resumeSleeps()
        try await transferTestWaitFor("trigger sweep retry timer dispatch") {
            TransferURLProtocol.requests.count == 3
        }
        XCTAssertEqual(transferTestBoundaryItemID(from: TransferURLProtocol.requests[2]), backedOffID)
        let queuedGateAfterTimer = await harness.engine.itemSnapshot(itemID: queuedGateID)
        let convertedAfterTimer = await harness.engine.itemSnapshot(itemID: convertedID)
        let attentionGateAfterTimer = await harness.engine.itemSnapshot(itemID: attentionGateID)
        XCTAssertNotNil(queuedGateAfterTimer)
        XCTAssertNotNil(convertedAfterTimer)
        XCTAssertNotNil(attentionGateAfterTimer)
    }

    private func makeHarness(
        diagnosticsSink: @escaping TransferDiagnosticSink = { _ in }
    ) -> (
        engine: TransferEngine,
        mirror: TransferStatusMirror,
        enqueuer: ObserverAudioTransferEnqueuer,
        omi: OmiUploaderHolder,
        watch: WatchUploaderHolder
    ) {
        makeTransferCutoverHarness(
            rootURL: self.rootURL,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: OwnerGateAvailableEndpointResolver(),
            diagnosticsSink: diagnosticsSink
        )
    }

    private func manifest(itemID: UUID, chunkIndex: Int) -> TransferManifest {
        ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: itemID,
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: chunkIndex, startedAt: Date())
        )
    }

    private func payloadFileURLs(contents: String) throws -> [String: URL] {
        try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        let url = self.rootURL.appendingPathComponent("payload-\(UUID().uuidString).m4a")
        try Data(contents.utf8).write(to: url)
        return ["audio": url]
    }

    private func sentItemIDs() -> [UUID] {
        TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:))
    }

    private func gatedToken(
        _ outcome: TransferGateRegistrationOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> TransferGateToken {
        guard case .gated(let token) = outcome else {
            XCTFail("expected gate registration", file: file, line: line)
            fatalError("expected gate registration")
        }
        return token
    }
}

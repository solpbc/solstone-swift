// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated private struct AvailableTransferEndpointResolver: TransferEndpointResolver {
    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        .available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))
    }
}

private actor TransferLaunchBarrierHoldGate {
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

final class TransferLaunchBarrierTests: XCTestCase {
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferLaunchBarrierTests-\(UUID().uuidString)", isDirectory: true)
        TransferURLProtocol.reset()
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.rootURL)
        self.rootURL = nil
        super.tearDown()
    }

    @MainActor func testInitializeDefersDispatchUntilEnable() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let harness = makeTransferCutoverHarness(
            rootURL: self.rootURL,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: AvailableTransferEndpointResolver()
        )
        let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: UUID(),
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 0, startedAt: Date())
        )

        try await harness.engine.initialize()
        try await harness.engine.initialize()
        _ = try await harness.engine.enqueue(manifest: manifest, payloads: ["audio": Data("audio".utf8)])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)

        await harness.engine.enableDispatch()
        try await transferTestWaitFor("single dispatch") {
            TransferURLProtocol.requests.count == 1
        }
        await harness.engine.enableDispatch()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(TransferURLProtocol.requests.count, 1)
    }

    @MainActor func testConstructionDefersEveryDispatchTriggerUntilInitializeAndEnable() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let harness = makeTransferCutoverHarness(
            rootURL: self.rootURL,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: AvailableTransferEndpointResolver()
        )
        let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: UUID(),
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 0, startedAt: Date())
        )

        _ = try await harness.engine.enqueue(manifest: manifest, payloads: ["audio": Data("audio".utf8)])
        await harness.engine.endpointAvailabilityChanged()
        await harness.engine.kick()
        await harness.engine.setPacingMode(.finishSyncing)
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)

        try await harness.engine.initialize()
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("construction barrier dispatch") {
            TransferURLProtocol.requests.count == 1
        }
    }

    @MainActor func testOmiReconciliationCompletesBeforeLaunchDispatchAndRestartSendsOnce() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let appGroupRoot = self.rootURL.appendingPathComponent("group", isDirectory: true)
        let transferRoot = appGroupRoot
            .appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let sessionID = UUID()
        let itemID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        let omiDirectory = appGroupRoot
            .appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
        let chunkID = "\(sessionID.uuidString.lowercased())-0"
        let audioURL = omiDirectory.appendingPathComponent("\(chunkID).m4a", isDirectory: false)
        let sidecarURL = omiDirectory.appendingPathComponent("\(chunkID).json", isDirectory: false)
        try writeTransferTestAudio(at: audioURL)
        try writeTransferTestSidecar(sidecar, to: sidecarURL)

        let token = OmiSegmentMetadataToken(kind: .reconnect, processID: UUID(), sequence: 1, revision: 1)
        let envelopeURL = OmiPendingHandoffStore.url(for: audioURL)
        let envelope = OmiPendingHandoffEnvelope(
            itemID: itemID,
            sidecar: sidecar,
            metadata: nil,
            frozenTokens: [token]
        )
        try OmiPendingHandoffStore.write(try OmiPendingHandoffStore.encode(envelope), to: envelopeURL)

        let spool = TransferSpool(rootURL: transferRoot)
        let omiManifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar)
        _ = try spool.commitStagedItem(itemID: spool.stage(
            manifest: omiManifest,
            payloads: ["audio": Data(contentsOf: audioURL)]
        ).item.manifest.itemID)
        let unrelatedID = UUID()
        var unrelatedManifest = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: unrelatedID,
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 1, startedAt: Date())
        )
        unrelatedManifest.source = "unrelated"
        unrelatedManifest.priority = TransferPriorityInputs(sourceKey: "unrelated")
        _ = try spool.commitStagedItem(itemID: spool.stage(
            manifest: unrelatedManifest,
            payloads: ["audio": Data("unrelated".utf8)]
        ).item.manifest.itemID)

        let defaultsSuite = "TransferLaunchBarrierTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        let first = makeTransferCutoverHarness(
            rootURL: transferRoot,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: AvailableTransferEndpointResolver()
        )

        try await first.engine.initialize()
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)

        var acknowledgements: [[OmiSegmentMetadataToken]] = []
        await OmiTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            legacyCachesRootURL: nil,
            transferEnqueuer: first.enqueuer,
            diagnosticLog: nil,
            acknowledgeTokens: { acknowledgements.append($0) },
            registerDispatchHold: { _ in },
            defaults: defaults
        )

        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        XCTAssertEqual(acknowledgements, [[token]])
        let omiSnapshots = await first.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(omiSnapshots.filter { $0.manifest.itemID == itemID }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeURL.path))
        XCTAssertFalse(transferTestPathExists(
            containing: itemID.uuidString,
            under: transferRoot.appendingPathComponent(TransferSpool.stagingDirectoryName, isDirectory: true)
        ))
        XCTAssertFalse(transferTestPathExists(
            containing: itemID.uuidString,
            under: transferRoot.appendingPathComponent(TransferSpool.salvageDirectoryName, isDirectory: true)
        ))

        // A process death after reconciliation leaves the committed owner intact;
        // the fresh engine must be the only one that enables dispatch.
        let second = makeTransferCutoverHarness(
            rootURL: transferRoot,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: AvailableTransferEndpointResolver()
        )
        try await second.engine.initialize()
        await OmiTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            legacyCachesRootURL: nil,
            transferEnqueuer: second.enqueuer,
            diagnosticLog: nil,
            acknowledgeTokens: { acknowledgements.append($0) },
            registerDispatchHold: { _ in },
            defaults: defaults
        )
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)

        await second.engine.enableDispatch()
        try await transferTestWaitFor("omi and unrelated items to dispatch") {
            TransferURLProtocol.requests.count == 2
        }
        XCTAssertEqual(
            TransferURLProtocol.requests.filter { transferTestBoundaryItemID(from: $0) == itemID }.count,
            1
        )
        XCTAssertEqual(
            TransferURLProtocol.requests.filter { transferTestBoundaryItemID(from: $0) == unrelatedID }.count,
            1
        )
    }

    @MainActor func testBootstrapHoldsCleanupResidueBeforeEagerDispatch() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let appGroupRoot = self.rootURL.appendingPathComponent("bootstrap-hold", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let sessionID = UUID()
        let heldID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        let directory = appGroupRoot
            .appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
        let chunkID = "\(sessionID.uuidString.lowercased())-0"
        let audioURL = directory.appendingPathComponent("\(chunkID).m4a")
        let sidecarURL = directory.appendingPathComponent("\(chunkID).json")
        try writeTransferTestAudio(at: audioURL)
        try writeTransferTestSidecar(sidecar, to: sidecarURL)
        let envelopeURL = OmiPendingHandoffStore.url(for: audioURL)
        try OmiPendingHandoffStore.write(
            try OmiPendingHandoffStore.encode(
                OmiPendingHandoffEnvelope(itemID: heldID, sidecar: sidecar, metadata: nil, frozenTokens: [])
            ),
            to: envelopeURL
        )

        let spool = TransferSpool(rootURL: transferRoot)
        _ = try spool.commitStagedItem(itemID: spool.stage(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: heldID, sidecar: sidecar),
            payloads: ["audio": Data(contentsOf: audioURL)]
        ).item.manifest.itemID)
        let unrelatedID = UUID()
        var unrelated = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: unrelatedID,
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 1, startedAt: Date())
        )
        unrelated.source = "unrelated"
        unrelated.priority = TransferPriorityInputs(sourceKey: "unrelated")
        _ = try spool.commitStagedItem(itemID: spool.stage(
            manifest: unrelated,
            payloads: ["audio": Data("unrelated".utf8)]
        ).item.manifest.itemID)

        let defaultsName = "TransferLaunchBarrierTests-bootstrap-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }
        let harness = makeTransferCutoverHarness(
            rootURL: transferRoot,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: AvailableTransferEndpointResolver()
        )
        await SolstoneSwiftApp.bootstrapTransfer(
            initialize: { try await harness.engine.initialize() },
            appGroupRoot: { appGroupRoot },
            cachesRootURL: nil,
            migrate: { root, cacheRoot in
                await OmiTransferSpoolMigrator.migrate(
                    appGroupRootURL: root,
                    legacyCachesRootURL: cacheRoot,
                    transferEnqueuer: harness.enqueuer,
                    diagnosticLog: nil,
                    acknowledgeTokens: { _ in },
                    registerDispatchHold: { itemID in await harness.engine.hold(itemID: itemID) },
                    defaults: defaults,
                    fileManager: TargetedRemovalFailingFileManager(failingURL: audioURL)
                )
            },
            reconcile: { _ in },
            enableDispatch: { await harness.engine.enableDispatch() },
            openOmiReadiness: {},
            reportFailure: { _, _ in XCTFail("bootstrap should not fail") }
        )

        try await transferTestWaitFor("unrelated eager dispatch") {
            TransferURLProtocol.requests.count == 1
        }
        XCTAssertEqual(transferTestBoundaryItemID(from: TransferURLProtocol.requests[0]), unrelatedID)
        let heldSnapshot = await harness.engine.itemSnapshot(itemID: heldID)
        XCTAssertNotNil(heldSnapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelopeURL.path))
    }

    @MainActor func testBootstrapAwaitsDispatchHoldRegistrationBeforeEnablingDispatch() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let appGroupRoot = self.rootURL.appendingPathComponent("await-hold", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let sessionID = UUID()
        let itemID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        let directory = appGroupRoot
            .appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
        let audioURL = directory.appendingPathComponent("\(sessionID.uuidString.lowercased())-0.m4a")
        try writeTransferTestAudio(at: audioURL)
        try writeTransferTestSidecar(sidecar, to: audioURL.deletingPathExtension().appendingPathExtension("json"))
        let envelopeURL = OmiPendingHandoffStore.url(for: audioURL)
        try OmiPendingHandoffStore.write(
            try OmiPendingHandoffStore.encode(OmiPendingHandoffEnvelope(itemID: itemID, sidecar: sidecar, metadata: nil, frozenTokens: [])),
            to: envelopeURL
        )
        let spool = TransferSpool(rootURL: transferRoot)
        _ = try spool.commitStagedItem(itemID: spool.stage(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar),
            payloads: ["audio": Data(contentsOf: audioURL)]
        ).item.manifest.itemID)
        let defaultsName = "TransferLaunchBarrierTests-await-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }
        let harness = makeTransferCutoverHarness(
            rootURL: transferRoot,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: AvailableTransferEndpointResolver()
        )
        let gate = TransferLaunchBarrierHoldGate()
        var didEnableDispatch = false
        let bootstrap = Task { @MainActor in
            await SolstoneSwiftApp.bootstrapTransfer(
                initialize: { try await harness.engine.initialize() },
                appGroupRoot: { appGroupRoot },
                cachesRootURL: nil,
                migrate: { root, cacheRoot in
                    await OmiTransferSpoolMigrator.migrate(
                        appGroupRootURL: root,
                        legacyCachesRootURL: cacheRoot,
                        transferEnqueuer: harness.enqueuer,
                        diagnosticLog: nil,
                        acknowledgeTokens: { _ in },
                        registerDispatchHold: { id in
                            await gate.suspend()
                            await harness.engine.hold(itemID: id)
                        },
                        defaults: defaults,
                        fileManager: TargetedRemovalFailingFileManager(failingURL: audioURL)
                    )
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

        try await transferTestWaitFor("hold registration suspension") { await gate.waiting() }
        XCTAssertFalse(didEnableDispatch)
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        await gate.resume()
        await bootstrap.value
        XCTAssertTrue(didEnableDispatch)
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
    }

    @MainActor func testBootstrapRestartConvergesWhenCleanupFaultIsRemovedOrRetained() async throws {
        for retainsFault in [false, true] {
            TransferURLProtocol.reset()
            TransferURLProtocol.handler = { request, _ in
                (transferTestResponse(for: request, statusCode: 204), Data())
            }
            let appGroupRoot = self.rootURL.appendingPathComponent("restart-\(retainsFault)", isDirectory: true)
            let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
            let sessionID = UUID()
            let itemID = UUID()
            let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
            let directory = appGroupRoot
                .appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true)
                .appendingPathComponent(sessionID.uuidString, isDirectory: true)
                .appendingPathComponent("pending", isDirectory: true)
            let audioURL = directory.appendingPathComponent("\(sessionID.uuidString.lowercased())-0.m4a")
            try writeTransferTestAudio(at: audioURL)
            try writeTransferTestSidecar(sidecar, to: audioURL.deletingPathExtension().appendingPathExtension("json"))
            let envelopeURL = OmiPendingHandoffStore.url(for: audioURL)
            try OmiPendingHandoffStore.write(
                try OmiPendingHandoffStore.encode(OmiPendingHandoffEnvelope(itemID: itemID, sidecar: sidecar, metadata: nil, frozenTokens: [])),
                to: envelopeURL
            )
            let spool = TransferSpool(rootURL: transferRoot)
            _ = try spool.commitStagedItem(itemID: spool.stage(
                manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar),
                payloads: ["audio": Data(contentsOf: audioURL)]
            ).item.manifest.itemID)
            let defaultsName = "TransferLaunchBarrierTests-restart-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }
            let first = makeTransferCutoverHarness(
                rootURL: transferRoot,
                sessionConfiguration: makeTransferTestURLSessionConfiguration(),
                endpointResolver: AvailableTransferEndpointResolver()
            )
            await SolstoneSwiftApp.bootstrapTransfer(
                initialize: { try await first.engine.initialize() },
                appGroupRoot: { appGroupRoot },
                cachesRootURL: nil,
                migrate: { root, cacheRoot in
                    await OmiTransferSpoolMigrator.migrate(
                        appGroupRootURL: root, legacyCachesRootURL: cacheRoot,
                        transferEnqueuer: first.enqueuer, diagnosticLog: nil,
                        acknowledgeTokens: { _ in },
                        registerDispatchHold: { await first.engine.hold(itemID: $0) },
                        defaults: defaults,
                        fileManager: TargetedRemovalFailingFileManager(failingURL: audioURL)
                    )
                },
                reconcile: { _ in }, enableDispatch: { await first.engine.enableDispatch() },
                openOmiReadiness: {}, reportFailure: { _, _ in XCTFail("bootstrap should not fail") }
            )
            XCTAssertEqual(TransferURLProtocol.requests.count, 0)

            let second = makeTransferCutoverHarness(
                rootURL: transferRoot,
                sessionConfiguration: makeTransferTestURLSessionConfiguration(),
                endpointResolver: AvailableTransferEndpointResolver()
            )
            await SolstoneSwiftApp.bootstrapTransfer(
                initialize: { try await second.engine.initialize() },
                appGroupRoot: { appGroupRoot },
                cachesRootURL: nil,
                migrate: { root, cacheRoot in
                    await OmiTransferSpoolMigrator.migrate(
                        appGroupRootURL: root, legacyCachesRootURL: cacheRoot,
                        transferEnqueuer: second.enqueuer, diagnosticLog: nil,
                        acknowledgeTokens: { _ in },
                        registerDispatchHold: { await second.engine.hold(itemID: $0) },
                        defaults: defaults,
                        fileManager: retainsFault ? TargetedRemovalFailingFileManager(failingURL: audioURL) : .default
                    )
                },
                reconcile: { _ in }, enableDispatch: { await second.engine.enableDispatch() },
                openOmiReadiness: {}, reportFailure: { _, _ in XCTFail("bootstrap should not fail") }
            )
            if retainsFault {
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertEqual(TransferURLProtocol.requests.count, 0)
            } else {
                try await transferTestWaitFor("single restart dispatch") {
                    TransferURLProtocol.requests.count == 1
                }
            }
            XCTAssertFalse(transferTestPathExists(containing: itemID.uuidString, under: transferRoot.appendingPathComponent(TransferSpool.stagingDirectoryName, isDirectory: true)))
            XCTAssertFalse(transferTestPathExists(containing: itemID.uuidString, under: transferRoot.appendingPathComponent(TransferSpool.salvageDirectoryName, isDirectory: true)))
            let omiItems = await second.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
            XCTAssertLessThanOrEqual(omiItems.filter { $0.manifest.itemID == itemID }.count, 1)
        }
    }

}

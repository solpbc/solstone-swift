// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Foundation
import Opus
import os
import XCTest

nonisolated private struct CutoverAvailableEndpointResolver: TransferEndpointResolver {
    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        .available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))
    }
}

final class OmiLaunchCaptureCutoverTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiLaunchCaptureCutoverTests-\(UUID().uuidString)", isDirectory: true)
        CutoverTransferURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        CutoverTransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.rootURL)
    }

    @MainActor func testReservedOwnersAppearOnlyAfterFinalEvidenceAndRouteSubsequentAudio() async throws {
        let frame = try Self.opusFrame()
        let sealedCallback = Self.packet(1, index: 0, body: frame)
        let reservedCallback = Self.packet(2, index: 0, body: frame)
        let world = try await self.driveCutLifecycle(
            sealedCallbacks: [Self.marker(packet: 0, epoch: 2_000), sealedCallback],
            reservedCallbacks: [reservedCallback]
        )
        let reservedRoot = OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: world.captureRoot)
        let sealedRecords = try self.allLeaseRecords(rootURL: world.captureRoot, generationID: world.sealedGenerationID)
        let reservedRecords = try self.allLeaseRecords(rootURL: reservedRoot, generationID: world.reservedGenerationID)
        XCTAssertEqual(sealedRecords.map(\.payload).filter { $0 == sealedCallback }.count, 1)
        XCTAssertEqual(reservedRecords.map(\.payload).filter { $0 == sealedCallback }.count, 0)
        XCTAssertEqual(sealedRecords.map(\.payload).filter { $0 == reservedCallback }.count, 0)
        XCTAssertEqual(reservedRecords.map(\.payload).filter { $0 == reservedCallback }.count, 1)
        XCTAssertEqual(world.manager.activeLaunchCaptureGenerationID, world.reservedGenerationID)
        XCTAssertNotNil(world.final)
        XCTAssertTrue(world.preFinalReservedArtifactIDs.isEmpty)
        XCTAssertTrue(world.requestIDsBeforeFinal.contains(world.controlItemID))

        let reservedIDs = try Self.materializedIDs(rootURL: reservedRoot, generationID: world.reservedGenerationID)
        XCTAssertFalse(reservedIDs.isEmpty)
        XCTAssertTrue(reservedIDs.isDisjoint(with: world.preFinalOmiItemIDs))
        XCTAssertTrue(reservedIDs.isDisjoint(with: Set(world.requestIDsBeforeFinal)))
        try await transferTestWaitFor("reserved delivery after final evidence") {
            reservedIDs.isSubset(of: Set(Self.requestIDs()))
        }
        XCTAssertTrue(reservedIDs.allSatisfy { Self.requestIDs().contains($0) })
    }

    @MainActor func testCutoverExistenceReadFailureKeepsRouteOnCapture() async throws {
        let defaults = self.defaults(enabled: true)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let generation = UUID()
        let ingress = OmiLaunchCaptureIngress(appGroupRoot: { self.rootURL }, generationID: generation, clock: clock)
        let manager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: ingress)
        manager.enable()
        manager.buildOpusDecoder()
        await manager.openLaunchReadiness()
        var decodedHandoffs = 0
        manager.onDecodedSamples = { _ in decodedHandoffs += 1 }

        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("transfer", isDirectory: true))
        try await harness.engine.initialize()
        let io = FaultInjectingOmiLaunchCaptureIO()
        let reader = OmiLaunchCaptureLeaseReader(rootURL: self.captureRoot, generationID: generation, io: io)
        // The first four capture-file existence reads are recovery and lease checks; the fifth is cutover validation.
        io.failExists(at: reader.fileURL, fromCall: 5)
        await OmiLaunchCaptureCommitCoordinator(rootURL: self.captureRoot, engine: harness.engine, sourceManager: manager, io: io).reconcile()

        let peripheralID = UUID()
        let frame = try Self.opusFrame()
        manager.handleAudioData(.payload(Self.packet(0, index: 0, body: frame)), peripheralID: peripheralID)
        manager.handleAudioData(.payload(Self.packet(1, index: 0, body: frame)), peripheralID: peripheralID)
        XCTAssertEqual(decodedHandoffs, 0)
        guard case .valid(let intent) = OmiLaunchCaptureCutReservationStore(rootURL: self.captureRoot, io: io).read() else {
            return XCTFail("cut intent was not readable")
        }
        let reservedURL = OmiLaunchCaptureFormat.fileURL(rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: self.captureRoot), generationID: intent.reservedGenerationID)
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: reservedURL.path)[.size] as? Int ?? 0, 0)
    }

    @MainActor func testReplayDiagnosticsDeduplicatesRebootBeforeLiveMarker() throws {
        let fileURL = self.rootURL.appendingPathComponent("diagnostics.json")
        let defaults = self.defaults(enabled: true)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 200))
        let markers = [
            OmiLaunchCaptureMarkerObservation(epoch: 2_000, acquiredAt: clock.now(), sequence: 0),
            OmiLaunchCaptureMarkerObservation(epoch: 1_000, acquiredAt: clock.now(), sequence: 1),
        ]
        let first = OmiSourceManager(defaults: defaults, diagnostics: OmiDiagnostics(fileURL: fileURL), clock: clock, bluetoothPort: MockOmiBluetoothPort())
        first.observeRecoveredLaunchCaptureMarkers(markers)
        XCTAssertEqual(first.diagnostics.payload.pendantRebootEvents?.count, 1)

        let restarted = OmiSourceManager(defaults: defaults, diagnostics: OmiDiagnostics(fileURL: fileURL), clock: clock, bluetoothPort: MockOmiBluetoothPort())
        restarted.observeRecoveredLaunchCaptureMarkers(markers)
        restarted.handleAudioData(.payload(Self.marker(packet: 0, epoch: 1_001)), peripheralID: UUID())
        XCTAssertEqual(restarted.diagnostics.payload.pendantRebootEvents?.count, 1)
        XCTAssertEqual(restarted.lastMarkerDate, Date(timeIntervalSince1970: 1_001))
    }

    @MainActor func testReplayMarkerHighWaterPreservesBoundaryOrderAndSameTimestampDistinctness() async throws {
        let generation = UUID()
        let defaults = self.defaults(enabled: true)
        let diagnosticsURL = self.rootURL.appendingPathComponent("marker-diagnostics.json")
        let observedAt = Date(timeIntervalSince1970: 100)
        let clock = MockObserverClock(now: observedAt)
        let ingress = OmiLaunchCaptureIngress(appGroupRoot: { self.rootURL }, generationID: generation, clock: clock)
        let manager = OmiSourceManager(defaults: defaults, diagnostics: OmiDiagnostics(fileURL: diagnosticsURL), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: ingress)
        manager.enable()
        // Prime a higher epoch so each coordinator-delivered marker transition is
        // observable through the source manager's replay diagnostics.
        manager.observeRecoveredLaunchCaptureMarkers([
            OmiLaunchCaptureMarkerObservation(epoch: 5_000, acquiredAt: observedAt, sequence: nil),
        ])
        let writer = OmiLaunchCaptureWriter(rootURL: self.captureRoot, generationID: generation, clock: clock)
        // Records 1 and 2 are an exact duplicate; all four carry the same source
        // timestamp, so sequence is the only distinction at the batch boundary.
        for (packet, epoch) in [(0, 3_000), (1, 1_000), (2, 1_000), (3, 999)] {
            Self.assertRetained(writer.append(Self.marker(packet: UInt16(packet), epoch: UInt32(epoch))))
        }
        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("marker-transfer", isDirectory: true))
        try await harness.engine.initialize()
        let coordinator = OmiLaunchCaptureCommitCoordinator(rootURL: self.captureRoot, engine: harness.engine, sourceManager: manager)
        await coordinator.reconcile()
        let reader = OmiLaunchCaptureLeaseReader(rootURL: self.captureRoot, generationID: generation)
        XCTAssertEqual(reader.cursor()?.replayMarkerNextSequence, 2)

        // This lands between the two bounded coordinator batches. The next replayed
        // 1_000 marker is otherwise indistinguishable from its predecessor except
        // for sequence, so its distinct diagnostic transition proves it arrived.
        manager.observeRecoveredLaunchCaptureMarkers([
            OmiLaunchCaptureMarkerObservation(epoch: 4_000, acquiredAt: observedAt, sequence: nil),
        ])
        await Task.yield()
        await Task.yield()

        // These are source-manager effects of coordinator-delivered markers. The
        // second and third transitions have the same acquiredAt and epochAfter;
        // only their source sequence distinguishes the two replayed entries.
        XCTAssertEqual(
            (manager.diagnostics.payload.pendantRebootEvents ?? []).map {
                "\($0.epochBefore)->\($0.epochAfter)@\($0.observedAt.timeIntervalSince1970)"
            },
            [
                "5000->3000@100.0",
                "3000->1000@100.0",
                "4000->1000@100.0",
            ]
        )
        XCTAssertEqual(reader.cursor()?.replayMarkerNextSequence, 4)
        XCTAssertEqual(manager.lastMarkerDate, Date(timeIntervalSince1970: 999))
        XCTAssertEqual(manager.diagnostics.payload.pendantRebootEvents?.count, 3)

        // A fresh coordinator starts after the durable high-water mark; it cannot
        // apply the already observed marker records again.
        await OmiLaunchCaptureCommitCoordinator(rootURL: self.captureRoot, engine: harness.engine, sourceManager: manager).reconcile()
        XCTAssertEqual(reader.cursor()?.replayMarkerNextSequence, 4)
        XCTAssertEqual(manager.diagnostics.payload.pendantRebootEvents?.count, 3)
    }

    @MainActor func testCutoverWaitsForAllGenerationsAndRetiresInactiveCaptureInCaptureOrder() async throws {
        let defaults = self.defaults(enabled: true)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let activeGeneration = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        let inactiveGeneration = try XCTUnwrap(UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff"))
        let ingress = OmiLaunchCaptureIngress(appGroupRoot: { self.rootURL }, generationID: activeGeneration, clock: clock)
        let manager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: ingress)
        manager.enable()

        let frame = try Self.opusFrame()
        let inactiveWriter = OmiLaunchCaptureWriter(rootURL: self.captureRoot, generationID: inactiveGeneration, clock: clock)
        Self.assertRetained(inactiveWriter.append(Self.marker(packet: 0, epoch: 2_000)))
        Self.assertRetained(inactiveWriter.append(Self.packet(1, index: 0, body: frame)))
        clock.advance(by: 1)
        let peripheralID = UUID()
        manager.handleAudioData(.payload(Self.marker(packet: 0, epoch: 1_000)), peripheralID: peripheralID)
        manager.handleAudioData(.payload(Self.packet(1, index: 0, body: frame)), peripheralID: peripheralID)

        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("transfer", isDirectory: true))
        try await harness.engine.initialize()
        let barrier = CutoverBarrier()
        var didSuspend = false
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: self.captureRoot,
            engine: harness.engine,
            sourceManager: manager,
            onReconciliationPhase: { phase in
                if phase == .afterSealedOwnerGatedEnqueued, !didSuspend {
                    didSuspend = true
                    await barrier.suspend()
                }
            }
        )
        let recovery = Task { @MainActor in await coordinator.reconcile() }
        try await transferTestWaitFor("first generation gated") { await barrier.waiting() }
        // Intent-first routing seals the active generation before reconciliation.
        // The inactive generation is therefore replayed (and delivers its marker)
        // before the active sealed owner reaches this suspension point.
        XCTAssertNotNil(manager.lastMarkerDate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inactiveWriter.fileURL.path))
        await barrier.resume()
        await recovery.value
        try await transferTestWaitFor("all-generation cutover") {
            await MainActor.run { manager.lastMarkerDate != nil }
        }
        XCTAssertEqual(manager.lastMarkerDate, Date(timeIntervalSince1970: 1_000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inactiveWriter.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: OmiLaunchCaptureFormat.fileURL(rootURL: self.captureRoot, generationID: activeGeneration).path))
        XCTAssertEqual(manager.diagnostics.payload.pendantRebootEvents?.count, 1)
    }

    @MainActor func testPersistedDisabledLeavesCaptureEffectsInertAndPreservesExistingOwnerEvidence() async throws {
        let generation = UUID()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let writer = OmiLaunchCaptureWriter(rootURL: self.captureRoot, generationID: generation, clock: clock)
        Self.assertRetained(writer.append(Self.marker(packet: 0, epoch: 2_000)))
        Self.assertRetained(writer.append(Self.packet(1, index: 0, body: try Self.opusFrame())))
        let decoder = try OmiOpusAudioDecoder()
        let partition = try XCTUnwrap(OmiLaunchCaptureMaterializer(rootURL: self.captureRoot, generationID: generation, decode: { decoder.decode($0) }).materializeForTests().partitions.first)

        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("transfer", isDirectory: true))
        try await harness.engine.initialize()
        let envelope = try OmiPendingHandoffStore.read(from: partition.envelopeURL)
        _ = try await harness.engine.enqueue(manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: partition.itemID, sidecar: envelope.sidecar), payloads: ["audio": Data(contentsOf: partition.audioURL)])
        let defaults = self.defaults(enabled: false)
        let ingress = OmiLaunchCaptureIngress(appGroupRoot: { self.rootURL }, generationID: generation, clock: clock)
        XCTAssertTrue(ingress.arm())
        let manager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: ingress)
        var decodedHandoffs = 0
        manager.onDecodedSamples = { _ in decodedHandoffs += 1 }
        let reader = OmiLaunchCaptureLeaseReader(rootURL: self.captureRoot, generationID: generation)
        let sourceSizeBefore = try FileManager.default.attributesOfItem(atPath: reader.fileURL.path)[.size] as? Int
        let materializedBefore = try FileManager.default.contentsOfDirectory(
            at: partition.envelopeURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
        let snapshotsBefore = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        await OmiLaunchCaptureCommitCoordinator(rootURL: self.captureRoot, engine: harness.engine, sourceManager: manager).reconcile()

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots, snapshotsBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reader.cursorURL.path))
        XCTAssertNil(manager.lastMarkerDate)
        manager.handleAudioData(.payload(Self.marker(packet: 2, epoch: 1_000)), peripheralID: UUID())
        manager.handleAudioData(.payload(Self.packet(3, index: 0, body: try Self.opusFrame())), peripheralID: UUID())
        XCTAssertEqual(decodedHandoffs, 0)
        XCTAssertNil(manager.lastMarkerDate)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: reader.fileURL.path)[.size] as? Int, sourceSizeBefore)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: partition.envelopeURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent).sorted(),
            materializedBefore
        )

        manager.enable()
        manager.handleAudioData(.payload(Self.packet(4, index: 0, body: try Self.opusFrame())), peripheralID: UUID())
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: reader.fileURL.path)[.size] as? Int ?? 0, sourceSizeBefore ?? 0)
        XCTAssertEqual(decodedHandoffs, 0)
    }

    @MainActor func testDisableDuringRecoveryHoldsOwnerAndExplicitEnableCallbackCoalesces() async throws {
        let generation = UUID()
        let writer = OmiLaunchCaptureWriter(rootURL: self.captureRoot, generationID: generation, clock: MockObserverClock())
        Self.assertRetained(writer.append(Self.packet(0, index: 0, body: try Self.opusFrame())))
        let defaults = self.defaults(enabled: true)
        let manager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: MockObserverClock(), bluetoothPort: MockOmiBluetoothPort())
        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("transfer", isDirectory: true))
        try await harness.engine.initialize()
        await harness.engine.enableDispatch()
        let initialBarrier = CutoverBarrier()
        let resumeBarrier = CutoverBarrier()
        let resumePasses = CutoverPassCounter()
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: self.captureRoot,
            engine: harness.engine,
            sourceManager: manager,
            onReconciliationPhase: { phase in
                switch phase {
                case .afterSealedOwnerGatedEnqueued:
                    await initialBarrier.suspend()
                case .afterSealedOwnershipVerified:
                    await resumePasses.increment()
                    await resumeBarrier.suspend()
                case .afterCutIntentCommittedBeforeRouteSwap:
                    break
                case .afterSealedCursorAcknowledged, .afterSealedEnvelopeCleaned,
                     .beforeSealedOwnerReleased, .afterSealedOwnerReleased,
                     .afterFinalMarkerCommittedBeforeReservedMaterialization,
                     .beforeReservedOwnerReleased, .afterReservedOwnerReleased:
                    break
                }
            }
        )
        manager.onLaunchCaptureExplicitEnable = { await coordinator.resumeAfterExplicitEnable() }

        let recovery = Task { @MainActor in await coordinator.reconcile() }
        try await transferTestWaitFor("gated recovery") { await initialBarrier.waiting() }
        manager.disable()
        await initialBarrier.resume()
        await recovery.value
        XCTAssertEqual(CutoverTransferURLProtocol.requests.count, 0)
        let heldSnapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(heldSnapshots.count, 1)
        let heldID = try XCTUnwrap(heldSnapshots.first?.itemID)
        guard case .gated(let restoredToken) = await harness.engine.restoreGateFromHold(itemID: heldID) else {
            return XCTFail("disabled recovery did not retain a lifetime hold")
        }
        let heldSettlement = await harness.engine.convertGateToHold(restoredToken)
        XCTAssertEqual(heldSettlement, .settled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.captureRoot.appendingPathComponent(OmiLaunchCaptureFormat.materializedDirectoryName, isDirectory: true).path))

        manager.enable()
        try await transferTestWaitFor("resumed explicit-enable recovery") { await resumeBarrier.waiting() }
        let callback = try XCTUnwrap(manager.onLaunchCaptureExplicitEnable)
        let secondResume = Task { @MainActor in await callback() }
        await secondResume.value
        let observedResumePasses = await resumePasses.count()
        XCTAssertEqual(observedResumePasses, 1)
        await resumeBarrier.resume()
        try await transferTestWaitFor("held owner dispatched after explicit enable") {
            CutoverTransferURLProtocol.requests.count == 1
        }
        XCTAssertEqual(CutoverTransferURLProtocol.requests.count, 1)
    }

    @MainActor func testCutReservationCommitFailureLeavesSealedCaptureOnOrdinaryRoute() async throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let defaults = self.defaults(enabled: true)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let generation = UUID()
        let ingress = OmiLaunchCaptureIngress(captureRoot: { self.captureRoot }, generationID: generation, clock: clock, io: io)
        let manager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: ingress)
        manager.enable()
        let peripheralID = UUID()
        let frame = try Self.opusFrame()
        manager.handleAudioData(.payload(Self.marker(packet: 0, epoch: 2_000)), peripheralID: peripheralID)
        manager.handleAudioData(.payload(Self.packet(1, index: 0, body: frame)), peripheralID: peripheralID)
        let sealedURL = OmiLaunchCaptureFormat.fileURL(rootURL: self.captureRoot, generationID: generation)
        let bytesBefore = try Data(contentsOf: sealedURL)
        let leaseBefore = OmiLaunchCaptureLeaseReader(rootURL: self.captureRoot, generationID: generation, io: io).lease(from: .init(generationID: generation, nextSequence: 0, offset: 0))
        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("transfer", isDirectory: true))
        try await harness.engine.initialize()
        let reservationURL = OmiLaunchCaptureCutReservationFormat.fileURL(rootURL: self.captureRoot)
        io.failReplace(at: reservationURL, fromCall: 1)
        await OmiLaunchCaptureCommitCoordinator(rootURL: self.captureRoot, engine: harness.engine, sourceManager: manager, io: io).reconcile()
        XCTAssertEqual(OmiLaunchCaptureCutReservationStore(rootURL: self.captureRoot, io: io).read(), .absent)
        XCTAssertEqual(try Data(contentsOf: sealedURL), bytesBefore)
        XCTAssertEqual(OmiLaunchCaptureLeaseReader(rootURL: self.captureRoot, generationID: generation, io: io).lease(from: .init(generationID: generation, nextSequence: 0, offset: 0)), leaseBefore)
        manager.handleAudioData(.payload(Self.packet(2, index: 0, body: frame)), peripheralID: peripheralID)
        XCTAssertGreaterThan(try io.fileSize(at: sealedURL), bytesBefore.count)
    }

    @MainActor func testReservedCallbacksRemainExclusiveUntilFinalEvidenceThenEnterTransportDiscovery() async throws {
        let frame = try Self.opusFrame()
        let before = Self.packet(1, index: 0, body: frame)
        let after = Self.packet(2, index: 0, body: frame)
        let world = try await self.driveCutLifecycle(
            sealedCallbacks: [Self.marker(packet: 0, epoch: 2_000), before],
            reservedCallbacks: [after]
        )
        let sealedURL = OmiLaunchCaptureFormat.fileURL(rootURL: world.captureRoot, generationID: world.sealedGenerationID)
        let reservedURL = OmiLaunchCaptureFormat.fileURL(
            rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: world.captureRoot),
            generationID: world.reservedGenerationID
        )
        let sealedBytes = try Data(contentsOf: sealedURL)
        let reservedBytes = try Data(contentsOf: reservedURL)
        XCTAssertEqual(Self.occurrences(of: before, in: sealedBytes), 1)
        XCTAssertEqual(Self.occurrences(of: before, in: reservedBytes), 0)
        XCTAssertEqual(Self.occurrences(of: after, in: sealedBytes), 0)
        XCTAssertEqual(Self.occurrences(of: after, in: reservedBytes), 1)
        let rootEntries = try FileManager.default.contentsOfDirectory(at: world.captureRoot, includingPropertiesForKeys: nil)
        XCTAssertFalse(rootEntries.contains { $0.lastPathComponent == reservedURL.lastPathComponent })
        XCTAssertEqual(world.manager.activeLaunchCaptureGenerationID, world.reservedGenerationID)

        let reservedIDs = try Self.materializedIDs(
            rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: world.captureRoot),
            generationID: world.reservedGenerationID
        )
        XCTAssertFalse(reservedIDs.isEmpty)
        XCTAssertTrue(world.preFinalReservedArtifactIDs.isEmpty)
        XCTAssertTrue(reservedIDs.isDisjoint(with: world.preFinalOmiItemIDs))
        XCTAssertTrue(reservedIDs.isDisjoint(with: Set(world.requestIDsBeforeFinal)))
        XCTAssertTrue(world.requestIDsBeforeFinal.contains(world.controlItemID))
        try await transferTestWaitFor("reserved transport discovery") {
            reservedIDs.allSatisfy { Self.requestIDs().contains($0) }
        }
    }

    @MainActor func testReservedCallbacksPreserveSealedEvidenceThenMaterializeAfterFinalEvidence() async throws {
        let frame = try Self.opusFrame()
        let tags = (0..<32).map { Data(String(format: "reserved-%02d", $0).utf8) }
        let world = try await self.driveCutLifecycle(
            sealedCallbacks: [Self.marker(packet: 0, epoch: 2_000), Self.packet(1, index: 0, body: frame)],
            // The trailing complete frame gives the deferred materializer one
            // transportable partition without changing the 32 raw callbacks this
            // regression originally proved were retained exactly once.
            reservedCallbacks: tags + [Self.packet(99, index: 0, body: frame)]
        )
        let sealedReader = OmiLaunchCaptureLeaseReader(rootURL: world.captureRoot, generationID: world.sealedGenerationID)
        let sealedLease = sealedReader.lease(from: .init(generationID: world.sealedGenerationID, nextSequence: 0, offset: 0))
        let reservedURL = OmiLaunchCaptureFormat.fileURL(
            rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: world.captureRoot),
            generationID: world.reservedGenerationID
        )
        let reservedBytes = try Data(contentsOf: reservedURL)
        for tag in tags { XCTAssertEqual(Self.occurrences(of: tag, in: reservedBytes), 1) }
        XCTAssertEqual(try Data(contentsOf: sealedReader.fileURL), world.sealedBytesBeforeFinal)
        XCTAssertEqual(sealedReader.lease(from: .init(generationID: world.sealedGenerationID, nextSequence: 0, offset: 0)), sealedLease)

        let reservedIDs = try Self.materializedIDs(
            rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: world.captureRoot),
            generationID: world.reservedGenerationID
        )
        XCTAssertFalse(reservedIDs.isEmpty)
        XCTAssertTrue(reservedIDs.isDisjoint(with: world.preFinalOmiItemIDs))
        XCTAssertTrue(reservedIDs.isDisjoint(with: Set(world.requestIDsBeforeFinal)))
        XCTAssertTrue(world.requestIDsBeforeFinal.contains(world.controlItemID))
        try await transferTestWaitFor("reserved materialization") {
            reservedIDs.allSatisfy { Self.requestIDs().contains($0) }
        }
    }

    @MainActor func testCallbacksAtEveryCutoverAwaitRemainExclusivelyClassifiedOnce() async throws {
        let phases: [OmiLaunchCaptureCommitCoordinator.ReconciliationPhase] = [
            .afterCutIntentCommittedBeforeRouteSwap,
            .afterSealedOwnerGatedEnqueued,
            .afterSealedOwnershipVerified,
            .afterSealedCursorAcknowledged,
            .afterSealedEnvelopeCleaned,
            .beforeSealedOwnerReleased,
            .afterSealedOwnerReleased,
            .afterFinalMarkerCommittedBeforeReservedMaterialization,
            .beforeReservedOwnerReleased,
            .afterReservedOwnerReleased,
        ]
        let frame = try Self.opusFrame()
        let phasesBeforeReservedSeed = Set(phases.prefix(4))
        for (index, phase) in phases.enumerated() {
            CutoverTransferURLProtocol.reset()
            let callbackPrecedesReservedSeed = phasesBeforeReservedSeed.contains(phase)
            let callback = Self.packet(callbackPrecedesReservedSeed ? 2 : 3, index: 0, body: frame)
            let reservedSeed = Self.packet(callbackPrecedesReservedSeed ? 3 : 2, index: 0, body: frame)
            let world = try await self.driveCutLifecycle(
                sealedCallbacks: [Self.marker(packet: 0, epoch: 2_000), Self.packet(1, index: 0, body: frame)],
                reservedCallbacks: [reservedSeed],
                callbacksByPhase: [phase: [callback]],
                appGroupRoot: self.rootURL.appendingPathComponent("callback-phase-\(index)", isDirectory: true),
                performPreFinalProbe: false
            )
            let sealedURL = OmiLaunchCaptureFormat.fileURL(
                rootURL: world.captureRoot,
                generationID: world.sealedGenerationID
            )
            let reservedURL = OmiLaunchCaptureFormat.fileURL(
                rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: world.captureRoot),
                generationID: world.reservedGenerationID
            )
            let sealedBytes = try Data(contentsOf: sealedURL)
            let reservedBytes = try Data(contentsOf: reservedURL)
            let sealedCount = Self.occurrences(of: callback, in: sealedBytes)
            let reservedCount = Self.occurrences(of: callback, in: reservedBytes)
            XCTAssertEqual(sealedCount + reservedCount, 1, String(describing: phase))
            if phase == .afterCutIntentCommittedBeforeRouteSwap {
                XCTAssertEqual(sealedCount, 1)
                XCTAssertEqual(reservedCount, 0)
            } else {
                XCTAssertEqual(sealedCount, 0, String(describing: phase))
                XCTAssertEqual(reservedCount, 1, String(describing: phase))
            }
            try await transferTestWaitFor("phase transfer drain: \(phase)") {
                await world.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
                    .allSatisfy { $0.state == .attention }
            }
        }
    }

    @MainActor func testPostFinalSealedAppendFailsClosedOnReopen() async throws {
        let frame = try Self.opusFrame()
        let world = try await self.driveCutLifecycle(
            sealedCallbacks: [Self.marker(packet: 0, epoch: 2_000), Self.packet(1, index: 0, body: frame)],
            reservedCallbacks: [Self.packet(2, index: 0, body: frame)]
        )
        let final = try XCTUnwrap(world.final)
        let sealedWriter = OmiLaunchCaptureWriter(rootURL: world.captureRoot, generationID: world.sealedGenerationID)
        Self.assertRetained(sealedWriter.append(Self.packet(3, index: 0, body: frame)))

        let defaults = self.defaults(enabled: true)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let freshManager = OmiSourceManager(
            defaults: defaults,
            diagnostics: self.diagnostics(),
            clock: clock,
            bluetoothPort: MockOmiBluetoothPort(),
            launchCaptureIngress: OmiLaunchCaptureIngress(captureRoot: { world.captureRoot }, generationID: world.sealedGenerationID, clock: clock)
        )
        freshManager.enable()
        let defectHarness = self.makeHarness(
            rootURL: self.rootURL.appendingPathComponent("final-defect-transfer", isDirectory: true)
        )
        try await defectHarness.engine.initialize()
        let blockedItemID = UUID()
        _ = try await defectHarness.engine.enqueue(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(
                itemID: blockedItemID,
                sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 0, startedAt: Date())
            ),
            payloads: ["audio": Data("blocked-omi".utf8)]
        )
        let controlItemID = UUID()
        var control = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: controlItemID,
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 1, startedAt: Date())
        )
        control.source = "unrelated"
        control.priority = TransferPriorityInputs(sourceKey: "unrelated")
        _ = try await defectHarness.engine.enqueue(
            manifest: control,
            payloads: ["audio": Data("control".utf8)]
        )
        let defectCoordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: world.captureRoot,
            engine: defectHarness.engine,
            sourceManager: freshManager
        )
        await defectCoordinator.reconcile()
        await defectHarness.engine.enableDispatch()

        XCTAssertEqual(final.sealedGenerationID, world.sealedGenerationID)
        XCTAssertNil(freshManager.activeLaunchCaptureGenerationID)
        let reservedURL = OmiLaunchCaptureFormat.fileURL(
            rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: world.captureRoot),
            generationID: world.reservedGenerationID
        )
        let bytesBeforeBlockedRoute = try Data(contentsOf: reservedURL)
        freshManager.handleAudioData(.payload(Self.packet(4, index: 0, body: frame)), peripheralID: UUID())
        XCTAssertEqual(try Data(contentsOf: reservedURL), bytesBeforeBlockedRoute)
        try await transferTestWaitFor("unrelated delivery with final defect held") {
            Self.requestIDs().contains(controlItemID)
        }
        XCTAssertFalse(Self.requestIDs().contains(blockedItemID))
        let snapshots = await defectHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        let attention = try XCTUnwrap(snapshots.first {
            $0.manifest.attention?.reason == "launch_capture_cut_final_invalid"
        })
        XCTAssertEqual(attention.manifest.diskState, .attention)
        XCTAssertEqual(attention.manifest.payloadParts, [])
        await defectCoordinator.reconcile()
        let repeated = await defectHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(
            repeated.filter { $0.manifest.attention?.reason == "launch_capture_cut_final_invalid" }.map(\.itemID),
            [attention.itemID]
        )
    }

    @MainActor func testRestartAfterCommittedReservationBeforeRouteMutationRestoresReservedClassification() async throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let defaults = self.defaults(enabled: true)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let generation = UUID()
        let ingress = OmiLaunchCaptureIngress(captureRoot: { self.captureRoot }, generationID: generation, clock: clock, io: io)
        let manager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: ingress)
        manager.enable()
        let peripheralID = UUID()
        manager.handleAudioData(.payload(Self.marker(packet: 0, epoch: 2_000)), peripheralID: peripheralID)
        manager.handleAudioData(.payload(Self.packet(1, index: 0, body: try Self.opusFrame())), peripheralID: peripheralID)
        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("transfer", isDirectory: true))
        try await harness.engine.initialize()
        let barrier = CutoverBarrier()
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: self.captureRoot,
            engine: harness.engine,
            sourceManager: manager,
            io: io,
            onReconciliationPhase: { phase in
                if phase == .afterCutIntentCommittedBeforeRouteSwap { await barrier.suspend() }
            }
        )
        let pass = Task { @MainActor in await coordinator.reconcile() }
        try await transferTestWaitFor("reservation committed before route mutation") { await barrier.waiting() }
        guard case .valid(let committed) = OmiLaunchCaptureCutReservationStore(rootURL: self.captureRoot, io: io).read() else {
            return XCTFail("committed reservation was not readable")
        }
        try io.restoreLastSynchronizedState()
        let freshIngress = OmiLaunchCaptureIngress(captureRoot: { self.captureRoot }, generationID: generation, clock: clock, io: io)
        let freshManager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: freshIngress)
        let freshCoordinator = OmiLaunchCaptureCommitCoordinator(rootURL: self.captureRoot, engine: harness.engine, sourceManager: freshManager, io: io)
        guard case .valid(let reopened) = OmiLaunchCaptureCutReservationStore(rootURL: self.captureRoot, io: io).read() else {
            return XCTFail("reservation was lost after simulated death")
        }
        XCTAssertEqual(reopened, committed)
        XCTAssertEqual(freshManager.activeLaunchCaptureGenerationID, committed.reservedGenerationID)
        await freshCoordinator.reconcile()
        let tag = Data("restart-reserved-B".utf8)
        freshManager.handleAudioData(.payload(tag), peripheralID: peripheralID)
        let sealedURL = OmiLaunchCaptureFormat.fileURL(rootURL: self.captureRoot, generationID: generation)
        let reservedURL = OmiLaunchCaptureFormat.fileURL(rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: self.captureRoot), generationID: committed.reservedGenerationID)
        XCTAssertEqual(Self.occurrences(of: tag, in: try Data(contentsOf: sealedURL)), 0)
        XCTAssertEqual(Self.occurrences(of: tag, in: try Data(contentsOf: reservedURL)), 1)
        await barrier.resume()
        await pass.value
    }

    @MainActor func testFailedReservedIngressArmRetriesSameIntentBeforeScanningSealedCapture() async throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let defaults = self.defaults(enabled: true)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let sealedGenerationID = UUID()
        let manager = OmiSourceManager(
            defaults: defaults,
            diagnostics: self.diagnostics(),
            clock: clock,
            bluetoothPort: MockOmiBluetoothPort(),
            launchCaptureIngress: OmiLaunchCaptureIngress(
                captureRoot: { self.captureRoot },
                generationID: sealedGenerationID,
                clock: clock,
                io: io
            )
        )
        manager.enable()
        let peripheralID = UUID()
        manager.handleAudioData(.payload(Self.marker(packet: 0, epoch: 2_000)), peripheralID: peripheralID)
        manager.handleAudioData(.payload(Self.packet(1, index: 0, body: try Self.opusFrame())), peripheralID: peripheralID)

        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("arm-retry-transfer", isDirectory: true))
        try await harness.engine.initialize()
        var armAttempts = 0
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: self.captureRoot,
            engine: harness.engine,
            sourceManager: manager,
            io: io,
            clock: clock,
            onReconciliationPhase: { phase in
                if phase == .afterCutIntentCommittedBeforeRouteSwap {
                    armAttempts += 1
                }
                if phase == .afterCutIntentCommittedBeforeRouteSwap, armAttempts <= 2 {
                    io.failNext(.open)
                }
            }
        )

        await coordinator.reconcile()
        XCTAssertEqual(armAttempts, 1)
        guard case .valid(let intent) = OmiLaunchCaptureCutReservationStore(rootURL: self.captureRoot, io: io).read() else {
            return XCTFail("cut intent was not retained after arm failure")
        }
        XCTAssertEqual(manager.activeLaunchCaptureGenerationID, sealedGenerationID)
        XCTAssertEqual(OmiLaunchCaptureCutFinalStore(rootURL: self.captureRoot, io: io).read(), .absent)

        let whileSealed = Data("while-reserved-arm-failed".utf8)
        manager.handleAudioData(.payload(whileSealed), peripheralID: peripheralID)
        let sealedURL = OmiLaunchCaptureFormat.fileURL(rootURL: self.captureRoot, generationID: sealedGenerationID)
        XCTAssertEqual(Self.occurrences(of: whileSealed, in: try Data(contentsOf: sealedURL)), 1)
        try await transferTestWaitFor("reserved arm retry") {
            await MainActor.run { clock.pendingSleeperCount == 1 }
        }
        clock.advance(by: 1)
        try await transferTestWaitFor("second reserved arm retry") {
            await MainActor.run { armAttempts == 2 && clock.pendingSleeperCount == 1 }
        }
        clock.advance(by: 1)
        try await transferTestWaitFor("reserved arm recovered") {
            await MainActor.run {
                manager.activeLaunchCaptureGenerationID == intent.reservedGenerationID
            }
        }

        let afterRetry = Data("after-reserved-arm-retry".utf8)
        manager.handleAudioData(.payload(afterRetry), peripheralID: peripheralID)
        let reservedURL = OmiLaunchCaptureFormat.fileURL(
            rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: self.captureRoot),
            generationID: intent.reservedGenerationID
        )
        XCTAssertEqual(Self.occurrences(of: afterRetry, in: try Data(contentsOf: sealedURL)), 0)
        XCTAssertEqual(Self.occurrences(of: afterRetry, in: try Data(contentsOf: reservedURL)), 1)
        XCTAssertEqual(OmiLaunchCaptureCutReservationStore(rootURL: self.captureRoot, io: io).read(), .valid(intent))
    }

    @MainActor func testPersistentReservedIngressArmFailureStopsWithDurableAttention() async throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let defaults = self.defaults(enabled: true)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let sealedGenerationID = UUID()
        let manager = OmiSourceManager(
            defaults: defaults,
            diagnostics: self.diagnostics(),
            clock: clock,
            bluetoothPort: MockOmiBluetoothPort(),
            launchCaptureIngress: OmiLaunchCaptureIngress(
                captureRoot: { self.captureRoot },
                generationID: sealedGenerationID,
                clock: clock,
                io: io
            )
        )
        manager.enable()
        let peripheralID = UUID()
        manager.handleAudioData(.payload(Self.marker(packet: 0, epoch: 2_000)), peripheralID: peripheralID)
        manager.handleAudioData(.payload(Self.packet(1, index: 0, body: try Self.opusFrame())), peripheralID: peripheralID)

        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("persistent-arm-transfer", isDirectory: true))
        try await harness.engine.initialize()
        var armAttempts = 0
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: self.captureRoot,
            engine: harness.engine,
            sourceManager: manager,
            io: io,
            clock: clock,
            onReconciliationPhase: { phase in
                guard phase == .afterCutIntentCommittedBeforeRouteSwap else { return }
                armAttempts += 1
                io.failNext(.open)
            }
        )

        await coordinator.reconcile()
        for expectedAttempt in 2...3 {
            try await transferTestWaitFor("persistent arm retry \(expectedAttempt)") {
                await MainActor.run { clock.pendingSleeperCount == 1 }
            }
            clock.advance(by: 1)
            try await transferTestWaitFor("persistent arm attempt \(expectedAttempt)") {
                await MainActor.run { armAttempts == expectedAttempt }
            }
        }
        try await transferTestWaitFor("persistent arm attention") {
            let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
            return snapshots.filter {
                $0.manifest.attention?.reason == "launch_capture_cut_reservation_arm_failed"
            }.count == 1
        }
        XCTAssertEqual(clock.pendingSleeperCount, 0)
        XCTAssertEqual(manager.activeLaunchCaptureGenerationID, sealedGenerationID)
        XCTAssertEqual(OmiLaunchCaptureCutFinalStore(rootURL: self.captureRoot, io: io).read(), .absent)

        let retained = Data("persistent-arm-retained-on-sealed".utf8)
        manager.handleAudioData(.payload(retained), peripheralID: peripheralID)
        let sealedURL = OmiLaunchCaptureFormat.fileURL(rootURL: self.captureRoot, generationID: sealedGenerationID)
        XCTAssertEqual(Self.occurrences(of: retained, in: try Data(contentsOf: sealedURL)), 1)

        await coordinator.reconcile()
        XCTAssertEqual(armAttempts, 3)
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(
            snapshots.filter { $0.manifest.attention?.reason == "launch_capture_cut_reservation_arm_failed" }.count,
            1
        )
    }

    @MainActor func testRestartAfterReservedAppendPreservesCutClassificationAndEvidenceSides() async throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let defaults = self.defaults(enabled: true)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let generation = UUID()
        let ingress = OmiLaunchCaptureIngress(captureRoot: { self.captureRoot }, generationID: generation, clock: clock, io: io)
        let manager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: ingress)
        manager.enable()
        let peripheralID = UUID()
        let tagA = Self.packet(1, index: 0, body: try Self.opusFrame())
        manager.handleAudioData(.payload(Self.marker(packet: 0, epoch: 2_000)), peripheralID: peripheralID)
        manager.handleAudioData(.payload(tagA), peripheralID: peripheralID)
        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("transfer", isDirectory: true))
        try await harness.engine.initialize()
        let coordinator = OmiLaunchCaptureCommitCoordinator(rootURL: self.captureRoot, engine: harness.engine, sourceManager: manager, io: io)
        await coordinator.reconcile()
        let reservationURL = OmiLaunchCaptureCutReservationFormat.fileURL(rootURL: self.captureRoot)
        try await transferTestWaitFor("cut reservation") { FileManager.default.fileExists(atPath: reservationURL.path) }
        guard case .valid(let committed) = OmiLaunchCaptureCutReservationStore(rootURL: self.captureRoot, io: io).read() else { return XCTFail("cut reservation was not readable") }
        let tagB = Data("reserved-after-cut-B".utf8)
        manager.handleAudioData(.payload(tagB), peripheralID: peripheralID)
        try io.restoreLastSynchronizedState()
        let freshIngress = OmiLaunchCaptureIngress(captureRoot: { self.captureRoot }, generationID: generation, clock: clock, io: io)
        let freshManager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: freshIngress)
        _ = OmiLaunchCaptureCommitCoordinator(rootURL: self.captureRoot, engine: harness.engine, sourceManager: freshManager, io: io)
        guard case .valid(let reopened) = OmiLaunchCaptureCutReservationStore(rootURL: self.captureRoot, io: io).read() else { return XCTFail("reservation was not readable after restart") }
        XCTAssertEqual(reopened, committed)
        XCTAssertEqual(freshManager.activeLaunchCaptureGenerationID, committed.reservedGenerationID)
        let sealedBytes = try Data(contentsOf: OmiLaunchCaptureFormat.fileURL(rootURL: self.captureRoot, generationID: generation))
        let reservedURL = OmiLaunchCaptureFormat.fileURL(rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: self.captureRoot), generationID: committed.reservedGenerationID)
        let reservedBytes = try Data(contentsOf: reservedURL)
        XCTAssertEqual(Self.occurrences(of: tagA, in: reservedBytes), 0)
        XCTAssertEqual(Self.occurrences(of: tagB, in: sealedBytes), 0)
        XCTAssertEqual(Self.occurrences(of: tagB, in: reservedBytes), 1)
    }

    @MainActor func testCutReservationTempWriteFailureLeavesNoClaimOrTemporaryFile() throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let defaults = self.defaults(enabled: true)
        let generation = UUID()
        let manager = OmiSourceManager(
            defaults: defaults,
            diagnostics: self.diagnostics(),
            clock: MockObserverClock(now: Date(timeIntervalSince1970: 100)),
            bluetoothPort: MockOmiBluetoothPort(),
            launchCaptureIngress: OmiLaunchCaptureIngress(captureRoot: { self.captureRoot }, generationID: generation, io: io)
        )
        manager.enable()
        let peripheralID = UUID()
        let sealedTag = Data("sealed-before-write-failure".utf8)
        manager.handleAudioData(.payload(sealedTag), peripheralID: peripheralID)
        let reader = OmiLaunchCaptureLeaseReader(rootURL: self.captureRoot, generationID: generation, io: io)
        let sealedURL = reader.fileURL
        let bytesBefore = try Data(contentsOf: sealedURL)
        let leaseBefore = reader.lease(from: .init(generationID: generation, nextSequence: 0, offset: 0))
        let reservation = OmiLaunchCaptureCutReservation(
            sealedGenerationID: generation,
            reservedGenerationID: UUID()
        )
        let store = OmiLaunchCaptureCutReservationStore(rootURL: self.captureRoot, io: io)
        io.failWrite(onCall: 1, afterBytes: 0)
        XCTAssertEqual(store.commit(reservation), .refused(.writeFailed))
        XCTAssertEqual(store.read(), .absent)
        XCTAssertEqual(try Data(contentsOf: sealedURL), bytesBefore)
        XCTAssertEqual(reader.lease(from: .init(generationID: generation, nextSequence: 0, offset: 0)), leaseBefore)
        let entries = try FileManager.default.contentsOfDirectory(at: self.captureRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.map(\.lastPathComponent), [sealedURL.lastPathComponent])
        XCTAssertFalse(entries.contains { $0.pathExtension == "tmp" })
        manager.handleAudioData(.payload(Data("sealed-after-write-failure".utf8)), peripheralID: peripheralID)
        XCTAssertGreaterThan(try io.fileSize(at: sealedURL), bytesBefore.count)
        XCTAssertEqual(manager.activeLaunchCaptureGenerationID, generation)
    }

    @MainActor func testProcessDeathBeforeReservationCommitReopensOrdinaryCaptureRoute() async throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let defaults = self.defaults(enabled: true)
        let generation = UUID()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let manager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: OmiLaunchCaptureIngress(captureRoot: { self.captureRoot }, generationID: generation, clock: clock, io: io))
        manager.enable()
        let peripheralID = UUID()
        manager.handleAudioData(.payload(Data("sealed-before-death".utf8)), peripheralID: peripheralID)
        let sealedURL = OmiLaunchCaptureFormat.fileURL(rootURL: self.captureRoot, generationID: generation)
        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("transfer", isDirectory: true))
        try await harness.engine.initialize()
        io.failReplace(at: OmiLaunchCaptureCutReservationFormat.fileURL(rootURL: self.captureRoot), fromCall: 1)
        await OmiLaunchCaptureCommitCoordinator(rootURL: self.captureRoot, engine: harness.engine, sourceManager: manager, io: io).reconcile()
        try io.restoreLastSynchronizedState()
        let freshManager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: OmiLaunchCaptureIngress(captureRoot: { self.captureRoot }, generationID: generation, clock: clock, io: io))
        _ = OmiLaunchCaptureCommitCoordinator(rootURL: self.captureRoot, engine: harness.engine, sourceManager: freshManager, io: io)
        XCTAssertEqual(OmiLaunchCaptureCutReservationStore(rootURL: self.captureRoot, io: io).read(), .absent)
        XCTAssertEqual(freshManager.activeLaunchCaptureGenerationID, generation)
        let bytesBefore = try Data(contentsOf: sealedURL)
        freshManager.enable()
        freshManager.handleAudioData(.payload(Data("sealed-after-death".utf8)), peripheralID: peripheralID)
        XCTAssertGreaterThan(try io.fileSize(at: sealedURL), bytesBefore.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: self.captureRoot).path))
    }

    @MainActor func testReservedAppendWriteFailureTriggersFlowControlWithoutTransportOwner() async throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let world = try await self.makeReservedCaptureWorld(io: io)
        let snapshots = await world.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        let payload = Data("reserved-write-failure".utf8)
        io.failNext(.write)
        world.manager.handleAudioData(.payload(payload), peripheralID: world.peripheralID)
        XCTAssertTrue(world.manager.writerFaulted)
        let snapshotsAfter = await world.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshotsAfter, snapshots)
        XCTAssertEqual(Self.occurrences(of: payload, in: try Data(contentsOf: world.sealedURL)), 0)
        XCTAssertEqual(Self.occurrences(of: payload, in: try Data(contentsOf: world.reservedURL)), 0)
    }

    @MainActor func testReservedAppendBarrierFailureTriggersFlowControlWithoutTransportOwner() async throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let world = try await self.makeReservedCaptureWorld(io: io)
        let snapshots = await world.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        let payload = Data("reserved-barrier-failure".utf8)
        io.failNext(.barrier)
        world.manager.handleAudioData(.payload(payload), peripheralID: world.peripheralID)
        XCTAssertTrue(world.manager.writerFaulted)
        let snapshotsAfter = await world.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshotsAfter, snapshots)
        XCTAssertEqual(Self.occurrences(of: payload, in: try Data(contentsOf: world.sealedURL)), 0)
        XCTAssertEqual(Self.occurrences(of: payload, in: try Data(contentsOf: world.reservedURL)), 0)
    }

    @MainActor func testReservedOverLimitPayloadTriggersFlowControlWithoutTransportOwner() async throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let world = try await self.makeReservedCaptureWorld(io: io)
        let snapshots = await world.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        let payload = Data(repeating: 0x5a, count: OmiLaunchCaptureFormat.maximumPayloadBytes + 1)
        world.manager.handleAudioData(.payload(payload), peripheralID: world.peripheralID)
        XCTAssertTrue(world.manager.writerFaulted)
        let snapshotsAfter = await world.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshotsAfter, snapshots)
        XCTAssertEqual(Self.occurrences(of: payload, in: try Data(contentsOf: world.sealedURL)), 0)
        XCTAssertEqual(Self.occurrences(of: payload, in: try Data(contentsOf: world.reservedURL)), 0)
    }

    @MainActor func testDisableAroundCutPreservesReservationAndExplicitEnableDoesNotMoveIt() async throws {
        let beforeIO = FaultInjectingOmiLaunchCaptureIO()
        let defaults = self.defaults(enabled: true)
        let generation = UUID()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let beforeManager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: OmiLaunchCaptureIngress(captureRoot: { self.captureRoot }, generationID: generation, clock: clock, io: beforeIO))
        beforeManager.enable()
        beforeManager.handleAudioData(.payload(Data("disable-before-cut".utf8)), peripheralID: UUID())
        let beforeHarness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("before-transfer", isDirectory: true))
        try await beforeHarness.engine.initialize()
        beforeManager.disable()
        await OmiLaunchCaptureCommitCoordinator(rootURL: self.captureRoot, engine: beforeHarness.engine, sourceManager: beforeManager, io: beforeIO).reconcile()
        XCTAssertEqual(OmiLaunchCaptureCutReservationStore(rootURL: self.captureRoot, io: beforeIO).read(), .absent)
        XCTAssertEqual(beforeManager.activeLaunchCaptureGenerationID, generation)

        let world = try await self.makeReservedCaptureWorld(io: FaultInjectingOmiLaunchCaptureIO(), rootURL: self.rootURL.appendingPathComponent("after", isDirectory: true))
        let tag = Data("reserved-before-disable".utf8)
        world.manager.handleAudioData(.payload(tag), peripheralID: world.peripheralID)
        let sealedBytes = try Data(contentsOf: world.sealedURL)
        let reservationBytes = try Data(contentsOf: OmiLaunchCaptureCutReservationFormat.fileURL(rootURL: world.captureRoot))
        let reservedBytes = try Data(contentsOf: world.reservedURL)
        let passes = CutoverPassCounter()
        world.manager.onLaunchCaptureExplicitEnable = { await passes.increment() }
        world.manager.disable()
        world.manager.handleAudioData(.payload(Data("ignored-while-disabled".utf8)), peripheralID: world.peripheralID)
        XCTAssertEqual(try Data(contentsOf: world.sealedURL), sealedBytes)
        XCTAssertEqual(try Data(contentsOf: OmiLaunchCaptureCutReservationFormat.fileURL(rootURL: world.captureRoot)), reservationBytes)
        XCTAssertEqual(try Data(contentsOf: world.reservedURL), reservedBytes)
        world.manager.enable()
        try await transferTestWaitFor("single explicit enable callback") { await passes.count() == 1 }
        let explicitEnablePasses = await passes.count()
        XCTAssertEqual(explicitEnablePasses, 1)
        XCTAssertEqual(OmiLaunchCaptureCutReservationStore(rootURL: world.captureRoot, io: world.io).read(), .valid(world.reservation))
    }

    @MainActor func testSealedOwnersSendBeforeReservedOwnersInExactOrder() async throws {
        let frame = try Self.opusFrame()
        let world = try await self.driveCutLifecycle(
            sealedCallbacks: [Self.marker(packet: 0, epoch: 2_000), Self.packet(1, index: 0, body: frame)],
            reservedCallbacks: [Self.packet(2, index: 0, body: frame)]
        )
        let sealedIDs = try Self.materializedIDs(rootURL: world.captureRoot, generationID: world.sealedGenerationID)
        let reservedIDs = try Self.materializedIDs(rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: world.captureRoot), generationID: world.reservedGenerationID)
        XCTAssertNil(world.finalBeforeSealedSpoolDrain)
        XCTAssertTrue(reservedIDs.isDisjoint(with: world.preFinalOmiItemIDs))
        XCTAssertTrue(reservedIDs.isDisjoint(with: Set(world.requestIDsBeforeFinal)))
        XCTAssertTrue(world.requestIDsBeforeFinal.contains(world.controlItemID))
        try await transferTestWaitFor("reserved delivery") {
            reservedIDs.allSatisfy { Self.requestIDs().contains($0) }
        }
        let requests = Self.requestIDs()
        XCTAssertFalse(sealedIDs.isEmpty)
        XCTAssertFalse(reservedIDs.isEmpty)
        XCTAssertTrue(requests.contains(world.controlItemID))
        XCTAssertTrue(sealedIDs.allSatisfy { requests.contains($0) })
        for sealed in sealedIDs {
            guard let sealedIndex = requests.firstIndex(of: sealed) else { return XCTFail("sealed request missing") }
            XCTAssertEqual(requests.filter { $0 == sealed }.count, 1)
            for reserved in reservedIDs {
                guard let reservedIndex = requests.firstIndex(of: reserved) else { return XCTFail("reserved request missing") }
                XCTAssertLessThan(sealedIndex, reservedIndex)
                XCTAssertEqual(requests.filter { $0 == reserved }.count, 1)
            }
        }
    }

    @MainActor func testCommittedReservedGapRemainsRetainedAcrossRetryAndRestart() async throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let sealedGenerationID = UUID()
        let reservedGenerationID = UUID()
        let sealedWriter = OmiLaunchCaptureWriter(rootURL: self.captureRoot, generationID: sealedGenerationID, io: io)
        Self.assertRetained(sealedWriter.append(Self.marker(packet: 0, epoch: 2_000)))
        let sealedEndOffset = try io.fileSize(at: sealedWriter.fileURL)
        let reservedRoot = OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: self.captureRoot)
        let reservedWriter = OmiLaunchCaptureWriter(rootURL: reservedRoot, generationID: reservedGenerationID, io: io)
        XCTAssertEqual(reservedWriter.reserveGap(), .visibleGap(sequence: 0, .intentionalGap))
        XCTAssertEqual(
            OmiLaunchCaptureCutReservationStore(rootURL: self.captureRoot, io: io).commit(
                OmiLaunchCaptureCutReservation(sealedGenerationID: sealedGenerationID, reservedGenerationID: reservedGenerationID)
            ),
            .committed
        )
        XCTAssertEqual(
            OmiLaunchCaptureCutFinalStore(rootURL: self.captureRoot, io: io).commit(
                OmiLaunchCaptureCutFinal(
                    sealedGenerationID: sealedGenerationID,
                    sealedNextSequence: 1,
                    sealedEndOffset: sealedEndOffset,
                    reservedGenerationID: reservedGenerationID
                )
            ),
            .committed
        )

        let defaults = self.defaults(enabled: true)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let manager = OmiSourceManager(
            defaults: defaults,
            diagnostics: self.diagnostics(),
            clock: clock,
            bluetoothPort: MockOmiBluetoothPort(),
            launchCaptureIngress: OmiLaunchCaptureIngress(captureRoot: { self.captureRoot }, generationID: sealedGenerationID, clock: clock, io: io)
        )
        manager.enable()
        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("gap-transfer", isDirectory: true))
        try await harness.engine.initialize()
        let controlID = UUID()
        var control = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: controlID,
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 99, startedAt: Date())
        )
        control.source = "unrelated"
        control.priority = TransferPriorityInputs(sourceKey: "unrelated")
        _ = try await harness.engine.enqueue(manifest: control, payloads: ["audio": Data("control".utf8)])
        let coordinator = OmiLaunchCaptureCommitCoordinator(rootURL: self.captureRoot, engine: harness.engine, sourceManager: manager, io: io)
        await coordinator.reconcile()
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("gap control delivery") { Self.requestIDs().contains(controlID) }

        let reader = OmiLaunchCaptureLeaseReader(rootURL: reservedRoot, generationID: reservedGenerationID, io: io)
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        let attention = try XCTUnwrap(snapshots.first { $0.manifest.attention?.reason == "launch_capture_boundary" })
        XCTAssertTrue(attention.manifest.payloadParts.isEmpty)
        XCTAssertEqual(reader.acknowledgedPosition(), OmiLaunchCaptureReadPosition(generationID: reservedGenerationID, nextSequence: 0, offset: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reservedWriter.fileURL.path))
        XCTAssertFalse(Self.requestIDs().contains(attention.itemID))

        let stableAttentionID = attention.itemID
        try io.restoreLastSynchronizedState()
        let restartedHarness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("gap-transfer", isDirectory: true))
        try await restartedHarness.engine.initialize()
        let restartedManager = OmiSourceManager(
            defaults: defaults,
            diagnostics: self.diagnostics(),
            clock: clock,
            bluetoothPort: MockOmiBluetoothPort(),
            launchCaptureIngress: OmiLaunchCaptureIngress(captureRoot: { self.captureRoot }, generationID: sealedGenerationID, clock: clock, io: io)
        )
        restartedManager.enable()
        let restarted = OmiLaunchCaptureCommitCoordinator(rootURL: self.captureRoot, engine: restartedHarness.engine, sourceManager: restartedManager, io: io)
        await restarted.reconcile()
        await restarted.reconcile()
        let restartedSnapshots = await restartedHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(restartedSnapshots.filter { $0.manifest.attention?.reason == "launch_capture_boundary" }.map(\.itemID), [stableAttentionID])
        XCTAssertEqual(OmiLaunchCaptureLeaseReader(rootURL: reservedRoot, generationID: reservedGenerationID, io: io).acknowledgedPosition(), OmiLaunchCaptureReadPosition(generationID: reservedGenerationID, nextSequence: 0, offset: 0))
        await restartedHarness.engine.enableDispatch()
        XCTAssertFalse(Self.requestIDs().contains(stableAttentionID))
    }

    @MainActor func testRestartAtEachCutLifecyclePhaseReconstructsStableOwnersBeforeDispatch() async throws {
        let phases: [OmiLaunchCaptureCommitCoordinator.ReconciliationPhase] = [
            .afterSealedOwnerGatedEnqueued,
            .afterSealedOwnershipVerified,
            .afterSealedCursorAcknowledged,
            .afterSealedEnvelopeCleaned,
            .beforeSealedOwnerReleased,
            .afterSealedOwnerReleased,
            .afterFinalMarkerCommittedBeforeReservedMaterialization,
            .beforeReservedOwnerReleased,
            .afterReservedOwnerReleased,
        ]

        for phase in phases {
            CutoverTransferURLProtocol.reset()
            let baseRoot = self.rootURL.appendingPathComponent("restart-\(String(describing: phase))", isDirectory: true)
            let captureRoot = baseRoot.appendingPathComponent(OmiLaunchCaptureFormat.rootDirectoryName, isDirectory: true)
            let transferRoot = baseRoot.appendingPathComponent("transfer", isDirectory: true)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let defaults = self.defaults(enabled: true)
            let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
            let sealedGenerationID = UUID()
            let manager = OmiSourceManager(
                defaults: defaults,
                diagnostics: OmiDiagnostics(fileURL: baseRoot.appendingPathComponent("diagnostics.json")),
                clock: clock,
                bluetoothPort: MockOmiBluetoothPort(),
                launchCaptureIngress: OmiLaunchCaptureIngress(captureRoot: { captureRoot }, generationID: sealedGenerationID, clock: clock, io: io)
            )
            manager.enable()
            let peripheralID = UUID()
            let frame = try Self.opusFrame()
            manager.handleAudioData(.payload(Self.marker(packet: 0, epoch: 2_000)), peripheralID: peripheralID)
            manager.handleAudioData(.payload(Self.packet(1, index: 0, body: frame)), peripheralID: peripheralID)
            let first = self.makeHarness(rootURL: transferRoot)
            try await first.engine.initialize()
            let controlID = UUID()
            var control = ObserverAudioTransferEnqueuer.makeOmiManifest(
                itemID: controlID,
                sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 99, startedAt: Date())
            )
            control.source = "unrelated"
            control.priority = TransferPriorityInputs(sourceKey: "unrelated")
            _ = try await first.engine.enqueue(manifest: control, payloads: ["audio": Data("control".utf8)])
            await first.engine.enableDispatch()
            try await transferTestWaitFor("restart control \(String(describing: phase))") { Self.requestIDs().contains(controlID) }

            let barrier = CutoverBarrier()
            let coordinator = OmiLaunchCaptureCommitCoordinator(
                rootURL: captureRoot,
                engine: first.engine,
                sourceManager: manager,
                io: io,
                onReconciliationPhase: { observed in
                    if observed == .afterCutIntentCommittedBeforeRouteSwap,
                       case .valid(let intent) = OmiLaunchCaptureCutReservationStore(rootURL: captureRoot, io: io).read() {
                        // The normal route mutation follows this observation point.
                        // Perform the same synchronous mutation in the fixture so
                        // the later reserved-release window has nonempty evidence.
                        _ = manager.completeLaunchCaptureCutover(
                            intent,
                            ingress: OmiLaunchCaptureIngress(
                                captureRoot: { OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: captureRoot) },
                                generationID: intent.reservedGenerationID,
                                clock: clock,
                                io: io
                            )
                        )
                        manager.handleAudioData(.payload(Self.packet(2, index: 0, body: frame)), peripheralID: peripheralID)
                    }
                    if observed == phase { await barrier.suspend() }
                }
            )
            let pass = Task { @MainActor in await coordinator.reconcile() }
            try await transferTestWaitFor("parked cut lifecycle \(String(describing: phase))") { await barrier.waiting() }

            try io.restoreLastSynchronizedState()
            let requestsBeforeRestart = Self.requestIDs()

            let restarted = self.makeHarness(rootURL: transferRoot)
            try await restarted.engine.initialize()
            let freshManager = OmiSourceManager(
                defaults: defaults,
                diagnostics: OmiDiagnostics(fileURL: baseRoot.appendingPathComponent("fresh-diagnostics.json")),
                clock: clock,
                bluetoothPort: MockOmiBluetoothPort(),
                launchCaptureIngress: OmiLaunchCaptureIngress(captureRoot: { captureRoot }, generationID: sealedGenerationID, clock: clock, io: io)
            )
            freshManager.enable()
            let fresh = OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: restarted.engine, sourceManager: freshManager, io: io)
            await fresh.reconcile()
            guard case .valid(let intent) = OmiLaunchCaptureCutReservationStore(rootURL: captureRoot, io: io).read() else {
                XCTFail("intent must reconstruct at \(String(describing: phase))")
                await barrier.resume()
                await pass.value
                continue
            }
            XCTAssertEqual(freshManager.activeLaunchCaptureGenerationID, intent.reservedGenerationID, "\(phase)")
            XCTAssertEqual(Self.requestIDs(), requestsBeforeRestart, "fresh reconciliation must finish before eager dispatch at \(phase)")

            await restarted.engine.enableDispatch()
            await fresh.reconcile()
            try await transferTestWaitFor("restarted reserved materialization \(String(describing: phase))") {
                guard let reserved = try? Self.materializedIDs(
                    rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: captureRoot),
                    generationID: intent.reservedGenerationID
                ) else { return false }
                return !reserved.isEmpty
            }
            try await transferTestWaitFor("restarted cut lifecycle delivery \(String(describing: phase))") {
                let sealed = try? Self.materializedIDs(rootURL: captureRoot, generationID: sealedGenerationID)
                let reserved = try? Self.materializedIDs(
                    rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: captureRoot),
                    generationID: intent.reservedGenerationID
                )
                let expected = (sealed ?? []).union(reserved ?? [])
                return !expected.isEmpty && expected.isSubset(of: Set(Self.requestIDs()))
            }
            let sealedIDs = try Self.materializedIDs(rootURL: captureRoot, generationID: sealedGenerationID)
            let reservedIDs = try Self.materializedIDs(
                rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: captureRoot),
                generationID: intent.reservedGenerationID
            )
            let expectedIDs = sealedIDs.union(reservedIDs)
            XCTAssertFalse(sealedIDs.isEmpty, "\(phase)")
            XCTAssertFalse(reservedIDs.isEmpty, "\(phase)")
            for itemID in expectedIDs {
                XCTAssertEqual(Self.requestIDs().filter { $0 == itemID }.count, 1, "\(phase)")
            }
            let requestIDs = Self.requestIDs()
            let lastSealed = try XCTUnwrap(sealedIDs.compactMap { requestIDs.lastIndex(of: $0) }.max(), "\(phase)")
            let firstReserved = try XCTUnwrap(reservedIDs.compactMap { requestIDs.firstIndex(of: $0) }.min(), "\(phase)")
            XCTAssertLessThan(lastSealed, firstReserved, "\(phase)")

            await barrier.resume()
            await pass.value
        }
    }

    @MainActor func testDisableDuringSealedSettlementAndBeforeReservedReleasePreservesBothEvidenceSides() async throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let sealedGenerationID = UUID()
        let defaults = self.defaults(enabled: true)
        let manager = OmiSourceManager(
            defaults: defaults,
            diagnostics: self.diagnostics(),
            clock: clock,
            bluetoothPort: MockOmiBluetoothPort(),
            launchCaptureIngress: OmiLaunchCaptureIngress(captureRoot: { self.captureRoot }, generationID: sealedGenerationID, clock: clock, io: io)
        )
        manager.enable()
        let frame = try Self.opusFrame()
        let peripheralID = UUID()
        manager.handleAudioData(.payload(Self.marker(packet: 0, epoch: 2_000)), peripheralID: peripheralID)
        manager.handleAudioData(.payload(Self.packet(1, index: 0, body: frame)), peripheralID: peripheralID)
        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("disable-lifecycle-transfer", isDirectory: true))
        try await harness.engine.initialize()
        let controlID = UUID()
        var control = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: controlID,
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 99, startedAt: Date())
        )
        control.source = "unrelated"
        control.priority = TransferPriorityInputs(sourceKey: "unrelated")
        _ = try await harness.engine.enqueue(manifest: control, payloads: ["audio": Data("control".utf8)])
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("disable lifecycle control") { Self.requestIDs().contains(controlID) }

        var disabledDuringSealedSettlement = false
        var disabledBeforeReservedRelease = false
        let reservedDisablePasses = CutoverPassCounter()
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: self.captureRoot,
            engine: harness.engine,
            sourceManager: manager,
            io: io,
            onReconciliationPhase: { phase in
                if phase == .afterCutIntentCommittedBeforeRouteSwap,
                   case .valid(let intent) = OmiLaunchCaptureCutReservationStore(rootURL: self.captureRoot, io: io).read() {
                    _ = manager.completeLaunchCaptureCutover(
                        intent,
                        ingress: OmiLaunchCaptureIngress(
                            captureRoot: { OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: self.captureRoot) },
                            generationID: intent.reservedGenerationID,
                            clock: clock,
                            io: io
                        )
                    )
                    manager.handleAudioData(.payload(Self.packet(2, index: 0, body: frame)), peripheralID: peripheralID)
                }
                if phase == .beforeSealedOwnerReleased, !disabledDuringSealedSettlement {
                    disabledDuringSealedSettlement = true
                    manager.disable()
                }
                if phase == .beforeReservedOwnerReleased, !disabledBeforeReservedRelease {
                    disabledBeforeReservedRelease = true
                    manager.disable()
                    await reservedDisablePasses.increment()
                }
            }
        )
        manager.onLaunchCaptureExplicitEnable = { await coordinator.resumeAfterExplicitEnable() }

        await coordinator.reconcile()
        XCTAssertTrue(disabledDuringSealedSettlement)
        XCTAssertTrue(Self.requestIDs().contains(controlID))
        XCTAssertEqual(Self.requestIDs().filter { $0 != controlID }.count, 0, "the live control proves dispatch is enabled while the sealed owner is ineligible")
        guard case .valid(let intent) = OmiLaunchCaptureCutReservationStore(rootURL: self.captureRoot, io: io).read() else {
            return XCTFail("cut intent was not readable")
        }
        let sealedURL = OmiLaunchCaptureFormat.fileURL(rootURL: self.captureRoot, generationID: sealedGenerationID)
        let reservedRoot = OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: self.captureRoot)
        let reservedURL = OmiLaunchCaptureFormat.fileURL(rootURL: reservedRoot, generationID: intent.reservedGenerationID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reservedURL.path))

        manager.enable()
        try await transferTestWaitFor("disable before reserved release") { await reservedDisablePasses.count() == 1 }
        let reservedIDsBeforeEnable = try Self.materializedIDs(rootURL: reservedRoot, generationID: intent.reservedGenerationID)
        XCTAssertFalse(reservedIDsBeforeEnable.isEmpty)
        XCTAssertTrue(reservedIDsBeforeEnable.isDisjoint(with: Set(Self.requestIDs())))
        XCTAssertEqual(Self.requestIDs().filter { $0 != controlID }.count, 1, "only the sealed owner may have sent before the reserved-side enable")

        manager.enable()
        try await transferTestWaitFor("reserved delivery after explicit enable") {
            guard let reservedIDs = try? Self.materializedIDs(rootURL: reservedRoot, generationID: intent.reservedGenerationID) else {
                return false
            }
            return !reservedIDs.isEmpty && reservedIDs.isSubset(of: Set(Self.requestIDs()))
        }
        let sealedIDs = try Self.materializedIDs(rootURL: self.captureRoot, generationID: sealedGenerationID)
        let reservedIDs = try Self.materializedIDs(rootURL: reservedRoot, generationID: intent.reservedGenerationID)
        XCTAssertFalse(sealedIDs.isEmpty)
        XCTAssertFalse(reservedIDs.isEmpty)
        for itemID in sealedIDs.union(reservedIDs) {
            XCTAssertEqual(Self.requestIDs().filter { $0 == itemID }.count, 1)
        }
    }

    @MainActor func testLateDisablePreservesOwnerLinkAcrossRestartUntilExplicitEnable() async throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let sealedGenerationID = UUID()
        let defaults = self.defaults(enabled: true)
        let manager = OmiSourceManager(
            defaults: defaults,
            diagnostics: self.diagnostics(),
            clock: clock,
            bluetoothPort: MockOmiBluetoothPort(),
            launchCaptureIngress: OmiLaunchCaptureIngress(
                captureRoot: { self.captureRoot },
                generationID: sealedGenerationID,
                clock: clock,
                io: io
            )
        )
        manager.enable()
        let peripheralID = UUID()
        manager.handleAudioData(.payload(Self.marker(packet: 0, epoch: 2_000)), peripheralID: peripheralID)
        manager.handleAudioData(.payload(Self.packet(1, index: 0, body: try Self.opusFrame())), peripheralID: peripheralID)

        let transferRoot = self.rootURL.appendingPathComponent("late-disable-restart-transfer", isDirectory: true)
        let firstHarness = self.makeHarness(rootURL: transferRoot)
        try await firstHarness.engine.initialize()
        await firstHarness.engine.enableDispatch()
        var disabledAfterCleanup = false
        let cleanupBarrier = CutoverBarrier()
        let firstCoordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: self.captureRoot,
            engine: firstHarness.engine,
            sourceManager: manager,
            io: io,
            onReconciliationPhase: { phase in
                if phase == .afterSealedEnvelopeCleaned, !disabledAfterCleanup {
                    disabledAfterCleanup = true
                    manager.disable()
                    await cleanupBarrier.suspend()
                }
            }
        )
        let firstReconciliation = Task { @MainActor in await firstCoordinator.reconcile() }
        try await transferTestWaitFor("late-disable settlement marker") { await cleanupBarrier.waiting() }
        XCTAssertTrue(disabledAfterCleanup)
        let sealedIDs = try Self.materializedIDs(rootURL: self.captureRoot, generationID: sealedGenerationID)
        XCTAssertFalse(sealedIDs.isEmpty)
        XCTAssertTrue(sealedIDs.isDisjoint(with: Set(Self.requestIDs())))
        let materializedDirectory = self.captureRoot
            .appendingPathComponent(OmiLaunchCaptureFormat.materializedDirectoryName, isDirectory: true)
            .appendingPathComponent(sealedGenerationID.uuidString, isDirectory: true)
        let retainedFiles = try FileManager.default.contentsOfDirectory(
            at: materializedDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(retainedFiles.contains(where: OmiPendingHandoffStore.isSettlementURL))

        // A new engine has no process-local hold or gate. Reconcile while the
        // source remains disabled, then prove unrelated dispatch can open.
        let restartedHarness = self.makeHarness(rootURL: transferRoot)
        try await restartedHarness.engine.initialize()
        let restartedManager = OmiSourceManager(
            defaults: defaults,
            diagnostics: self.diagnostics(),
            clock: clock,
            bluetoothPort: MockOmiBluetoothPort(),
            launchCaptureIngress: OmiLaunchCaptureIngress(
                captureRoot: { self.captureRoot },
                generationID: sealedGenerationID,
                clock: clock,
                io: io
            )
        )
        let restartedCoordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: self.captureRoot,
            engine: restartedHarness.engine,
            sourceManager: restartedManager,
            io: io
        )
        restartedManager.onLaunchCaptureExplicitEnable = {
            await restartedCoordinator.resumeAfterExplicitEnable()
        }
        await restartedCoordinator.reconcile()
        let controlID = UUID()
        var control = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: controlID,
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 99, startedAt: Date())
        )
        control.source = "unrelated"
        control.priority = TransferPriorityInputs(sourceKey: "unrelated")
        _ = try await restartedHarness.engine.enqueue(manifest: control, payloads: ["audio": Data("control".utf8)])
        await restartedHarness.engine.enableDispatch()
        try await transferTestWaitFor("restart control delivery") { Self.requestIDs().contains(controlID) }
        XCTAssertTrue(sealedIDs.isDisjoint(with: Set(Self.requestIDs())))

        restartedManager.enable()
        try await transferTestWaitFor("late-disable owner delivery after restart") {
            sealedIDs.isSubset(of: Set(Self.requestIDs()))
        }
        for itemID in sealedIDs {
            XCTAssertEqual(Self.requestIDs().filter { $0 == itemID }.count, 1)
        }
        await cleanupBarrier.resume()
        await firstReconciliation.value
        let settledFiles = try FileManager.default.contentsOfDirectory(
            at: materializedDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(settledFiles.contains { $0.pathExtension == OmiPendingHandoffEnvelope.pathExtension })
    }

    @MainActor func testHeldSealedNoProgressBoundsReservedCorpusUntilFaultRemoval() async throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let captureRoot = self.captureRoot
        let sealedGenerationID = UUID()
        let defaults = self.defaults(enabled: true)
        let manager = OmiSourceManager(
            defaults: defaults,
            diagnostics: self.diagnostics(),
            clock: clock,
            bluetoothPort: MockOmiBluetoothPort(),
            launchCaptureIngress: OmiLaunchCaptureIngress(captureRoot: { captureRoot }, generationID: sealedGenerationID, clock: clock, io: io)
        )
        manager.enable()
        let peripheralID = UUID()
        let frame = try Self.opusFrame()
        manager.handleAudioData(.payload(Self.marker(packet: 0, epoch: 2_000)), peripheralID: peripheralID)
        manager.handleAudioData(.payload(Self.packet(1, index: 0, body: frame)), peripheralID: peripheralID)
        let sealedPaths = OmiLaunchCaptureMaterializedArtifactPaths(rootURL: captureRoot, generationID: sealedGenerationID, ordinal: 0)
        io.failReplace(at: sealedPaths.audioURL, fromCall: 1)
        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("bounded-reserved-transfer", isDirectory: true))
        try await harness.engine.initialize()
        let controlID = UUID()
        var control = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: controlID,
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 99, startedAt: Date())
        )
        control.source = "unrelated"
        control.priority = TransferPriorityInputs(sourceKey: "unrelated")
        _ = try await harness.engine.enqueue(manifest: control, payloads: ["audio": Data("control".utf8)])
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("bounded reserved control") { Self.requestIDs().contains(controlID) }

        let tags = (0..<32).map { Data(String(format: "reserved-%02d", $0).utf8) }
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: manager,
            io: io,
            clock: clock,
            onReconciliationPhase: { phase in
                if phase == .afterCutIntentCommittedBeforeRouteSwap,
                   case .valid(let intent) = OmiLaunchCaptureCutReservationStore(rootURL: captureRoot, io: io).read() {
                    _ = manager.completeLaunchCaptureCutover(
                        intent,
                        ingress: OmiLaunchCaptureIngress(
                            captureRoot: { OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: captureRoot) },
                            generationID: intent.reservedGenerationID,
                            clock: clock,
                            io: io
                        )
                    )
                    for tag in tags { manager.handleAudioData(.payload(tag), peripheralID: peripheralID) }
                    manager.handleAudioData(.payload(Self.packet(99, index: 0, body: frame)), peripheralID: peripheralID)
                }
            }
        )
        await coordinator.reconcile()
        await Task.yield()
        XCTAssertEqual(clock.pendingSleeperCount, 1)
        guard case .valid(let intent) = OmiLaunchCaptureCutReservationStore(rootURL: captureRoot, io: io).read() else {
            return XCTFail("cut intent was not readable")
        }
        let reservedRoot = OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: captureRoot)
        let reservedURL = OmiLaunchCaptureFormat.fileURL(rootURL: reservedRoot, generationID: intent.reservedGenerationID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: OmiLaunchCaptureFormat.fileURL(rootURL: captureRoot, generationID: sealedGenerationID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reservedURL.path))
        XCTAssertEqual(Self.requestIDs(), [controlID], "the live control proves dispatch is enabled while the held sealed owner blocks the reserved side")

        let callsWhileHeld = io.performedIOCallCount
        await coordinator.reconcile()
        XCTAssertEqual(clock.pendingSleeperCount, 1)
        XCTAssertGreaterThanOrEqual(io.performedIOCallCount, callsWhileHeld)
        let callsAfterTrigger = io.performedIOCallCount
        await Task.yield()
        XCTAssertEqual(io.performedIOCallCount, callsAfterTrigger, "the 1-second successor is the only no-progress retry armed while the fault holds")

        io.clearFaults()
        try await transferTestWaitFor("bounded no-progress successor armed") {
            await MainActor.run { clock.pendingSleeperCount > 0 }
        }
        clock.advance(by: 1)
        try await transferTestWaitFor("bounded sealed convergence") {
            guard let sealed = try? Self.materializedIDs(rootURL: captureRoot, generationID: sealedGenerationID) else {
                return false
            }
            return !sealed.isEmpty && sealed.isSubset(of: Set(Self.requestIDs()))
        }
        // Sealed release schedules the ordinary one-second reconciliation that
        // observes spool absence and commits final evidence; it is distinct from
        // the bounded no-progress retry above.
        try await transferTestWaitFor("post-release finalization successor") {
            await MainActor.run { clock.pendingSleeperCount > 0 }
        }
        clock.advance(by: 1)
        try await transferTestWaitFor("bounded reserved materialization") {
            guard let reserved = try? Self.materializedIDs(rootURL: reservedRoot, generationID: intent.reservedGenerationID) else {
                return false
            }
            return !reserved.isEmpty
        }
        try await transferTestWaitFor("bounded reserved convergence") {
            let sealed = try? Self.materializedIDs(rootURL: captureRoot, generationID: sealedGenerationID)
            let reserved = try? Self.materializedIDs(rootURL: reservedRoot, generationID: intent.reservedGenerationID)
            let expected = (sealed ?? []).union(reserved ?? [])
            return !expected.isEmpty && expected.isSubset(of: Set(Self.requestIDs()))
        }
        let sealedIDs = try Self.materializedIDs(rootURL: captureRoot, generationID: sealedGenerationID)
        let reservedIDs = try Self.materializedIDs(rootURL: reservedRoot, generationID: intent.reservedGenerationID)
        XCTAssertFalse(sealedIDs.isEmpty)
        XCTAssertFalse(reservedIDs.isEmpty)
        for itemID in sealedIDs.union(reservedIDs) {
            XCTAssertEqual(Self.requestIDs().filter { $0 == itemID }.count, 1)
        }
    }

    @MainActor func testRecoverableSealedFaultsKeepReservedCaptureOutsideTransportUntilFinalEvidence() async throws {
        enum Fault: CaseIterable, Equatable {
            case unreadableCursor
            case orphanRepair
            case materialization
            case conservativeRescan
            case multiOwnerSettlement

            var name: String {
                switch self {
                case .unreadableCursor: "unreadable cursor"
                case .orphanRepair: "orphan repair"
                case .materialization: "middle materialization"
                case .conservativeRescan: "conservative rescan"
                case .multiOwnerSettlement: "multi-owner settlement"
                }
            }
        }

        for fault in Fault.allCases {
            CutoverTransferURLProtocol.reset()
            let io = FaultInjectingOmiLaunchCaptureIO()
            let world = try await self.makeFaultedCutLifecycleWorld(
                io: io,
                name: fault.name
            )
            let sealedReader = OmiLaunchCaptureLeaseReader(
                rootURL: world.captureRoot,
                generationID: world.sealedGenerationID,
                io: io
            )
            let validCursor = OmiLaunchCaptureCursor(
                generationID: world.sealedGenerationID,
                acknowledgedPrefixNextSequence: 0,
                acknowledgedPrefixEndOffset: 0
            ).encoded()
            let settlementFault = CutoverSettlementFault(isEnabled: fault == .multiOwnerSettlement)

            switch fault {
            case .unreadableCursor:
                try validCursor.write(to: sealedReader.cursorURL)
                var unreadable = validCursor
                unreadable[unreadable.startIndex] ^= 0xff
                try unreadable.write(to: sealedReader.cursorURL)

            case .orphanRepair:
                let decoder = try OmiOpusAudioDecoder()
                let orphan = OmiLaunchCaptureMaterializer(
                    rootURL: world.captureRoot,
                    generationID: world.sealedGenerationID,
                    io: CrashAfterFinalAudioReplaceIO(),
                    decode: { decoder.decode($0) }
                )
                XCTAssertTrue(orphan.materializeForTests().partitions.isEmpty, fault.name)
                io.failBarrier(onCall: 1)

            case .materialization:
                let failed = OmiLaunchCaptureMaterializedArtifactPaths(
                    rootURL: world.captureRoot,
                    generationID: world.sealedGenerationID,
                    ordinal: 1
                )
                io.failReplace(at: failed.audioURL, fromCall: 1)

            case .conservativeRescan:
                io.failNext(.listDirectory)

            case .multiOwnerSettlement:
                break
            }

            let coordinator = OmiLaunchCaptureCommitCoordinator(
                rootURL: world.captureRoot,
                engine: world.engine,
                sourceManager: world.manager,
                io: io,
                clock: world.clock,
                onSettlementAction: { _, action in
                    action == .release && settlementFault.shouldFail() ? .unknownToken : nil
                }
            )
            await coordinator.reconcile()
            if fault == .multiOwnerSettlement {
                // The first pass finishes the reassembled source frame; the next
                // ordinary reconciliation settles its resulting owners.
                await coordinator.reconcile()
            }

            try await transferTestWaitFor("control delivery while \(fault.name) is held") {
                Self.requestIDs().contains(world.controlItemID)
            }
            let reservedCandidateIDs = try self.reservedFrontierIDs(
                rootURL: world.reservedRoot,
                generationID: world.reservedGenerationID
            )
            XCTAssertFalse(reservedCandidateIDs.isEmpty, fault.name)
            let snapshots = await world.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
            XCTAssertTrue(
                reservedCandidateIDs.isDisjoint(with: Set(snapshots.map(\.itemID))),
                "reserved owners must remain absent while \(fault.name) holds"
            )
            XCTAssertTrue(
                Self.requestIDs().filter { reservedCandidateIDs.contains($0) }.isEmpty,
                "the live control proves dispatch is enabled; no reserved owner may send while \(fault.name) holds"
            )
            XCTAssertEqual(OmiLaunchCaptureCutFinalStore(rootURL: world.captureRoot, io: io).read(), .absent, fault.name)
            XCTAssertEqual(try Data(contentsOf: world.sealedURL), world.sealedBytes, fault.name)
            XCTAssertEqual(try Data(contentsOf: world.reservedURL), world.reservedBytes, fault.name)
            if fault == .unreadableCursor {
                let attention = try XCTUnwrap(snapshots.first {
                    $0.manifest.attention?.reason == "launch_capture_cursor_unreadable"
                })
                XCTAssertEqual(attention.manifest.payloadParts, [])
                XCTAssertEqual(attention.manifest.diskState, .attention)
                let stableAttentionID = attention.itemID
                await coordinator.reconcile()
                let repeatedSnapshots = await world.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
                XCTAssertEqual(
                    repeatedSnapshots.filter {
                        $0.manifest.attention?.reason == "launch_capture_cursor_unreadable"
                    }.map(\.itemID),
                    [stableAttentionID]
                )
            }
            if fault == .multiOwnerSettlement {
                XCTAssertGreaterThan(settlementFault.failureCount, 0, "the settlement failure must be exercised")
            }

            switch fault {
            case .unreadableCursor:
                try validCursor.write(to: sealedReader.cursorURL)
            case .orphanRepair, .materialization, .conservativeRescan:
                io.clearFaults()
            case .multiOwnerSettlement:
                settlementFault.clear()
            }

            let recovered: OmiLaunchCaptureCommitCoordinator
            if fault == .conservativeRescan {
                recovered = OmiLaunchCaptureCommitCoordinator(
                    rootURL: world.captureRoot,
                    engine: world.engine,
                    sourceManager: world.manager,
                    io: io,
                    clock: world.clock
                )
            } else {
                recovered = coordinator
            }
            for attempt in 0..<4 {
                await recovered.reconcile()
                if attempt == 0 {
                    try await transferTestWaitFor("delayed reconciliation after \(fault.name) repair") {
                        await MainActor.run { world.clock.pendingSleeperCount > 0 }
                    }
                }
                world.clock.advance(by: 1)
                await Task.yield()
            }

            try await transferTestWaitFor("sealed convergence after \(fault.name) repair") {
                guard let sealedIDs = try? Self.materializedIDs(rootURL: world.captureRoot, generationID: world.sealedGenerationID),
                      !sealedIDs.isEmpty
                else { return false }
                return sealedIDs.isSubset(of: Set(Self.requestIDs()))
            }
            let sealedIDsBeforeFinal = try Self.materializedIDs(
                rootURL: world.captureRoot,
                generationID: world.sealedGenerationID
            )
            try await transferTestWaitFor("sealed spool removal after \(fault.name) repair") {
                let snapshots = await world.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
                return sealedIDsBeforeFinal.isDisjoint(with: Set(snapshots.map(\.itemID)))
            }
            // Delivery removes the sealed owners from the spool; the next
            // ordinary reconciliation publishes final evidence before the
            // reserved root becomes eligible.
            await recovered.reconcile()
            try await transferTestWaitFor("final evidence after \(fault.name) repair") {
                if case .valid = OmiLaunchCaptureCutFinalStore(rootURL: world.captureRoot, io: io).read() {
                    return true
                }
                return false
            }
            await Task.yield()
            await recovered.reconcile()

            try await transferTestWaitFor("both capture roots converge after \(fault.name) repair") {
                guard let sealedIDs = try? Self.materializedIDs(rootURL: world.captureRoot, generationID: world.sealedGenerationID),
                      let reservedIDs = try? Self.materializedIDs(rootURL: world.reservedRoot, generationID: world.reservedGenerationID),
                      !sealedIDs.isEmpty,
                      !reservedIDs.isEmpty
                else { return false }
                return sealedIDs.union(reservedIDs).isSubset(of: Set(Self.requestIDs()))
            }
            let sealedIDs = try Self.materializedIDs(rootURL: world.captureRoot, generationID: world.sealedGenerationID)
            let reservedIDs = try Self.materializedIDs(rootURL: world.reservedRoot, generationID: world.reservedGenerationID)
            XCTAssertFalse(sealedIDs.isEmpty, fault.name)
            XCTAssertFalse(reservedIDs.isEmpty, fault.name)
            let requests = Self.requestIDs()
            for sealedID in sealedIDs {
                guard let sealedIndex = requests.firstIndex(of: sealedID) else { return XCTFail("sealed request missing: \(fault.name)") }
                XCTAssertEqual(requests.filter { $0 == sealedID }.count, 1, fault.name)
                for reservedID in reservedIDs {
                    guard let reservedIndex = requests.firstIndex(of: reservedID) else { return XCTFail("reserved request missing: \(fault.name)") }
                    XCTAssertLessThan(sealedIndex, reservedIndex, fault.name)
                    XCTAssertEqual(requests.filter { $0 == reservedID }.count, 1, fault.name)
                }
            }
        }
    }

    @MainActor func testCutoverCountingOracleEnumeratesBothRootsAtAssertTime() async throws {
        let frame = try Self.opusFrame()
        let world = try await self.driveCutLifecycle(
            sealedCallbacks: [Self.marker(packet: 0, epoch: 2_000), Self.packet(1, index: 0, body: frame)],
            reservedCallbacks: [Self.packet(2, index: 0, body: frame), Self.packet(3, index: 0, body: frame)]
        )
        XCTAssertNotNil(world.final)
        let sealedRecords = try self.allLeaseRecords(rootURL: world.captureRoot, generationID: world.sealedGenerationID)
        let sealedIDs = try self.materializationIDs(from: sealedRecords, generationID: world.sealedGenerationID)
        let reservedRoot = OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: world.captureRoot)
        let reservedRecords = try self.allLeaseRecords(rootURL: reservedRoot, generationID: world.reservedGenerationID)
        let reservedIDs = try self.materializationIDs(from: reservedRecords, generationID: world.reservedGenerationID)
        XCTAssertFalse(sealedRecords.isEmpty)
        XCTAssertFalse(reservedRecords.isEmpty)
        XCTAssertFalse(sealedIDs.isEmpty)
        XCTAssertFalse(reservedIDs.isEmpty)
        let expectedIDs = sealedIDs.union(reservedIDs)
        try await transferTestWaitFor("both-root transport discovery") {
            expectedIDs.isSubset(of: Set(Self.requestIDs()))
        }
        let requests = Self.requestIDs()
        let delivered = Set(requests).subtracting([world.controlItemID])
        XCTAssertEqual(delivered, expectedIDs)
        for itemID in expectedIDs {
            XCTAssertEqual(requests.filter { $0 == itemID }.count, 1)
        }
    }
}

private extension OmiLaunchCaptureCutoverTests {
    @MainActor struct FaultedCutLifecycleWorld {
        let manager: OmiSourceManager
        let engine: TransferEngine
        let clock: MockObserverClock
        let captureRoot: URL
        let reservedRoot: URL
        let sealedGenerationID: UUID
        let reservedGenerationID: UUID
        let controlItemID: UUID
        let sealedURL: URL
        let reservedURL: URL
        let sealedBytes: Data
        let reservedBytes: Data
    }

    @MainActor struct CutLifecycleWorld {
        let manager: OmiSourceManager
        let engine: TransferEngine
        let mirror: TransferStatusMirror
        let coordinator: OmiLaunchCaptureCommitCoordinator
        let captureRoot: URL
        let sealedGenerationID: UUID
        let reservedGenerationID: UUID
        let intent: OmiLaunchCaptureCutReservation
        let finalBeforeSealedSpoolDrain: OmiLaunchCaptureCutFinal?
        let final: OmiLaunchCaptureCutFinal?
        let peripheralID: UUID
        let controlItemID: UUID
        let preFinalOmiItemIDs: Set<UUID>
        let preFinalReservedArtifactIDs: Set<UUID>
        let requestIDsBeforeFinal: [UUID]
        let sealedBytesBeforeFinal: Data
    }

    @MainActor func driveCutLifecycle(
        sealedCallbacks: [Data],
        reservedCallbacks: [Data],
        callbacksByPhase: [OmiLaunchCaptureCommitCoordinator.ReconciliationPhase: [Data]] = [:],
        appGroupRoot: URL? = nil,
        performPreFinalProbe: Bool = true,
        onReconciliationPhase: (@MainActor @Sendable (OmiLaunchCaptureCommitCoordinator.ReconciliationPhase) async -> Void)? = nil
    ) async throws -> CutLifecycleWorld {
        let lifecycleRoot = appGroupRoot ?? self.rootURL!
        let captureRoot = lifecycleRoot.appendingPathComponent(OmiLaunchCaptureFormat.rootDirectoryName, isDirectory: true)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let sealedGenerationID = UUID()
        let ingress = OmiLaunchCaptureIngress(appGroupRoot: { lifecycleRoot }, generationID: sealedGenerationID, clock: clock)
        let manager = OmiSourceManager(defaults: self.defaults(enabled: true), diagnostics: self.diagnostics(), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: ingress)
        manager.enable()
        let peripheralID = UUID()
        for callback in sealedCallbacks { manager.handleAudioData(.payload(callback), peripheralID: peripheralID) }
        let harness = self.makeHarness(rootURL: lifecycleRoot.appendingPathComponent("lifecycle-transfer", isDirectory: true))
        try await harness.engine.initialize()
        let preFinalBarrier = CutoverBarrier()
        var didSuspendBeforeSealedRelease = false
        var injectedCallbackPhases: Set<OmiLaunchCaptureCommitCoordinator.ReconciliationPhase> = []
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: captureRoot,
            engine: harness.engine,
            sourceManager: manager,
            onReconciliationPhase: { phase in
                if phase == .afterSealedEnvelopeCleaned, !didSuspendBeforeSealedRelease {
                    didSuspendBeforeSealedRelease = true
                    await preFinalBarrier.suspend()
                }
                if injectedCallbackPhases.insert(phase).inserted {
                    for callback in callbacksByPhase[phase, default: []] {
                        manager.handleAudioData(.payload(callback), peripheralID: peripheralID)
                    }
                }
                if let onReconciliationPhase { await onReconciliationPhase(phase) }
            }
        )
        let initialPass = Task { @MainActor in await coordinator.reconcile() }
        try await transferTestWaitFor("sealed owner held before release") { await preFinalBarrier.waiting() }
        guard case .valid(let intent) = OmiLaunchCaptureCutReservationStore(rootURL: captureRoot).read() else {
            await preFinalBarrier.resume()
            await initialPass.value
            throw NSError(domain: "OmiLaunchCaptureCutoverTests", code: 2)
        }
        for callback in reservedCallbacks { manager.handleAudioData(.payload(callback), peripheralID: peripheralID) }
        let finalBeforeSealedSpoolDrain: OmiLaunchCaptureCutFinal?
        if performPreFinalProbe {
            let preFinalProbe = OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: manager)
            await preFinalProbe.reconcile()
            switch OmiLaunchCaptureCutFinalStore(rootURL: captureRoot).read() {
            case .valid(let value): finalBeforeSealedSpoolDrain = value
            case .absent, .unreadable: finalBeforeSealedSpoolDrain = nil
            }
        } else {
            finalBeforeSealedSpoolDrain = nil
        }
        let controlItemID = UUID()
        var controlManifest = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: controlItemID,
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 99, startedAt: Date())
        )
        controlManifest.source = "unrelated"
        controlManifest.priority = TransferPriorityInputs(sourceKey: "unrelated")
        _ = try await harness.engine.enqueue(manifest: controlManifest, payloads: ["audio": Data("control".utf8)])
        await harness.engine.enableDispatch()
        try await transferTestWaitFor("unrelated control delivery") { Self.requestIDs().contains(controlItemID) }
        let preFinalOmiItemIDs = Set(
            (await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi))
                .filter { $0.state != .attention }
                .map(\.itemID)
        )
        XCTAssertFalse(preFinalOmiItemIDs.isEmpty)
        let reservedRoot = OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: captureRoot)
        let preFinalReservedArtifactIDs = try Self.materializedIDs(rootURL: reservedRoot, generationID: intent.reservedGenerationID)
        let requestIDsBeforeFinal = Self.requestIDs()
        let sealedURL = OmiLaunchCaptureFormat.fileURL(rootURL: captureRoot, generationID: sealedGenerationID)
        let sealedBytesBeforeFinal = try Data(contentsOf: sealedURL)
        await preFinalBarrier.resume()
        await initialPass.value
        try await transferTestWaitFor("sealed spool drain") {
            let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
            let remainingIDs = Set(snapshots.map(\.itemID))
            return preFinalOmiItemIDs.isDisjoint(with: remainingIDs)
        }
        if finalBeforeSealedSpoolDrain == nil {
            await coordinator.reconcile()
        }
        let final: OmiLaunchCaptureCutFinal?
        switch OmiLaunchCaptureCutFinalStore(rootURL: captureRoot).read() {
        case .valid(let value): final = value
        case .absent, .unreadable: final = nil
        }
        if final != nil {
            await coordinator.reconcile()
            if !reservedCallbacks.isEmpty {
                let reservedDirectory = OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: captureRoot)
                    .appendingPathComponent(OmiLaunchCaptureFormat.materializedDirectoryName, isDirectory: true)
                    .appendingPathComponent(intent.reservedGenerationID.uuidString, isDirectory: true)
                try await transferTestWaitFor("reserved artifact materialization") {
                    guard let files = try? FileManager.default.contentsOfDirectory(at: reservedDirectory, includingPropertiesForKeys: nil) else {
                        return false
                    }
                    return files.contains { $0.pathExtension == OmiLaunchCaptureMaterializationProvenance.pathExtension }
                }
            }
        }
        return CutLifecycleWorld(
            manager: manager, engine: harness.engine, mirror: harness.mirror, coordinator: coordinator,
            captureRoot: captureRoot, sealedGenerationID: sealedGenerationID,
            reservedGenerationID: intent.reservedGenerationID, intent: intent,
            finalBeforeSealedSpoolDrain: finalBeforeSealedSpoolDrain, final: final,
            peripheralID: peripheralID, controlItemID: controlItemID,
            preFinalOmiItemIDs: preFinalOmiItemIDs,
            preFinalReservedArtifactIDs: preFinalReservedArtifactIDs,
            requestIDsBeforeFinal: requestIDsBeforeFinal,
            sealedBytesBeforeFinal: sealedBytesBeforeFinal
        )
    }

    @MainActor func makeFaultedCutLifecycleWorld(
        io: FaultInjectingOmiLaunchCaptureIO,
        name: String
    ) async throws -> FaultedCutLifecycleWorld {
        let baseRoot = self.rootURL.appendingPathComponent("faulted-cut-\(name)", isDirectory: true)
        let captureRoot = baseRoot.appendingPathComponent(OmiLaunchCaptureFormat.rootDirectoryName, isDirectory: true)
        let reservedRoot = OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: captureRoot)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let sealedGenerationID = UUID()
        let reservedGenerationID = UUID()
        let frame = try Self.opusFrame()
        let sealedWriter = OmiLaunchCaptureWriter(rootURL: captureRoot, generationID: sealedGenerationID, clock: clock, io: io)
        for sequence in 0..<3 {
            Self.assertRetained(sealedWriter.append(Self.packet(UInt16(sequence), index: 0, body: frame)))
            clock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
        }
        let reservedWriter = OmiLaunchCaptureWriter(rootURL: reservedRoot, generationID: reservedGenerationID, clock: clock, io: io)
        Self.assertRetained(reservedWriter.append(Self.packet(0, index: 0, body: frame)))
        let intent = OmiLaunchCaptureCutReservation(
            sealedGenerationID: sealedGenerationID,
            reservedGenerationID: reservedGenerationID
        )
        guard case .committed = OmiLaunchCaptureCutReservationStore(rootURL: captureRoot, io: io).commit(intent) else {
            throw NSError(domain: "OmiLaunchCaptureCutoverTests", code: 4)
        }
        let manager = OmiSourceManager(
            defaults: self.defaults(enabled: true),
            diagnostics: OmiDiagnostics(fileURL: baseRoot.appendingPathComponent("diagnostics.json")),
            clock: clock,
            bluetoothPort: MockOmiBluetoothPort(),
            launchCaptureIngress: OmiLaunchCaptureIngress(
                captureRoot: { captureRoot },
                generationID: sealedGenerationID,
                clock: clock,
                io: io
            )
        )
        manager.enable()
        let harness = self.makeHarness(rootURL: baseRoot.appendingPathComponent("transfer", isDirectory: true))
        try await harness.engine.initialize()
        let controlItemID = UUID()
        var control = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: controlItemID,
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 99, startedAt: Date())
        )
        control.source = "unrelated"
        control.priority = TransferPriorityInputs(sourceKey: "unrelated")
        _ = try await harness.engine.enqueue(manifest: control, payloads: ["audio": Data("control".utf8)])
        await harness.engine.enableDispatch()
        let sealedURL = OmiLaunchCaptureFormat.fileURL(rootURL: captureRoot, generationID: sealedGenerationID)
        let reservedURL = OmiLaunchCaptureFormat.fileURL(rootURL: reservedRoot, generationID: reservedGenerationID)
        return FaultedCutLifecycleWorld(
            manager: manager,
            engine: harness.engine,
            clock: clock,
            captureRoot: captureRoot,
            reservedRoot: reservedRoot,
            sealedGenerationID: sealedGenerationID,
            reservedGenerationID: reservedGenerationID,
            controlItemID: controlItemID,
            sealedURL: sealedURL,
            reservedURL: reservedURL,
            sealedBytes: try Data(contentsOf: sealedURL),
            reservedBytes: try Data(contentsOf: reservedURL)
        )
    }

    @MainActor func reservedFrontierIDs(rootURL: URL, generationID: UUID) throws -> Set<UUID> {
        let records = try self.allLeaseRecords(rootURL: rootURL, generationID: generationID)
        guard let first = records.first else { return [] }
        return [OmiLaunchCaptureMaterializationIdentity.itemID(
            generationID: generationID,
            partitionOrdinal: 0,
            startSequence: first.sequence,
            startSampleOffset: 0
        )]
    }

    @MainActor func allLeaseRecords(rootURL: URL, generationID: UUID) throws -> [OmiLaunchCaptureRecord] {
        let reader = OmiLaunchCaptureLeaseReader(rootURL: rootURL, generationID: generationID)
        var position = OmiLaunchCaptureReadPosition(generationID: generationID, nextSequence: 0, offset: 0)
        var records: [OmiLaunchCaptureRecord] = []
        while true {
            switch reader.lease(from: position) {
            case .lease(let lease):
                records.append(contentsOf: lease.records)
                position = OmiLaunchCaptureReadPosition(generationID: generationID, nextSequence: lease.throughSequence + 1, offset: lease.endOffset)
                if lease.endsAtVerifiedPrefix { return records }
            case .empty:
                return records
            case .unavailable:
                throw NSError(domain: "OmiLaunchCaptureCutoverTests", code: 3)
            }
        }
    }

    @MainActor func materializationIDs(from records: [OmiLaunchCaptureRecord], generationID: UUID) throws -> Set<UUID> {
        let decoder = try OmiOpusAudioDecoder()
        var reassembler = OmiAudioReassembler()
        var currentSampleCount = 0
        var currentPartitionExists = false
        var nextOrdinal = 0
        var nextSampleOffset: UInt64 = 0
        var itemIDs: Set<UUID> = []

        func consume(_ frames: [OmiReassembledFrame]) throws {
            for frame in frames {
                guard let startSequence = frame.startSequence,
                      let samples = decoder.decode(frame.data),
                      !samples.isEmpty
                else { continue }
                var remaining = samples.count
                while remaining > 0 {
                    if !currentPartitionExists {
                        itemIDs.insert(OmiLaunchCaptureMaterializationIdentity.itemID(
                            generationID: generationID,
                            partitionOrdinal: nextOrdinal,
                            startSequence: startSequence,
                            startSampleOffset: nextSampleOffset
                        ))
                        currentPartitionExists = true
                        currentSampleCount = 0
                        nextOrdinal += 1
                    }
                    let consumed = min(OmiAudioChunkFormat.sampleLimit - currentSampleCount, remaining)
                    currentSampleCount += consumed
                    nextSampleOffset += UInt64(consumed)
                    remaining -= consumed
                    if currentSampleCount == OmiAudioChunkFormat.sampleLimit {
                        currentPartitionExists = false
                    }
                }
            }
        }

        for record in records {
            let acquiredAt = Date(timeIntervalSince1970: Double(record.acquiredAtUnixMicros) / 1_000_000)
            let output = reassembler.ingest(record.payload, acquiredAt: acquiredAt, recordSequence: record.sequence)
            guard !output.discardedStartedFrame else {
                throw NSError(domain: "OmiLaunchCaptureCutoverTests", code: 5)
            }
            try consume(output.completedFrames)
        }
        try consume(reassembler.flushFinalFrame().completedFrames)
        return itemIDs
    }

    nonisolated static func materializedIDs(rootURL: URL, generationID: UUID) throws -> Set<UUID> {
        let directory = rootURL.appendingPathComponent(OmiLaunchCaptureFormat.materializedDirectoryName, isDirectory: true)
            .appendingPathComponent(generationID.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try Set(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == OmiLaunchCaptureMaterializationProvenance.pathExtension }
            .map { file in
                let value = try JSONDecoder().decode(OmiLaunchCaptureMaterializationProvenance.self, from: Data(contentsOf: file))
                return OmiLaunchCaptureMaterializationIdentity.itemID(generationID: value.generationID, partitionOrdinal: value.partitionOrdinal, startSequence: value.startSequence, startSampleOffset: value.startSampleOffset)
            })
    }

    nonisolated static func requestIDs() -> [UUID] {
        CutoverTransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:))
    }
    @MainActor var captureRoot: URL {
        self.rootURL.appendingPathComponent(OmiLaunchCaptureFormat.rootDirectoryName, isDirectory: true)
    }

    @MainActor func defaults(enabled: Bool) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "OmiLaunchCaptureCutoverTests-\(UUID().uuidString)")!
        defaults.set(enabled, forKey: OmiSourceManager.enabledKey)
        return defaults
    }

    @MainActor func diagnostics() -> OmiDiagnostics {
        OmiDiagnostics(fileURL: self.rootURL.appendingPathComponent("diagnostics-\(UUID().uuidString).json"))
    }

    @MainActor func makeHarness(rootURL: URL) -> (engine: TransferEngine, mirror: TransferStatusMirror, enqueuer: ObserverAudioTransferEnqueuer, omi: OmiUploaderHolder, watch: WatchUploaderHolder) {
        CutoverTransferURLProtocol.handler = { request, _ in (transferTestResponse(for: request, statusCode: 204), Data()) }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [CutoverTransferURLProtocol.self]
        return makeTransferCutoverHarness(
            rootURL: rootURL,
            sessionConfiguration: sessionConfiguration,
            endpointResolver: CutoverAvailableEndpointResolver()
        )
    }

    static func packet(_ number: UInt16, index: UInt8, body: Data) -> Data {
        Data([UInt8(number & 0xff), UInt8(number >> 8), index]) + body
    }

    static func marker(packet: UInt16, epoch: UInt32) -> Data {
        var data = Data([UInt8(packet & 0xff), UInt8(packet >> 8), 0xff])
        data.append(UInt8(epoch & 0xff))
        data.append(UInt8((epoch >> 8) & 0xff))
        data.append(UInt8((epoch >> 16) & 0xff))
        data.append(UInt8((epoch >> 24) & 0xff))
        return data
    }

    static func opusFrame() throws -> Data {
        let format = try XCTUnwrap(AVAudioFormat(opusPCMFormat: .int16, sampleRate: OmiAudioChunkFormat.sampleRate, channels: OmiAudioChunkFormat.channelCount))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
        buffer.frameLength = 320
        for index in 0..<320 { buffer.int16ChannelData![0][index] = Int16(index % 128) }
        let encoder = try Opus.Encoder(format: format)
        var encoded = Data(repeating: 0, count: 512)
        _ = try encoder.encode(buffer, to: &encoded)
        return encoded
    }

    static func assertRetained(_ outcome: OmiLaunchCaptureAppendOutcome) {
        guard case .retained = outcome else { XCTFail("fixture append failed"); return }
    }

    static func occurrences(of needle: Data, in haystack: Data) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var start = haystack.startIndex
        while let range = haystack.range(of: needle, options: [], in: start..<haystack.endIndex) {
            count += 1
            start = range.upperBound
        }
        return count
    }

    @MainActor func makeReservedCaptureWorld(
        io: FaultInjectingOmiLaunchCaptureIO,
        rootURL: URL? = nil
    ) async throws -> (
        manager: OmiSourceManager,
        engine: TransferEngine,
        io: FaultInjectingOmiLaunchCaptureIO,
        captureRoot: URL,
        generation: UUID,
        reservation: OmiLaunchCaptureCutReservation,
        peripheralID: UUID,
        sealedURL: URL,
        reservedURL: URL
    ) {
        let baseRoot: URL
        if let rootURL {
            baseRoot = rootURL
        } else {
            baseRoot = try XCTUnwrap(self.rootURL)
        }
        let captureRoot = baseRoot.appendingPathComponent(OmiLaunchCaptureFormat.rootDirectoryName, isDirectory: true)
        let generation = UUID()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let manager = OmiSourceManager(defaults: self.defaults(enabled: true), diagnostics: OmiDiagnostics(fileURL: baseRoot.appendingPathComponent("diagnostics.json")), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: OmiLaunchCaptureIngress(captureRoot: { captureRoot }, generationID: generation, clock: clock, io: io))
        manager.enable()
        let peripheralID = UUID()
        manager.handleAudioData(.payload(Data("sealed-for-reserved-world".utf8)), peripheralID: peripheralID)
        let harness = self.makeHarness(rootURL: baseRoot.appendingPathComponent("transfer", isDirectory: true))
        try await harness.engine.initialize()
        await OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: manager, io: io).reconcile()
        let store = OmiLaunchCaptureCutReservationStore(rootURL: captureRoot, io: io)
        guard case .valid(let reservation) = store.read() else {
            throw NSError(domain: "OmiLaunchCaptureCutoverTests", code: 1)
        }
        return (
            manager,
            harness.engine,
            io,
            captureRoot,
            generation,
            reservation,
            peripheralID,
            OmiLaunchCaptureFormat.fileURL(rootURL: captureRoot, generationID: generation),
            OmiLaunchCaptureFormat.fileURL(rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: captureRoot), generationID: reservation.reservedGenerationID)
        )
    }
}

private actor CutoverBarrier {
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

private actor CutoverPassCounter {
    private var value = 0

    func increment() { self.value += 1 }
    func count() -> Int { self.value }
}

@MainActor
private final class CutoverSettlementFault {
    private var isEnabled: Bool
    private(set) var failureCount = 0

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    func shouldFail() -> Bool {
        guard self.isEnabled else { return false }
        self.failureCount += 1
        return true
    }

    func clear() { self.isEnabled = false }
}

private final class CutoverTransferURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data)?

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let requestsBox = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    static var requests: [URLRequest] {
        self.requestsBox.withLock { $0 }
    }

    static func reset() {
        self.handler = nil
        self.requestsBox.withLock { $0 = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestsBox.withLock { $0.append(self.request) }
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        do {
            guard let (response, data) = try handler(self.request, Data()) else {
                return
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

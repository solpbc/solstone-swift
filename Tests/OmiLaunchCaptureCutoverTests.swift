// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Foundation
import Opus
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
        TransferURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.rootURL)
    }

    @MainActor func testCoordinatorCutoverRoutesSubsequentAudioToReservedCapture() async throws {
        let defaults = self.defaults(enabled: true)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let generation = UUID()
        let ingress = OmiLaunchCaptureIngress(appGroupRoot: { self.rootURL }, generationID: generation, clock: clock)
        let manager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: ingress)
        manager.enable()

        let frame = try Self.opusFrame()
        var decodedHandoffs = 0
        manager.onDecodedSamples = { _ in decodedHandoffs += 1 }
        manager.buildOpusDecoder()
        await manager.openLaunchReadiness()
        let peripheralID = UUID()
        manager.handleAudioData(.payload(Self.marker(packet: 0, epoch: 2_000)), peripheralID: peripheralID)
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
                if phase == .afterNewOwnerGated, !didSuspend {
                    didSuspend = true
                    await barrier.suspend()
                }
            }
        )
        let recovery = Task { @MainActor in await coordinator.reconcile() }
        try await transferTestWaitFor("prefix owner gated") { await barrier.waiting() }
        manager.handleAudioData(.payload(Self.packet(2, index: 0, body: frame)), peripheralID: peripheralID)
        XCTAssertEqual(decodedHandoffs, 0)
        await barrier.resume()
        await recovery.value
        // The first bounded pass returned after acknowledging only the leased prefix.
        // Wait until its immediate successors drain the retained tail; completion
        // switches the route synchronously on the main actor immediately afterward.
        let captureRoot = self.captureRoot
        try await transferTestWaitFor("capture drain") {
            await MainActor.run {
                switch OmiLaunchCaptureLeaseReader(rootURL: captureRoot, generationID: generation).lease() {
                case .empty:
                    true
                case .lease, .unavailable:
                    false
                }
            }
        }
        let reservationURL = OmiLaunchCaptureCutReservationFormat.fileURL(rootURL: self.captureRoot)
        try await transferTestWaitFor("durable cut reservation") {
            FileManager.default.fileExists(atPath: reservationURL.path)
        }
        let reservation: OmiLaunchCaptureCutReservation
        switch OmiLaunchCaptureCutReservationStore(rootURL: self.captureRoot).read() {
        case .valid(let value): reservation = value
        case .absent, .unreadable:
            return XCTFail("cut reservation was not readable")
        }
        let transportSnapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        let transportRequests = TransferURLProtocol.requests.count
        manager.handleAudioData(.payload(Self.packet(3, index: 0, body: frame)), peripheralID: peripheralID)
        manager.handleAudioData(.payload(Self.packet(4, index: 0, body: frame)), peripheralID: peripheralID)
        XCTAssertEqual(decodedHandoffs, 0)
        XCTAssertEqual(manager.audioPackets, 0)
        let sealedCallbackCount: Int
        switch OmiLaunchCaptureLeaseReader(rootURL: self.captureRoot, generationID: generation).lease(
            from: OmiLaunchCaptureReadPosition(generationID: generation, nextSequence: 0, offset: 0)
        ) {
        case .lease(let lease):
            sealedCallbackCount = lease.records.count
        case .empty, .unavailable:
            return XCTFail("capture route did not retain its callbacks")
        }
        XCTAssertEqual(sealedCallbackCount, 2)
        let reservedRoot = OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: self.captureRoot)
        let reservedReader = OmiLaunchCaptureLeaseReader(rootURL: reservedRoot, generationID: reservation.reservedGenerationID)
        guard case .lease(let reservedLease) = reservedReader.lease() else {
            return XCTFail("reserved route did not retain its callbacks")
        }
        XCTAssertEqual(reservedLease.records.count, 2)
        let snapshotsAfterReservedCallbacks = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshotsAfterReservedCallbacks, transportSnapshots)
        XCTAssertEqual(TransferURLProtocol.requests.count, transportRequests)
        XCTAssertEqual(OmiLaunchCaptureLeaseReader(rootURL: self.captureRoot, generationID: generation).lease(), .empty)
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

        let sizeBefore = try FileManager.default.attributesOfItem(atPath: reader.fileURL.path)[.size] as? Int ?? 0
        let peripheralID = UUID()
        let frame = try Self.opusFrame()
        manager.handleAudioData(.payload(Self.packet(0, index: 0, body: frame)), peripheralID: peripheralID)
        manager.handleAudioData(.payload(Self.packet(1, index: 0, body: frame)), peripheralID: peripheralID)
        XCTAssertEqual(decodedHandoffs, 0)
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: reader.fileURL.path)[.size] as? Int ?? 0, sizeBefore)
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
                if phase == .afterNewOwnerGated, !didSuspend {
                    didSuspend = true
                    await barrier.suspend()
                }
            }
        )
        let recovery = Task { @MainActor in await coordinator.reconcile() }
        try await transferTestWaitFor("first generation gated") { await barrier.waiting() }
        XCTAssertNil(manager.lastMarkerDate)
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
                case .afterNewOwnerGated:
                    await initialBarrier.suspend()
                case .afterOwnerRegisteredBeforeAcknowledgment:
                    await resumePasses.increment()
                    await resumeBarrier.suspend()
                case .afterCutReservationCommittedBeforeRouteMutation:
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
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
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
            TransferURLProtocol.requests.count == 1
        }
        XCTAssertEqual(TransferURLProtocol.requests.count, 1)
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

    @MainActor func testReservedCallbacksAreExclusiveAndRemainOutsideTransportDiscovery() async throws {
        let defaults = self.defaults(enabled: true)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let generation = UUID()
        let ingress = OmiLaunchCaptureIngress(appGroupRoot: { self.rootURL }, generationID: generation, clock: clock)
        let manager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: ingress)
        manager.enable()
        let peripheralID = UUID()
        let frame = try Self.opusFrame()
        let before = Self.packet(1, index: 0, body: frame)
        manager.handleAudioData(.payload(Self.marker(packet: 0, epoch: 2_000)), peripheralID: peripheralID)
        manager.handleAudioData(.payload(before), peripheralID: peripheralID)
        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("transfer", isDirectory: true))
        try await harness.engine.initialize()
        let coordinator = OmiLaunchCaptureCommitCoordinator(rootURL: self.captureRoot, engine: harness.engine, sourceManager: manager)
        await coordinator.reconcile()
        let reservationURL = OmiLaunchCaptureCutReservationFormat.fileURL(rootURL: self.captureRoot)
        try await transferTestWaitFor("cut reservation") { FileManager.default.fileExists(atPath: reservationURL.path) }
        guard case .valid(let reservation) = OmiLaunchCaptureCutReservationStore(rootURL: self.captureRoot).read() else {
            return XCTFail("cut reservation was not readable")
        }
        let after = Data("reserved-callback-B".utf8)
        manager.handleAudioData(.payload(after), peripheralID: peripheralID)
        let sealedBytes = try Data(contentsOf: OmiLaunchCaptureFormat.fileURL(rootURL: self.captureRoot, generationID: generation))
        let reservedURL = OmiLaunchCaptureFormat.fileURL(rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: self.captureRoot), generationID: reservation.reservedGenerationID)
        let reservedBytes = try Data(contentsOf: reservedURL)
        XCTAssertEqual(Self.occurrences(of: before, in: sealedBytes), 1)
        XCTAssertEqual(Self.occurrences(of: before, in: reservedBytes), 0)
        XCTAssertEqual(Self.occurrences(of: after, in: sealedBytes), 0)
        XCTAssertEqual(Self.occurrences(of: after, in: reservedBytes), 1)
        let rootEntries = try FileManager.default.contentsOfDirectory(at: self.captureRoot, includingPropertiesForKeys: nil)
        XCTAssertFalse(rootEntries.contains { $0.lastPathComponent == reservedURL.lastPathComponent })
        XCTAssertNil(manager.activeLaunchCaptureGenerationID)
    }

    @MainActor func testThirtyTwoReservedCallbacksLeaveSealedEvidenceAndTransportUnchanged() async throws {
        let defaults = self.defaults(enabled: true)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let generation = UUID()
        let ingress = OmiLaunchCaptureIngress(appGroupRoot: { self.rootURL }, generationID: generation, clock: clock)
        let manager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: ingress)
        manager.enable()
        let peripheralID = UUID()
        manager.handleAudioData(.payload(Self.marker(packet: 0, epoch: 2_000)), peripheralID: peripheralID)
        manager.handleAudioData(.payload(Self.packet(1, index: 0, body: try Self.opusFrame())), peripheralID: peripheralID)
        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("transfer", isDirectory: true))
        try await harness.engine.initialize()
        let captureRoot = self.captureRoot
        let coordinator = OmiLaunchCaptureCommitCoordinator(rootURL: captureRoot, engine: harness.engine, sourceManager: manager)
        await coordinator.reconcile()
        let reservationURL = OmiLaunchCaptureCutReservationFormat.fileURL(rootURL: captureRoot)
        try await transferTestWaitFor("cut reservation") { FileManager.default.fileExists(atPath: reservationURL.path) }
        guard case .valid(let reservation) = OmiLaunchCaptureCutReservationStore(rootURL: self.captureRoot).read() else { return XCTFail("cut reservation was not readable") }
        let sealedReader = OmiLaunchCaptureLeaseReader(rootURL: self.captureRoot, generationID: generation)
        let sealedSize = try FileManager.default.attributesOfItem(atPath: sealedReader.fileURL.path)[.size] as? Int
        let sealedLease = sealedReader.lease(from: .init(generationID: generation, nextSequence: 0, offset: 0))
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        let tags = (0..<32).map { Data(String(format: "reserved-%02d", $0).utf8) }
        for tag in tags {
            XCTAssertLessThanOrEqual(tag.count, OmiLaunchCaptureFormat.maximumPayloadBytes)
            manager.handleAudioData(.payload(tag), peripheralID: peripheralID)
        }
        let reservedURL = OmiLaunchCaptureFormat.fileURL(rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: self.captureRoot), generationID: reservation.reservedGenerationID)
        let reservedBytes = try Data(contentsOf: reservedURL)
        for tag in tags { XCTAssertEqual(Self.occurrences(of: tag, in: reservedBytes), 1) }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: sealedReader.fileURL.path)[.size] as? Int, sealedSize)
        XCTAssertEqual(sealedReader.lease(from: .init(generationID: generation, nextSequence: 0, offset: 0)), sealedLease)
        let snapshotsAfter = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshotsAfter, snapshots)
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
                if phase == .afterCutReservationCommittedBeforeRouteMutation { await barrier.suspend() }
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
        XCTAssertNil(freshManager.activeLaunchCaptureGenerationID)
        await freshCoordinator.reconcile()
        let tag = Data("restart-reserved-B".utf8)
        freshManager.handleAudioData(.payload(tag), peripheralID: peripheralID)
        let reservedURL = OmiLaunchCaptureFormat.fileURL(rootURL: OmiLaunchCaptureCutReservationFormat.reservedRootURL(rootURL: self.captureRoot), generationID: committed.reservedGenerationID)
        XCTAssertEqual(Self.occurrences(of: tag, in: try Data(contentsOf: reservedURL)), 1)
        await barrier.resume()
        await pass.value
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
        XCTAssertNil(freshManager.activeLaunchCaptureGenerationID)
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
            sealedNextSequence: 1,
            sealedEndOffset: bytesBefore.count,
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
        io.failNext(.write)
        world.manager.handleAudioData(.payload(Data("reserved-write-failure".utf8)), peripheralID: world.peripheralID)
        XCTAssertTrue(world.manager.writerFaulted)
        let snapshotsAfter = await world.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshotsAfter, snapshots)
        XCTAssertEqual(Self.occurrences(of: Data("reserved-write-failure".utf8), in: try Data(contentsOf: world.reservedURL)), 0)
    }

    @MainActor func testReservedAppendBarrierFailureTriggersFlowControlWithoutTransportOwner() async throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let world = try await self.makeReservedCaptureWorld(io: io)
        let snapshots = await world.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        io.failNext(.barrier)
        world.manager.handleAudioData(.payload(Data("reserved-barrier-failure".utf8)), peripheralID: world.peripheralID)
        XCTAssertTrue(world.manager.writerFaulted)
        let snapshotsAfter = await world.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshotsAfter, snapshots)
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
}

private extension OmiLaunchCaptureCutoverTests {
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
        TransferURLProtocol.handler = { request, _ in (transferTestResponse(for: request, statusCode: 204), Data()) }
        return makeTransferCutoverHarness(
            rootURL: rootURL,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
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

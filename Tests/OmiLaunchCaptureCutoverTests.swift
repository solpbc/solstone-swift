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

    @MainActor func testCoordinatorCutoverRoutesSubsequentAudioToLiveDecode() async throws {
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
        try await transferTestWaitFor("coordinator cutover") {
            await MainActor.run { manager.lastMarkerDate == Date(timeIntervalSince1970: 2_000) }
        }
        manager.handleAudioData(.payload(Self.packet(3, index: 0, body: frame)), peripheralID: peripheralID)
        manager.handleAudioData(.payload(Self.packet(4, index: 0, body: frame)), peripheralID: peripheralID)
        XCTAssertEqual(decodedHandoffs, 1)
        let capturedCallbackCount: Int
        switch OmiLaunchCaptureLeaseReader(rootURL: self.captureRoot, generationID: generation).lease(
            from: OmiLaunchCaptureReadPosition(generationID: generation, nextSequence: 0, offset: 0)
        ) {
        case .lease(let lease):
            capturedCallbackCount = lease.records.count
        case .empty, .unavailable:
            return XCTFail("capture route did not retain its callbacks")
        }
        XCTAssertEqual(capturedCallbackCount, 2)
        XCTAssertEqual(manager.audioPackets, 2)
        XCTAssertEqual(capturedCallbackCount + manager.audioPackets, 4)
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
        first.completeLaunchCaptureCutover(markers: markers)
        XCTAssertEqual(first.diagnostics.payload.pendantRebootEvents?.count, 1)

        let restarted = OmiSourceManager(defaults: defaults, diagnostics: OmiDiagnostics(fileURL: fileURL), clock: clock, bluetoothPort: MockOmiBluetoothPort())
        restarted.completeLaunchCaptureCutover(markers: markers)
        restarted.handleAudioData(.payload(Self.marker(packet: 0, epoch: 1_001)), peripheralID: UUID())
        XCTAssertEqual(restarted.diagnostics.payload.pendantRebootEvents?.count, 1)
        XCTAssertEqual(restarted.lastMarkerDate, Date(timeIntervalSince1970: 1_001))
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
        let partition = try XCTUnwrap(OmiLaunchCaptureMaterializer(rootURL: self.captureRoot, generationID: generation, decode: { decoder.decode($0) }).materialize().partitions.first)

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

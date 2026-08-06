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

    @MainActor func testVerifiedPrefixReplayPrecedesLiveSamplesAndEachCallbackUsesOneRoute() async throws {
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
        manager.handleAudioData(Self.marker(packet: 0, epoch: 2_000), peripheralID: peripheralID)
        manager.handleAudioData(Self.packet(1, index: 0, body: frame), peripheralID: peripheralID)
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
        manager.handleAudioData(Self.packet(2, index: 0, body: frame), peripheralID: peripheralID)
        XCTAssertEqual(decodedHandoffs, 0)
        await barrier.resume()
        await recovery.value
        try await transferTestWaitFor("coordinator cutover") {
            await MainActor.run { manager.lastMarkerDate == Date(timeIntervalSince1970: 2_000) }
        }
        manager.handleAudioData(Self.packet(3, index: 0, body: frame), peripheralID: peripheralID)
        manager.handleAudioData(Self.packet(4, index: 0, body: frame), peripheralID: peripheralID)
        XCTAssertEqual(decodedHandoffs, 1)
        XCTAssertEqual(OmiLaunchCaptureLeaseReader(rootURL: self.captureRoot, generationID: generation).lease(), .empty)
    }

    @MainActor func testReplayMarkersPrecedeLiveMarkerWithoutDuplicateRebootAcrossRestart() throws {
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
        restarted.handleAudioData(Self.marker(packet: 0, epoch: 1_001), peripheralID: UUID())
        XCTAssertEqual(restarted.diagnostics.payload.pendantRebootEvents?.count, 1)
        XCTAssertEqual(restarted.lastMarkerDate, Date(timeIntervalSince1970: 1_001))
    }

    @MainActor func testCutoverWaitsForAllGenerationsAndRetiresOnlyInactiveCapture() async throws {
        let defaults = self.defaults(enabled: true)
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 100))
        let activeGeneration = UUID()
        let inactiveGeneration = UUID()
        let ingress = OmiLaunchCaptureIngress(appGroupRoot: { self.rootURL }, generationID: activeGeneration, clock: clock)
        let manager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: clock, bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: ingress)
        manager.enable()

        let frame = try Self.opusFrame()
        let peripheralID = UUID()
        manager.handleAudioData(Self.marker(packet: 0, epoch: 2_000), peripheralID: peripheralID)
        manager.handleAudioData(Self.packet(1, index: 0, body: frame), peripheralID: peripheralID)
        let inactiveWriter = OmiLaunchCaptureWriter(rootURL: self.captureRoot, generationID: inactiveGeneration, clock: clock)
        Self.assertRetained(inactiveWriter.append(Self.packet(0, index: 0, body: frame)))

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
            await MainActor.run { manager.lastMarkerDate == Date(timeIntervalSince1970: 2_000) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: inactiveWriter.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: OmiLaunchCaptureFormat.fileURL(rootURL: self.captureRoot, generationID: activeGeneration).path))
    }

    @MainActor func testPersistedDisabledLeavesCaptureAndLiveEffectsInertButPreservesOwners() async throws {
        let generation = UUID()
        let writer = OmiLaunchCaptureWriter(rootURL: self.captureRoot, generationID: generation, clock: MockObserverClock())
        Self.assertRetained(writer.append(Self.packet(0, index: 0, body: try Self.opusFrame())))
        let decoder = try OmiOpusAudioDecoder()
        let partition = try XCTUnwrap(OmiLaunchCaptureMaterializer(rootURL: self.captureRoot, generationID: generation, decode: { decoder.decode($0) }).materialize().partitions.first)

        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("transfer", isDirectory: true))
        try await harness.engine.initialize()
        let envelope = try OmiPendingHandoffStore.read(from: partition.envelopeURL)
        _ = try await harness.engine.enqueue(manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: partition.itemID, sidecar: envelope.sidecar), payloads: ["audio": Data(contentsOf: partition.audioURL)])
        let defaults = self.defaults(enabled: false)
        let ingress = OmiLaunchCaptureIngress(appGroupRoot: { self.rootURL }, generationID: generation, clock: MockObserverClock())
        let manager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: MockObserverClock(), bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: ingress)
        await OmiLaunchCaptureCommitCoordinator(rootURL: self.captureRoot, engine: harness.engine, sourceManager: manager).reconcile()

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.map(\.itemID), [partition.itemID])
        XCTAssertNotEqual(OmiLaunchCaptureLeaseReader(rootURL: self.captureRoot, generationID: generation).lease(), .empty)
        XCTAssertNil(manager.lastMarkerDate)
    }

    @MainActor func testDisableDuringRecoveryThenExplicitReenableResumesExactlyOnce() async throws {
        let generation = UUID()
        let writer = OmiLaunchCaptureWriter(rootURL: self.captureRoot, generationID: generation, clock: MockObserverClock())
        Self.assertRetained(writer.append(Self.packet(0, index: 0, body: try Self.opusFrame())))
        let defaults = self.defaults(enabled: true)
        let manager = OmiSourceManager(defaults: defaults, diagnostics: self.diagnostics(), clock: MockObserverClock(), bluetoothPort: MockOmiBluetoothPort())
        let harness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("transfer", isDirectory: true))
        try await harness.engine.initialize()
        await harness.engine.enableDispatch()
        let barrier = CutoverBarrier()
        let coordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: self.captureRoot,
            engine: harness.engine,
            sourceManager: manager,
            onReconciliationPhase: { phase in
                if phase == .afterNewOwnerGated { await barrier.suspend() }
            }
        )
        manager.onLaunchCaptureExplicitEnable = { await coordinator.resumeAfterExplicitEnable() }

        let recovery = Task { @MainActor in await coordinator.reconcile() }
        try await transferTestWaitFor("gated recovery") { await barrier.waiting() }
        manager.disable()
        await barrier.resume()
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

        let resumeGeneration = UUID()
        let resumeWriter = OmiLaunchCaptureWriter(rootURL: self.captureRoot, generationID: resumeGeneration, clock: MockObserverClock())
        Self.assertRetained(resumeWriter.append(Self.packet(0, index: 0, body: try Self.opusFrame())))
        var rootAvailable = false
        let resumeIngress = OmiLaunchCaptureIngress(
            appGroupRoot: {
                guard rootAvailable else { throw CocoaError(.fileNoSuchFile) }
                return self.rootURL
            },
            generationID: resumeGeneration,
            clock: MockObserverClock()
        )
        XCTAssertFalse(resumeIngress.arm())
        let resumeManager = OmiSourceManager(defaults: self.defaults(enabled: true), diagnostics: self.diagnostics(), clock: MockObserverClock(), bluetoothPort: MockOmiBluetoothPort(), launchCaptureIngress: resumeIngress)
        let resumeHarness = self.makeHarness(rootURL: self.rootURL.appendingPathComponent("resume-transfer", isDirectory: true))
        try await resumeHarness.engine.initialize()
        await resumeHarness.engine.enableDispatch()
        let resumePasses = CutoverPassCounter()
        let resumeCoordinator = OmiLaunchCaptureCommitCoordinator(
            rootURL: self.captureRoot,
            engine: resumeHarness.engine,
            sourceManager: resumeManager,
            onReconciliationPhase: { phase in
                if phase == .afterNewOwnerGated { await resumePasses.increment() }
            }
        )
        resumeManager.onLaunchCaptureExplicitEnable = { await resumeCoordinator.resumeAfterExplicitEnable() }
        rootAvailable = true
        let firstResume = await resumeManager.resumeLaunchCaptureOnce()
        let secondResume = await resumeManager.resumeLaunchCaptureOnce()
        XCTAssertTrue(firstResume)
        XCTAssertFalse(secondResume)
        try await transferTestWaitFor("single resumed recovery") { await resumePasses.count() == 1 }
        let observedResumePasses = await resumePasses.count()
        XCTAssertEqual(observedResumePasses, 1)
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

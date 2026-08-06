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
        manager.handleAudioData(Self.packet(0, index: 0, body: frame), peripheralID: UUID())
        XCTAssertEqual(OmiLaunchCaptureRecovery(rootURL: self.captureRoot, generationID: generation).recover().verifiedPrefixNextSequence, 1)

        manager.completeLaunchCaptureCutover(markers: [
            OmiLaunchCaptureMarkerObservation(epoch: 2_000, acquiredAt: clock.now(), sequence: 0),
            OmiLaunchCaptureMarkerObservation(epoch: 1_000, acquiredAt: clock.now(), sequence: 1),
        ])
        XCTAssertEqual(manager.lastMarkerDate, Date(timeIntervalSince1970: 1_000))

        var decodedHandoffs = 0
        manager.onDecodedSamples = { _ in decodedHandoffs += 1 }
        manager.buildOpusDecoder()
        await manager.openLaunchReadiness()
        manager.handleAudioData(Self.packet(1, index: 0, body: frame), peripheralID: UUID())
        manager.handleAudioData(Self.packet(2, index: 0, body: frame), peripheralID: UUID())

        XCTAssertEqual(decodedHandoffs, 1)
        XCTAssertEqual(OmiLaunchCaptureRecovery(rootURL: self.captureRoot, generationID: generation).recover().verifiedPrefixNextSequence, 1)
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

        manager.enable()
        manager.enable()
        try await transferTestWaitFor("single resumed delivery") { TransferURLProtocol.requests.count == 1 }
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

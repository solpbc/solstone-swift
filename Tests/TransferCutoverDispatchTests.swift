// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class TransferCutoverDispatchTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferCutoverDispatchTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        TransferURLProtocol.reset()
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    @MainActor
    func testAC7EndpointFlapsDoNotFloodOrCancelQueuedOmiItems() async throws {
        let resolver = TransferEndpointResolverStub(.unavailable("waiting"))
        let events = OSAllocatedUnfairLock<[TransferDiagnosticEvent]>(initialState: [])
        let maxSeenInFlight = OSAllocatedUnfairLock<Int>(initialState: 0)
        let maxConcurrent = 3
        TransferURLProtocol.handler = { request, _ in
            Thread.sleep(forTimeInterval: 0.003)
            return (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let harness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("transfer", isDirectory: true),
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: resolver,
            diagnosticsSink: { event in events.withLock { $0.append(event) } },
            maxConcurrent: maxConcurrent
        )
        try await harness.engine.start()

        let sessionID = UUID()
        for index in 0..<200 {
            let sidecar = makeTransferTestSidecar(
                sessionID: sessionID,
                chunkIndex: index,
                startedAt: Date(timeIntervalSince1970: 1_780_480_800 + TimeInterval(index))
            )
            let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(
                itemID: Self.uuid(index),
                sidecar: sidecar
            )
            _ = try await harness.engine.enqueue(manifest: manifest, payloads: ["audio": Data("audio-\(index)".utf8)])
        }

        let sampler = Task {
            while !Task.isCancelled {
                let count = await harness.engine.snapshot().counters.inFlightCount
                maxSeenInFlight.withLock { value in value = max(value, count) }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        await harness.engine.endpointAvailabilityChanged()
        resolver.setResolution(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
        await harness.engine.endpointAvailabilityChanged()
        try await Task.sleep(for: .milliseconds(20))
        resolver.setResolution(.unavailable("waiting"))
        await harness.engine.endpointAvailabilityChanged()
        try await Task.sleep(for: .milliseconds(20))
        resolver.setResolution(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
        await harness.engine.endpointAvailabilityChanged()

        try await transferTestWaitFor("all omi items delivered", timeout: .seconds(8)) {
            await harness.engine.snapshot().counters.deliveredCount == 200
        }
        sampler.cancel()
        _ = await sampler.result

        let snapshot = await harness.engine.snapshot()
        XCTAssertEqual(snapshot.counters.queuedCount, 0)
        XCTAssertEqual(snapshot.counters.inFlightCount, 0)
        XCTAssertEqual(snapshot.sources[ObserverAudioTransferSource.omi]?.deliveredCount, 200)
        let observedMaxInFlight = maxSeenInFlight.withLock { $0 }
        XCTAssertGreaterThan(
            observedMaxInFlight,
            0,
            "sampler never observed an in-flight dispatch; the cap assertion would be vacuous"
        )
        XCTAssertLessThanOrEqual(observedMaxInFlight, maxConcurrent)
        XCTAssertEqual(TransferURLProtocol.requests.count, 200)
        XCTAssertTrue(events.withLock { values in values.filter { $0.outcome == .retrying }.isEmpty })
    }

    @MainActor
    func testAC7EndpointFlapsDoNotFloodOrCancelQueuedMobileSegments() async throws {
        let resolver = TransferEndpointResolverStub(.unavailable("waiting"))
        let events = OSAllocatedUnfairLock<[TransferDiagnosticEvent]>(initialState: [])
        let maxSeenInFlight = OSAllocatedUnfairLock<Int>(initialState: 0)
        let maxConcurrent = 3
        TransferURLProtocol.handler = { request, _ in
            Thread.sleep(forTimeInterval: 0.003)
            return (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let harness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("mobile-transfer", isDirectory: true),
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: resolver,
            diagnosticsSink: { event in events.withLock { $0.append(event) } },
            maxConcurrent: maxConcurrent
        )
        try await harness.engine.start()

        for index in 0..<50 {
            _ = try await harness.engine.enqueue(
                manifest: Self.mobileManifest(
                    itemID: Self.uuid(10_000 + index),
                    segmentID: Self.uuid(11_000 + index),
                    index: index
                ),
                payloads: ["audio": Data("mobile-\(index)".utf8)]
            )
        }

        let sampler = Task {
            while !Task.isCancelled {
                let count = await harness.engine.snapshot().counters.inFlightCount
                maxSeenInFlight.withLock { value in value = max(value, count) }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        await harness.engine.endpointAvailabilityChanged()
        resolver.setResolution(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
        await harness.engine.endpointAvailabilityChanged()
        try await Task.sleep(for: .milliseconds(20))
        resolver.setResolution(.unavailable("waiting"))
        await harness.engine.endpointAvailabilityChanged()
        try await Task.sleep(for: .milliseconds(20))
        resolver.setResolution(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
        await harness.engine.endpointAvailabilityChanged()

        try await transferTestWaitFor("all mobile items delivered", timeout: .seconds(6)) {
            await harness.engine.snapshot().sources[ObserverAudioTransferSource.mobileSegment]?.deliveredCount == 50
        }
        sampler.cancel()
        _ = await sampler.result

        let snapshot = await harness.engine.snapshot()
        XCTAssertEqual(snapshot.counters.queuedCount, 0)
        XCTAssertEqual(snapshot.counters.inFlightCount, 0)
        XCTAssertEqual(snapshot.sources[ObserverAudioTransferSource.mobileSegment]?.deliveredCount, 50)
        let observedMaxInFlight = maxSeenInFlight.withLock { $0 }
        XCTAssertGreaterThan(
            observedMaxInFlight,
            0,
            "sampler never observed an in-flight dispatch; the cap assertion would be vacuous"
        )
        XCTAssertLessThanOrEqual(observedMaxInFlight, maxConcurrent)
        XCTAssertEqual(TransferURLProtocol.requests.count, 50)
        XCTAssertTrue(events.withLock { values in values.filter { $0.outcome == .dropped }.isEmpty })
        XCTAssertTrue(events.withLock { values in values.filter { $0.outcome == .retrying }.isEmpty })
    }

    @MainActor
    func testAC10AuthProviderRoutesDistinctBearerHandlesBySource() async throws {
        let omiID = Self.uuid(900)
        let watchID = Self.uuid(901)
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let harness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("auth-transfer", isDirectory: true),
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            authProvider: { manifest in
                switch manifest.source {
                case ObserverAudioTransferSource.omi:
                    return "omi-handle"
                case ObserverAudioTransferSource.watch:
                    return "watch-handle"
                default:
                    throw URLError(.userAuthenticationRequired)
                }
            },
            endpointResolver: TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
        )
        try await harness.engine.start()
        let sessionID = UUID()
        let omiManifest = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: omiID,
            sidecar: makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 1, startedAt: Date(timeIntervalSince1970: 1_780_480_800))
        )
        let watchManifest = ObserverAudioTransferEnqueuer.makeWatchManifest(
            itemID: watchID,
            sidecar: makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 2, startedAt: Date(timeIntervalSince1970: 1_780_480_860)),
            hasLocation: false
        )
        _ = try await harness.engine.enqueue(manifest: omiManifest, payloads: ["audio": Data("omi".utf8)])
        _ = try await harness.engine.enqueue(manifest: watchManifest, payloads: ["audio": Data("watch".utf8)])

        try await transferTestWaitFor("auth routed requests", timeout: .seconds(3)) {
            await harness.engine.snapshot().counters.deliveredCount == 2
        }

        let headersByItemID = Dictionary(uniqueKeysWithValues: TransferURLProtocol.requests.compactMap { request -> (UUID, String)? in
            guard let itemID = transferTestBoundaryItemID(from: request),
                  let authorization = request.value(forHTTPHeaderField: "Authorization")
            else {
                return nil
            }
            return (itemID, authorization)
        })
        XCTAssertEqual(headersByItemID[omiID], "Bearer omi-handle")
        XCTAssertEqual(headersByItemID[watchID], "Bearer watch-handle")
    }
}

private extension TransferCutoverDispatchTests {
    static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    static func mobileManifest(itemID: UUID, segmentID: UUID, index: Int) -> TransferManifest {
        let startedAt = Date(timeIntervalSince1970: 1_780_480_800 + TimeInterval(index))
        let durationS: TimeInterval = 60
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.audio],
            activeSourceSetVersion: 1
        )
        manifest.day = "20260628"
        manifest.segment = "090000_60"
        manifest.endedAt = startedAt.addingTimeInterval(durationS)
        manifest.durationS = durationS
        manifest.audio = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: "audio.m4a",
            bytes: Int64(Data("mobile-\(index)".utf8).count),
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(durationS),
            durationS: durationS,
            mode: .meeting
        )
        return ObserverAudioTransferEnqueuer.makeMobileSegmentManifest(
            itemID: itemID,
            manifest: manifest,
            now: startedAt.addingTimeInterval(durationS),
            sources: [.audio],
            payloadParts: [ObserverAudioTransferEnqueuer.audioPart()]
        )
    }
}

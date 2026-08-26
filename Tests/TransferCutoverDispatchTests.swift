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
            return (transferTestResponse(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
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
            return (transferTestResponse(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
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
    func testAC5EndpointFlapsDoNotCancelQueuedShareItemsAndRespectGlobalCap() async throws {
        let resolver = TransferEndpointResolverStub(.unavailable("waiting"))
        let events = OSAllocatedUnfairLock<[TransferDiagnosticEvent]>(initialState: [])
        let maxSeenInFlight = OSAllocatedUnfairLock<Int>(initialState: 0)
        let maxConcurrent = 4
        TransferURLProtocol.handler = { request, _ in
            Thread.sleep(forTimeInterval: 0.01)
            return (
                transferTestResponse(for: request, statusCode: 200),
                Data(#"{"recommended_action":"do_not_start","path":"/imports/share","timestamp":"2026-07-09T00:00:00Z"}"#.utf8)
            )
        }
        let harness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("share-transfer", isDirectory: true),
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: resolver,
            diagnosticsSink: { event in events.withLock { $0.append(event) } },
            maxConcurrent: maxConcurrent,
            bodyBuilder: Self.shareBodyBuilder
        )
        try await harness.engine.start()

        for index in 0..<50 {
            _ = try await harness.engine.enqueue(
                manifest: Self.shareManifest(itemID: Self.uuid(20_000 + index), index: index),
                payloads: ["text": Data("share-\(index)".utf8)]
            )
        }

        let sampler = Task {
            while !Task.isCancelled {
                let count = await harness.engine.snapshot().counters.inFlightCount
                maxSeenInFlight.withLock { value in value = max(value, count) }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        resolver.setResolution(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
        await harness.engine.endpointAvailabilityChanged()
        try await Task.sleep(for: .milliseconds(20))
        resolver.setResolution(.unavailable("waiting"))
        await harness.engine.endpointAvailabilityChanged()
        try await Task.sleep(for: .milliseconds(20))
        resolver.setResolution(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
        await harness.engine.endpointAvailabilityChanged()

        try await transferTestWaitFor("all share items delivered", timeout: .seconds(8)) {
            await harness.engine.snapshot().sources[ObserverAudioTransferSource.share]?.deliveredCount == 50
        }
        sampler.cancel()
        _ = await sampler.result

        let snapshot = await harness.engine.snapshot()
        XCTAssertEqual(snapshot.counters.queuedCount, 0)
        XCTAssertEqual(snapshot.counters.inFlightCount, 0)
        XCTAssertEqual(snapshot.sources[ObserverAudioTransferSource.share]?.deliveredCount, 50)
        XCTAssertGreaterThan(maxSeenInFlight.withLock { $0 }, 0)
        XCTAssertLessThanOrEqual(maxSeenInFlight.withLock { $0 }, maxConcurrent)
        XCTAssertEqual(TransferURLProtocol.requests.count, 50)
        XCTAssertTrue(events.withLock { values in values.filter { $0.outcome == .retrying }.isEmpty })
        XCTAssertTrue(events.withLock { values in values.filter { $0.shortDetail.contains("cancelled") }.isEmpty })
    }

    @MainActor
    func testAC2bGlobalMaxConcurrentAppliesAcrossShareAndMobileSegmentSources() async throws {
        let maxConcurrent = 4
        TransferURLProtocol.handler = { request, _ in
            TransferURLProtocol.hold(request)
        }
        let harness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("global-cap-transfer", isDirectory: true),
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))),
            maxConcurrent: maxConcurrent,
            bodyBuilder: Self.shareBodyBuilder
        )
        try await harness.engine.start()

        for index in 0..<8 {
            _ = try await harness.engine.enqueue(
                manifest: Self.shareManifest(itemID: Self.uuid(30_000 + index), index: index),
                payloads: ["text": Data("share-\(index)".utf8)]
            )
            _ = try await harness.engine.enqueue(
                manifest: Self.mobileManifest(
                    itemID: Self.uuid(31_000 + index),
                    segmentID: Self.uuid(32_000 + index),
                    index: index
                ),
                payloads: ["audio": Data("mobile-\(index)".utf8)]
            )
        }

        try await transferTestWaitFor("global cap in flight") {
            TransferURLProtocol.requests.count == maxConcurrent
        }
        try await Task.sleep(for: .milliseconds(50))
        let snapshot = await harness.engine.snapshot()
        let shareInFlight = snapshot.sources[ObserverAudioTransferSource.share]?.inFlightCount ?? 0
        let mobileInFlight = snapshot.sources[ObserverAudioTransferSource.mobileSegment]?.inFlightCount ?? 0
        XCTAssertEqual(snapshot.counters.inFlightCount, maxConcurrent)
        XCTAssertEqual(shareInFlight + mobileInFlight, maxConcurrent)
        XCTAssertGreaterThan(shareInFlight, 0)
        XCTAssertGreaterThan(mobileInFlight, 0)
        XCTAssertEqual(TransferURLProtocol.requests.count, maxConcurrent)
    }

    @MainActor
    func testLinkedDeviceIngestSetsProtocolAndNoAuthorization() async throws {
        let omiID = Self.uuid(900)
        let watchID = Self.uuid(901)
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }
        let harness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("auth-transfer", isDirectory: true),
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
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

        XCTAssertEqual(TransferURLProtocol.requests.count, 2)
        for request in TransferURLProtocol.requests {
            XCTAssertEqual(
                request.value(forHTTPHeaderField: ObserverServerURL.protocolVersionHeaderName),
                ObserverServerURL.ingestProtocolVersion
            )
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }
}

extension TransferCutoverDispatchTests {
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

    static func shareManifest(itemID: UUID, index: Int) -> TransferManifest {
        let createdAt = Date(timeIntervalSince1970: 1_780_480_800 + TimeInterval(index))
        return TransferManifest(
            itemID: itemID,
            source: ObserverAudioTransferSource.share,
            createdAt: createdAt,
            priority: TransferPriorityInputs(basePriority: .normal, sourceKey: ObserverAudioTransferSource.share),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: "text",
                    kind: .text,
                    relativePath: "raw.bin",
                    filename: "text.txt",
                    contentType: "text/plain",
                    byteCount: Data("share-\(index)".utf8).count
                ),
            ],
            endpoint: TransferEndpointDescriptor(
                destinationKind: .saveThenStart,
                path: "/imports/save",
                startPath: "/imports/start"
            ),
            meta: ShareImportTransferMetadata.meta(fields: ShareImportTransferMetadata.Fields(
                basis: "file",
                contentType: "text/plain",
                targetJournal: "",
                filename: "note.txt",
                originApp: nil,
                itemTime: "2026-07-09T00:00:00Z",
                bytes: Int64(Data("share-\(index)".utf8).count),
                requestSource: "quick"
            )),
            saveThenStart: TransferSaveThenStartState(phase: .savePending)
        )
    }

    static var shareBodyBuilder: TransferBodyBuilder {
        { item, spool in
            if item.manifest.saveThenStart?.phase == .savePending {
                return try ShareImportSaveBody.build(item: item, spool: spool)
            }
            return try DefaultTransferBodyBuilder.build(item: item, spool: spool)
        }
    }
}

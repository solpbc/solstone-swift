// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class WatchSegmentDrainTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchSegmentDrainTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        WatchDrainURLProtocol.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        WatchDrainURLProtocol.reset()
        super.tearDown()
    }

    @MainActor
    func testColdStartNoMergeHoldsThenResumesUnderWatchKey() async throws {
        let stagingRoot = self.stagingRootURL()
        let manifest = self.makeManifest()
        try self.writeStagedSegment(stagingRoot: stagingRoot, manifest: manifest, audioData: Data("audio".utf8))
        let transferHarness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("cold-transfer", isDirectory: true)
        )
        let drain = try WatchSegmentDrain(
            stagingRootURL: stagingRoot,
            ledger: WatchSegmentLedger(fileURL: self.ledgerFileURL(name: "cold-ledger")),
            transferEnqueuer: transferHarness.enqueuer,
            transferEngine: transferHarness.engine
        )

        await drain.drain()

        var snapshots = await transferHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.watch)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.manifest.observerIngest?.sessionID, manifest.id)
        XCTAssertTrue(self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id))

        await drain.drain()

        snapshots = await transferHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.watch)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id))
    }

    @MainActor
    func testDrainIsIdempotentAndRemovesStagingAfterTwoHundred() async throws {
        WatchDrainURLProtocol.handler = Self.okResponse
        let stagingRoot = self.stagingRootURL()
        let manifest = self.makeManifest()
        try self.writeStagedSegment(stagingRoot: stagingRoot, manifest: manifest, audioData: Data("audio".utf8))
        let transferHarness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("idempotent-transfer", isDirectory: true)
        )
        let drain = try WatchSegmentDrain(
            stagingRootURL: stagingRoot,
            ledger: WatchSegmentLedger(fileURL: self.ledgerFileURL(name: "idempotent-ledger")),
            transferEnqueuer: transferHarness.enqueuer,
            transferEngine: transferHarness.engine
        )

        await drain.drain()

        var snapshots = await transferHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.watch)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.manifest.observerIngest?.sessionID, manifest.id)
        XCTAssertTrue(self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id))

        await drain.drain()

        snapshots = await transferHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.watch)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id))
    }

    @MainActor
    func testAC2AudioHandoffRecordsHandedOnceAndRemovesStaging() async throws {
        WatchDrainURLProtocol.handler = Self.okResponse
        let stagingRoot = self.stagingRootURL(name: "ac2-audio")
        let ledgerURL = self.ledgerFileURL(name: "ac2-audio-ledger")
        let ledger = WatchSegmentLedger(fileURL: ledgerURL)
        let manifest = self.makeManifest()
        try self.writeStagedSegment(stagingRoot: stagingRoot, manifest: manifest, audioData: Data("audio".utf8))
        let transferHarness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("ac2-audio-transfer", isDirectory: true)
        )
        let drain = try WatchSegmentDrain(
            stagingRootURL: stagingRoot,
            ledger: ledger,
            transferEnqueuer: transferHarness.enqueuer,
            transferEngine: transferHarness.engine
        )

        await drain.drain()
        let snapshots = await transferHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.watch)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id))
        ledger.recordHanded(id: manifest.id)
        drain.removeStaged(manifest.id)
        XCTAssertEqual(ledger.lifetimeReceived, 1)
        XCTAssertEqual(ledger.lifetimeHanded, 1)
        XCTAssertEqual(ledger.nonTerminalCount, 0)
        XCTAssertTrue(ledger.isTerminal(id: manifest.id))

        let store = try self.loadStore(ledgerURL)
        let entry = try XCTUnwrap(store.entries[manifest.id.uuidString])
        XCTAssertNotNil(entry.handedAt)
        XCTAssertNil(entry.droppedAt)

        ledger.recordHanded(id: manifest.id)
        XCTAssertEqual(ledger.lifetimeHanded, 1)
    }

    @MainActor
    func testDrainUsesManifestTimeForCrossMidnightAndSkewedSegments() async throws {
        WatchDrainURLProtocol.handler = Self.okResponse
        try await self.assertManifestValuesSurviveDrain(
            manifest: self.makeManifest(
                day: "20260602",
                segment: "235800_120",
                startedAt: Date(timeIntervalSince1970: 1_780_467_480),
                duration: 120
            )
        )
        WatchDrainURLProtocol.reset()
        WatchDrainURLProtocol.handler = Self.okResponse
        try await self.assertManifestValuesSurviveDrain(
            manifest: self.makeManifest(
                day: "20380119",
                segment: "031407_60",
                startedAt: Date(timeIntervalSince1970: 2_147_483_647),
                duration: 60
            )
        )
    }

    @MainActor
    func testAudioAndLocationAreCoLocatedInOnePost() async throws {
        WatchDrainURLProtocol.handler = Self.okResponse
        let stagingRoot = self.stagingRootURL()
        let locationBytes = Data(#"{"lat":40.0,"lon":-105.0}"#.utf8) + Data([0x0A])
        let manifest = self.makeManifest(sensors: [.audio, .location], fixCount: 1)
        try self.writeStagedSegment(
            stagingRoot: stagingRoot,
            manifest: manifest,
            audioData: Data("known audio".utf8),
            locationData: locationBytes
        )
        let transferHarness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("audio-location-transfer", isDirectory: true)
        )
        let drain = try WatchSegmentDrain(
            stagingRootURL: stagingRoot,
            ledger: WatchSegmentLedger(fileURL: self.ledgerFileURL(name: "audio-location-ledger")),
            transferEnqueuer: transferHarness.enqueuer,
            transferEngine: transferHarness.engine
        )

        await drain.drain()

        let snapshots = await transferHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.watch)
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshot.manifest.observerIngest?.platform, "watchos")
        XCTAssertEqual(snapshot.manifest.observerIngest?.sources, ["audio", "location"])
        XCTAssertEqual(snapshot.manifest.payloadParts.map(\.partID), ["audio", "location"])
        XCTAssertTrue(self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id))
    }

    @MainActor
    func testLocationOnlySegmentUsesDirectWatchPostAndColdStartHolds() async throws {
        let coldStagingRoot = self.stagingRootURL(name: "cold-location-staging")
        let coldManifest = self.makeManifest(sensors: [.location], fixCount: 1)
        try self.writeStagedSegment(
            stagingRoot: coldStagingRoot,
            manifest: coldManifest,
            locationData: Data(#"{"cold":true}"#.utf8) + Data([0x0A])
        )
        let coldHarness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("cold-location-transfer", isDirectory: true)
        )
        let coldDrain = try WatchSegmentDrain(
            stagingRootURL: coldStagingRoot,
            ledger: WatchSegmentLedger(fileURL: self.ledgerFileURL(name: "cold-location-ledger")),
            transferEnqueuer: coldHarness.enqueuer,
            transferEngine: coldHarness.engine
        )

        await coldDrain.drain()

        let coldSnapshots = await coldHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.watch)
        XCTAssertEqual(coldSnapshots.count, 1)
        XCTAssertTrue(self.stagedSegmentExists(stagingRoot: coldStagingRoot, id: coldManifest.id))

        WatchDrainURLProtocol.reset()
        WatchDrainURLProtocol.handler = Self.okResponse
        let stagingRoot = self.stagingRootURL(name: "location-staging")
        let locationBytes = Data(#"{"location":true}"#.utf8) + Data([0x0A])
        let manifest = self.makeManifest(day: "20260604", segment: "010203_45", duration: 45, sensors: [.location], fixCount: 1)
        try self.writeStagedSegment(
            stagingRoot: stagingRoot,
            manifest: manifest,
            locationData: locationBytes
        )
        let transferHarness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("location-transfer", isDirectory: true)
        )
        let drain = try WatchSegmentDrain(
            stagingRootURL: stagingRoot,
            ledger: WatchSegmentLedger(fileURL: self.ledgerFileURL(name: "location-ledger")),
            transferEnqueuer: transferHarness.enqueuer,
            transferEngine: transferHarness.engine
        )

        await drain.drain()

        let locationSnapshots = await transferHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.watch)
        let locationSnapshot = try XCTUnwrap(locationSnapshots.first)
        XCTAssertEqual(locationSnapshot.manifest.observerIngest?.platform, "watchos")
        XCTAssertEqual(locationSnapshot.manifest.observerIngest?.segment, manifest.segment)
        XCTAssertEqual(locationSnapshot.manifest.observerIngest?.day, manifest.day)
        XCTAssertEqual(locationSnapshot.manifest.observerIngest?.sources, ["location"])
        XCTAssertEqual(locationSnapshot.manifest.payloadParts.map(\.partID), ["location"])
        XCTAssertTrue(self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id))
    }

    @MainActor
    func testAC2LocationOnlyHandoffRecordsHandedOnceAndRemovesStaging() async throws {
        let stagingRoot = self.stagingRootURL(name: "ac2-location")
        let ledgerURL = self.ledgerFileURL(name: "ac2-location-ledger")
        let ledger = WatchSegmentLedger(fileURL: ledgerURL)
        let manifest = self.makeManifest(sensors: [.location], fixCount: 1)
        try self.writeStagedSegment(
            stagingRoot: stagingRoot,
            manifest: manifest,
            locationData: Data(#"{"location":true}"#.utf8) + Data([0x0A])
        )
        let transferHarness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("ac2-location-transfer", isDirectory: true)
        )
        let drain = try WatchSegmentDrain(
            stagingRootURL: stagingRoot,
            ledger: ledger,
            transferEnqueuer: transferHarness.enqueuer,
            transferEngine: transferHarness.engine
        )

        await drain.drain()

        let snapshots = await transferHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.watch)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id))
        ledger.recordHanded(id: manifest.id)
        drain.removeStaged(manifest.id)
        XCTAssertEqual(ledger.lifetimeReceived, 1)
        XCTAssertEqual(ledger.lifetimeHanded, 1)
        XCTAssertEqual(ledger.nonTerminalCount, 0)
        XCTAssertTrue(ledger.isTerminal(id: manifest.id))
        XCTAssertFalse(self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id))

        let store = try self.loadStore(ledgerURL)
        let entry = try XCTUnwrap(store.entries[manifest.id.uuidString])
        XCTAssertNotNil(entry.handedAt)
        XCTAssertNil(entry.droppedAt)

        ledger.recordHanded(id: manifest.id)
        XCTAssertEqual(ledger.lifetimeHanded, 1)
    }

    @MainActor
    func testAC5aDrainSkipsTerminalStagingAndCleansUp() async throws {
        WatchDrainURLProtocol.handler = Self.okResponse
        let stagingRoot = self.stagingRootURL(name: "ac5a-terminal")
        let ledger = WatchSegmentLedger(fileURL: self.ledgerFileURL(name: "ac5a-terminal-ledger"))
        let manifest = self.makeManifest()
        ledger.recordReceived(id: manifest.id)
        ledger.recordHanded(id: manifest.id)
        try self.writeStagedSegment(stagingRoot: stagingRoot, manifest: manifest, audioData: Data("audio".utf8))
        let drain = try self.makeDrain(stagingRoot: stagingRoot, ledger: ledger)

        await drain.drain()

        XCTAssertEqual(WatchDrainURLProtocol.capturedRequests.count, 0)
        XCTAssertFalse(self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id))
        XCTAssertEqual(ledger.lifetimeHanded, 1)
    }

    @MainActor
    func testDrainDropsFilesLessStagedSegmentAndRemovesStaging() async throws {
        let stagingRoot = self.stagingRootURL(name: "files-less-staging")
        let ledger = WatchSegmentLedger(fileURL: self.ledgerFileURL(name: "files-less-ledger"))
        let manifest = self.makeManifest()
        ledger.recordReceived(id: manifest.id)
        try self.writeStagedSegment(stagingRoot: stagingRoot, manifest: manifest)
        let drain = try self.makeDrain(stagingRoot: stagingRoot, ledger: ledger)

        await drain.drain()

        XCTAssertFalse(self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id))
        XCTAssertTrue(ledger.isTerminal(id: manifest.id))
        XCTAssertEqual(ledger.nonTerminalCount, 0)
        XCTAssertEqual(ledger.lifetimeReceived, 1)
    }

    @MainActor
    func testDrainTripsMaintenanceCheckpointsForLargeStagedBacklog() async throws {
        WatchDrainURLProtocol.handler = Self.okResponse
        let stagingRoot = self.stagingRootURL(name: "checkpoint-staging")
        for _ in 0..<6 {
            try self.writeStagedSegment(
                stagingRoot: stagingRoot,
                manifest: self.makeManifest(),
                audioData: Data("audio".utf8)
            )
        }
        let cooperator = MaintenanceCooperator(chunkSize: 2)
        let drain = try self.makeDrain(stagingRoot: stagingRoot, cooperator: cooperator)

        await drain.drain()

        XCTAssertGreaterThan(cooperator.checkpointCount, 0)
    }
}

private extension WatchSegmentDrainTests {
    static func okResponse(request: URLRequest) throws -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            Data(#"{"status":"ok"}"#.utf8)
        )
    }

    @MainActor
    func makeDrain(
        stagingRoot: URL,
        ledger: WatchSegmentLedger? = nil,
        cooperator: MaintenanceCooperator = MaintenanceCooperator()
    ) throws -> WatchSegmentDrain {
        let transferHarness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("watch-transfer-\(UUID().uuidString)", isDirectory: true)
        )
        return try WatchSegmentDrain(
            stagingRootURL: stagingRoot,
            ledger: ledger ?? WatchSegmentLedger(fileURL: self.ledgerFileURL(name: "ledger-\(UUID().uuidString)")),
            transferEnqueuer: transferHarness.enqueuer,
            transferEngine: transferHarness.engine,
            cooperator: cooperator
        )
    }

    func makeCapturedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WatchDrainURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func stagingRootURL(name: String = "staging") -> URL {
        self.tempDirectory.appendingPathComponent(name, isDirectory: true)
    }

    func ledgerFileURL(name: String = "ledger") -> URL {
        self.tempDirectory
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("ledger.json", isDirectory: false)
    }

    func loadStore(_ fileURL: URL) throws -> WatchSegmentLedgerStore {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WatchSegmentLedgerStore.self, from: data)
    }

    func makeManifest(
        id: UUID = UUID(),
        day: String = "20260603",
        segment: String = "120000_300",
        startedAt: Date = Date(timeIntervalSince1970: 1_780_444_800),
        duration: Double = 300,
        sensors: [WatchSensor] = [.audio],
        fixCount: Int = 0
    ) -> WatchSegmentManifest {
        WatchSegmentManifest(
            id: id,
            day: day,
            segment: segment,
            startedAt: startedAt,
            duration: duration,
            sensors: sensors,
            partial: false,
            lost: false,
            gap: false,
            fixCount: fixCount,
            state: .finalized,
            failureReason: nil
        )
    }

    @MainActor
    func writeStagedSegment(
        stagingRoot: URL,
        manifest: WatchSegmentManifest,
        audioData: Data? = nil,
        locationData: Data? = nil
    ) throws {
        let directory = stagingRoot.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent(WatchSegmentBundleCodec.manifestFilename, isDirectory: false),
            options: .atomic
        )
        if let audioData {
            try audioData.write(
                to: directory.appendingPathComponent(WatchSegmentBundleCodec.audioFilename, isDirectory: false),
                options: .atomic
            )
        }
        if let locationData {
            try locationData.write(
                to: directory.appendingPathComponent(WatchSegmentBundleCodec.locationFilename, isDirectory: false),
                options: .atomic
            )
        }
    }

    func stagedSegmentExists(stagingRoot: URL, id: UUID) -> Bool {
        FileManager.default.fileExists(
            atPath: stagingRoot.appendingPathComponent(id.uuidString, isDirectory: true).path
        )
    }

    func capturedBodyString(index: Int = 0) throws -> String {
        let body = try XCTUnwrap(WatchDrainURLProtocol.capturedBodies[safe: index])
        return String(decoding: body, as: UTF8.self)
    }

    func filesPartCount(in body: String) -> Int {
        body.components(separatedBy: "name=\"files\"").count - 1
    }

    @MainActor
    func assertManifestValuesSurviveDrain(manifest: WatchSegmentManifest) async throws {
        let stagingRoot = self.stagingRootURL(name: "staging-\(manifest.id.uuidString)")
        try self.writeStagedSegment(stagingRoot: stagingRoot, manifest: manifest, audioData: Data("audio".utf8))
        let transferHarness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("manifest-transfer-\(manifest.id.uuidString)", isDirectory: true)
        )
        let drain = try WatchSegmentDrain(
            stagingRootURL: stagingRoot,
            ledger: WatchSegmentLedger(fileURL: self.ledgerFileURL(name: "manifest-ledger-\(manifest.id.uuidString)")),
            transferEnqueuer: transferHarness.enqueuer,
            transferEngine: transferHarness.engine
        )

        await drain.drain()

        let snapshots = await transferHarness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.watch)
        let snapshot = try XCTUnwrap(snapshots.first)
        let ingest = try XCTUnwrap(snapshot.manifest.observerIngest)
        XCTAssertEqual(ingest.segment, manifest.segment)
        XCTAssertEqual(ingest.day, manifest.day)
        XCTAssertEqual(ingest.startedAt, manifest.startedAt)
        XCTAssertEqual(ingest.durationS, manifest.duration)
        XCTAssertEqual(ingest.sessionID, manifest.id)
        XCTAssertTrue(self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id))
    }

    @MainActor
    func waitFor(
        _ label: String,
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(label)")
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private final class WatchDrainURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let callCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)
    private static let bodiesBox = OSAllocatedUnfairLock<[Data]>(initialState: [])
    private static let capturedRequestsBox = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }
    static var callCount: Int {
        get { self.callCountBox.withLock { $0 } }
        set { self.callCountBox.withLock { $0 = newValue } }
    }
    static var capturedBodies: [Data] {
        get { self.bodiesBox.withLock { $0 } }
        set { self.bodiesBox.withLock { $0 = newValue } }
    }
    static var capturedRequests: [URLRequest] {
        get { self.capturedRequestsBox.withLock { $0 } }
        set { self.capturedRequestsBox.withLock { $0 = newValue } }
    }

    static func reset() {
        self.handler = nil
        self.callCount = 0
        self.capturedBodies = []
        self.capturedRequests = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.callCountBox.withLock { $0 += 1 }
        Self.capturedRequestsBox.withLock { $0.append(self.request) }
        Self.bodiesBox.withLock { $0.append(Self.bodyData(from: self.request)) }
        guard let handler = Self.handler else {
            XCTFail("WatchDrainURLProtocol handler not set")
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }

        var output = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 {
                break
            }
            output.append(buffer, count: read)
        }
        return output
    }
}

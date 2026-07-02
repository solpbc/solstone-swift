// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class WatchSegmentDrainTests: XCTestCase {
    private let watchHandle = "watch-handle-xyz"
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
    func testWatchUploaderUsesWatchAuthorizationOnly() async throws {
        WatchDrainURLProtocol.handler = Self.okResponse
        let watchHandle = self.watchHandle
        let uploader = self.makeWatchUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("watch-uploader", isDirectory: true),
            ensureRegistered: { watchHandle }
        )
        let sessionID = UUID()
        let chunkURL = self.tempDirectory.appendingPathComponent("watch-direct.m4a", isDirectory: false)
        try Data("watch audio".utf8).write(to: chunkURL)

        await uploader.enqueue(
            chunkURL: chunkURL,
            sidecar: ChunkSidecar(
                segment: "120000_300",
                day: "20260603",
                chunkIndex: 0,
                startedAt: Date(timeIntervalSince1970: 1_780_444_800),
                durationS: 300,
                sessionID: sessionID,
                mode: .meeting,
                locationJSONL: nil
            )
        )

        try await self.waitFor("watch direct upload") {
            WatchDrainURLProtocol.capturedRequests.count == 1 && uploader.pendingCount == 0
        }
        let request = try XCTUnwrap(WatchDrainURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.watchHandle)")
        XCTAssertNotEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-observer-key-abc")
        XCTAssertNotEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer omi-handle-xyz")
        let body = try self.capturedBodyString()
        XCTAssertEqual(try self.multipartValue(named: "platform", in: body), "watchos")
    }

    @MainActor
    func testColdStartNoMergeHoldsThenResumesUnderWatchKey() async throws {
        WatchDrainURLProtocol.handler = Self.okResponse
        let registrationResolved = OSAllocatedUnfairLock<Bool>(initialState: false)
        let watchHandle = self.watchHandle
        let stagingRoot = self.stagingRootURL()
        let manifest = self.makeManifest()
        try self.writeStagedSegment(stagingRoot: stagingRoot, manifest: manifest, audioData: Data("audio".utf8))
        let uploader = self.makeWatchUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("cold-uploader", isDirectory: true),
            ensureRegistered: {
                if registrationResolved.withLock({ $0 }) {
                    return watchHandle
                }
                throw ObserverUploaderError.registrationUnavailable
            },
            maxAttempts: 1
        )
        let drain = try WatchSegmentDrain(
            stagingRootURL: stagingRoot,
            ledger: WatchSegmentLedger(fileURL: self.ledgerFileURL(name: "cold-ledger")),
            watchUploader: uploader,
            watchRegistration: self.makeWatchRegistration(loadKey: nil, activeLocalPort: nil),
            localPortProvider: { 7071 },
            tempDirectoryURL: self.tempDirectory.appendingPathComponent("cold-temp", isDirectory: true)
        )

        await drain.drain()
        try await self.waitFor("cold-start hold") {
            uploader.pendingCount + uploader.failedCount == 1
        }

        XCTAssertEqual(WatchDrainURLProtocol.capturedRequests.count, 0)
        XCTAssertTrue(self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id))
        XCTAssertNil(uploader.lastUploadAt)

        registrationResolved.withLock { $0 = true }
        await uploader.reconcilePortAndResume()
        await uploader.retryFailed()
        await drain.drain()

        try await self.waitFor("cold-start resume") {
            WatchDrainURLProtocol.capturedRequests.count == 1
                && uploader.pendingCount == 0
                && uploader.failedCount == 0
                && !self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id)
        }
        let request = try XCTUnwrap(WatchDrainURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.watchHandle)")
    }

    @MainActor
    func testDrainIsIdempotentAndRemovesStagingAfterTwoHundred() async throws {
        WatchDrainURLProtocol.handler = Self.okResponse
        let stagingRoot = self.stagingRootURL()
        let manifest = self.makeManifest()
        try self.writeStagedSegment(stagingRoot: stagingRoot, manifest: manifest, audioData: Data("audio".utf8))
        let drain = try self.makeDrain(stagingRoot: stagingRoot)

        await drain.drain()

        try await self.waitFor("staging removal") {
            WatchDrainURLProtocol.capturedRequests.count == 1
                && !self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id)
        }

        await drain.drain()

        XCTAssertEqual(WatchDrainURLProtocol.capturedRequests.count, 1)
        XCTAssertFalse(self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id))
    }

    @MainActor
    func testAC2AudioHandoffRecordsHandedOnceAndRemovesStaging() async throws {
        WatchDrainURLProtocol.handler = Self.okResponse
        let stagingRoot = self.stagingRootURL(name: "ac2-audio")
        let ledgerURL = self.ledgerFileURL(name: "ac2-audio-ledger")
        let ledger = WatchSegmentLedger(fileURL: ledgerURL)
        let manifest = self.makeManifest()
        try self.writeStagedSegment(stagingRoot: stagingRoot, manifest: manifest, audioData: Data("audio".utf8))
        let watchHandle = self.watchHandle
        let uploader = self.makeWatchUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("ac2-audio-uploader", isDirectory: true),
            ensureRegistered: { watchHandle }
        )
        let drain = try WatchSegmentDrain(
            stagingRootURL: stagingRoot,
            ledger: ledger,
            watchUploader: uploader,
            watchRegistration: self.makeWatchRegistration(loadKey: self.watchHandle, activeLocalPort: 7071),
            localPortProvider: { 7071 },
            tempDirectoryURL: self.tempDirectory.appendingPathComponent("ac2-audio-temp", isDirectory: true)
        )

        await drain.drain()
        try await self.waitFor("audio handoff") {
            WatchDrainURLProtocol.capturedRequests.count == 1
                && !self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id)
        }
        XCTAssertEqual(ledger.lifetimeReceived, 1)
        XCTAssertEqual(ledger.lifetimeHanded, 1)
        XCTAssertEqual(ledger.nonTerminalCount, 0)
        XCTAssertTrue(ledger.isTerminal(id: manifest.id))

        let store = try self.loadStore(ledgerURL)
        let entry = try XCTUnwrap(store.entries[manifest.id.uuidString])
        XCTAssertNotNil(entry.handedAt)
        XCTAssertNil(entry.droppedAt)

        uploader.onSegmentDelivered?(manifest.id)
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
        let drain = try self.makeDrain(stagingRoot: stagingRoot)

        await drain.drain()

        try await self.waitFor("audio location upload") {
            WatchDrainURLProtocol.capturedRequests.count == 1
                && !self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id)
        }
        let body = try self.capturedBodyString()
        XCTAssertEqual(try self.multipartValue(named: "platform", in: body), "watchos")
        XCTAssertEqual(self.filesPartCount(in: body), 2)
        XCTAssertTrue(body.contains("name=\"files\"; filename=\"audio.m4a\""))
        XCTAssertFalse(body.contains("name=\"" + "files" + "[]\""))
        XCTAssertTrue(body.contains("Content-Type: audio/mp4"))
        XCTAssertTrue(body.contains("name=\"files\"; filename=\"location.jsonl\""))
        XCTAssertTrue(body.contains("Content-Type: application/x-ndjson"))
        XCTAssertTrue(body.contains(String(decoding: locationBytes, as: UTF8.self)))
        XCTAssertFalse(body.contains("filename=\"\(manifest.id.uuidString).m4a\""))
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
        let coldDrain = try self.makeDrain(
            stagingRoot: coldStagingRoot,
            watchRegistration: self.makeWatchRegistration(loadKey: nil, activeLocalPort: nil),
            localPortProvider: { 7071 },
            directSession: self.makeCapturedSession(),
            tempName: "cold-location-temp"
        )

        await coldDrain.drain()

        XCTAssertEqual(WatchDrainURLProtocol.capturedRequests.count, 0)
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
        let ingestURL = try XCTUnwrap(URL(string: "http://127.0.0.1:7071/app/observer/ingest"))
        let drain = try self.makeDrain(
            stagingRoot: stagingRoot,
            directSession: self.makeCapturedSession(),
            urlBuilder: { _ in ingestURL },
            tempName: "location-temp"
        )

        await drain.drain()

        XCTAssertEqual(WatchDrainURLProtocol.capturedRequests.count, 1)
        let request = try XCTUnwrap(WatchDrainURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url, ingestURL)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.watchHandle)")
        let body = try self.capturedBodyString()
        XCTAssertEqual(try self.multipartValue(named: "platform", in: body), "watchos")
        XCTAssertEqual(try self.multipartValue(named: "segment", in: body), manifest.segment)
        XCTAssertEqual(try self.multipartValue(named: "day", in: body), manifest.day)
        XCTAssertEqual(self.filesPartCount(in: body), 1)
        XCTAssertTrue(body.contains("name=\"files\"; filename=\"location.jsonl\""))
        XCTAssertFalse(body.contains("name=\"" + "files" + "[]\""))
        XCTAssertFalse(body.contains("filename=\"audio.m4a\""))
        XCTAssertTrue(body.contains(String(decoding: locationBytes, as: UTF8.self)))
        XCTAssertFalse(self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id))
    }

    @MainActor
    func testAC2LocationOnlyHandoffRecordsHandedOnceAndRemovesStaging() async throws {
        WatchDrainURLProtocol.handler = Self.okResponse
        let stagingRoot = self.stagingRootURL(name: "ac2-location")
        let ledgerURL = self.ledgerFileURL(name: "ac2-location-ledger")
        let ledger = WatchSegmentLedger(fileURL: ledgerURL)
        let manifest = self.makeManifest(sensors: [.location], fixCount: 1)
        try self.writeStagedSegment(
            stagingRoot: stagingRoot,
            manifest: manifest,
            locationData: Data(#"{"location":true}"#.utf8) + Data([0x0A])
        )
        let drain = try self.makeDrain(
            stagingRoot: stagingRoot,
            ledger: ledger,
            directSession: self.makeCapturedSession(),
            tempName: "ac2-location-temp"
        )

        await drain.drain()

        XCTAssertEqual(WatchDrainURLProtocol.capturedRequests.count, 1)
        XCTAssertFalse(self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id))
        XCTAssertEqual(ledger.lifetimeReceived, 1)
        XCTAssertEqual(ledger.lifetimeHanded, 1)
        XCTAssertEqual(ledger.nonTerminalCount, 0)

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
}

private extension WatchSegmentDrainTests {
    static func okResponse(request: URLRequest) throws -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            Data("ok".utf8)
        )
    }

    @MainActor
    func makeDrain(
        stagingRoot: URL,
        ledger: WatchSegmentLedger? = nil,
        watchRegistration: ObserverRegistration? = nil,
        localPortProvider: @escaping @Sendable @MainActor () -> Int? = { 7071 },
        directSession: URLSession = .shared,
        urlBuilder: @escaping @Sendable (Int) -> URL? = { ObserverServerURL.ingestURL(localPort: $0) },
        tempName: String = "watch-drain-temp"
    ) throws -> WatchSegmentDrain {
        let watchHandle = self.watchHandle
        let uploader = self.makeWatchUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("watch-cache-\(UUID().uuidString)", isDirectory: true),
            ensureRegistered: { watchHandle }
        )
        return try WatchSegmentDrain(
            stagingRootURL: stagingRoot,
            ledger: ledger ?? WatchSegmentLedger(fileURL: self.ledgerFileURL(name: "ledger-\(UUID().uuidString)")),
            watchUploader: uploader,
            watchRegistration: watchRegistration ?? self.makeWatchRegistration(loadKey: self.watchHandle, activeLocalPort: 7071),
            localPortProvider: localPortProvider,
            session: directSession,
            urlBuilder: urlBuilder,
            tempDirectoryURL: self.tempDirectory.appendingPathComponent(tempName, isDirectory: true)
        )
    }

    @MainActor
    func makeWatchUploader(
        cacheRootURL: URL,
        ensureRegistered: @escaping @Sendable @MainActor () async throws -> String,
        isJournalConfigured: @escaping @Sendable @MainActor () -> Bool = { true },
        localPortProvider: @escaping @Sendable @MainActor () -> Int? = { 7071 },
        maxAttempts: Int = 5
    ) -> ObserverUploader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WatchDrainURLProtocol.self]
        return ObserverUploader(
            cacheRootURL: cacheRootURL,
            sessionConfiguration: configuration,
            ensureRegistered: ensureRegistered,
            isJournalConfigured: isJournalConfigured,
            localPortProvider: localPortProvider,
            sourceType: "watch-audio",
            platform: "watchos",
            retryDelays: [0],
            maxAttempts: maxAttempts,
            sleep: { _ in },
            startPathMonitor: false
        )
    }

    @MainActor
    func makeWatchRegistration(loadKey: String?, activeLocalPort: Int?) -> ObserverRegistration {
        let registration = ObserverRegistration(
            hostname: "test-phone",
            version: "0.1.0",
            streamType: "watch",
            label: "watch",
            retryDelays: [],
            sleep: { _ in },
            loadKey: { loadKey },
            saveKey: { _ in },
            deleteKey: {},
            loadPrefix: { nil },
            savePrefix: { _ in },
            deletePrefix: {}
        )
        registration.activeLocalPort = activeLocalPort
        return registration
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

    func multipartValue(named name: String, in body: String) throws -> String {
        let marker = "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
        let start = try XCTUnwrap(body.range(of: marker))
        let rest = body[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\r\n--"))
        return String(rest[..<end.lowerBound])
    }

    func multipartMeta(in body: String) throws -> [String: Any] {
        let value = try self.multipartValue(named: "meta", in: body)
        let object = try JSONSerialization.jsonObject(with: Data(value.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    func filesPartCount(in body: String) -> Int {
        body.components(separatedBy: "name=\"files\"").count - 1
    }

    @MainActor
    func assertManifestValuesSurviveDrain(manifest: WatchSegmentManifest) async throws {
        let stagingRoot = self.stagingRootURL(name: "staging-\(manifest.id.uuidString)")
        try self.writeStagedSegment(stagingRoot: stagingRoot, manifest: manifest, audioData: Data("audio".utf8))
        let drain = try self.makeDrain(stagingRoot: stagingRoot, tempName: "temp-\(manifest.id.uuidString)")

        await drain.drain()

        try await self.waitFor("manifest-value upload") {
            WatchDrainURLProtocol.capturedRequests.count == 1
                && !self.stagedSegmentExists(stagingRoot: stagingRoot, id: manifest.id)
        }
        let body = try self.capturedBodyString()
        XCTAssertEqual(try self.multipartValue(named: "segment", in: body), manifest.segment)
        XCTAssertEqual(try self.multipartValue(named: "day", in: body), manifest.day)
        let meta = try self.multipartMeta(in: body)
        XCTAssertEqual(meta["segment"] as? String, manifest.segment)
        XCTAssertEqual(meta["day"] as? String, manifest.day)
        XCTAssertEqual(meta["started_at"] as? String, ISO8601DateFormatter().string(from: manifest.startedAt))
        XCTAssertEqual(meta["duration_s"] as? Double, manifest.duration)
        XCTAssertEqual(meta["session_id"] as? String, manifest.id.uuidString)
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

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class ObserverHealthBeaconTests: XCTestCase {
    private struct SourceKind: Sendable {
        let label: String
        let streamType: String
        let sourceType: String
        let prefix: String
        let version: String

        static let all: [SourceKind] = [
            SourceKind(label: "mobile", streamType: "mobile", sourceType: "observer-audio", prefix: "obs_mobile_", version: "1.2.3"),
            SourceKind(label: "omi", streamType: "omi", sourceType: "omi-audio", prefix: "obs_omi_", version: "1.2.4"),
            SourceKind(label: "watch", streamType: "watch", sourceType: "watch-audio", prefix: "obs_watch_", version: "1.2.5"),
        ]
    }

    private let expectedPayloadKeys: Set<String> = [
        "name",
        "stream_type",
        "version",
        "uptime",
        "last_successful_sync",
        "pending_queue_depth",
        "recent_error_count",
        "last_error_reason",
    ]
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObserverHealthBeaconTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        Self.resetURLProtocols()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        Self.resetURLProtocols()
        super.tearDown()
    }

    @MainActor
    func testEachSourceKindEmitsExpectedHealthPayload() async throws {
        for source in SourceKind.all {
            Self.resetURLProtocols()
            ObserverHealthBeaconURLProtocol.handler = { request in
                (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8)
                )
            }
            let clock = MockObserverClock()
            let beacon = self.makeBeacon(source: source, clock: clock)

            beacon.start()
            try await self.waitFor("health request for \(source.label)") {
                ObserverHealthBeaconURLProtocol.callCount == 1
            }
            beacon.stop()

            let request = try XCTUnwrap(ObserverHealthBeaconURLProtocol.capturedRequests.first)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/app/observer/health")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-observer-key-abc")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body = try self.firstPayload()
            XCTAssertEqual(Set(body.keys), self.expectedPayloadKeys)
            XCTAssertEqual(body["name"] as? String, source.prefix)
            XCTAssertEqual(body["stream_type"] as? String, source.streamType)
            XCTAssertEqual(body["version"] as? String, source.version)
        }
    }

    @MainActor
    func testStartEmitsImmediatelyThenPeriodicallyWithUptime() async throws {
        ObserverHealthBeaconURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{}".utf8)
            )
        }
        let clock = MockObserverClock()
        let beacon = self.makeBeacon(source: SourceKind.all[0], clock: clock, interval: .seconds(300))

        beacon.start()
        try await self.waitFor("initial beacon sleep") {
            ObserverHealthBeaconURLProtocol.callCount == 1 && self.pendingSleeperCount(in: clock) == 1
        }
        let first = try self.payload(at: 0)
        XCTAssertEqual(first["uptime"] as? Int, 0)

        clock.advance(by: 300)
        try await self.waitFor("periodic beacon sleep") {
            ObserverHealthBeaconURLProtocol.callCount == 2 && self.pendingSleeperCount(in: clock) == 1
        }
        beacon.stop()

        let second = try self.payload(at: 1)
        XCTAssertEqual(second["uptime"] as? Int, 300)
    }

    @MainActor
    func testSkipGatesDoNotEmitHealthOrRegister() async throws {
        struct SkipCase {
            let label: String
            let paired: Bool
            let port: Int?
            let key: String?
            let prefix: String?
        }
        let source = SourceKind.all[0]
        let cases = [
            SkipCase(label: "unpaired", paired: false, port: 7071, key: "test-observer-key-abc", prefix: source.prefix),
            SkipCase(label: "no port", paired: true, port: nil, key: "test-observer-key-abc", prefix: source.prefix),
            SkipCase(label: "idle", paired: true, port: 7071, key: nil, prefix: source.prefix),
        ]

        for item in cases {
            Self.resetURLProtocols()
            ObserverHealthBeaconURLProtocol.handler = { request in
                XCTFail("unexpected health request for \(item.label): \(request)")
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            let clock = MockObserverClock()
            let registration = self.makeRegistration(source: source, key: item.key, prefix: item.prefix, localPort: item.port)
            let uploader = self.makeUploader()
            let beacon = ObserverHealthBeacon(
                registration: registration,
                uploader: uploader,
                isJournalConfigured: { item.paired },
                session: self.makeHealthSession(),
                clock: clock,
                interval: .seconds(300)
            )

            beacon.start()
            try await Task.sleep(for: .milliseconds(50))
            beacon.stop()

            XCTAssertEqual(ObserverHealthBeaconURLProtocol.callCount, 0, item.label)
            XCTAssertEqual(ObserverHealthRegistrationURLProtocol.callCount, 0, item.label)
        }
    }

    @MainActor
    func testMissingPersistedPrefixBackfillsAndEmitsHealth() async throws {
        ObserverHealthBeaconURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{}".utf8)
            )
        }
        let source = SourceKind.all[0]
        let key = "ABCDEFGH1234567890"
        let clock = MockObserverClock()
        let registration = self.makeRegistration(source: source, key: key, prefix: nil, localPort: 7071)
        let uploader = self.makeUploader()
        let beacon = ObserverHealthBeacon(
            registration: registration,
            uploader: uploader,
            isJournalConfigured: { true },
            session: self.makeHealthSession(),
            clock: clock,
            interval: .seconds(300)
        )

        beacon.start()
        try await self.waitFor("health with backfilled prefix") {
            ObserverHealthBeaconURLProtocol.callCount == 1
        }
        beacon.stop()

        XCTAssertEqual(registration.registrationPrefix, "ABCDEFGH")
        let body = try self.firstPayload()
        XCTAssertEqual(body["name"] as? String, "ABCDEFGH")
    }

    @MainActor
    func testPayloadKeepsExactKeySetWhenLastErrorIsPresent() async throws {
        ObserverHealthBeaconURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{}".utf8)
            )
        }
        let source = SourceKind.all[0]
        let clock = MockObserverClock()
        let registration = self.makeRegistration(source: source, key: "test-observer-key-abc", prefix: source.prefix, localPort: 7071)
        let uploader = self.makeUploader()
        uploader.lastError = "first line\nsecond line Bearer secret-token"
        let beacon = ObserverHealthBeacon(
            registration: registration,
            uploader: uploader,
            isJournalConfigured: { true },
            session: self.makeHealthSession(),
            clock: clock
        )

        beacon.start()
        try await self.waitFor("health with error") {
            ObserverHealthBeaconURLProtocol.callCount == 1
        }
        beacon.stop()

        let body = try self.firstPayload()
        XCTAssertEqual(Set(body.keys), self.expectedPayloadKeys)
        let reason = try XCTUnwrap(body["last_error_reason"] as? String)
        XCTAssertFalse(reason.contains("\n"))
        XCTAssertFalse(reason.contains("secret-token"))
    }

    @MainActor
    func testPayloadMapsUploaderStateAndLastSuccessfulSync() async throws {
        ObserverHealthBeaconURLProtocol.handler = { request in
            if request.url?.path == "/app/observer/ingest" {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                    Data("service unavailable".utf8)
                )
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{}".utf8)
            )
        }
        let source = SourceKind.all[0]
        let start = Date(timeIntervalSince1970: 1_713_624_000)
        let clock = MockObserverClock(now: start)
        let registration = self.makeRegistration(source: source, key: "test-observer-key-abc", prefix: source.prefix, localPort: 7071)
        let uploader = self.makeUploader()
        uploader.failedCount = 1
        uploader.recentErrorCount = 1
        XCTAssertEqual(uploader.recentErrorCount, 1)
        ObserverHealthBeaconURLProtocol.callCount = 0
        ObserverHealthBeaconURLProtocol.capturedRequests = []
        ObserverHealthBeaconURLProtocol.capturedBodies = []

        uploader.pendingCount = 7
        uploader.lastUploadAt = start.addingTimeInterval(600)
        uploader.lastError = "Authorization: Bearer secret\n" + String(repeating: "x", count: 240)
        let beacon = ObserverHealthBeacon(
            registration: registration,
            uploader: uploader,
            isJournalConfigured: { true },
            session: self.makeHealthSession(),
            clock: clock,
            interval: .seconds(300)
        )

        beacon.start()
        try await self.waitFor("state beacon") {
            ObserverHealthBeaconURLProtocol.callCount == 1 && self.pendingSleeperCount(in: clock) == 1
        }
        let first = try self.payload(at: 0)
        XCTAssertEqual(first["pending_queue_depth"] as? Int, 7)
        XCTAssertEqual(first["recent_error_count"] as? Int, 1)
        XCTAssertEqual(first["last_successful_sync"] as? String, ISO8601DateFormatter().string(from: start.addingTimeInterval(600)))
        let reason = try XCTUnwrap(first["last_error_reason"] as? String)
        XCTAssertLessThanOrEqual(reason.count, 200)
        XCTAssertFalse(reason.contains("\n"))
        XCTAssertFalse(reason.contains("secret"))

        uploader.lastUploadAt = start.addingTimeInterval(-10)
        clock.advance(by: 300)
        try await self.waitFor("prior contact beacon") {
            ObserverHealthBeaconURLProtocol.callCount == 2 && self.pendingSleeperCount(in: clock) == 1
        }
        beacon.stop()
        let second = try self.payload(at: 1)
        XCTAssertEqual(second["last_successful_sync"] as? String, ISO8601DateFormatter().string(from: start))
    }

    @MainActor
    func testPayloadMapsCappedAndResetRecentErrorCount() async throws {
        ObserverHealthBeaconURLProtocol.handler = { request in
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{}".utf8)
            )
        }
        let source = SourceKind.all[0]
        let clock = MockObserverClock()
        let registration = self.makeRegistration(source: source, key: "test-observer-key-abc", prefix: source.prefix, localPort: 7071)
        let uploader = self.makeUploader()
        uploader.failedCount = 1
        uploader.recentErrorCount = 99
        XCTAssertEqual(uploader.recentErrorCount, 99)
        ObserverHealthBeaconURLProtocol.callCount = 0
        ObserverHealthBeaconURLProtocol.capturedRequests = []
        ObserverHealthBeaconURLProtocol.capturedBodies = []

        let beacon = ObserverHealthBeacon(
            registration: registration,
            uploader: uploader,
            isJournalConfigured: { true },
            session: self.makeHealthSession(),
            clock: clock
        )
        beacon.start()
        try await self.waitFor("capped recent error beacon") {
            ObserverHealthBeaconURLProtocol.callCount == 1
        }
        beacon.stop()
        XCTAssertEqual(try self.payload(at: 0)["recent_error_count"] as? Int, 99)

        uploader.lastUploadAt = clock.now()
        uploader.recentErrorCount = 0
        ObserverHealthBeaconURLProtocol.callCount = 0
        ObserverHealthBeaconURLProtocol.capturedRequests = []
        ObserverHealthBeaconURLProtocol.capturedBodies = []

        beacon.start()
        try await self.waitFor("reset recent error beacon") {
            ObserverHealthBeaconURLProtocol.callCount == 1
        }
        beacon.stop()
        XCTAssertEqual(try self.payload(at: 0)["recent_error_count"] as? Int, 0)
    }

    @MainActor
    func testFailedDeliveryDoesNotAdvanceContactAndLaterSuccessStillWorks() async throws {
        enum FailureMode {
            case http500
            case transport
        }

        for mode in [FailureMode.http500, .transport] {
            Self.resetURLProtocols()
            let requestIndex = OSAllocatedUnfairLock<Int>(initialState: 0)
            ObserverHealthBeaconURLProtocol.handler = { request in
                let index = requestIndex.withLock { value in
                    value += 1
                    return value
                }
                if index == 1 {
                    switch mode {
                    case .http500:
                        return (
                            HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                            Data("fail".utf8)
                        )
                    case .transport:
                        throw URLError(.timedOut)
                    }
                }
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{}".utf8)
                )
            }

            let start = Date(timeIntervalSince1970: 1_713_624_000)
            let clock = MockObserverClock(now: start)
            let beacon = self.makeBeacon(source: SourceKind.all[0], clock: clock, interval: .seconds(300))
            beacon.start()
            try await self.waitFor("failed beacon") {
                ObserverHealthBeaconURLProtocol.callCount == 1 && self.pendingSleeperCount(in: clock) == 1
            }
            let failed = try self.payload(at: 0)
            XCTAssertTrue(failed["last_successful_sync"] is NSNull)

            clock.advance(by: 300)
            try await self.waitFor("successful beacon after failure") {
                ObserverHealthBeaconURLProtocol.callCount == 2 && self.pendingSleeperCount(in: clock) == 1
            }
            let afterFailure = try self.payload(at: 1)
            XCTAssertTrue(afterFailure["last_successful_sync"] is NSNull)

            clock.advance(by: 300)
            try await self.waitFor("contact after successful beacon") {
                ObserverHealthBeaconURLProtocol.callCount == 3 && self.pendingSleeperCount(in: clock) == 1
            }
            beacon.stop()
            let afterSuccess = try self.payload(at: 2)
            XCTAssertEqual(afterSuccess["last_successful_sync"] as? String, ISO8601DateFormatter().string(from: start.addingTimeInterval(300)))
        }
    }

    private static func resetURLProtocols() {
        ObserverHealthBeaconURLProtocol.handler = nil
        ObserverHealthBeaconURLProtocol.callCount = 0
        ObserverHealthBeaconURLProtocol.capturedRequests = []
        ObserverHealthBeaconURLProtocol.capturedBodies = []
        ObserverHealthRegistrationURLProtocol.callCount = 0
    }

    @MainActor private func makeBeacon(
        source: SourceKind,
        clock: MockObserverClock,
        interval: Duration = .seconds(300)
    ) -> ObserverHealthBeacon {
        let registration = self.makeRegistration(
            source: source,
            key: "test-observer-key-abc",
            prefix: source.prefix,
            localPort: 7071
        )
        let uploader = self.makeUploader()
        return ObserverHealthBeacon(
            registration: registration,
            uploader: uploader,
            isJournalConfigured: { true },
            session: self.makeHealthSession(),
            clock: clock,
            interval: interval
        )
    }

    @MainActor private func makeRegistration(
        source: SourceKind,
        key: String?,
        prefix: String?,
        localPort: Int?
    ) -> ObserverRegistration {
        let keyBox = OSAllocatedUnfairLock<String?>(initialState: key)
        let prefixBox = OSAllocatedUnfairLock<String?>(initialState: prefix)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObserverHealthRegistrationURLProtocol.self]
        let registration = ObserverRegistration(
            hostname: "test-device",
            version: source.version,
            streamType: source.streamType,
            session: URLSession(configuration: configuration),
            retryDelays: [0],
            sleep: { _ in },
            loadKey: { keyBox.withLock { $0 } },
            saveKey: { value in keyBox.withLock { $0 = value } },
            deleteKey: { keyBox.withLock { $0 = nil } },
            loadPrefix: { prefixBox.withLock { $0 } },
            savePrefix: { value in prefixBox.withLock { $0 = value } },
            deletePrefix: { prefixBox.withLock { $0 = nil } }
        )
        registration.activeLocalPort = localPort
        return registration
    }

    @MainActor private func makeUploader() -> HealthQueueStub {
        HealthQueueStub()
    }

    private func makeHealthSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObserverHealthBeaconURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func firstPayload() throws -> [String: Any] {
        try self.payload(at: 0)
    }

    private func payload(at index: Int) throws -> [String: Any] {
        let bodies = ObserverHealthBeaconURLProtocol.capturedBodies
        let body = try XCTUnwrap(bodies.indices.contains(index) ? bodies[index] : nil)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @MainActor private func waitFor(
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

    @MainActor private func pendingSleeperCount(in clock: MockObserverClock) -> Int {
        guard let sleepers = Mirror(reflecting: clock).children.first(where: { $0.label == "sleepers" }) else {
            return 0
        }
        return Mirror(reflecting: sleepers.value).children.count
    }
}

@MainActor
private final class HealthQueueStub: ObserverQueueHealthProviding {
    var pendingCount = 0
    var failedCount = 0
    var recentErrorCount = 0
    var lastError: String?
    var lastUploadAt: Date?
}

private final class ObserverHealthBeaconURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let callCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)
    private static let capturedRequestsBox = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
    private static let bodiesBox = OSAllocatedUnfairLock<[Data]>(initialState: [])

    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    static var callCount: Int {
        get { self.callCountBox.withLock { $0 } }
        set { self.callCountBox.withLock { $0 = newValue } }
    }

    static var capturedRequests: [URLRequest] {
        get { self.capturedRequestsBox.withLock { $0 } }
        set { self.capturedRequestsBox.withLock { $0 = newValue } }
    }

    static var capturedBodies: [Data] {
        get { self.bodiesBox.withLock { $0 } }
        set { self.bodiesBox.withLock { $0 = newValue } }
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
            XCTFail("ObserverHealthBeaconURLProtocol handler not set")
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

private final class ObserverHealthRegistrationURLProtocol: URLProtocol, @unchecked Sendable {
    private static let callCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)

    static var callCount: Int {
        get { self.callCountBox.withLock { $0 } }
        set { self.callCountBox.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.callCountBox.withLock { $0 += 1 }
        let response = HTTPURLResponse(url: self.request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data())
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

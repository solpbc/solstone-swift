// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

@MainActor
final class MobileSegmentAppWiringTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        MobileSegmentAppWiringURLProtocol.reset()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentAppWiringTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        MobileSegmentAppWiringURLProtocol.reset()
        super.tearDown()
    }

    func testOmiWatchShareIdentitiesStaySeparateFromMobileSegmentEngine() async throws {
        let mobileKeys = KeyBoxes(key: "mobile-key", prefix: "obs_mobile_")
        let omiKeys = KeyBoxes(key: "omi-key", prefix: "obs_omi_")
        let watchKeys = KeyBoxes(key: "watch-key", prefix: "obs_watch_")
        let mobileRegistration = self.registration(streamType: "mobile", keys: mobileKeys)
        let omiRegistration = self.registration(streamType: "omi", label: "omi pendant", keys: omiKeys)
        let watchRegistration = self.registration(streamType: "watch", label: "watch", keys: watchKeys)

        XCTAssertEqual(mobileRegistration.streamType, "mobile")
        XCTAssertEqual(omiRegistration.streamType, "omi")
        XCTAssertEqual(watchRegistration.streamType, "watch")
        XCTAssertEqual(try mobileKeys.loadKey(), "mobile-key")
        XCTAssertEqual(try omiKeys.loadKey(), "omi-key")
        XCTAssertEqual(try watchKeys.loadKey(), "watch-key")
        try omiKeys.saveKey("omi-new")
        XCTAssertEqual(try mobileKeys.loadKey(), "mobile-key")
        XCTAssertEqual(try omiKeys.loadKey(), "omi-new")
        XCTAssertEqual(try watchKeys.loadKey(), "watch-key")

        XCTAssertEqual(ObserverUploader.backgroundSessionIdentifier, "app.solstone.swift.observer-upload")
        XCTAssertEqual(OmiSegmentWriter.backgroundSessionIdentifier, "app.solstone.swift.omi-upload")
        XCTAssertEqual(OmiSegmentWriter.cacheDirectoryName, "OmiObserver")
        XCTAssertEqual(WatchSegmentDrain.backgroundSessionIdentifier, "app.solstone.swift.watch-upload")
        XCTAssertEqual(WatchSegmentDrain.cacheDirectoryName, "WatchObserver")
        XCTAssertEqual(ImportQueue.backgroundSessionIdentifier, "app.solstone.swift.share-upload")
        XCTAssertEqual(ImporterServerURL.saveURL(localPort: 7071)?.path, "/app/import/api/save")
        XCTAssertEqual(ImporterServerURL.startURL(localPort: 7071)?.path, "/app/import/api/start")

        XCTAssertEqual(OnThisPhoneAudioSource(sourceType: "omi-audio"), .omi)
        XCTAssertEqual(OnThisPhoneAudioSource(sourceType: "watch-audio"), .watch)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MobileSegmentAppWiringURLProtocol.self]
        let watchRoot = self.tempDirectory.appendingPathComponent("WatchObserver", isDirectory: true)
        let watchUploader = ObserverUploader(
            cacheRootURL: watchRoot,
            sessionConfiguration: configuration,
            ensureRegistered: { "test-observer-key-abc" },
            isJournalConfigured: { true },
            localPortProvider: { 7071 },
            sourceType: "watch-audio",
            platform: "watchos",
            retryDelays: [0],
            sleep: { _ in },
            startPathMonitor: false
        )
        MobileSegmentAppWiringURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        await watchUploader.enqueue(chunkURL: try self.audioFile(named: "watch"), sidecar: self.sidecar(sessionID: UUID()))
        try await self.waitFor("watch multipart") {
            MobileSegmentAppWiringURLProtocol.callCount == 1
        }
        let watchBody = String(decoding: try XCTUnwrap(MobileSegmentAppWiringURLProtocol.capturedBodies.first), as: UTF8.self)
        XCTAssertTrue(watchBody.contains(#"name="platform""#))
        XCTAssertTrue(watchBody.contains("watchos"))

        let mobileTransportRoot = self.tempDirectory.appendingPathComponent("Observer", isDirectory: true)
        let mobileTransport = ObserverUploader(
            cacheRootURL: mobileTransportRoot,
            sessionConfiguration: .ephemeral,
            sourceType: "observer-audio",
            platform: "ios",
            startPathMonitor: false
        )
        let appGroupMobileSegmentRoot = self.tempDirectory
            .appendingPathComponent("AppGroup", isDirectory: true)
            .appendingPathComponent("MobileSegment", isDirectory: true)
        let mobileSegmentStore = MobileSegmentStore(rootURL: appGroupMobileSegmentRoot)
        let mobileSegmentUploader = MobileSegmentUploader(
            transport: mobileTransport,
            store: mobileSegmentStore,
            clock: MockObserverClock()
        )
        let engine = MobileSegmentEngine(uploader: mobileSegmentUploader, clock: MockObserverClock())
        _ = engine

        let omiRoot = self.tempDirectory.appendingPathComponent("OmiObserver", isDirectory: true)
        let omiUploader = ObserverUploader(
            cacheRootURL: omiRoot,
            sessionConfiguration: .ephemeral,
            sourceType: "omi-audio",
            startPathMonitor: false
        )
        let importRoot = self.tempDirectory.appendingPathComponent("ImportQueue", isDirectory: true)
        let importQueue = ImportQueue(
            cacheRootURL: importRoot,
            sessionConfiguration: .ephemeral,
            startPathMonitor: false
        )
        XCTAssertEqual(mobileSegmentStore.rootURL, appGroupMobileSegmentRoot)
        XCTAssertNotEqual(mobileSegmentStore.rootURL, mobileTransportRoot)
        XCTAssertNotEqual(mobileSegmentStore.rootURL, omiRoot)
        XCTAssertNotEqual(mobileSegmentStore.rootURL, watchRoot)
        XCTAssertNotEqual(mobileSegmentStore.rootURL, importRoot)
        XCTAssertNotEqual(mobileSegmentUploader.pendingCount, omiUploader.pendingCount + 1)
        XCTAssertEqual(importQueue.pendingCount, 0)
    }
}

private extension MobileSegmentAppWiringTests {
    final class KeyBoxes: @unchecked Sendable {
        private let keyBox: OSAllocatedUnfairLock<String?>
        private let prefixBox: OSAllocatedUnfairLock<String?>

        init(key: String?, prefix: String?) {
            self.keyBox = OSAllocatedUnfairLock(initialState: key)
            self.prefixBox = OSAllocatedUnfairLock(initialState: prefix)
        }

        func loadKey() throws -> String? {
            self.keyBox.withLock { $0 }
        }

        func saveKey(_ value: String) throws {
            self.keyBox.withLock { $0 = value }
        }

        func deleteKey() throws {
            self.keyBox.withLock { $0 = nil }
        }

        func loadPrefix() throws -> String? {
            self.prefixBox.withLock { $0 }
        }

        func savePrefix(_ value: String) throws {
            self.prefixBox.withLock { $0 = value }
        }

        func deletePrefix() throws {
            self.prefixBox.withLock { $0 = nil }
        }
    }

    func registration(streamType: String, label: String? = nil, keys: KeyBoxes) -> ObserverRegistration {
        ObserverRegistration(
            hostname: "test-device",
            version: "0.1.0",
            streamType: streamType,
            label: label,
            session: URLSession(configuration: .ephemeral),
            loadKey: { try keys.loadKey() },
            saveKey: { try keys.saveKey($0) },
            deleteKey: { try keys.deleteKey() },
            loadPrefix: { try keys.loadPrefix() },
            savePrefix: { try keys.savePrefix($0) },
            deletePrefix: { try keys.deletePrefix() }
        )
    }

    func audioFile(named name: String) throws -> URL {
        let url = self.tempDirectory.appendingPathComponent("\(name).m4a", isDirectory: false)
        try Data("audio".utf8).write(to: url, options: .atomic)
        return url
    }

    func sidecar(sessionID: UUID) -> ChunkSidecar {
        ChunkSidecar(
            segment: "090000_60",
            day: "20260628",
            chunkIndex: 0,
            startedAt: Date(timeIntervalSince1970: 1_780_480_800),
            durationS: 60,
            sessionID: sessionID,
            mode: .meeting,
            locationJSONL: nil
        )
    }

    func waitFor(_ label: String, timeout: Duration = .seconds(2), condition: @escaping @MainActor () -> Bool) async throws {
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

private final class MobileSegmentAppWiringURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let callCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)
    private static let bodiesBox = OSAllocatedUnfairLock<[Data]>(initialState: [])

    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    static var callCount: Int {
        self.callCountBox.withLock { $0 }
    }

    static var capturedBodies: [Data] {
        self.bodiesBox.withLock { $0 }
    }

    static func reset() {
        self.handler = nil
        self.callCountBox.withLock { $0 = 0 }
        self.bodiesBox.withLock { $0 = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.callCountBox.withLock { $0 += 1 }
        Self.bodiesBox.withLock { $0.append(Self.bodyData(from: self.request)) }
        guard let handler = Self.handler else {
            XCTFail("MobileSegmentAppWiringURLProtocol handler not set")
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

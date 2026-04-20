// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class ObserverManagerTests: XCTestCase {
    private var recorder: MockObserverRecorder!
    private var uploader: ObserverUploader!
    private var clock: MockObserverClock!
    private var liveActivity: MockObserverLiveActivity!
    private var tempDirectory: URL!
    private var manager: ObserverManager!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObserverManagerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.recorder = MockObserverRecorder()
        self.clock = MockObserverClock()
        self.liveActivity = MockObserverLiveActivity()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObserverManagerURLProtocol.self]
        ObserverManagerURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        self.uploader = ObserverUploader(
            cacheRootURL: self.tempDirectory,
            sessionConfiguration: configuration,
            ensureRegistered: { "test-observer-key-abc" },
            localPortProvider: { 7071 },
            retryDelays: [0],
            sleep: { _ in },
            startPathMonitor: false
        )
        self.manager = ObserverManager(
            recorder: self.recorder,
            uploader: self.uploader,
            clock: self.clock,
            liveActivity: self.liveActivity
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.manager = nil
        self.uploader = nil
        self.recorder = nil
        self.clock = nil
        self.liveActivity = nil
        self.tempDirectory = nil
        ObserverManagerURLProtocol.handler = nil
        super.tearDown()
    }

    func testStartSessionTransitionsToActive() async {
        await self.manager.startSession(mode: .meeting)

        guard case .active(let session) = self.manager.state else {
            return XCTFail("Expected active state")
        }
        XCTAssertEqual(session.mode, .meeting)
        XCTAssertEqual(session.currentChunkIndex, 0)
        XCTAssertEqual(self.recorder.startCallCount, 1)
    }

    func testPermissionDeniedTransitionsToError() async {
        self.recorder.permissionGranted = false

        await self.manager.startSession(mode: .meeting)

        XCTAssertEqual(self.manager.state, .error(.permissionDenied))
    }

    func testClockDrivenSegmentationRotatesChunk() async {
        await self.manager.startSession(mode: .meeting)
        try? await Task.sleep(for: .milliseconds(20))

        self.clock.advance(by: 300)
        try? await Task.sleep(for: .milliseconds(40))

        guard case .active(let session) = self.manager.state else {
            return XCTFail("Expected active state")
        }
        XCTAssertEqual(session.currentChunkIndex, 1)
        XCTAssertEqual(self.recorder.rotateCallCount, 1)
    }

    func testVoiceMemoSilenceStopsSession() async {
        await self.manager.startSession(mode: .voiceMemo)

        self.recorder.emitMeter(level: -55, duration: 0.5)
        self.recorder.emitMeter(level: -55, duration: 3.6)
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(self.manager.state, .idle)
        XCTAssertEqual(self.recorder.stopCallCount, 1)
    }

    func testMeetingModeIgnoresSilence() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitMeter(level: -55, duration: 4)
        try? await Task.sleep(for: .milliseconds(20))

        if case .active = self.manager.state {
        } else {
            XCTFail("Expected active state")
        }
    }

    func testShortInterruptionResumes() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitInterruption(.began)
        try? await Task.sleep(for: .milliseconds(20))
        self.clock.advance(by: 30)
        self.recorder.emitInterruption(.ended)
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(self.recorder.pauseCallCount, 1)
        XCTAssertEqual(self.recorder.resumeCallCount, 1)
        if case .active = self.manager.state {
        } else {
            XCTFail("Expected active state")
        }
    }

    func testLongInterruptionStopsWithConflictError() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitInterruption(.began)
        try? await Task.sleep(for: .milliseconds(20))
        self.clock.advance(by: 61)
        self.recorder.emitInterruption(.ended)
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
    }

    func testTapToCancelDuringStarting() async {
        self.recorder.permissionDelay = .milliseconds(100)
        let task = Task {
            await self.manager.startSession(mode: .meeting)
        }

        try? await Task.sleep(for: .milliseconds(20))
        await self.manager.stopSession()
        await task.value

        XCTAssertEqual(self.manager.state, .idle)
    }

    func testStartSessionIsIdempotentWhenAlreadyActive() async {
        await self.manager.startSession(mode: .meeting)
        await self.manager.startSession(mode: .meeting)

        XCTAssertEqual(self.recorder.startCallCount, 1)
    }
}

private final class ObserverManagerURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("ObserverManagerURLProtocol handler not set")
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
}

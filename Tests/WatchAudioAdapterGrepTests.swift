// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class WatchAudioAdapterGrepTests: XCTestCase {
    func testRecorderStartEnrollsRetentionWithSource() throws {
        let path = "Sources/WatchCapture/LiveWatchAudioRecorder.swift"
        let body = try self.section(
            from: "func start(url: URL, source: WatchCaptureSourceToken) throws",
            to: "func stop() throws -> TimeInterval",
            in: path
        )

        XCTAssertTrue(body.contains("self.terminalRetention.enroll(recorder: recorder, source: source, sink: self.eventSink)"))
        XCTAssertTrue(body.contains("_ = self.terminalRetention.stopCurrent()"))
    }

    func testLiveRecorderHasNoAdapterOwnedRecorderState() throws {
        let path = "Sources/WatchCapture/LiveWatchAudioRecorder.swift"
        let body = try self.contents(path)

        XCTAssertFalse(body.contains("LiveWatchAudioRecorder: AVAudioRecorderDelegate"))
        XCTAssertFalse(body.contains("recorder.delegate = self"))
        XCTAssertFalse(body.contains("private var recorder"))
        XCTAssertFalse(body.contains("private var activeForwarder"))
        XCTAssertFalse(body.contains("self.recorder = nil"))
        XCTAssertFalse(body.contains("self.activeForwarder = nil"))
    }

    func testForwarderDelegateMethodsOnlyCallDeliveryMethods() throws {
        let body = try self.contents("Sources/WatchCapture/WatchCaptureTerminalSource.swift")

        XCTAssertTrue(body.contains("self.deliverDidFinish(successfully: flag)"))
        XCTAssertTrue(body.contains("self.deliverEncodeError(error)"))
    }

    func testForwarderCapturesSourceBeforeReleasingRetention() throws {
        let body = try self.contents("Sources/WatchCapture/WatchCaptureTerminalSource.swift")

        for marker in ["func deliverDidFinish(successfully: Bool)", "func deliverEncodeError(_ error: (any Error)?)"] {
            let section = try self.section(
                from: marker,
                to: "self.terminalHandoff",
                in: "Sources/WatchCapture/WatchCaptureTerminalSource.swift"
            )
            let release = try XCTUnwrap(section.range(of: "let released = self.releasePair(self.identity)"))
            let source = try XCTUnwrap(section.range(of: "let source = self.source"))
            XCTAssertLessThan(source.lowerBound, release.lowerBound, marker)
        }
    }

    func testMicrophonePermissionIsReadOnlyAdapter() throws {
        let path = "Sources/WatchCapture/LiveWatchAudioRecorder.swift"
        let body = try self.section(
            from: "var microphonePermission: WatchMicrophonePermission",
            to: "func requestPermission() async -> WatchMicrophonePermission",
            in: path
        )

        XCTAssertTrue(body.contains("AVAudioApplication.shared.recordPermission"))
        XCTAssertFalse(body.contains("requestRecordPermission"))
    }

    func testPromptOnlyLivesInRequestPermission() throws {
        let path = "Sources/WatchCapture/LiveWatchAudioRecorder.swift"
        let body = try self.section(
            from: "func requestPermission() async -> WatchMicrophonePermission",
            to: "func start(url: URL, source: WatchCaptureSourceToken) throws",
            in: path
        )

        XCTAssertTrue(body.contains("AVAudioApplication.requestRecordPermission"))
    }

    func testCurrentTimeReadsLiveRecorderState() throws {
        let path = "Sources/WatchCapture/LiveWatchAudioRecorder.swift"
        let body = try self.section(
            from: "var currentTime: TimeInterval",
            to: "var isRecording: Bool",
            in: path
        )

        XCTAssertTrue(body.contains("self.terminalRetention.currentTime()"))
    }

    func testIsRecordingReadsLiveRecorderState() throws {
        let path = "Sources/WatchCapture/LiveWatchAudioRecorder.swift"
        let body = try self.section(
            from: "var isRecording: Bool",
            to: "var microphonePermission: WatchMicrophonePermission",
            in: path
        )

        XCTAssertTrue(body.contains("self.terminalRetention.currentIsRecording()"))
    }

    func testRouteSuitabilityReadsLiveAudioSessionInputState() throws {
        let path = "Sources/WatchCapture/LiveWatchAudioRecorder.swift"
        let body = try self.section(
            from: "var hasSuitableInput: Bool",
            to: "func setCategory(",
            in: path
        )

        XCTAssertTrue(body.contains("self.session.isInputAvailable"))
        XCTAssertTrue(body.contains("self.session.currentRoute.inputs.isEmpty"))
    }

    func testNoPauseResumeAudioSurface() throws {
        let files = [
            "Sources/WatchCapture/WatchCaptureProtocols.swift",
            "Sources/WatchCapture/LiveWatchAudioRecorder.swift",
            "Tests/WatchCaptureTests.swift",
        ]

        for file in files {
            let body = try self.contents(file)
            XCTAssertFalse(body.contains("func pause("), file)
            XCTAssertFalse(body.contains("func resume("), file)
        }
    }

    func testDidFailWithErrorForwardsToCoverageSeam() throws {
        let path = "Watch/Sources/LiveWatchLocationProvider.swift"
        let body = try self.section(
            from: "nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error)",
            to: "nonisolated static func fix(from location: CLLocation)",
            in: path
        )

        XCTAssertTrue(body.contains("onFailure?(error)"))
        XCTAssertFalse(body.contains("WatchCaptureRuntimeStatus"))
    }

    private func contents(_ path: String) throws -> String {
        try String(contentsOfFile: self.worktreeRoot().appendingPathComponent(path).path, encoding: .utf8)
    }

    private func section(from start: String, to end: String, in path: String) throws -> String {
        let text = try self.contents(path)
        guard let startRange = text.range(of: start),
              let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex)
        else {
            throw GrepFailure(path: path, start: start, end: end)
        }
        return String(text[startRange.lowerBound..<endRange.lowerBound])
    }

    private func worktreeRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct GrepFailure: Error, CustomStringConvertible {
    let path: String
    let start: String
    let end: String

    var description: String {
        "Could not find section \(self.start) ... \(self.end) in \(self.path)"
    }
}

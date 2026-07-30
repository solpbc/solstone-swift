// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class WatchAudioAdapterGrepTests: XCTestCase {
    func testFinishUnsuccessfulForwardsToEngineSink() throws {
        let path = "Watch/Sources/LiveWatchAudioRecorder.swift"
        let body = try self.section(
            from: "extension LiveWatchAudioRecorder: AVAudioRecorderDelegate",
            to: "@MainActor\nfinal class LiveWatchAudioSessionController",
            in: path
        )

        XCTAssertTrue(body.contains("audioRecorderDidFinishRecording"))
        XCTAssertTrue(body.contains("audioRecorderDidFinish(successfully: flag)"))
        XCTAssertFalse(body.contains("WatchCaptureTerminalReason"))
    }

    func testEncodeErrorForwardsToEngineSink() throws {
        let path = "Watch/Sources/LiveWatchAudioRecorder.swift"
        let body = try self.section(
            from: "extension LiveWatchAudioRecorder: AVAudioRecorderDelegate",
            to: "@MainActor\nfinal class LiveWatchAudioSessionController",
            in: path
        )

        XCTAssertTrue(body.contains("audioRecorderEncodeErrorDidOccur"))
        XCTAssertTrue(body.contains("audioRecorderEncodeError(error)"))
        XCTAssertFalse(body.contains("WatchCaptureTerminalReason"))
    }

    func testMicrophonePermissionIsReadOnlyAdapter() throws {
        let path = "Watch/Sources/LiveWatchAudioRecorder.swift"
        let body = try self.section(
            from: "var microphonePermission: WatchMicrophonePermission",
            to: "func requestPermission() async -> WatchMicrophonePermission",
            in: path
        )

        XCTAssertTrue(body.contains("AVAudioApplication.shared.recordPermission"))
        XCTAssertFalse(body.contains("requestRecordPermission"))
    }

    func testPromptOnlyLivesInRequestPermission() throws {
        let path = "Watch/Sources/LiveWatchAudioRecorder.swift"
        let body = try self.section(
            from: "func requestPermission() async -> WatchMicrophonePermission",
            to: "func start(url: URL) throws",
            in: path
        )

        XCTAssertTrue(body.contains("AVAudioApplication.requestRecordPermission"))
    }

    func testCurrentTimeReadsLiveRecorderState() throws {
        let path = "Watch/Sources/LiveWatchAudioRecorder.swift"
        let body = try self.section(
            from: "var currentTime: TimeInterval",
            to: "var isRecording: Bool",
            in: path
        )

        XCTAssertTrue(body.contains("self.recorder?.currentTime"))
    }

    func testIsRecordingReadsLiveRecorderState() throws {
        let path = "Watch/Sources/LiveWatchAudioRecorder.swift"
        let body = try self.section(
            from: "var isRecording: Bool",
            to: "var microphonePermission: WatchMicrophonePermission",
            in: path
        )

        XCTAssertTrue(body.contains("self.recorder?.isRecording"))
    }

    func testRouteSuitabilityReadsLiveAudioSessionInputState() throws {
        let path = "Watch/Sources/LiveWatchAudioRecorder.swift"
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
            "Watch/Sources/LiveWatchAudioRecorder.swift",
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

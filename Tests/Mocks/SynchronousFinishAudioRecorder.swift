// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation

@MainActor
final class RecorderTelemetry {
    struct Snapshot: Equatable {
        let stopCallCount: Int
        let recordCallCount: Int
        let deliveredCallbackCount: Int
        let reportedCurrentTime: TimeInterval?
        let isRecording: Bool
    }

    var stopCallCount = 0
    var recordCallCount = 0
    var deliveredCallbackCount = 0
    var reportedCurrentTime: TimeInterval?
    var isRecording = false

    var snapshot: Snapshot {
        Snapshot(
            stopCallCount: self.stopCallCount,
            recordCallCount: self.recordCallCount,
            deliveredCallbackCount: self.deliveredCallbackCount,
            reportedCurrentTime: self.reportedCurrentTime,
            isRecording: self.isRecording
        )
    }
}

@MainActor
final class WeakRecorderHandle {
    weak var recorder: SynchronousFinishAudioRecorder?
    weak var forwarder: WatchAudioRecorderTerminalForwarder?
    let telemetry: RecorderTelemetry

    init(telemetry: RecorderTelemetry) {
        self.telemetry = telemetry
    }

    var isReleased: Bool {
        self.recorder == nil && self.forwarder == nil
    }
}

@MainActor
final class SynchronousFinishAudioRecorder: AVAudioRecorder, @unchecked Sendable {
    enum StopCallback {
        case none
        case unsuccessfulFinish
    }

    let telemetry: RecorderTelemetry
    var recordSucceeds = true
    var stopCallback: StopCallback = .none
    var duringStop: (() -> Void)?

    init(
        url: URL,
        settings: [String: Any],
        telemetry: RecorderTelemetry = RecorderTelemetry()
    ) throws {
        self.telemetry = telemetry
        try super.init(url: url, settings: settings)
    }

    var reportedCurrentTime: TimeInterval? {
        get { self.telemetry.reportedCurrentTime }
        set { self.telemetry.reportedCurrentTime = newValue }
    }

    var stopCallCount: Int { self.telemetry.stopCallCount }

    override var currentTime: TimeInterval {
        get { self.telemetry.reportedCurrentTime ?? super.currentTime }
        set { self.telemetry.reportedCurrentTime = newValue }
    }

    override func record() -> Bool {
        self.telemetry.recordCallCount += 1
        self.telemetry.isRecording = self.recordSucceeds
        return self.recordSucceeds
    }

    override var isRecording: Bool { self.telemetry.isRecording }

    override func stop() {
        self.telemetry.stopCallCount += 1
        self.telemetry.isRecording = false
        self.duringStop?()
        if case .unsuccessfulFinish = self.stopCallback {
            self.telemetry.deliveredCallbackCount += 1
            self.delegate?.audioRecorderDidFinishRecording?(self, successfully: false)
        }
    }

    func fireFinish(successfully: Bool) {
        self.telemetry.deliveredCallbackCount += 1
        self.delegate?.audioRecorderDidFinishRecording?(self, successfully: successfully)
    }

    func fireEncodeError(_ error: (any Error)? = nil) {
        self.telemetry.deliveredCallbackCount += 1
        self.delegate?.audioRecorderEncodeErrorDidOccur?(self, error: error)
    }
}

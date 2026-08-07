// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation

@MainActor
final class LiveWatchAudioRecorder: NSObject, WatchAudioRecording {
    private var recorder: AVAudioRecorder?
    private var activeForwarder: WatchAudioRecorderTerminalForwarder?
    weak var eventSink: (any WatchAudioRecorderEventSink)?

    var url: URL? {
        self.recorder?.url
    }

    var currentTime: TimeInterval {
        self.recorder?.currentTime ?? 0
    }

    var isRecording: Bool {
        self.recorder?.isRecording ?? false
    }

    var microphonePermission: WatchMicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    func requestPermission() async -> WatchMicrophonePermission {
        switch self.microphonePermission {
        case .granted, .denied:
            return self.microphonePermission
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted ? WatchMicrophonePermission.granted : .denied)
                }
            }
        }
    }

    func start(url: URL, source: WatchCaptureSourceToken) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        let forwarder = WatchAudioRecorderTerminalForwarder(source: source, sink: self.eventSink)
        recorder.delegate = forwarder
        guard recorder.record() else {
            throw ObserverError.unavailable(reason: "audio unavailable")
        }
        self.recorder = recorder
        self.activeForwarder = forwarder
    }

    func stop() throws -> TimeInterval {
        let duration = self.recorder?.currentTime ?? 0
        self.recorder?.stop()
        self.recorder = nil
        self.activeForwarder = nil
        return duration
    }
}

@MainActor
final class LiveWatchAudioSessionController: WatchAudioSessionControlling {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    var hasSuitableInput: Bool {
        self.session.isInputAvailable || !self.session.currentRoute.inputs.isEmpty
    }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        try self.session.setCategory(category, mode: mode, options: options)
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        try self.session.setActive(active, options: options)
    }
}

@MainActor
final class LiveWatchAudioProbe: WatchAudioProbing {
    func decodableDuration(at url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
            return nil
        }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}

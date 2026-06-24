// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation

@MainActor
final class LiveWatchAudioRecorder: NSObject, WatchAudioRecording {
    private var recorder: AVAudioRecorder?

    var url: URL? {
        self.recorder?.url
    }

    var currentTime: TimeInterval {
        self.recorder?.currentTime ?? 0
    }

    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    func start(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record() else {
            throw ObserverError.unavailable(reason: "audio unavailable")
        }
        self.recorder = recorder
    }

    func pause() {
        self.recorder?.pause()
    }

    func resume() throws {
        guard let recorder = self.recorder else { return }
        guard recorder.record() else {
            throw ObserverError.unavailable(reason: "audio unavailable")
        }
    }

    func stop() throws -> TimeInterval {
        let duration = self.recorder?.currentTime ?? 0
        self.recorder?.stop()
        self.recorder = nil
        return duration
    }
}

@MainActor
final class LiveWatchAudioSessionController: WatchAudioSessionControlling {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
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

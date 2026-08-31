// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation

typealias WatchAudioRecorderFactory = @MainActor (URL, [String: Any]) throws -> AVAudioRecorder
typealias WatchMicrophonePermissionProvider = @MainActor () -> WatchMicrophonePermission

@MainActor
final class LiveWatchAudioRecorder: NSObject, WatchAudioRecording {
    private let recorderFactory: WatchAudioRecorderFactory
    private let microphonePermissionProvider: WatchMicrophonePermissionProvider
    private let terminalRetention: WatchAudioRecorderTerminalRetention
    weak var eventSink: (any WatchAudioRecorderEventSink)?

    init(
        recorderFactory: @escaping WatchAudioRecorderFactory = { url, settings in
            try AVAudioRecorder(url: url, settings: settings)
        },
        microphonePermissionProvider: @escaping WatchMicrophonePermissionProvider =
            LiveWatchAudioRecorder.liveMicrophonePermission,
        retentionClock: any WatchAudioRecorderRetentionClock = LiveWatchAudioRecorderRetentionClock(),
        expiryTaskSpawner: @escaping WatchAudioRecorderRetentionTaskSpawner = { body in
            Task { await body() }
        },
        terminalHandoff: @escaping WatchAudioRecorderTerminalHandoff = { operation in
            Task { @MainActor in operation() }
        }
    ) {
        self.recorderFactory = recorderFactory
        self.microphonePermissionProvider = microphonePermissionProvider
        self.terminalRetention = WatchAudioRecorderTerminalRetention(
            clock: retentionClock,
            spawnExpiryTask: expiryTaskSpawner,
            terminalHandoff: terminalHandoff
        )
    }

    var url: URL? {
        self.terminalRetention.currentURL()
    }

    var currentTime: TimeInterval {
        self.terminalRetention.currentTime()
    }

    var isRecording: Bool {
        self.terminalRetention.currentIsRecording()
    }

    var microphonePermission: WatchMicrophonePermission {
        self.microphonePermissionProvider()
    }

    static let liveMicrophonePermission: WatchMicrophonePermissionProvider = {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .denied
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
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let recorder = try self.recorderFactory(url, settings)
        self.terminalRetention.enroll(recorder: recorder, source: source, sink: self.eventSink)
        guard recorder.record() else {
            _ = self.terminalRetention.stopCurrent()
            throw ObserverError.unavailable(reason: "audio unavailable")
        }
    }

    func stop() throws -> TimeInterval {
        self.terminalRetention.stopCurrent()
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

nonisolated struct LiveWatchAudioProbe: WatchAudioProbing {
    static func classification(for error: any Error) -> WatchAudioProbeResult {
        let nsError = error as NSError
        switch nsError.code {
        case 0x7479_703F, // 'typ?' — unsupported file type
             0x666D_743F, // 'fmt?' — unsupported data format
             0x6474_613F, // 'dta?' — invalid file
             0x6368_6B3F: // 'chk?' — invalid chunk
            return .confirmedUndecodable
        default:
            return .ioUnknown
        }
    }

    func probe(at url: URL) async -> WatchAudioProbeResult {
        do {
            _ = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return .ioUnknown
        }
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.fileFormat.sampleRate > 0 else {
                return .confirmedUndecodable
            }
            let duration = Double(file.length) / file.fileFormat.sampleRate
            return duration > 0 ? .decodable(duration: duration) : .confirmedUndecodable
        } catch {
            return Self.classification(for: error)
        }
    }
}

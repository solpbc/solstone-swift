// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation

nonisolated struct WatchCaptureSourceToken: Equatable, Sendable {
    let sessionID: String
}

/// Binds recorder callbacks to one immutable owner session. The MainActor hop
/// retains this forwarder so a callback raised during recorder teardown still
/// forwards before the adapter releases its active forwarder.
@MainActor
final class WatchAudioRecorderTerminalForwarder: NSObject, AVAudioRecorderDelegate {
    let source: WatchCaptureSourceToken
    private weak var sink: (any WatchAudioRecorderEventSink)?

    init(source: WatchCaptureSourceToken, sink: (any WatchAudioRecorderEventSink)?) {
        self.source = source
        self.sink = sink
    }

    nonisolated func deliverDidFinish(successfully: Bool) {
        let source = self.source
        Task { @MainActor in
            self.sink?.audioRecorderDidFinish(successfully: successfully, source: source)
        }
    }

    nonisolated func deliverEncodeError(_ error: (any Error)?) {
        let source = self.source
        Task { @MainActor in
            self.sink?.audioRecorderEncodeError(error, source: source)
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        self.deliverDidFinish(successfully: flag)
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        self.deliverEncodeError(error)
    }
}

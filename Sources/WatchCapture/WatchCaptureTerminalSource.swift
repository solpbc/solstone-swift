// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation

nonisolated struct WatchCaptureSourceToken: Equatable, Sendable {
    let sessionID: String
}

/// Binds recorder callbacks to one immutable owner session and one concrete
/// recorder pair. Callback entry releases terminal retention before forwarding
/// the event to the MainActor sink.
@MainActor
final class WatchAudioRecorderTerminalForwarder: NSObject, AVAudioRecorderDelegate {
    nonisolated let identity: UUID
    let source: WatchCaptureSourceToken
    private weak var sink: (any WatchAudioRecorderEventSink)?
    nonisolated private let releasePair: @Sendable (UUID) -> AnyObject?

    init(
        identity: UUID,
        source: WatchCaptureSourceToken,
        sink: (any WatchAudioRecorderEventSink)?,
        releasePair: @escaping @Sendable (UUID) -> AnyObject?
    ) {
        self.identity = identity
        self.source = source
        self.sink = sink
        self.releasePair = releasePair
    }

    nonisolated func deliverDidFinish(successfully: Bool) {
        let source = self.source
        let released = self.releasePair(self.identity)
        Task { @MainActor in
            self.sink?.audioRecorderDidFinish(successfully: successfully, source: source)
        }
        withExtendedLifetime(released) {}
    }

    nonisolated func deliverEncodeError(_ error: (any Error)?) {
        let source = self.source
        let released = self.releasePair(self.identity)
        Task { @MainActor in
            self.sink?.audioRecorderEncodeError(error, source: source)
        }
        withExtendedLifetime(released) {}
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        self.deliverDidFinish(successfully: flag)
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        self.deliverEncodeError(error)
    }
}

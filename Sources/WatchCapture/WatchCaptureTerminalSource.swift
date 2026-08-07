// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation

nonisolated struct WatchCaptureSourceToken: Equatable, Sendable {
    let sessionID: String
    let enrollment: UUID?

    init(sessionID: String, enrollment: UUID? = nil) {
        self.sessionID = sessionID
        self.enrollment = enrollment
    }
}

/// Binds recorder callbacks to one immutable owner session and one concrete
/// recorder pair. Callback entry transfers a current pair into terminal-pending
/// ownership so production cleanup can still stop it, and releases a pair that
/// is already retired, before forwarding the event to the MainActor sink.
@MainActor
final class WatchAudioRecorderTerminalForwarder: NSObject, AVAudioRecorderDelegate {
    nonisolated let identity: UUID
    let source: WatchCaptureSourceToken
    private weak var sink: (any WatchAudioRecorderEventSink)?
    nonisolated private let releasePair: @Sendable (UUID) -> AnyObject?
    nonisolated private let terminalHandoff: WatchAudioRecorderTerminalHandoff

    init(
        identity: UUID,
        source: WatchCaptureSourceToken,
        sink: (any WatchAudioRecorderEventSink)?,
        releasePair: @escaping @Sendable (UUID) -> AnyObject?,
        terminalHandoff: @escaping WatchAudioRecorderTerminalHandoff = { operation in
            Task { @MainActor in operation() }
        }
    ) {
        self.identity = identity
        self.source = source
        self.sink = sink
        self.releasePair = releasePair
        self.terminalHandoff = terminalHandoff
    }

    nonisolated func deliverDidFinish(successfully: Bool) {
        let source = self.source
        let released = self.releasePair(self.identity)
        self.terminalHandoff { @MainActor in
            self.sink?.audioRecorderDidFinish(successfully: successfully, source: source)
        }
        withExtendedLifetime(released) {}
    }

    nonisolated func deliverEncodeError(_ error: (any Error)?) {
        let source = self.source
        let released = self.releasePair(self.identity)
        self.terminalHandoff { @MainActor in
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

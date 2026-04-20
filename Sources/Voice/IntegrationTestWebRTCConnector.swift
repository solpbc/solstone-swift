// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if DEBUG
import Foundation

final class IntegrationTestWebRTCConnector: WebRTCConnecting {
    private var eventContinuation: AsyncStream<DataChannelEvent>.Continuation?

    func connect(ephemeralKey: String) async throws -> (callId: String, events: AsyncStream<DataChannelEvent>) {
        self.disconnect()

        let (stream, continuation) = AsyncStream<DataChannelEvent>.makeStream()
        self.eventContinuation = continuation

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.eventContinuation?.yield(.toolCallCompleted)
        }

        return (callId: "integration-test-call-id", events: stream)
    }

    func disconnect() {
        self.eventContinuation?.finish()
        self.eventContinuation = nil
    }
}
#endif

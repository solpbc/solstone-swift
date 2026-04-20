// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

final class MockWebRTCConnector: WebRTCConnecting {
    var connectError: Error?
    var connectCallCount = 0
    var disconnectCallCount = 0
    var delay: Duration?
    var callId = "test-call-id"
    private(set) var eventContinuation: AsyncStream<DataChannelEvent>.Continuation?

    func connect(ephemeralKey: String) async throws -> (callId: String, events: AsyncStream<DataChannelEvent>) {
        self.connectCallCount += 1
        if let delay {
            try await Task.sleep(for: delay)
        }
        if let error = self.connectError {
            throw error
        }
        let (stream, continuation) = AsyncStream<DataChannelEvent>.makeStream()
        self.eventContinuation = continuation
        return (callId: self.callId, events: stream)
    }

    func disconnect() {
        self.disconnectCallCount += 1
        self.eventContinuation?.finish()
        self.eventContinuation = nil
    }
}

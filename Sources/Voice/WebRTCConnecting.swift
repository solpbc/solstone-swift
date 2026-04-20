// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

enum DataChannelEvent: Sendable {
    case modelSpeakingStarted
    case modelSpeakingStopped
    case userSpeechStarted
    case userSpeechStopped
    case disconnected
}

protocol WebRTCConnecting: AnyObject {
    func connect(ephemeralKey: String) async throws -> (callId: String, events: AsyncStream<DataChannelEvent>)
    func disconnect()
}

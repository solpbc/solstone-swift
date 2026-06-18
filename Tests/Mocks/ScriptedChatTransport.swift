// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift

final class ScriptedChatTransport: ChatTransporting, @unchecked Sendable {
    var replies: [ChatReply]
    private(set) var sentMessages: [String] = []

    init(replies: [ChatReply] = []) {
        self.replies = replies
    }

    func send(message: String) async -> ChatReply {
        self.sentMessages.append(message)
        guard !self.replies.isEmpty else {
            return .ok("scripted reply")
        }
        return self.replies.removeFirst()
    }
}

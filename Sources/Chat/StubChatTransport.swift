import Foundation

nonisolated struct StubChatTransport: ChatTransporting, Sendable {
    func send(message: String) async -> ChatReply {
        try? await Task.sleep(for: .milliseconds(250))
        // lode 3: real convey reply
        return .ok("i can answer here once native ask connects to your journal.")
    }
}

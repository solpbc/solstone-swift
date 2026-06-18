import Foundation

nonisolated struct StubChatTransport: ChatTransporting, Sendable {
    func send(message: String) async -> ChatReply {
        try? await Task.sleep(for: .milliseconds(250))
        // lode 3: real convey reply
        return .ok("i can answer here once native ask connects to your journal.", Self.provenance(for: message))
    }

    private static func provenance(for message: String) -> AnswerProvenance {
        if self.message(message, contains: "unknown sources") {
            return .unknown(coverage: ["read your journal"])
        }
        if self.message(message, contains: "low confidence") {
            return .sourced(
                sources: [self.cannedSource],
                confidence: .low,
                coverage: ["read your journal"]
            )
        }
        return .sourced(
            sources: [self.cannedSource],
            confidence: .high,
            coverage: ["read your journal"]
        )
    }

    private static var cannedSource: AnswerProvenance.ProvenanceSource {
        AnswerProvenance.ProvenanceSource(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000902") ?? UUID(),
            label: "9:02 call with jack",
            detail: "37 min",
            openURL: URL(string: "http://127.0.0.1/")
        )
    }

    private static func message(_ message: String, contains sentinel: String) -> Bool {
        message.range(of: sentinel, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

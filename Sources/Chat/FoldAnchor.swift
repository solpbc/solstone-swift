import Foundation

nonisolated enum FoldAnchorPlacement: Equatable {
    case anchored(toMessageID: UUID)
    case inlineAsk(String)
}

nonisolated enum FoldAnchor {
    static func resolve(origin: ChatSolOrigin, messages: [ChatMessage]) -> FoldAnchorPlacement {
        if let message = messages.first(where: { $0.role == .user && $0.useID == origin.logicalUseID }) {
            return .anchored(toMessageID: message.id)
        }

        let ask = origin.ask?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !ask.isEmpty {
            return .inlineAsk(ask)
        }

        return .inlineAsk(SourceVocabulary.chatFoldOriginalQuestionUnavailable)
    }
}

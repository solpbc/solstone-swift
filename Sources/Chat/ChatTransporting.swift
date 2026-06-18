import Foundation

enum ChatReply: Sendable {
    case ok(String, AnswerProvenance?)
    case serverError(status: Int, reason: String?)
    case decode
    case transport
}

nonisolated protocol ChatTransporting: Sendable {
    func send(message: String) async -> ChatReply
}

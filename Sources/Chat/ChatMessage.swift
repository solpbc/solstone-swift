import Foundation

struct ChatMessage: Identifiable, Sendable, Equatable {
    enum Role: String, Sendable, Equatable {
        case user
        case assistant
    }

    enum Status: Sendable, Equatable {
        case sent
        case pending
        case failed
    }

    let id: UUID
    let role: Role
    var text: String
    let timestamp: Date
    var status: Status
    var provenance: AnswerProvenance?
    var requestID: String?
    var useID: String?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        timestamp: Date = Date(),
        status: Status = .sent,
        provenance: AnswerProvenance? = nil,
        requestID: String? = nil,
        useID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.status = status
        self.provenance = provenance
        self.requestID = requestID
        self.useID = useID
    }
}

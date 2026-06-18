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
    let text: String
    let timestamp: Date
    var status: Status

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        timestamp: Date = Date(),
        status: Status = .sent
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.status = status
    }
}

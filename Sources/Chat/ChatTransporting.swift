import Foundation

nonisolated enum ChatPostResult: Sendable, Equatable {
    case ack(useID: String, queued: Bool, queueDepth: Int?)
    case queueFull(queueDepth: Int?)
    case unavailable(reason: String?)
    case serverError(status: Int, reason: String?)
    case malformed
    case transport
}

nonisolated enum ChatEvent: Sendable, Equatable {
    case snapshot(ChatSessionSnapshot)
    case ownerMessage(ChatOwnerMessage)
    case solMessage(ChatSolMessage)
    case talentSpawned(ChatTalentActivity)
    case talentFinished(ChatTalentActivity)
    case talentErrored(ChatTalentActivity)
    case chatError(ChatErrorEvent)
    case queueDepth(Int)
    case result(ChatResultEvent)
}

nonisolated struct ChatSessionSnapshot: Sendable, Equatable {
    let latestSolMessage: ChatSolMessage?
    let activeTalents: [ChatTalentActivity]
    let completedTalents: [ChatTalentActivity]
    let queueDepth: Int?

    init(
        latestSolMessage: ChatSolMessage? = nil,
        activeTalents: [ChatTalentActivity] = [],
        completedTalents: [ChatTalentActivity] = [],
        queueDepth: Int? = nil
    ) {
        self.latestSolMessage = latestSolMessage
        self.activeTalents = activeTalents
        self.completedTalents = completedTalents
        self.queueDepth = queueDepth
    }
}

nonisolated struct ChatOwnerMessage: Sendable, Equatable {
    let id: String
    let text: String
    let requestID: String?
    let useID: String?
    let timestamp: Date?

    init(id: String, text: String, requestID: String? = nil, useID: String? = nil, timestamp: Date? = nil) {
        self.id = id
        self.text = text
        self.requestID = requestID
        self.useID = useID
        self.timestamp = timestamp
    }
}

nonisolated struct ChatSolMessage: Sendable, Equatable {
    let id: String
    let text: String
    let requestID: String?
    let useID: String?
    let requestedTarget: String?
    let provenance: AnswerProvenance
    let offer: ChatOffer?
    let draft: ChatDraft?
    let timestamp: Date?

    init(
        id: String,
        text: String,
        requestID: String? = nil,
        useID: String? = nil,
        requestedTarget: String? = nil,
        provenance: AnswerProvenance = AnswerProvenance(),
        offer: ChatOffer? = nil,
        draft: ChatDraft? = nil,
        timestamp: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.requestID = requestID
        self.useID = useID
        self.requestedTarget = requestedTarget
        self.provenance = provenance
        self.offer = offer
        self.draft = draft
        self.timestamp = timestamp
    }
}

nonisolated struct ChatTalentActivity: Identifiable, Sendable, Equatable {
    let id: String
    let useID: String?
    let label: String
    let timestamp: Date?

    init(id: String, useID: String? = nil, label: String, timestamp: Date? = nil) {
        self.id = id
        self.useID = useID
        self.label = label
        self.timestamp = timestamp
    }
}

nonisolated struct ChatWorkingTrace: Sendable, Equatable {
    let activeLabels: [String]
    let completedLabels: [String]
    let erroredLabels: [String]

    init(activeLabels: [String] = [], completedLabels: [String] = [], erroredLabels: [String] = []) {
        self.activeLabels = activeLabels
        self.completedLabels = completedLabels
        self.erroredLabels = erroredLabels
    }

    var isEmpty: Bool {
        self.activeLabels.isEmpty && self.completedLabels.isEmpty && self.erroredLabels.isEmpty
    }
}

nonisolated struct ChatErrorEvent: Sendable, Equatable {
    let id: String
    let requestID: String?
    let useID: String?
    let reason: String
    let detail: String?
    let timestamp: Date?

    init(
        id: String,
        requestID: String? = nil,
        useID: String? = nil,
        reason: String,
        detail: String? = nil,
        timestamp: Date? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.useID = useID
        self.reason = reason
        self.detail = detail
        self.timestamp = timestamp
    }
}

nonisolated struct ChatResultEvent: Sendable, Equatable {
    let id: String
    let requestID: String?
    let useID: String?
    let ok: Bool
    let message: String?
    let timestamp: Date?

    init(
        id: String,
        requestID: String? = nil,
        useID: String? = nil,
        ok: Bool,
        message: String? = nil,
        timestamp: Date? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.useID = useID
        self.ok = ok
        self.message = message
        self.timestamp = timestamp
    }
}

nonisolated struct ChatOffer: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable, Equatable {
        case support
    }

    let id: String
    let kind: Kind
    let text: String

    init(id: String = "support", kind: Kind = .support, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

nonisolated struct ChatDraft: Identifiable, Sendable, Equatable {
    let id: String
    let body: String
    let fields: [ChatDraftField]
    let diagnosticsIncluded: Bool

    init(id: String, body: String, fields: [ChatDraftField] = [], diagnosticsIncluded: Bool = false) {
        self.id = id
        self.body = body
        self.fields = fields
        self.diagnosticsIncluded = diagnosticsIncluded
    }
}

nonisolated struct ChatDraftField: Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let value: String

    init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

nonisolated enum DraftOutcome: Sendable, Equatable {
    case accepted(ChatSolMessage?)
    case cancelled(ChatSolMessage?)
    case failed(reason: String?)
    case transport
}

nonisolated protocol ChatTransporting: Sendable {
    func postMessage(_ text: String) async -> ChatPostResult
    func events() -> AsyncStream<ChatEvent>
    func declineOffer() async -> Bool
    func confirmDraft(id: String) async -> DraftOutcome
    func cancelDraft(id: String) async -> DraftOutcome
}

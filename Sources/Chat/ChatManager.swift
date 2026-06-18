import Foundation
import os

@MainActor
@Observable
final class ChatManager {
    var messages: [ChatMessage] = []
    var isSending = false
    var lastError: String?

    private let transport: any ChatTransporting
    private let isReachable: () -> Bool
    private let logger = Logger(subsystem: "app.solstone.swift", category: "chat")
    private var inFlightTask: Task<Void, Never>?
    private var inFlightToken: InFlightToken?
    private var retryTask: Task<Void, Never>?

    init(
        transport: any ChatTransporting = StubChatTransport(),
        isReachable: @escaping () -> Bool = { true }
    ) {
        self.transport = transport
        self.isReachable = isReachable
    }

    func reset() {
        self.inFlightTask?.cancel()
        self.stopRetryTick()
        self.inFlightTask = nil
        self.inFlightToken = nil
        self.messages = []
        self.isSending = false
        self.lastError = nil
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        self.lastError = nil

        if !self.isReachable() {
            self.messages.append(ChatMessage(role: .user, text: trimmed, status: .pending))
            self.logger.info("chat queued unreachable")
            self.startRetryTickIfNeeded()
            return
        }

        if !self.hasPending && self.inFlightTask == nil {
            let message = ChatMessage(role: .user, text: trimmed)
            self.messages.append(message)
            let task = self.performSend(messageID: message.id, text: trimmed)
            await task.value
        } else {
            self.messages.append(ChatMessage(role: .user, text: trimmed, status: .pending))
            self.logger.info("chat queued")
            self.drainIfPossible()
        }
    }

    func _testDrainStep() {
        self.drainIfPossible()
    }
}

private extension ChatManager {
    var hasPending: Bool {
        self.messages.contains { $0.status == .pending }
    }

    func drainIfPossible() {
        guard self.inFlightTask == nil,
              let pending = self.messages.first(where: { $0.status == .pending })
        else { return }

        self.startRetryTickIfNeeded()
        guard self.isReachable() else {
            self.logger.info("chat drain paused unreachable")
            return
        }

        self.performSend(messageID: pending.id, text: pending.text)
    }

    @discardableResult
    func performSend(messageID: UUID, text: String) -> Task<Void, Never> {
        self.inFlightTask?.cancel()
        self.isSending = true
        self.logger.info("chat drain start")

        let token = InFlightToken()
        let task = Task { @MainActor [weak self, token] in
            guard let self else { return }
            // lode 3: real transport reads observerRegistration.activeLocalPort
            let reply = await self.transport.send(message: text)
            guard !Task.isCancelled, self.inFlightToken === token else { return }
            self.apply(reply, headID: messageID)
        }

        self.inFlightTask = task
        self.inFlightToken = token
        return task
    }

    func apply(_ reply: ChatReply, headID: UUID) {
        var shouldContinueQueue = true

        switch reply {
        case .ok(let text, let provenance):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                self.updateMessageStatus(id: headID, status: .failed)
                self.lastError = SourceVocabulary.chatErrorEmptyReply
                self.logger.info("chat drain empty")
            } else {
                self.markSentAndInsertAssistant(headID: headID, text: trimmed, provenance: provenance)
                self.lastError = nil
                self.logger.info("chat drain ok")
            }
        case .serverError(let status, let reason):
            switch status {
            case 503:
                self.updateMessageStatus(id: headID, status: .pending)
                self.lastError = nil
                shouldContinueQueue = false
                self.logger.info("chat drain 503 keep-pending")
            case 500:
                self.updateMessageStatus(id: headID, status: .failed)
                self.lastError = reason ?? SourceVocabulary.chatErrorServer
                self.logger.info("chat drain failed status=\(status)")
            default:
                self.updateMessageStatus(id: headID, status: .failed)
                self.lastError = reason ?? SourceVocabulary.chatErrorGeneric
                self.logger.info("chat drain failed status=\(status)")
            }
        case .decode:
            self.updateMessageStatus(id: headID, status: .failed)
            self.lastError = SourceVocabulary.chatErrorDecode
            self.logger.error("chat drain decode")
        case .transport:
            self.updateMessageStatus(id: headID, status: .pending)
            self.lastError = nil
            shouldContinueQueue = false
            self.logger.info("chat drain transport keep-pending")
        }

        self.isSending = false
        self.inFlightTask = nil
        self.inFlightToken = nil

        if self.hasPending {
            self.startRetryTickIfNeeded()
            if shouldContinueQueue {
                self.drainIfPossible()
            }
        } else {
            self.stopRetryTick()
        }
    }

    func updateMessageStatus(id: UUID, status: ChatMessage.Status) {
        guard let index = self.messages.firstIndex(where: { $0.id == id }) else { return }
        self.messages[index].status = status
    }

    func markSentAndInsertAssistant(headID: UUID, text: String, provenance: AnswerProvenance?) {
        guard let index = self.messages.firstIndex(where: { $0.id == headID }) else {
            self.messages.append(ChatMessage(role: .assistant, text: text, provenance: provenance))
            return
        }
        self.messages[index].status = .sent
        self.messages.insert(ChatMessage(role: .assistant, text: text, provenance: provenance), at: index + 1)
    }

    func startRetryTickIfNeeded() {
        guard self.retryTask == nil, self.hasPending else { return }

        self.retryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.hasPending else {
                    self.retryTask = nil
                    return
                }
                if self.inFlightTask == nil {
                    self.drainIfPossible()
                }
            }
        }
    }

    func stopRetryTick() {
        self.retryTask?.cancel()
        self.retryTask = nil
    }
}

private final class InFlightToken {}

import Foundation
import os

@MainActor
@Observable
final class ChatManager {
    var messages: [ChatMessage] = []
    var isSending = false
    var lastError: String?
    var queueDepth: Int?
    var pendingOffer: ChatOffer?
    var pendingDraft: ChatDraft?
    var activeTrace: ChatWorkingTrace?
    var answerRetryText: String?
    var queuedTalents: [ChatTalentActivity] = []
    var runningTalents: [ChatTalentActivity] {
        self.sortedActiveTalents()
    }
    var hasTalentWork: Bool {
        !self.runningTalents.isEmpty || !self.queuedTalents.isEmpty
    }

    private let transport: any ChatTransporting
    private let isReachable: @Sendable @MainActor () -> Bool
    private let localPortProvider: @Sendable @MainActor () -> Int?
    private let logger = Logger(subsystem: "app.solstone.swift", category: "chat")
    private var inFlightTask: Task<Void, Never>?
    private var inFlightToken: InFlightToken?
    private var retryTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var outstandingTurnUseID: String?
    private var latestSolMessageAt: Date?
    private var activeTalents: [String: ChatTalentActivity] = [:]
    private var erroredTalentLabels: [String] = []

    init(
        transport: any ChatTransporting,
        isReachable: @escaping @Sendable @MainActor () -> Bool = { true },
        localPortProvider: @escaping @Sendable @MainActor () -> Int?
    ) {
        self.transport = transport
        self.isReachable = isReachable
        self.localPortProvider = localPortProvider
        self.startEventsListener()
    }

    func reset() {
        self.inFlightTask?.cancel()
        self.stopRetryTick()
        self.eventsTask?.cancel()
        self.inFlightTask = nil
        self.inFlightToken = nil
        self.messages = []
        self.isSending = false
        self.lastError = nil
        self.queueDepth = nil
        self.pendingOffer = nil
        self.pendingDraft = nil
        self.activeTrace = nil
        self.answerRetryText = nil
        self.queuedTalents = []
        self.outstandingTurnUseID = nil
        self.latestSolMessageAt = nil
        self.activeTalents = [:]
        self.erroredTalentLabels = []
        self.startEventsListener()
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        self.lastError = nil
        self.answerRetryText = nil

        let message = ChatMessage(role: .user, text: trimmed, status: .pending)
        self.messages.append(message)

        guard self.canDrainNow else {
            self.logger.info("chat queued")
            self.startRetryTickIfNeeded()
            return
        }

        let task = self.drainIfPossible()
        await task?.value
    }

    func retryAnswer() async {
        guard let text = self.answerRetryText else { return }
        self.answerRetryText = nil
        self.lastError = nil
        await self.send(text)
    }

    func acceptOffer() {
        self.pendingOffer = nil
    }

    func declineOffer() async {
        let declined = await self.transport.declineOffer()
        if declined {
            self.pendingOffer = nil
        } else {
            self.lastError = SourceVocabulary.chatErrorGeneric
        }
    }

    func confirmDraft(id: String) async {
        await self.applyDraftOutcome(await self.transport.confirmDraft(id: id))
    }

    func cancelDraft(id: String) async {
        await self.applyDraftOutcome(await self.transport.cancelDraft(id: id))
    }

    func _testDrainStep() {
        self.drainIfPossible()
    }
}

private extension ChatManager {
    var hasPending: Bool {
        self.messages.contains { $0.role == .user && $0.status == .pending }
    }

    var canDrainNow: Bool {
        self.inFlightTask == nil && self.isReachable() && self.localPortProvider() != nil
    }

    func startEventsListener() {
        self.eventsTask?.cancel()
        let stream = self.transport.events()
        self.eventsTask = Task { @MainActor [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                self?.apply(event)
            }
        }
    }

    @discardableResult
    func drainIfPossible() -> Task<Void, Never>? {
        guard self.inFlightTask == nil,
              let pending = self.messages.first(where: { $0.role == .user && $0.status == .pending })
        else { return nil }

        self.startRetryTickIfNeeded()
        guard self.isReachable(), self.localPortProvider() != nil else {
            self.logger.info("chat drain paused offline")
            return nil
        }

        return self.performPost(messageID: pending.id, text: pending.text)
    }

    @discardableResult
    func performPost(messageID: UUID, text: String) -> Task<Void, Never> {
        self.inFlightTask?.cancel()
        self.logger.info("chat post start")
        self.isSending = true

        let token = InFlightToken()
        let task = Task { @MainActor [weak self, token] in
            guard let self else { return }
            let reply = await self.transport.postMessage(text)
            guard !Task.isCancelled, self.inFlightToken === token else { return }
            self.apply(reply, headID: messageID, text: text)
        }

        self.inFlightTask = task
        self.inFlightToken = token
        return task
    }

    // User-message status reflects send success only; answer-side problems render assistant-side.
    func apply(_ result: ChatPostResult, headID: UUID, text: String) {
        var shouldContinueQueue = true

        switch result {
        case .ack(let useID, _, let depth):
            self.markUserSent(headID: headID, useID: useID)
            self.outstandingTurnUseID = useID
            self.upsertAssistantMessage(
                idSeed: "ack-\(useID)",
                text: SourceVocabulary.chatAckBubble,
                provenance: nil,
                useID: useID,
                requestID: nil,
                origin: nil
            )
            self.isSending = false
            self.lastError = nil
            self.queueDepth = depth
            self.logger.info("chat post ack")
        case .queueFull(let depth):
            self.updateMessageStatus(id: headID, status: .pending)
            self.isSending = false
            self.queueDepth = depth
            self.lastError = nil
            shouldContinueQueue = false
            self.logger.info("chat post queue-full keep-pending")
        case .unavailable:
            self.updateMessageStatus(id: headID, status: .pending)
            self.isSending = false
            self.lastError = nil
            shouldContinueQueue = false
            self.logger.info("chat post unavailable keep-pending")
        case .transport:
            self.updateMessageStatus(id: headID, status: .pending)
            self.isSending = false
            self.lastError = nil
            shouldContinueQueue = false
            self.logger.info("chat post transport keep-pending")
        case .malformed:
            self.updateMessageStatus(id: headID, status: .failed)
            self.isSending = false
            self.lastError = SourceVocabulary.chatErrorDecode
            self.logger.error("chat post malformed")
        case .serverError(let status, let reason):
            self.updateMessageStatus(id: headID, status: .failed)
            self.isSending = false
            self.lastError = reason ?? (status == 500 ? SourceVocabulary.chatErrorServer : SourceVocabulary.chatErrorGeneric)
            self.logger.info("chat post failed status=\(status)")
        }

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

    func apply(_ event: ChatEvent) {
        switch event {
        case .snapshot(let snapshot):
            self.queueDepth = snapshot.queueDepth
            self.activeTalents = Dictionary(uniqueKeysWithValues: snapshot.activeTalents.map { ($0.id, $0) })
            self.queuedTalents = self.dedupQueuedTalents(snapshot.queuedTalents + self.queuedTalents)
            self.removeQueuedTalentsThatAreActive()
            self.erroredTalentLabels = []
            self.rebuildActiveTrace()
            if let message = snapshot.latestSolMessage {
                self.applySolMessage(message)
            }
        case .ownerMessage(let message):
            self.applyOwnerMessage(message)
        case .solMessage(let message):
            self.applySolMessage(message)
        case .talentQueued(let talent):
            self.upsertQueuedTalent(talent)
        case .talentSpawned(let talent):
            if self.promoteQueuedTalentIfNeeded(talent) {
                return
            }
            guard self.matchesOutstandingTurn(useID: talent.useID) else { return }
            self.activeTalents[talent.id] = talent
            self.rebuildActiveTrace()
        case .talentFinished(let talent):
            if self.finishActiveTalentIfNeeded(talent, errored: false) {
                return
            }
            guard self.matchesOutstandingTurn(useID: talent.useID) else { return }
            self.activeTalents[talent.id] = nil
            self.rebuildActiveTrace()
        case .talentErrored(let talent):
            if self.finishActiveTalentIfNeeded(talent, errored: true) {
                return
            }
            guard self.matchesOutstandingTurn(useID: talent.useID) else { return }
            self.activeTalents[talent.id] = nil
            self.appendUnique(talent.label, to: &self.erroredTalentLabels)
            self.rebuildActiveTrace()
        case .chatError(let error):
            self.applyChatError(error)
        case .queueDepth(let depth):
            self.queueDepth = depth
        case .result(let result):
            self.applyResultEvent(result)
        }
    }

    func applyOwnerMessage(_ event: ChatOwnerMessage) {
        guard let index = self.userMessageIndex(useID: event.useID, requestID: event.requestID) else { return }
        self.messages[index].requestID = event.requestID
    }

    func applySolMessage(_ event: ChatSolMessage) {
        if let origin = event.origin {
            self.applyFoldSolMessage(event, origin: origin)
            return
        }

        guard self.matchesOutstandingTurn(useID: event.useID) else { return }

        let receivedAt = event.timestamp ?? Date()
        self.latestSolMessageAt = receivedAt

        if let offer = event.offer {
            self.pendingOffer = offer
            self.isSending = false
        }
        if let draft = event.draft {
            self.pendingDraft = draft
            self.isSending = false
        }

        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            if event.offer == nil, event.draft == nil {
                self.lastError = SourceVocabulary.chatErrorEmptyReply
                self.answerRetryText = self.userText(useID: event.useID, requestID: event.requestID)
                self.clearOutstandingTurn(useID: event.useID)
                self.logger.info("chat answer empty")
            }
            return
        }

        self.upsertAssistantMessage(
            idSeed: event.id,
            text: text,
            provenance: event.provenance,
            useID: event.useID,
            requestID: event.requestID,
            origin: nil
        )
        self.lastError = nil
        self.answerRetryText = nil
        self.pendingOffer = event.offer
        self.pendingDraft = event.draft
        self.clearOutstandingTurn(useID: event.useID)
    }

    func applyFoldSolMessage(_ event: ChatSolMessage, origin: ChatSolOrigin) {
        let receivedAt = event.timestamp ?? Date()
        self.latestSolMessageAt = receivedAt

        if let useID = event.useID {
            self.removeQueuedTalent(useID: useID)
            self.removeActiveTalent(useID: useID)
        }

        let text = self.displayText(for: event)
        self.upsertAssistantMessage(
            idSeed: event.id,
            text: text,
            provenance: event.provenance,
            useID: event.useID,
            requestID: event.requestID,
            origin: origin
        )
        self.lastError = nil
        self.answerRetryText = nil
        self.pendingOffer = event.offer
        self.pendingDraft = event.draft
    }

    func applyChatError(_ error: ChatErrorEvent) {
        guard self.matchesOutstandingTurn(useID: error.useID) else { return }
        guard self.isNewerThanLatestSolMessage(error.timestamp) else { return }
        let text = error.detail?.isEmpty == false ? error.detail! : error.reason
        self.upsertAssistantMessage(
            idSeed: error.id,
            text: text,
            provenance: AnswerProvenance(state: .failed),
            useID: error.useID,
            requestID: error.requestID,
            origin: nil
        )
        self.lastError = SourceVocabulary.chatErrorServer
        self.answerRetryText = self.userText(useID: error.useID, requestID: error.requestID)
        self.pendingOffer = nil
        self.pendingDraft = nil
        self.clearOutstandingTurn(useID: error.useID)
        self.logger.info("chat answer error")
    }

    func applyResultEvent(_ result: ChatResultEvent) {
        self.pendingOffer = nil
        self.pendingDraft = nil

        if result.ok {
            self.lastError = nil
            self.logger.info("chat result ok")
        } else {
            self.lastError = SourceVocabulary.chatErrorServer
            self.logger.info("chat result failed")
        }
    }

    func applyDraftOutcome(_ outcome: DraftOutcome) async {
        switch outcome {
        case .accepted(let message), .cancelled(let message):
            self.pendingDraft = nil
            if let message {
                self.applySolMessage(message)
            }
        case .failed(let reason):
            self.lastError = reason ?? SourceVocabulary.chatErrorGeneric
        case .transport:
            self.lastError = SourceVocabulary.chatErrorGeneric
        }
    }

    func clearOutstandingTurn(useID: String?) {
        if !self.matchesOutstandingTurn(useID: useID) {
            return
        }

        self.outstandingTurnUseID = nil
        self.isSending = false

        if self.hasPending {
            self.startRetryTickIfNeeded()
            self.drainIfPossible()
        } else {
            self.stopRetryTick()
        }
    }

    func isNewerThanLatestSolMessage(_ errorAt: Date?) -> Bool {
        guard let latestSolMessageAt else { return true }
        guard let errorAt else { return true }
        return errorAt >= latestSolMessageAt
    }

    func updateMessageStatus(id: UUID, status: ChatMessage.Status) {
        guard let index = self.messages.firstIndex(where: { $0.id == id }) else { return }
        self.messages[index].status = status
    }

    func markUserSent(headID: UUID, useID: String) {
        guard let index = self.messages.firstIndex(where: { $0.id == headID }) else { return }
        self.messages[index].status = .sent
        self.messages[index].useID = useID
    }

    func upsertAssistantMessage(
        idSeed: String,
        text: String,
        provenance: AnswerProvenance?,
        useID: String?,
        requestID: String?,
        origin: ChatSolOrigin?
    ) {
        if let index = self.assistantMessageIndex(useID: useID, requestID: requestID, origin: origin) {
            self.messages[index].text = text
            self.messages[index].provenance = provenance
            self.messages[index].origin = origin
            return
        }

        let assistant = ChatMessage(
            id: Self.uuid(seed: idSeed),
            role: .assistant,
            text: text,
            provenance: provenance,
            requestID: requestID,
            useID: useID,
            origin: origin
        )

        if origin != nil {
            self.messages.append(assistant)
        } else if let userIndex = self.userMessageIndex(useID: useID, requestID: requestID) {
            self.messages.insert(assistant, at: self.messages.index(after: userIndex))
        } else {
            self.messages.append(assistant)
        }
    }

    func userMessageIndex(useID: String?, requestID: String?) -> Int? {
        self.messages.firstIndex { message in
            guard message.role == .user else { return false }
            return self.matches(message, useID: useID, requestID: requestID)
        }
    }

    func assistantMessageIndex(useID: String?, requestID: String?, origin: ChatSolOrigin?) -> Int? {
        self.messages.firstIndex { message in
            guard message.role == .assistant else { return false }
            if let origin {
                return message.origin?.logicalUseID == origin.logicalUseID && message.useID == useID
            }
            guard message.origin == nil else { return false }
            return self.matches(message, useID: useID, requestID: requestID)
        }
    }

    func matches(_ message: ChatMessage, useID: String?, requestID: String?) -> Bool {
        if let useID, message.useID == useID {
            return true
        }
        if let requestID, message.requestID == requestID {
            return true
        }
        return false
    }

    func matchesOutstandingTurn(useID: String?) -> Bool {
        guard let outstandingTurnUseID else { return true }
        return useID == outstandingTurnUseID
    }

    func userText(useID: String?, requestID: String?) -> String? {
        if let index = self.userMessageIndex(useID: useID, requestID: requestID) {
            return self.messages[index].text
        }
        return self.messages.last(where: { $0.role == .user && $0.status == .sent })?.text
    }

    func rebuildActiveTrace() {
        let trace = ChatWorkingTrace(
            activeLabels: self.activeTalents.values.sorted { $0.id < $1.id }.map(\.label),
            erroredLabels: self.erroredTalentLabels
        )
        self.activeTrace = trace.isEmpty ? nil : trace
    }

    func appendUnique(_ value: String, to values: inout [String]) {
        guard !values.contains(value) else { return }
        values.append(value)
    }

    func displayText(for event: ChatSolMessage) -> String {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return text
        }
        if event.provenance.state == .failed {
            return SourceVocabulary.chatAnswerFailedLine
        }
        return SourceVocabulary.chatErrorEmptyReply
    }

    func sortedActiveTalents() -> [ChatTalentActivity] {
        self.activeTalents.values.sorted { lhs, rhs in
            lhs.id < rhs.id
        }
    }

    func dedupQueuedTalents(_ talents: [ChatTalentActivity]) -> [ChatTalentActivity] {
        var deduped: [ChatTalentActivity] = []
        for talent in talents {
            guard let useID = talent.useID, !useID.isEmpty else { continue }
            if let index = deduped.firstIndex(where: { $0.useID == useID }) {
                deduped[index] = self.mergedQueuedTalent(existing: deduped[index], incoming: talent)
            } else {
                deduped.append(talent)
            }
        }
        return deduped
    }

    func upsertQueuedTalent(_ talent: ChatTalentActivity) {
        guard talent.useID.map({ !$0.isEmpty }) == true else { return }
        self.queuedTalents = self.dedupQueuedTalents(self.queuedTalents + [talent])
    }

    func mergedQueuedTalent(existing: ChatTalentActivity, incoming: ChatTalentActivity) -> ChatTalentActivity {
        ChatTalentActivity(
            id: incoming.id,
            useID: incoming.useID,
            label: incoming.label,
            task: incoming.task ?? existing.task,
            timestamp: incoming.timestamp ?? existing.timestamp,
            queuedAt: incoming.queuedAt ?? existing.queuedAt
        )
    }

    func queuedTalent(useID: String?) -> ChatTalentActivity? {
        guard let useID else { return nil }
        return self.queuedTalents.first { $0.useID == useID }
    }

    func removeQueuedTalent(useID: String) {
        self.queuedTalents.removeAll { $0.useID == useID }
    }

    func removeQueuedTalentsThatAreActive() {
        var activeUseIDs = Set<String>()
        for talent in self.activeTalents.values {
            if let useID = talent.useID {
                activeUseIDs.insert(useID)
            }
        }
        self.queuedTalents.removeAll { talent in
            guard let useID = talent.useID else { return false }
            return activeUseIDs.contains(useID)
        }
    }

    func promoteQueuedTalentIfNeeded(_ talent: ChatTalentActivity) -> Bool {
        guard let queued = self.queuedTalent(useID: talent.useID), let useID = talent.useID else {
            return false
        }
        self.removeQueuedTalent(useID: useID)
        self.activeTalents[talent.id] = ChatTalentActivity(
            id: talent.id,
            useID: talent.useID,
            label: talent.label,
            task: talent.task ?? queued.task,
            timestamp: talent.timestamp ?? queued.timestamp,
            queuedAt: queued.queuedAt
        )
        self.rebuildActiveTrace()
        return true
    }

    func finishActiveTalentIfNeeded(_ talent: ChatTalentActivity, errored: Bool) -> Bool {
        guard let key = self.activeTalentKey(for: talent) else { return false }
        let active = self.activeTalents[key]
        self.activeTalents[key] = nil
        if errored {
            self.appendUnique(active?.label ?? talent.label, to: &self.erroredTalentLabels)
        }
        self.rebuildActiveTrace()
        return true
    }

    func removeActiveTalent(useID: String) {
        guard let key = self.activeTalentKey(useID: useID) else { return }
        self.activeTalents[key] = nil
        self.rebuildActiveTrace()
    }

    func activeTalentKey(for talent: ChatTalentActivity) -> String? {
        if self.activeTalents[talent.id] != nil {
            return talent.id
        }
        guard let useID = talent.useID else { return nil }
        return self.activeTalentKey(useID: useID)
    }

    func activeTalentKey(useID: String) -> String? {
        self.activeTalents.first { $0.value.useID == useID }?.key
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

    static func uuid(seed: String) -> UUID {
        let bytes = Array(seed.utf8)
        var value: UInt64 = 0xcbf29ce484222325
        for byte in bytes {
            value ^= UInt64(byte)
            value &*= 0x100000001b3
        }
        return UUID(uuid: (
            UInt8((value >> 56) & 0xff),
            UInt8((value >> 48) & 0xff),
            UInt8((value >> 40) & 0xff),
            UInt8((value >> 32) & 0xff),
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
            0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
            UInt8(bytes.count & 0xff),
            UInt8((bytes.count >> 8) & 0xff)
        ))
    }
}

private final class InFlightToken {}

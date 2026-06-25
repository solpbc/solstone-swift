// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private nonisolated struct ChatPostBody: Encodable {
    let message: String
}

private nonisolated struct ChatPostAckResponse: Decodable {
    let useId: String
    let queued: Bool
    let queueDepth: Int?
}

private nonisolated struct ChatServerErrorResponse: Decodable {
    let error: String?
    let reasonCode: String?
    let reason: String?
    let message: String?
    let queueDepth: Int?

    var displayReason: String? {
        self.reasonCode ?? self.reason ?? self.error ?? self.message
    }
}

nonisolated struct ConveyChatTransport: ChatTransporting, Sendable {
    private let localPortProvider: @Sendable @MainActor () -> Int?
    private let session: URLSession
    private let logger = Logger(subsystem: "app.solstone.swift", category: "chat")

    init(
        localPortProvider: @escaping @Sendable @MainActor () -> Int?,
        session: URLSession = .shared
    ) {
        self.localPortProvider = localPortProvider
        self.session = session
    }

    func postMessage(_ text: String) async -> ChatPostResult {
        guard let url = await self.url(path: "/api/chat") else {
            return .transport
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(ChatPostBody(message: text))
            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .transport }

            guard 200..<300 ~= http.statusCode else {
                let serverError = try? Self.decoder.decode(ChatServerErrorResponse.self, from: data)
                switch http.statusCode {
                case 429:
                    return .queueFull(queueDepth: serverError?.queueDepth)
                case 503:
                    return .unavailable(reason: serverError?.displayReason)
                default:
                    return .serverError(status: http.statusCode, reason: serverError?.displayReason)
                }
            }

            guard let ack = try? Self.decoder.decode(ChatPostAckResponse.self, from: data),
                  !ack.useId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .malformed
            }

            return .ack(useID: ack.useId, queued: ack.queued, queueDepth: ack.queueDepth)
        } catch {
            self.logger.debug("chat post failed: \(String(describing: error), privacy: .public)")
            return .transport
        }
    }

    func events() -> AsyncStream<ChatEvent> {
        AsyncStream { continuation in
            let task = Task {
                var backoffSeconds: UInt64 = 1

                while !Task.isCancelled {
                    guard let port = await self.currentLocalPort() else {
                        try? await Task.sleep(for: .seconds(1))
                        continue
                    }

                    await self.emitSessionSnapshot(localPort: port, continuation: continuation)

                    do {
                        try await self.streamEvents(localPort: port, continuation: continuation)
                        backoffSeconds = 1
                        continuation.yield(.eventStream(.reconnecting))
                    } catch {
                        continuation.yield(.eventStream(.reconnecting))
                        self.logger.debug("chat events dropped: \(String(describing: error), privacy: .public)")
                        try? await Task.sleep(for: .seconds(backoffSeconds))
                        backoffSeconds = min(backoffSeconds * 2, 8)
                    }
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func declineOffer() async -> Bool {
        await self.postNoBody(path: "/api/chat/offer/decline")
    }

    func confirmDraft(id: String) async -> DraftOutcome {
        await self.postDraftDecision(path: "/api/chat/support/draft/confirm", id: id, accepted: true)
    }

    func cancelDraft(id: String) async -> DraftOutcome {
        await self.postDraftDecision(path: "/api/chat/support/draft/cancel", id: id, accepted: false)
    }
}

private extension ConveyChatTransport {
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    func currentLocalPort() async -> Int? {
        await MainActor.run {
            self.localPortProvider()
        }
    }

    func url(path: String) async -> URL? {
        guard let port = await self.currentLocalPort() else { return nil }
        return ConveyChatURL.url(localPort: port, path: path)
    }

    func postNoBody(path: String) async -> Bool {
        guard let url = await self.url(path: path) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        do {
            let (_, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return 200..<300 ~= http.statusCode
        } catch {
            self.logger.debug("chat offer decline failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func postDraftDecision(path: String, id: String, accepted: Bool) async -> DraftOutcome {
        guard let url = await self.url(path: path) else { return .transport }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(["draft_id": id])
            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .transport }
            guard 200..<300 ~= http.statusCode else {
                let serverError = try? Self.decoder.decode(ChatServerErrorResponse.self, from: data)
                return .failed(reason: serverError?.displayReason)
            }

            let message = Self.decodeDraftOutcomeMessage(from: data)
            return accepted ? .accepted(message) : .cancelled(message)
        } catch {
            self.logger.debug("chat draft decision failed: \(String(describing: error), privacy: .public)")
            return .transport
        }
    }

    func emitSessionSnapshot(localPort: Int, continuation: AsyncStream<ChatEvent>.Continuation) async {
        guard let url = ConveyChatURL.url(localPort: localPort, path: "/api/chat/session") else { return }
        do {
            let (data, response) = try await self.session.data(from: url)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return }
            if let snapshot = try? Self.decoder.decode(WireSessionSnapshot.self, from: data).normalized {
                continuation.yield(.snapshot(snapshot))
            }
        } catch {
            self.logger.debug("chat session hydrate failed: \(String(describing: error), privacy: .public)")
        }
    }

    func streamEvents(localPort: Int, continuation: AsyncStream<ChatEvent>.Continuation) async throws {
        guard let url = ConveyChatURL.url(localPort: localPort, path: "/sse/events") else { return }
        let (bytes, response) = try await self.session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        continuation.yield(.eventStream(.connected))

        var parser = ServerSentEventParser()
        for try await byte in bytes {
            guard !Task.isCancelled else { return }
            let events = parser.append(Data([byte]))
            for serverEvent in events {
                if let event = Self.decodeChatEvent(from: serverEvent.data) {
                    continuation.yield(event)
                }
            }
        }

        for serverEvent in parser.finish() {
            if let event = Self.decodeChatEvent(from: serverEvent.data) {
                continuation.yield(event)
            }
        }
    }

    static func decodeChatEvent(from string: String) -> ChatEvent? {
        guard let data = string.data(using: .utf8),
              let envelope = try? Self.decoder.decode(WireChatEnvelope.self, from: data),
              envelope.tract == "chat"
        else {
            return nil
        }

        let kind = envelope.kind ?? envelope.event ?? envelope.type
        switch kind {
        case "snapshot":
            return .snapshot(envelope.snapshot)
        case "owner_message":
            guard let message = envelope.ownerMessage else { return nil }
            return .ownerMessage(message)
        case "sol_message":
            guard let message = envelope.solMessage else { return nil }
            return .solMessage(message)
        case "talent_queued":
            guard let talent = envelope.talent else { return nil }
            return .talentQueued(talent)
        case "talent_spawned":
            guard let talent = envelope.talent else { return nil }
            return .talentSpawned(talent)
        case "talent_finished":
            guard let talent = envelope.talent else { return nil }
            return .talentFinished(talent)
        case "talent_errored":
            guard let talent = envelope.talent else { return nil }
            return .talentErrored(talent)
        case "chat_error":
            guard let error = envelope.chatError else { return nil }
            return .chatError(error)
        case "chat_queue_depth":
            guard let depth = envelope.queueDepth else { return nil }
            return .queueDepth(depth)
        case "result":
            guard let result = envelope.result else { return nil }
            return .result(result)
        default:
            return nil
        }
    }

    static func decodeDraftOutcomeMessage(from data: Data) -> ChatSolMessage? {
        guard !data.isEmpty else { return nil }
        if let response = try? Self.decoder.decode(WireDraftOutcomeResponse.self, from: data) {
            return response.normalizedMessage
        }
        return nil
    }
}

private nonisolated struct WireSessionSnapshot: Decodable {
    let latestSolMessage: WireSolMessage?
    let activeTalents: [WireTalent]?
    let completedTalents: [WireTalent]?
    let queuedTalents: [WireTalent]?
    let chatError: WireChatError?
    let queueDepth: Int?
    let chat: WireSessionPayload?

    var normalized: ChatSessionSnapshot {
        let payload = self.chat ?? WireSessionPayload(
            latestSolMessage: self.latestSolMessage,
            activeTalents: self.activeTalents,
            completedTalents: self.completedTalents,
            queuedTalents: self.queuedTalents,
            chatError: self.chatError,
            queueDepth: self.queueDepth
        )
        return payload.normalized
    }
}

private nonisolated struct WireSessionPayload: Decodable {
    let latestSolMessage: WireSolMessage?
    let activeTalents: [WireTalent]?
    let completedTalents: [WireTalent]?
    let queuedTalents: [WireTalent]?
    let chatError: WireChatError?
    let queueDepth: Int?

    var normalized: ChatSessionSnapshot {
        ChatSessionSnapshot(
            latestSolMessage: self.latestSolMessage?.normalized,
            activeTalents: self.activeTalents?.compactMap (\.normalized) ?? [],
            completedTalents: self.completedTalents?.compactMap (\.normalized) ?? [],
            queuedTalents: self.queuedTalents?.compactMap (\.normalized) ?? [],
            chatError: self.chatError?.normalized,
            queueDepth: self.queueDepth
        )
    }
}

private nonisolated struct WireChatEnvelope: Decodable {
    let tract: String?
    let kind: String?
    let event: String?
    let type: String?
    let queueDepth: Int?
    let latestSolMessage: WireSolMessage?
    let activeTalents: [WireTalent]?
    let completedTalents: [WireTalent]?
    let queuedTalents: [WireTalent]?

    private let owner: WireOwnerMessage?
    private let sol: WireSolMessage?
    private let talentEvent: WireTalent?
    private let chatErrorEvent: WireChatError?
    private let resultEvent: WireResult?

    enum CodingKeys: String, CodingKey {
        case tract
        case kind
        case event
        case type
        case queueDepth
        case latestSolMessage
        case activeTalents
        case completedTalents
        case queuedTalents
        case ownerMessage
        case solMessage
        case message
        case talent
        case origin
        case error
        case result
        case id
        case text
        case requestId
        case useId
        case logicalUseId
        case ask
        case requestedTarget
        case answerState
        case sources
        case coverage
        case offer
        case draft
        case name
        case label
        case task
        case queuedAt
        case reason
        case detail
        case ok
        case ts
        case timestamp
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tract = try container.decodeIfPresent(String.self, forKey: .tract)
        self.kind = try container.decodeIfPresent(String.self, forKey: .kind)
        self.event = try container.decodeIfPresent(String.self, forKey: .event)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.queueDepth = try container.decodeIfPresent(Int.self, forKey: .queueDepth)
        self.latestSolMessage = try container.decodeIfPresent(WireSolMessage.self, forKey: .latestSolMessage)
        self.activeTalents = try container.decodeIfPresent([WireTalent].self, forKey: .activeTalents)
        self.completedTalents = try container.decodeIfPresent([WireTalent].self, forKey: .completedTalents)
        self.queuedTalents = try container.decodeIfPresent([WireTalent].self, forKey: .queuedTalents)

        self.owner = (try? container.decode(WireOwnerMessage.self, forKey: .ownerMessage))
            ?? (try? container.decode(WireOwnerMessage.self, forKey: .message))
            ?? WireOwnerMessage(envelopeContainer: container)
        self.sol = (try? container.decode(WireSolMessage.self, forKey: .solMessage))
            ?? (try? container.decode(WireSolMessage.self, forKey: .message))
            ?? WireSolMessage(envelopeContainer: container)
        self.talentEvent = (try? container.decode(WireTalent.self, forKey: .talent))
            ?? WireTalent(envelopeContainer: container)
        self.chatErrorEvent = (try? container.decode(WireChatError.self, forKey: .error))
            ?? WireChatError(envelopeContainer: container)
        self.resultEvent = (try? container.decode(WireResult.self, forKey: .result))
            ?? WireResult(envelopeContainer: container)
    }

    var snapshot: ChatSessionSnapshot {
        ChatSessionSnapshot(
            latestSolMessage: self.latestSolMessage?.normalized,
            activeTalents: self.activeTalents?.compactMap (\.normalized) ?? [],
            completedTalents: self.completedTalents?.compactMap (\.normalized) ?? [],
            queuedTalents: self.queuedTalents?.compactMap (\.normalized) ?? [],
            chatError: nil,
            queueDepth: self.queueDepth
        )
    }

    var ownerMessage: ChatOwnerMessage? {
        self.owner?.normalized
    }

    var solMessage: ChatSolMessage? {
        self.sol?.normalized
    }

    var talent: ChatTalentActivity? {
        self.talentEvent?.normalized
    }

    var chatError: ChatErrorEvent? {
        self.chatErrorEvent?.normalized
    }

    var result: ChatResultEvent? {
        self.resultEvent?.normalized
    }
}

private nonisolated struct WireOwnerMessage: Decodable {
    let id: String?
    let text: String?
    let requestId: String?
    let useId: String?
    let ts: Double?
    let timestamp: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        self.useId = try container.decodeIfPresent(String.self, forKey: .useId)
        self.ts = try container.decodeIfPresent(Double.self, forKey: .ts)
        self.timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
    }

    init?(envelopeContainer container: KeyedDecodingContainer<WireChatEnvelope.CodingKeys>) {
        self.id = try? container.decodeIfPresent(String.self, forKey: .id)
        self.text = try? container.decodeIfPresent(String.self, forKey: .text)
        self.requestId = try? container.decodeIfPresent(String.self, forKey: .requestId)
        self.useId = try? container.decodeIfPresent(String.self, forKey: .useId)
        self.ts = try? container.decodeIfPresent(Double.self, forKey: .ts)
        self.timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
        guard self.text != nil || self.id != nil || self.useId != nil || self.requestId != nil else { return nil }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case requestId
        case useId
        case ts
        case timestamp
    }

    var normalized: ChatOwnerMessage? {
        guard let text else { return nil }
        return ChatOwnerMessage(
            id: self.id ?? self.useId ?? self.requestId ?? text,
            text: text,
            requestID: self.requestId,
            useID: self.useId,
            timestamp: chatDate(ts: self.ts, timestamp: self.timestamp)
        )
    }
}

private nonisolated struct WireSolMessage: Decodable {
    let id: String?
    let text: String?
    let requestId: String?
    let useId: String?
    let requestedTarget: String?
    let origin: WireSolOrigin?
    let answerState: AnswerState?
    let sources: [WireSource]?
    let coverage: [String]?
    let offer: WireOffer?
    let draft: WireDraft?
    let ts: Double?
    let timestamp: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        self.useId = try container.decodeIfPresent(String.self, forKey: .useId)
        self.requestedTarget = try container.decodeIfPresent(String.self, forKey: .requestedTarget)
        self.origin = try container.decodeIfPresent(WireSolOrigin.self, forKey: .origin)
        self.answerState = try container.decodeIfPresent(AnswerState.self, forKey: .answerState)
        self.sources = try container.decodeIfPresent([WireSource].self, forKey: .sources)
        self.coverage = try container.decodeIfPresent([String].self, forKey: .coverage)
        self.offer = try container.decodeIfPresent(WireOffer.self, forKey: .offer)
        self.draft = try container.decodeIfPresent(WireDraft.self, forKey: .draft)
        self.ts = try container.decodeIfPresent(Double.self, forKey: .ts)
        self.timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
    }

    init?(envelopeContainer container: KeyedDecodingContainer<WireChatEnvelope.CodingKeys>) {
        self.id = try? container.decodeIfPresent(String.self, forKey: .id)
        self.text = try? container.decodeIfPresent(String.self, forKey: .text)
        self.requestId = try? container.decodeIfPresent(String.self, forKey: .requestId)
        self.useId = try? container.decodeIfPresent(String.self, forKey: .useId)
        self.requestedTarget = try? container.decodeIfPresent(String.self, forKey: .requestedTarget)
        self.origin = try? container.decodeIfPresent(WireSolOrigin.self, forKey: .origin)
        self.answerState = try? container.decodeIfPresent(AnswerState.self, forKey: .answerState)
        self.sources = try? container.decodeIfPresent([WireSource].self, forKey: .sources)
        self.coverage = try? container.decodeIfPresent([String].self, forKey: .coverage)
        self.offer = try? container.decodeIfPresent(WireOffer.self, forKey: .offer)
        self.draft = try? container.decodeIfPresent(WireDraft.self, forKey: .draft)
        self.ts = try? container.decodeIfPresent(Double.self, forKey: .ts)
        self.timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
        guard self.text != nil || self.id != nil || self.useId != nil || self.requestId != nil || self.offer != nil || self.draft != nil else {
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case requestId
        case useId
        case requestedTarget
        case origin
        case answerState
        case sources
        case coverage
        case offer
        case draft
        case ts
        case timestamp
    }

    var normalized: ChatSolMessage? {
        let rawText = self.text ?? ""
        let stripped = ChatMarkdown.stripSolCitations(from: rawText)
        let payloadSources = self.sources?.compactMap (\.normalized) ?? []
        let sources = dedupeSources(payloadSources + stripped.sources)
        let provenance = AnswerProvenance(
            state: self.answerState ?? .answered,
            sources: sources,
            coverage: self.coverage ?? []
        )
        return ChatSolMessage(
            id: self.id ?? self.useId ?? self.requestId ?? rawText,
            text: stripped.text,
            requestID: self.requestId,
            useID: self.useId,
            requestedTarget: self.requestedTarget,
            origin: self.origin?.normalized,
            provenance: provenance,
            offer: self.offer?.normalized,
            draft: self.draft?.normalized,
            timestamp: chatDate(ts: self.ts, timestamp: self.timestamp)
        )
    }
}

private nonisolated struct WireSolOrigin: Decodable {
    let logicalUseId: String?
    let ask: String?

    var normalized: ChatSolOrigin? {
        guard let logicalUseId, !logicalUseId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ChatSolOrigin(logicalUseID: logicalUseId, ask: self.ask)
    }
}

private nonisolated struct WireTalent: Decodable {
    let id: String?
    let useId: String?
    let name: String?
    let label: String?
    let task: String?
    let queuedAtString: String?
    let queuedAtTs: Double?
    let ts: Double?
    let timestamp: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.useId = try container.decodeIfPresent(String.self, forKey: .useId)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.label = try container.decodeIfPresent(String.self, forKey: .label)
        self.task = try container.decodeIfPresent(String.self, forKey: .task)
        self.queuedAtString = try? container.decodeIfPresent(String.self, forKey: .queuedAt)
        self.queuedAtTs = try? container.decodeIfPresent(Double.self, forKey: .queuedAt)
        self.ts = try container.decodeIfPresent(Double.self, forKey: .ts)
        self.timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
    }

    init?(envelopeContainer container: KeyedDecodingContainer<WireChatEnvelope.CodingKeys>) {
        self.id = try? container.decodeIfPresent(String.self, forKey: .id)
        self.useId = try? container.decodeIfPresent(String.self, forKey: .useId)
        self.name = try? container.decodeIfPresent(String.self, forKey: .name)
        self.label = try? container.decodeIfPresent(String.self, forKey: .label)
        self.task = try? container.decodeIfPresent(String.self, forKey: .task)
        self.queuedAtString = try? container.decodeIfPresent(String.self, forKey: .queuedAt)
        self.queuedAtTs = try? container.decodeIfPresent(Double.self, forKey: .queuedAt)
        self.ts = try? container.decodeIfPresent(Double.self, forKey: .ts)
        self.timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
        guard self.name != nil || self.label != nil || self.task != nil || self.id != nil || self.useId != nil else { return nil }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case useId
        case name
        case label
        case task
        case queuedAt
        case ts
        case timestamp
    }

    var normalized: ChatTalentActivity? {
        let label = self.name ?? self.label ?? self.task ?? self.id ?? self.useId ?? ""
        guard !label.isEmpty else { return nil }
        return ChatTalentActivity(
            id: self.id ?? self.useId ?? "talent-\(label)",
            useID: self.useId,
            label: label,
            task: self.task,
            timestamp: chatDate(ts: self.ts, timestamp: self.timestamp),
            queuedAt: chatDate(ts: self.queuedAtTs, timestamp: self.queuedAtString)
        )
    }
}

private nonisolated struct WireSource: Decodable {
    let ref: String?
    let label: String?
    let name: String?
    let url: URL?
    let openUrl: URL?

    var normalized: AnswerProvenance.ProvenanceSource? {
        guard let ref = self.ref ?? self.url?.absoluteString ?? self.openUrl?.absoluteString else { return nil }
        let label = self.label ?? self.name ?? ref
        return AnswerProvenance.ProvenanceSource(ref: ref, label: label, url: self.openUrl ?? self.url)
    }
}

private nonisolated struct WireOffer: Decodable {
    let id: String?
    let kind: String?
    let text: String?

    var normalized: ChatOffer? {
        let kind = ChatOffer.Kind(rawValue: self.kind ?? "support") ?? .support
        return ChatOffer(id: self.id ?? "support", kind: kind, text: self.text ?? "")
    }
}

private nonisolated struct WireDraft: Decodable {
    let id: String?
    let body: String?
    let fields: [WireDraftField]?
    let diagnosticsIncluded: Bool?

    var normalized: ChatDraft? {
        guard let id = self.id, let body = self.body else { return nil }
        return ChatDraft(
            id: id,
            body: body,
            fields: self.fields?.map(\.normalized) ?? [],
            diagnosticsIncluded: self.diagnosticsIncluded ?? false
        )
    }
}

private nonisolated struct WireDraftField: Decodable {
    let id: String?
    let label: String?
    let value: String?

    var normalized: ChatDraftField {
        let label = self.label ?? self.id ?? ""
        return ChatDraftField(id: self.id ?? label, label: label, value: self.value ?? "")
    }
}

private nonisolated struct WireChatError: Decodable {
    let id: String?
    let requestId: String?
    let useId: String?
    let reason: String?
    let detail: String?
    let ts: Double?
    let timestamp: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        self.useId = try container.decodeIfPresent(String.self, forKey: .useId)
        self.reason = try container.decodeIfPresent(String.self, forKey: .reason)
        self.detail = try container.decodeIfPresent(String.self, forKey: .detail)
        self.ts = try container.decodeIfPresent(Double.self, forKey: .ts)
        self.timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
    }

    init?(envelopeContainer container: KeyedDecodingContainer<WireChatEnvelope.CodingKeys>) {
        self.id = try? container.decodeIfPresent(String.self, forKey: .id)
        self.requestId = try? container.decodeIfPresent(String.self, forKey: .requestId)
        self.useId = try? container.decodeIfPresent(String.self, forKey: .useId)
        self.reason = try? container.decodeIfPresent(String.self, forKey: .reason)
        self.detail = try? container.decodeIfPresent(String.self, forKey: .detail)
        self.ts = try? container.decodeIfPresent(Double.self, forKey: .ts)
        self.timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
        guard self.reason != nil || self.detail != nil || self.id != nil else { return nil }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case requestId
        case useId
        case reason
        case detail
        case ts
        case timestamp
    }

    var normalized: ChatErrorEvent? {
        let reason = self.reason ?? self.detail ?? SourceVocabulary.chatErrorServer
        return ChatErrorEvent(
            id: self.id ?? self.useId ?? self.requestId ?? reason,
            requestID: self.requestId,
            useID: self.useId,
            reason: reason,
            detail: self.detail,
            timestamp: chatDate(ts: self.ts, timestamp: self.timestamp)
        )
    }
}

private nonisolated struct WireResult: Decodable {
    let id: String?
    let requestId: String?
    let useId: String?
    let ok: Bool?
    let message: String?
    let ts: Double?
    let timestamp: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        self.useId = try container.decodeIfPresent(String.self, forKey: .useId)
        self.ok = try container.decodeIfPresent(Bool.self, forKey: .ok)
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
        self.ts = try container.decodeIfPresent(Double.self, forKey: .ts)
        self.timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
    }

    init?(envelopeContainer container: KeyedDecodingContainer<WireChatEnvelope.CodingKeys>) {
        self.id = try? container.decodeIfPresent(String.self, forKey: .id)
        self.requestId = try? container.decodeIfPresent(String.self, forKey: .requestId)
        self.useId = try? container.decodeIfPresent(String.self, forKey: .useId)
        self.ok = try? container.decodeIfPresent(Bool.self, forKey: .ok)
        self.message = try? container.decodeIfPresent(String.self, forKey: .message)
        self.ts = try? container.decodeIfPresent(Double.self, forKey: .ts)
        self.timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
        guard self.ok != nil || self.message != nil || self.id != nil else { return nil }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case requestId
        case useId
        case ok
        case message
        case ts
        case timestamp
    }

    var normalized: ChatResultEvent? {
        guard let ok else { return nil }
        return ChatResultEvent(
            id: self.id ?? self.useId ?? self.requestId ?? String(ok),
            requestID: self.requestId,
            useID: self.useId,
            ok: ok,
            message: self.message,
            timestamp: chatDate(ts: self.ts, timestamp: self.timestamp)
        )
    }
}

private nonisolated struct WireDraftOutcomeResponse: Decodable {
    let solMessage: WireSolMessage?
    let message: WireSolMessage?

    var normalizedMessage: ChatSolMessage? {
        self.solMessage?.normalized ?? self.message?.normalized
    }
}

private nonisolated func chatDate(ts: Double?, timestamp: String?) -> Date? {
    if let ts {
        let seconds = ts > 1_000_000_000_000 ? ts / 1_000 : ts
        return Date(timeIntervalSince1970: seconds)
    }
    if let timestamp {
        return ISO8601DateFormatter().date(from: timestamp)
    }
    return nil
}

private nonisolated func dedupeSources(_ sources: [AnswerProvenance.ProvenanceSource]) -> [AnswerProvenance.ProvenanceSource] {
    var seen = Set<String>()
    return sources.filter { source in
        guard !seen.contains(source.ref) else { return false }
        seen.insert(source.ref)
        return true
    }
}

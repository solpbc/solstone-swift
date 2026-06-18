// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift

final class ScriptedChatTransport: ChatTransporting, @unchecked Sendable {
    var postResults: [ChatPostResult]
    var declineOfferResult: Bool
    var confirmDraftResults: [DraftOutcome]
    var cancelDraftResults: [DraftOutcome]
    private(set) var postedMessages: [String] = []
    private(set) var declinedOfferCount = 0
    private(set) var confirmedDraftIDs: [String] = []
    private(set) var cancelledDraftIDs: [String] = []

    private let continuation: AsyncStream<ChatEvent>.Continuation
    private let eventStream: AsyncStream<ChatEvent>

    init(
        postResults: [ChatPostResult] = [],
        declineOfferResult: Bool = true,
        confirmDraftResults: [DraftOutcome] = [],
        cancelDraftResults: [DraftOutcome] = []
    ) {
        let stream = AsyncStream<ChatEvent>.makeStream()
        self.eventStream = stream.stream
        self.continuation = stream.continuation
        self.postResults = postResults
        self.declineOfferResult = declineOfferResult
        self.confirmDraftResults = confirmDraftResults
        self.cancelDraftResults = cancelDraftResults
    }

    func postMessage(_ text: String) async -> ChatPostResult {
        self.postedMessages.append(text)
        guard !self.postResults.isEmpty else {
            return .ack(useID: "scripted-use-\(self.postedMessages.count)", queued: false, queueDepth: nil)
        }
        return self.postResults.removeFirst()
    }

    func events() -> AsyncStream<ChatEvent> {
        self.eventStream
    }

    func declineOffer() async -> Bool {
        self.declinedOfferCount += 1
        return self.declineOfferResult
    }

    func confirmDraft(id: String) async -> DraftOutcome {
        self.confirmedDraftIDs.append(id)
        guard !self.confirmDraftResults.isEmpty else { return .accepted(nil) }
        return self.confirmDraftResults.removeFirst()
    }

    func cancelDraft(id: String) async -> DraftOutcome {
        self.cancelledDraftIDs.append(id)
        guard !self.cancelDraftResults.isEmpty else { return .cancelled(nil) }
        return self.cancelDraftResults.removeFirst()
    }

    func push(_ event: ChatEvent) {
        self.continuation.yield(event)
    }

    func finishEvents() {
        self.continuation.finish()
    }
}

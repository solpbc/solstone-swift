// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class ChatManagerTests: XCTestCase {
    @MainActor
    func testAckMarksUserSentImmediatelyWithoutAssistantOrDuplicatePost() async {
        let transport = ScriptedChatTransport(postResults: [.ack(useID: "use-1", queued: false, queueDepth: nil)])
        let manager = self.makeManager(transport: transport)

        await manager.send("hello")
        manager._testDrainStep()
        await self.yieldForEvents()

        XCTAssertEqual(transport.postedMessages, ["hello"])
        XCTAssertEqual(manager.messages.count, 1)
        XCTAssertEqual(manager.messages[0].status, .sent)
        XCTAssertEqual(manager.messages[0].useID, "use-1")
        XCTAssertTrue(manager.isSending)
        XCTAssertNil(manager.lastError)
    }

    @MainActor
    func testFinalSolMessageInsertsAssistantAndDrainsNextQueuedTurn() async {
        let transport = ScriptedChatTransport(postResults: [
            .ack(useID: "use-1", queued: false, queueDepth: nil),
            .ack(useID: "use-2", queued: false, queueDepth: nil),
        ])
        let manager = self.makeManager(transport: transport)

        await manager.send("first")
        await manager.send("second")
        manager._testDrainStep()
        await self.yieldForEvents()

        XCTAssertEqual(transport.postedMessages, ["first"])
        XCTAssertEqual(manager.messages.map(\.status), [.sent, .pending])

        transport.push(.solMessage(ChatSolMessage(id: "sol-1", text: "hello back", useID: "use-1")))
        await self.yieldForEvents()

        XCTAssertEqual(transport.postedMessages, ["first", "second"])
        XCTAssertEqual(manager.messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(manager.messages[0].status, .sent)
        XCTAssertEqual(manager.messages[1].text, "hello back")
        XCTAssertEqual(manager.messages[2].status, .sent)
        XCTAssertTrue(manager.isSending)
    }

    @MainActor
    func testUncorrelatedFinalEventDoesNotClearAcceptedTurnOrDuplicatePost() async {
        let transport = ScriptedChatTransport(postResults: [
            .ack(useID: "use-1", queued: false, queueDepth: nil),
            .ack(useID: "use-2", queued: false, queueDepth: nil),
        ])
        let manager = self.makeManager(transport: transport)

        await manager.send("first")
        await manager.send("second")
        await self.yieldForEvents()

        transport.push(.solMessage(ChatSolMessage(id: "stray", text: "old answer")))
        manager._testDrainStep()
        await self.yieldForEvents()

        XCTAssertEqual(transport.postedMessages, ["first"])
        XCTAssertEqual(manager.messages.map(\.role), [.user, .user])
        XCTAssertEqual(manager.messages.map(\.status), [.sent, .pending])
        XCTAssertTrue(manager.isSending)

        transport.push(.solMessage(ChatSolMessage(id: "sol-1", text: "first answer", useID: "use-1")))
        await self.yieldForEvents()

        XCTAssertEqual(transport.postedMessages, ["first", "second"])
    }

    @MainActor
    func testUnreachableAndMissingPortStayPendingUntilDrainable() async {
        let transport = ScriptedChatTransport(postResults: [.ack(useID: "use-1", queued: false, queueDepth: nil)])
        let gate = OSAllocatedUnfairLock<(reachable: Bool, port: Int?)>(initialState: (false, nil))
        let manager = ChatManager(
            transport: transport,
            isReachable: { gate.withLock { $0.reachable } },
            localPortProvider: { gate.withLock { $0.port } }
        )

        await manager.send("hello")

        XCTAssertEqual(transport.postedMessages, [])
        XCTAssertEqual(manager.messages[0].status, .pending)

        gate.withLock { $0.reachable = true }
        manager._testDrainStep()
        await self.yieldForEvents()
        XCTAssertEqual(transport.postedMessages, [])

        gate.withLock { $0.port = 7071 }
        manager._testDrainStep()
        await self.yieldForEvents()

        XCTAssertEqual(transport.postedMessages, ["hello"])
        XCTAssertEqual(manager.messages[0].status, .sent)
    }

    @MainActor
    func testBackpressureKeepsPendingAndSchedulesRetrySurface() async {
        let queueFull = ScriptedChatTransport(postResults: [.queueFull(queueDepth: 3)])
        let queueFullManager = self.makeManager(transport: queueFull)

        await queueFullManager.send("full")

        XCTAssertEqual(queueFull.postedMessages, ["full"])
        XCTAssertEqual(queueFullManager.messages[0].status, .pending)
        XCTAssertEqual(queueFullManager.queueDepth, 3)
        XCTAssertNil(queueFullManager.lastError)

        let unavailable = ScriptedChatTransport(postResults: [.unavailable(reason: nil)])
        let unavailableManager = self.makeManager(transport: unavailable)

        await unavailableManager.send("unavailable")

        XCTAssertEqual(unavailableManager.messages[0].status, .pending)
        XCTAssertNil(unavailableManager.lastError)

        let transportFailure = ScriptedChatTransport(postResults: [.transport])
        let transportManager = self.makeManager(transport: transportFailure)

        await transportManager.send("transport")

        XCTAssertEqual(transportManager.messages[0].status, .pending)
        XCTAssertNil(transportManager.lastError)
    }

    @MainActor
    func testKeepPendingFailuresCanRetryToAck() async {
        let transport = ScriptedChatTransport(postResults: [
            .unavailable(reason: nil),
            .ack(useID: "use-1", queued: false, queueDepth: nil),
        ])
        let manager = self.makeManager(transport: transport)

        await manager.send("hello")
        manager._testDrainStep()
        await self.yieldForEvents()

        XCTAssertEqual(transport.postedMessages, ["hello", "hello"])
        XCTAssertEqual(manager.messages[0].status, .sent)
        XCTAssertEqual(manager.messages[0].useID, "use-1")
    }

    @MainActor
    func testMalformedAndServerErrorsFailAndDrainNextPending() async {
        let transport = ScriptedChatTransport(postResults: [
            .malformed,
            .serverError(status: 500, reason: nil),
            .serverError(status: 400, reason: nil),
        ])
        let manager = self.makeManager(transport: transport)

        await manager.send("bad decode")
        await self.yieldForEvents()
        await manager.send("server")
        await self.yieldForEvents()
        await manager.send("generic")
        await self.yieldForEvents()

        XCTAssertEqual(transport.postedMessages, ["bad decode", "server", "generic"])
        XCTAssertEqual(manager.messages.map(\.status), [.failed, .failed, .failed])
        XCTAssertEqual(manager.lastError, SourceVocabulary.chatErrorGeneric)
    }

    @MainActor
    func testServerProvidedReasonWins() async {
        let transport = ScriptedChatTransport(postResults: [.serverError(status: 400, reason: "custom reason")])
        let manager = self.makeManager(transport: transport)

        await manager.send("bad")

        XCTAssertEqual(manager.messages[0].status, .failed)
        XCTAssertEqual(manager.lastError, "custom reason")
    }

    @MainActor
    func testEmptyFinalAnswerIsAssistantSideRetryOnly() async {
        let transport = ScriptedChatTransport(postResults: [.ack(useID: "use-1", queued: false, queueDepth: nil)])
        let manager = self.makeManager(transport: transport)

        await manager.send("hello")
        transport.push(.solMessage(ChatSolMessage(id: "sol-empty", text: " \n ", useID: "use-1")))
        await self.yieldForEvents()

        XCTAssertEqual(manager.messages.count, 1)
        XCTAssertEqual(manager.messages[0].status, .sent)
        XCTAssertEqual(manager.lastError, SourceVocabulary.chatErrorEmptyReply)
        XCTAssertEqual(manager.answerRetryText, "hello")
        XCTAssertFalse(manager.isSending)
    }

    @MainActor
    func testChatErrorIsAssistantSideAndKeepsUserSent() async {
        let transport = ScriptedChatTransport(postResults: [.ack(useID: "use-1", queued: false, queueDepth: nil)])
        let manager = self.makeManager(transport: transport)

        await manager.send("hello")
        transport.push(.chatError(ChatErrorEvent(id: "err-1", useID: "use-1", reason: "could not answer")))
        await self.yieldForEvents()

        XCTAssertEqual(manager.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(manager.messages[0].status, .sent)
        XCTAssertEqual(manager.messages[1].provenance?.state, .failed)
        XCTAssertEqual(manager.messages[1].text, "could not answer")
        XCTAssertEqual(manager.answerRetryText, "hello")
        XCTAssertFalse(manager.isSending)
    }

    @MainActor
    func testOlderChatErrorAfterLatestSolMessageIsIgnored() async {
        let transport = ScriptedChatTransport(postResults: [.ack(useID: "use-1", queued: false, queueDepth: nil)])
        let manager = self.makeManager(transport: transport)
        let solAt = Date()

        await manager.send("hello")
        transport.push(.solMessage(ChatSolMessage(id: "sol-1", text: "answer", useID: "use-1", timestamp: solAt)))
        await self.yieldForEvents()

        transport.push(.chatError(ChatErrorEvent(
            id: "err-old",
            useID: "use-1",
            reason: "old failure",
            timestamp: solAt.addingTimeInterval(-1)
        )))
        await self.yieldForEvents()

        XCTAssertEqual(manager.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(manager.messages[0].status, .sent)
        XCTAssertEqual(manager.messages[1].text, "answer")
        XCTAssertNil(manager.lastError)
        XCTAssertNil(manager.answerRetryText)
        XCTAssertFalse(manager.isSending)
    }

    @MainActor
    func testWorkingTraceIsManagerLevelAndSettlesIntoCoverage() async {
        let transport = ScriptedChatTransport(postResults: [.ack(useID: "use-1", queued: false, queueDepth: nil)])
        let manager = self.makeManager(transport: transport)

        await manager.send("hello")
        transport.push(.talentSpawned(ChatTalentActivity(id: "read", useID: "use-1", label: "Reading your journal…")))
        await self.yieldForEvents()

        XCTAssertEqual(manager.activeTrace?.activeLabels, ["Reading your journal…"])
        XCTAssertEqual(manager.messages.count, 1)

        transport.push(.talentFinished(ChatTalentActivity(id: "read", useID: "use-1", label: "Reading your journal…")))
        transport.push(.solMessage(ChatSolMessage(id: "sol-1", text: "answer", useID: "use-1")))
        await self.yieldForEvents()

        XCTAssertNil(manager.activeTrace)
        XCTAssertEqual(manager.messages[1].provenance?.coverageLines, ["Reading your journal…"])
    }

    @MainActor
    func testOfferYesIsLocalDismissAndDeclineCallsEndpoint() async {
        let transport = ScriptedChatTransport(postResults: [.ack(useID: "use-1", queued: false, queueDepth: nil)])
        let manager = self.makeManager(transport: transport)

        await manager.send("help")
        transport.push(.solMessage(ChatSolMessage(
            id: "offer-1",
            text: "I can contact support.",
            useID: "use-1",
            requestedTarget: "support_offer",
            offer: ChatOffer(text: "I can contact support.")
        )))
        await self.yieldForEvents()

        XCTAssertNotNil(manager.pendingOffer)
        manager.acceptOffer()
        XCTAssertNil(manager.pendingOffer)
        XCTAssertEqual(transport.postedMessages, ["help"])

        manager.pendingOffer = ChatOffer(text: "I can contact support.")
        await manager.declineOffer()

        XCTAssertNil(manager.pendingOffer)
        XCTAssertEqual(transport.declinedOfferCount, 1)
        XCTAssertEqual(transport.postedMessages, ["help"])
    }

    @MainActor
    func testDraftOutcomeRendersReturnedSolMessageVerbatim() async {
        let result = ChatSolMessage(id: "draft-result", text: "sent to support", useID: "use-1")
        let transport = ScriptedChatTransport(confirmDraftResults: [.accepted(result)])
        let manager = self.makeManager(transport: transport)
        manager.pendingDraft = ChatDraft(id: "draft-1", body: "please help")

        await manager.confirmDraft(id: "draft-1")

        XCTAssertEqual(transport.confirmedDraftIDs, ["draft-1"])
        XCTAssertNil(manager.pendingDraft)
        XCTAssertEqual(manager.messages.map(\.role), [.assistant])
        XCTAssertEqual(manager.messages[0].text, "sent to support")
    }

    @MainActor
    func testResultEventRecordsOutcomeButRendersOnlyFollowingSolMessage() async {
        let transport = ScriptedChatTransport()
        let manager = self.makeManager(transport: transport)
        manager.pendingOffer = ChatOffer(text: "I can contact support.")
        manager.pendingDraft = ChatDraft(id: "draft-1", body: "please help")

        transport.push(.result(ChatResultEvent(
            id: "result-1",
            requestID: "draft-1",
            ok: true,
            message: "do not render from result"
        )))
        await self.yieldForEvents()

        XCTAssertNil(manager.pendingOffer)
        XCTAssertNil(manager.pendingDraft)
        XCTAssertTrue(manager.messages.isEmpty)
        XCTAssertNil(manager.lastError)

        transport.push(.solMessage(ChatSolMessage(
            id: "draft-result",
            text: "sent to support",
            requestID: "draft-1"
        )))
        await self.yieldForEvents()

        XCTAssertEqual(manager.messages.map(\.role), [.assistant])
        XCTAssertEqual(manager.messages[0].text, "sent to support")
    }

    @MainActor
    func testResetCancelsInFlightRetryStateAndIgnoresStalePostResult() async {
        let transport = DelayedFirstPostTransport()
        let manager = self.makeManager(transport: transport)

        let sendTask = Task { @MainActor in
            await manager.send("first")
        }
        await transport.waitForFirstPost()
        await manager.send("second")

        manager.lastError = SourceVocabulary.chatErrorServer
        manager.queueDepth = 2
        manager.pendingOffer = ChatOffer(text: "I can contact support.")
        manager.pendingDraft = ChatDraft(id: "draft-1", body: "please help")
        manager.activeTrace = ChatWorkingTrace(activeLabels: ["Reading your journal…"])

        XCTAssertEqual(transport.postedMessages, ["first"])
        XCTAssertEqual(manager.messages.map(\.status), [.pending, .pending])

        manager.reset()
        transport.completeFirst(.ack(useID: "stale-use", queued: false, queueDepth: nil))
        await sendTask.value
        await self.yieldForEvents()

        XCTAssertTrue(manager.messages.isEmpty)
        XCTAssertFalse(manager.isSending)
        XCTAssertNil(manager.lastError)
        XCTAssertNil(manager.queueDepth)
        XCTAssertNil(manager.pendingOffer)
        XCTAssertNil(manager.pendingDraft)
        XCTAssertNil(manager.activeTrace)

        await manager.send("fresh")
        await self.yieldForEvents()

        XCTAssertEqual(transport.postedMessages, ["first", "fresh"])
        XCTAssertEqual(manager.messages.map(\.text), ["fresh"])
        XCTAssertEqual(manager.messages[0].status, .sent)
        XCTAssertEqual(manager.messages[0].useID, "use-2")
    }

    @MainActor
    private func makeManager(transport: any ChatTransporting) -> ChatManager {
        ChatManager(
            transport: transport,
            isReachable: { true },
            localPortProvider: { 7071 }
        )
    }

    @MainActor
    private func yieldForEvents() async {
        for _ in 0..<6 {
            await Task.yield()
        }
    }
}

private final class DelayedFirstPostTransport: ChatTransporting, @unchecked Sendable {
    private(set) var postedMessages: [String] = []
    private var firstContinuation: CheckedContinuation<ChatPostResult, Never>?
    private var firstPostWaiters: [CheckedContinuation<Void, Never>] = []

    func postMessage(_ text: String) async -> ChatPostResult {
        self.postedMessages.append(text)
        if self.postedMessages.count == 1 {
            return await withCheckedContinuation { continuation in
                self.firstContinuation = continuation
                self.firstPostWaiters.forEach { $0.resume() }
                self.firstPostWaiters.removeAll()
            }
        }
        return .ack(useID: "use-\(self.postedMessages.count)", queued: false, queueDepth: nil)
    }

    func events() -> AsyncStream<ChatEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func declineOffer() async -> Bool {
        true
    }

    func confirmDraft(id: String) async -> DraftOutcome {
        .accepted(nil)
    }

    func cancelDraft(id: String) async -> DraftOutcome {
        .cancelled(nil)
    }

    func waitForFirstPost() async {
        if !self.postedMessages.isEmpty {
            return
        }
        await withCheckedContinuation { continuation in
            self.firstPostWaiters.append(continuation)
        }
    }

    func completeFirst(_ result: ChatPostResult) {
        self.firstContinuation?.resume(returning: result)
        self.firstContinuation = nil
    }
}

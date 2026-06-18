// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ChatManagerTests: XCTestCase {
    @MainActor
    func testOnlineSendInsertsAssistantReply() async {
        let provenance = Self.provenance
        let transport = ScriptedChatTransport(replies: [.ok("hello back", provenance)])
        let manager = ChatManager(transport: transport)

        await manager.send("hello")

        XCTAssertEqual(transport.sentMessages, ["hello"])
        XCTAssertEqual(manager.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(manager.messages[0].status, .sent)
        XCTAssertEqual(manager.messages[1].text, "hello back")
        XCTAssertEqual(manager.messages[1].provenance, provenance)
        XCTAssertNil(manager.lastError)
    }

    @MainActor
    func testUnreachableSendStaysPendingUntilReachable() async {
        let transport = ScriptedChatTransport(replies: [.ok("after reconnect", nil)])
        var reachable = false
        let manager = ChatManager(transport: transport, isReachable: { reachable })

        await manager.send("hello")

        XCTAssertEqual(transport.sentMessages, [])
        XCTAssertEqual(manager.messages.count, 1)
        XCTAssertEqual(manager.messages[0].status, .pending)

        manager._testDrainStep()
        await self.yieldForDrain()
        XCTAssertEqual(transport.sentMessages, [])

        reachable = true
        manager._testDrainStep()
        await self.yieldForDrain()

        XCTAssertEqual(transport.sentMessages, ["hello"])
        XCTAssertEqual(manager.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(manager.messages[0].status, .sent)
        XCTAssertEqual(manager.messages[1].text, "after reconnect")
    }

    @MainActor
    func testServiceUnavailableKeepsPendingThenRetries() async {
        let transport = ScriptedChatTransport(replies: [
            .serverError(status: 503, reason: nil),
            .ok("retried", nil)
        ])
        let manager = ChatManager(transport: transport)

        await manager.send("hello")

        XCTAssertEqual(transport.sentMessages, ["hello"])
        XCTAssertEqual(manager.messages.count, 1)
        XCTAssertEqual(manager.messages[0].status, .pending)
        XCTAssertNil(manager.lastError)

        manager._testDrainStep()
        await self.yieldForDrain()

        XCTAssertEqual(transport.sentMessages, ["hello", "hello"])
        XCTAssertEqual(manager.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(manager.messages[0].status, .sent)
        XCTAssertEqual(manager.messages[1].text, "retried")
    }

    @MainActor
    func testTransportFailureKeepsPending() async {
        let transport = ScriptedChatTransport(replies: [.transport])
        let manager = ChatManager(transport: transport)

        await manager.send("hello")

        XCTAssertEqual(transport.sentMessages, ["hello"])
        XCTAssertEqual(manager.messages.count, 1)
        XCTAssertEqual(manager.messages[0].status, .pending)
        XCTAssertNil(manager.lastError)
    }

    @MainActor
    func testClientAndServerErrorsFailWithFallbacks() async {
        let badRequestTransport = ScriptedChatTransport(replies: [.serverError(status: 400, reason: nil)])
        let badRequestManager = ChatManager(transport: badRequestTransport)

        await badRequestManager.send("bad")

        XCTAssertEqual(badRequestManager.messages[0].status, .failed)
        XCTAssertEqual(badRequestManager.lastError, SourceVocabulary.chatErrorGeneric)

        let serverTransport = ScriptedChatTransport(replies: [.serverError(status: 500, reason: nil)])
        let serverManager = ChatManager(transport: serverTransport)

        await serverManager.send("server")

        XCTAssertEqual(serverManager.messages[0].status, .failed)
        XCTAssertEqual(serverManager.lastError, SourceVocabulary.chatErrorServer)
    }

    @MainActor
    func testServerProvidedReasonWins() async {
        let transport = ScriptedChatTransport(replies: [.serverError(status: 400, reason: "custom reason")])
        let manager = ChatManager(transport: transport)

        await manager.send("bad")

        XCTAssertEqual(manager.messages[0].status, .failed)
        XCTAssertEqual(manager.lastError, "custom reason")
    }

    @MainActor
    func testEmptyOkFails() async {
        let transport = ScriptedChatTransport(replies: [.ok(" \n ", nil)])
        let manager = ChatManager(transport: transport)

        await manager.send("hello")

        XCTAssertEqual(manager.messages.count, 1)
        XCTAssertEqual(manager.messages[0].status, .failed)
        XCTAssertEqual(manager.lastError, SourceVocabulary.chatErrorEmptyReply)
    }

    @MainActor
    func testDecodeFailureFails() async {
        let transport = ScriptedChatTransport(replies: [.decode])
        let manager = ChatManager(transport: transport)

        await manager.send("hello")

        XCTAssertEqual(manager.messages.count, 1)
        XCTAssertEqual(manager.messages[0].status, .failed)
        XCTAssertEqual(manager.lastError, SourceVocabulary.chatErrorDecode)
    }

    @MainActor
    private func yieldForDrain() async {
        for _ in 0..<3 {
            await Task.yield()
        }
    }

    private static var provenance: AnswerProvenance {
        AnswerProvenance.sourced(
            sources: [
                AnswerProvenance.ProvenanceSource(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000902") ?? UUID(),
                    label: "9:02 call with jack",
                    detail: "37 min",
                    openURL: URL(string: "http://127.0.0.1/")
                )
            ],
            confidence: .high,
            coverage: ["read your journal"]
        )
    }
}

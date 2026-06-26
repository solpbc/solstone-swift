// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class ConveyChatTransportTests: XCTestCase {
    override func tearDown() {
        ChatTransportURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    func testPostMessageAckSendsExactMessageBody() async throws {
        ChatTransportURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/chat")
            let body = try XCTUnwrap(requestBody(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(json, ["message": "hello"])
            return Self.response(status: 200, request: request, body: #"{"use_id":"use-1","queued":false}"#)
        }

        let result = await self.transport.postMessage("hello")

        XCTAssertEqual(result, .ack(useID: "use-1", queued: false, queueDepth: nil))
    }

    @MainActor
    func testPostMessageMapsBackpressureAndUnavailable() async {
        ChatTransportURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/chat":
                return Self.response(status: 429, request: request, body: #"{"error":"chat_queue_full","queue_depth":4}"#)
            default:
                XCTFail("unexpected path \(request.url?.path ?? "")")
                return Self.response(status: 404, request: request)
            }
        }

        let queueFull = await self.transport.postMessage("hello")
        XCTAssertEqual(queueFull, .queueFull(queueDepth: 4))

        ChatTransportURLProtocol.handler = { request in
            Self.response(status: 503, request: request, body: #"{"error":"agent_unavailable"}"#)
        }

        let unavailable = await self.transport.postMessage("hello")
        XCTAssertEqual(unavailable, .unavailable(reason: "agent_unavailable"))

        ChatTransportURLProtocol.handler = { request in
            Self.response(status: 503, request: request, body: #"{"reason_code":"agent_unavailable","error":"different"}"#)
        }

        let unavailableReasonCode = await self.transport.postMessage("hello")
        XCTAssertEqual(unavailableReasonCode, .unavailable(reason: "agent_unavailable"))
    }

    @MainActor
    func testEventsHydratesChatErrorFromSessionSnapshot() async throws {
        let event = await self.sessionSnapshotEvent(#"{"chat_error":{"reason":"chat_timeout","use_id":"use-1","detail":"took too long"},"queue_depth":0}"#)

        XCTAssertEqual(
            event,
            .snapshot(ChatSessionSnapshot(
                chatError: ChatErrorEvent(id: "use-1", useID: "use-1", reason: "chat_timeout", detail: "took too long"),
                queueDepth: 0
            ))
        )
    }

    @MainActor
    func testPostMessageMapsMalformedServerAndTransportFailures() async {
        ChatTransportURLProtocol.handler = { request in
            Self.response(status: 200, request: request, body: #"{"queued":false}"#)
        }

        let malformed = await self.transport.postMessage("hello")
        XCTAssertEqual(malformed, .malformed)

        ChatTransportURLProtocol.handler = { request in
            Self.response(status: 500, request: request, body: #"{"error":"boom"}"#)
        }

        let serverError = await self.transport.postMessage("hello")
        XCTAssertEqual(serverError, .serverError(status: 500, reason: "boom"))

        ChatTransportURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let transport = await self.transport.postMessage("hello")
        XCTAssertEqual(transport, .transport)
    }

    @MainActor
    func testEventsHydratesSessionSnapshotBeforeSSE() async throws {
        let event = await self.sessionSnapshotEvent(#"{"latest_sol_message":{"id":"sol-1","text":"answer","use_id":"use-1"},"active_talents":[{"id":"read","label":"Reading your journal…"}],"queue_depth":2}"#)

        XCTAssertEqual(
            event,
            .snapshot(ChatSessionSnapshot(
                latestSolMessage: ChatSolMessage(id: "sol-1", text: "answer", useID: "use-1"),
                activeTalents: [ChatTalentActivity(id: "read", label: "Reading your journal…")],
                queueDepth: 2
            ))
        )
    }

    @MainActor
    func testEventsDecodesTalentQueued() async throws {
        let rawEvent = await self.firstEvent(sseBody: """
        data: {"tract":"chat","kind":"talent_queued","talent":{"use_id":"talent-1","name":"reading","task":"read notes","queued_at":"2026-06-18T10:11:12Z"}}

        """)
        let event = try XCTUnwrap(rawEvent)

        let queuedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-18T10:11:12Z"))
        XCTAssertEqual(
            event,
            .talentQueued(ChatTalentActivity(
                id: "talent-1",
                useID: "talent-1",
                label: "reading",
                task: "read notes",
                queuedAt: queuedAt
            ))
        )
    }

    @MainActor
    func testEventsDecodesSolMessageOriginPresentAndAbsent() async throws {
        let rawFolded = await self.firstEvent(sseBody: """
        data: {"tract":"chat","kind":"sol_message","sol_message":{"id":"fold-1","text":"folded answer","use_id":"talent-1","origin":{"logical_use_id":"turn-1","ask":"what changed?"}}}

        """)
        let folded = try XCTUnwrap(rawFolded)

        XCTAssertEqual(
            folded,
            .solMessage(ChatSolMessage(
                id: "fold-1",
                text: "folded answer",
                useID: "talent-1",
                origin: ChatSolOrigin(logicalUseID: "turn-1", ask: "what changed?")
            ))
        )

        let rawInline = await self.firstEvent(sseBody: """
        data: {"tract":"chat","kind":"sol_message","sol_message":{"id":"inline-1","text":"inline answer","use_id":"turn-1"}}

        """)
        let inline = try XCTUnwrap(rawInline)

        XCTAssertEqual(
            inline,
            .solMessage(ChatSolMessage(id: "inline-1", text: "inline answer", useID: "turn-1"))
        )
    }

    @MainActor
    func testEventsHydratesQueuedTalentsFromSessionSnapshot() async throws {
        let event = await self.sessionSnapshotEvent(#"{"queued_talents":[{"use_id":"talent-1","name":"reading","task":"read notes","queued_at":"2026-06-18T10:11:12Z"}]}"#)

        let queuedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-18T10:11:12Z"))
        XCTAssertEqual(
            event,
            .snapshot(ChatSessionSnapshot(
                queuedTalents: [ChatTalentActivity(
                    id: "talent-1",
                    useID: "talent-1",
                    label: "reading",
                    task: "read notes",
                    queuedAt: queuedAt
                )]
            ))
        )
    }

    @MainActor
    func testOfferDeclineAndDraftEndpoints() async throws {
        let paths = OSAllocatedUnfairLock<[String]>(initialState: [])
        ChatTransportURLProtocol.handler = { request in
            paths.withLock { $0.append(request.url?.path ?? "") }
            switch request.url?.path {
            case "/api/chat/offer/decline":
                XCTAssertEqual(request.httpMethod, "POST")
                return Self.response(status: 204, request: request)
            case "/api/chat/support/draft/confirm":
                let body = try XCTUnwrap(requestBody(from: request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
                XCTAssertEqual(json["draft_id"], "draft-1")
                return Self.response(
                    status: 200,
                    request: request,
                    body: #"{"sol_message":{"id":"confirm-1","text":"sent to support","use_id":"use-1"}}"#
                )
            case "/api/chat/support/draft/cancel":
                let body = try XCTUnwrap(requestBody(from: request))
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
                XCTAssertEqual(json["draft_id"], "draft-1")
                return Self.response(
                    status: 200,
                    request: request,
                    body: #"{"sol_message":{"id":"cancel-1","text":"not sent","use_id":"use-1"}}"#
                )
            default:
                XCTFail("unexpected path \(request.url?.path ?? "")")
                return Self.response(status: 404, request: request)
            }
        }

        let declined = await self.transport.declineOffer()
        XCTAssertTrue(declined)
        let confirm = await self.transport.confirmDraft(id: "draft-1")
        XCTAssertEqual(
            confirm,
            .accepted(ChatSolMessage(id: "confirm-1", text: "sent to support", useID: "use-1"))
        )
        let cancel = await self.transport.cancelDraft(id: "draft-1")
        XCTAssertEqual(
            cancel,
            .cancelled(ChatSolMessage(id: "cancel-1", text: "not sent", useID: "use-1"))
        )
        XCTAssertEqual(paths.withLock { $0 }, [
            "/api/chat/offer/decline",
            "/api/chat/support/draft/confirm",
            "/api/chat/support/draft/cancel",
        ])
    }

    @MainActor
    private var transport: ConveyChatTransport {
        self.transport(localPortProvider: { 7071 })
    }

    @MainActor
    private func transport(
        localPortProvider: @escaping @Sendable @MainActor () -> Int?
    ) -> ConveyChatTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatTransportURLProtocol.self]
        return ConveyChatTransport(localPortProvider: localPortProvider, session: URLSession(configuration: configuration))
    }

    @MainActor
    private func firstEvent(sseBody: String) async -> ChatEvent? {
        let port = OSAllocatedUnfairLock<Int?>(initialState: 7071)
        let transport = self.transport(localPortProvider: {
            port.withLock { $0 }
        })
        ChatTransportURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/chat/session":
                return Self.response(status: 204, request: request)
            case "/sse/events":
                port.withLock { $0 = nil }
                return Self.response(status: 200, request: request, body: sseBody)
            default:
                XCTFail("unexpected path \(request.url?.path ?? "")")
                return Self.response(status: 404, request: request)
            }
        }

        let stream = transport.events()
        var iterator = stream.makeAsyncIterator()
        while let event = await iterator.next() {
            if case .eventStream = event {
                continue
            }
            return event
        }
        return nil
    }

    @MainActor
    private func sessionSnapshotEvent(_ sessionBody: String) async -> ChatEvent? {
        let port = OSAllocatedUnfairLock<Int?>(initialState: 7071)
        let sseOpened = OSAllocatedUnfairLock<Bool>(initialState: false)
        let transport = self.transport(localPortProvider: { port.withLock { $0 } })
        ChatTransportURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/chat/session":
                return Self.response(status: 200, request: request, body: sessionBody)
            case "/sse/events":
                sseOpened.withLock { $0 = true }
                port.withLock { $0 = nil }
                return Self.response(status: 204, request: request)
            default:
                XCTFail("unexpected path \(request.url?.path ?? "")")
                return Self.response(status: 404, request: request)
            }
        }

        let stream = transport.events()
        let task = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        let event = await task.value
        task.cancel()
        for _ in 0..<20 where !sseOpened.withLock({ $0 }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(sseOpened.withLock { $0 }, "producer never reached /sse/events")
        return event
    }

    private static func response(status: Int, request: URLRequest, body: String = "") -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            Data(body.utf8)
        )
    }
}

private final class ChatTransportURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("ChatTransportURLProtocol handler not set")
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

nonisolated private func requestBody(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }

    return data
}

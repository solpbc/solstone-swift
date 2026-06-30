// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network
@testable import SPLTunnel
import XCTest

nonisolated final class DialClientTests: XCTestCase {
    func testRelayDialRequestUsesBearerAndInstance() throws {
        let request = try RelayWSTransport.makeRequest(
            endpoint: URL(string: "https://link.solstone.app")!,
            path: "session/dial",
            authorization: .bearer(token: "token", instanceID: "instance")
        )

        XCTAssertEqual(request.url?.absoluteString, "wss://link.solstone.app/session/dial?instance=instance")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertNil(request.value(forHTTPHeaderField: "Sec-Pair-Key"))
    }

    func testRelayHTTP503FailsBeforeTransportOpen() async throws {
        let server = try await OneShotHTTPServer.start(status: 503)
        defer { server.stop() }
        let endpoint = URL(string: "http://127.0.0.1:\(server.port)")!

        do {
            _ = try await DialClient.dial(
                .relay(endpoint: endpoint, instanceID: "instance", deviceToken: "token"),
                timeout: .seconds(2)
            )
            XCTFail("expected websocket handshake failure")
        } catch let error as DialError {
            XCTAssertEqual(error, .wsHandshakeFailed(httpStatus: 503))
        }
    }
}

private final class OneShotHTTPServer: @unchecked Sendable {
    let port: UInt16

    private let listener: NWListener

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start(status: Int) async throws -> OneShotHTTPServer {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = ServerReadyWaiter()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .utility))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let body = "HTTP/1.1 \(status) Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(body.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.complete(.success(()))
            case .failed(let error):
                ready.complete(.failure(error))
            case .cancelled:
                ready.complete(.failure(CancellationError()))
            case .setup, .waiting:
                break
            @unknown default:
                break
            }
        }
        listener.start(queue: .global(qos: .utility))
        try await ready.wait()
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
        return OneShotHTTPServer(listener: listener, port: port)
    }

    func stop() {
        listener.cancel()
    }
}

private final class ServerReadyWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let result: Result<Void, Error>? = lock.withLock {
                if let existing = self.result {
                    return existing
                }
                self.continuation = continuation
                return nil as Result<Void, Error>?
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func complete(_ result: Result<Void, Error>) {
        let continuation = lock.withLock {
            guard self.result == nil else {
                return nil as CheckedContinuation<Void, Error>?
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

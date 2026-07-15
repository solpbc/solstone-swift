// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class WatchConnectivitySessionTests: XCTestCase {
    private final class HandlerBox: @unchecked Sendable {
        let handler: (any Error) -> Void
        init(_ handler: @escaping (any Error) -> Void) { self.handler = handler }
    }

    private struct StubSendError: Error {}

    func testSendMessageErrorHandlerRunsOffMainActorWithoutTrapping() throws {
        var captured: ((any Error) -> Void)?
        let session = LiveWatchConnectivitySession(messageSend: { _, errorHandler in
            captured = errorHandler
        })

        session.sendMessage(["kind": "ping"])

        let box = HandlerBox(try XCTUnwrap(captured))
        let done = expectation(description: "error handler completes off the main actor")
        DispatchQueue.global(qos: .background).async {
            box.handler(StubSendError())
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}

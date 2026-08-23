// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import WebKit
import XCTest

@MainActor
final class JournalWebPagePolicyTests: XCTestCase {
    func testRewriteMapsToCancelAndIssuesReplacementLoad() async throws {
        let recorder = LoadRecorder()
        let session = JournalWebNavigationSession(
            sleep: { _ in },
            load: { request in
                recorder.loads.append(request)
                return nil
            },
            setState: { _ in }
        )
        session.requestLoad(url: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/")), reloadToken: 0)
        XCTAssertEqual(recorder.loads.count, 1)

        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://127.0.0.1:8080/app/home")))
        request.httpMethod = "GET"
        let policy = journalWebActionPolicy(session: session, request: request, isMainFrame: true)

        XCTAssertEqual(policy, .cancel)
        XCTAssertEqual(recorder.loads.count, 2)
        XCTAssertEqual(recorder.loads.last?.url?.scheme, "http")
        XCTAssertEqual(recorder.loads.last?.url?.host, "127.0.0.1")
        XCTAssertEqual(recorder.loads.last?.url?.port, 8080)
        session.teardown()
    }

    func testAllowKeepsPolicyAllow() async throws {
        let recorder = LoadRecorder()
        let session = JournalWebNavigationSession(
            sleep: { _ in },
            load: { request in
                recorder.loads.append(request)
                return nil
            },
            setState: { _ in }
        )
        session.requestLoad(url: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/")), reloadToken: 0)
        let loadCount = recorder.loads.count

        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/app/home")))
        request.httpMethod = "GET"
        let policy = journalWebActionPolicy(session: session, request: request, isMainFrame: true)

        XCTAssertEqual(policy, .allow)
        XCTAssertEqual(recorder.loads.count, loadCount)
        session.teardown()
    }
}

@MainActor
private final class LoadRecorder {
    var loads: [URLRequest] = []
}

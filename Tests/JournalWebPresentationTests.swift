// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class JournalWebPresentationTests: XCTestCase {
    func testResolvedURLUsesCurrentLivePort() throws {
        let firstURL = try XCTUnwrap(JournalWebPresentation.resolvedURL(activeLocalPort: 8080))
        let secondURL = try XCTUnwrap(JournalWebPresentation.resolvedURL(activeLocalPort: 9090))

        XCTAssertNotEqual(firstURL, secondURL)
        XCTAssertNil(JournalWebPresentation.resolvedURL(activeLocalPort: nil))
        XCTAssertEqual(firstURL.path, "/")
        XCTAssertEqual(firstURL.absoluteString, "http://127.0.0.1:8080/")
    }

    func testResolvedURLWithPath() throws {
        let healthURL = try XCTUnwrap(JournalWebPresentation.resolvedURL(activeLocalPort: 8080, path: "/app/health"))
        XCTAssertEqual(healthURL.absoluteString, "http://127.0.0.1:8080/app/health")

        let defaultURL = try XCTUnwrap(JournalWebPresentation.resolvedURL(activeLocalPort: 8080))
        XCTAssertEqual(defaultURL.absoluteString, "http://127.0.0.1:8080/")
    }

    func testLoadStateMapsStartedToLoading() {
        XCTAssertEqual(JournalWebPresentation.loadState(for: .started), .loading)
    }

    func testLoadStateMapsFinishedToLoaded() {
        XCTAssertEqual(JournalWebPresentation.loadState(for: .finished), .loaded)
    }

    func testLoadStateMapsCommittedToLoaded() {
        XCTAssertEqual(JournalWebPresentation.loadState(for: .committed), .loaded)
    }

    func testLoadStateMapsFailureToNonEmptyErrorMessage() {
        let state = JournalWebPresentation.loadState(for: .failed(urlErrorCode: NSURLErrorCannotConnectToHost))

        guard case .error(let message) = state else {
            XCTFail("expected error state")
            return
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testConnectionLostStateHasNonEmptyErrorMessage() {
        guard case .error(let message) = JournalWebPresentation.connectionLostState else {
            XCTFail("expected error state")
            return
        }
        XCTAssertFalse(message.isEmpty)
    }
}

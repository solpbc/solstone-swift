// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import WebKit
import XCTest

/// Runtime proof that discarding `page.load`'s per-load sequence still
/// delivers events on `page.navigations` — the exclusive subscription
/// the journal pane uses for both programmatic and user-initiated loads.
@MainActor
final class JournalWebPageNavigationsTests: XCTestCase {
    func testDiscardedLoadSequenceStillEmitsOnNavigations() async throws {
        let page = WebPage()
        var events: [WebPage.NavigationEvent] = []
        var caught: (any Error)?

        let consumer = Task { @MainActor in
            do {
                for try await event in page.navigations {
                    events.append(event)
                    if event == .finished {
                        break
                    }
                }
            } catch {
                caught = error
            }
        }

        await Task.yield()
        _ = page.load(
            html: "<html><body>ok</body></html>",
            baseURL: URL(string: "about:blank")!
        )

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if events.contains(.finished) || caught != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        consumer.cancel()

        XCTAssertNil(caught.map { String(describing: $0) })
        XCTAssertTrue(
            events.contains(.startedProvisionalNavigation),
            "page.navigations missed start for a discarded load() sequence: \(events)"
        )
        XCTAssertTrue(
            events.contains(.finished) || events.contains(.committed),
            "page.navigations missed commit/finish for a discarded load() sequence: \(events)"
        )
    }

    func testSecondLoadOnSameNavigationsSubscriptionEmitsAgain() async throws {
        let page = WebPage()
        var finishedCount = 0
        var caught: (any Error)?

        let consumer = Task { @MainActor in
            do {
                for try await event in page.navigations {
                    if event == .finished {
                        finishedCount += 1
                        if finishedCount >= 2 {
                            break
                        }
                    }
                }
            } catch {
                caught = error
            }
        }

        await Task.yield()
        _ = page.load(html: "<html><body>one</body></html>", baseURL: URL(string: "about:blank")!)

        let firstDeadline = Date().addingTimeInterval(5)
        while Date() < firstDeadline {
            if finishedCount >= 1 || caught != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(finishedCount, 1, "first discarded load did not finish on page.navigations")

        _ = page.load(html: "<html><body>two</body></html>", baseURL: URL(string: "about:blank")!)

        let secondDeadline = Date().addingTimeInterval(5)
        while Date() < secondDeadline {
            if finishedCount >= 2 || caught != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        consumer.cancel()

        XCTAssertNil(caught.map { String(describing: $0) })
        XCTAssertEqual(
            finishedCount,
            2,
            "second load on the same page.navigations subscription did not emit finished"
        )
    }
}

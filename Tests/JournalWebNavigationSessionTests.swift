// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

@MainActor
final class JournalWebNavigationSessionTests: XCTestCase {
    func testPolicyRewriteIssuesExactlyOneReplacementLoad() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        session.requestLoad(url: try self.url("http://127.0.0.1:8080/"), reloadToken: 0)
        try await self.waitFor("pending initial load bound") {
            gate.pendingCount == 1
        }
        XCTAssertEqual(recorder.loads.count, 1)

        let decision = session.decidePolicy(
            for: URLRequest(url: try self.url("https://127.0.0.1:8080/app/home?x=1#section")),
            isMainFrame: true
        )

        guard case .rewrite(let rewrittenURL) = decision else {
            XCTFail("expected rewrite")
            return
        }
        XCTAssertEqual(rewrittenURL.scheme, "http")
        XCTAssertEqual(recorder.loads.count, 2)
        XCTAssertEqual(recorder.loads.last?.url, rewrittenURL)
        session.teardown()
        gate.fireAll()
    }

    func testRequestLoadDedupesInitialUpdateAndReloadsOnRotation() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let firstURL = try self.url("http://127.0.0.1:8080/")
        let secondURL = try self.url("http://127.0.0.1:9090/")

        session.requestLoad(url: firstURL, reloadToken: 0)
        try await self.waitFor("pending first load bound") {
            gate.pendingCount == 1
        }
        session.requestLoad(url: firstURL, reloadToken: 0)
        XCTAssertEqual(recorder.loads.map(\.url), [firstURL])

        session.requestLoad(url: secondURL, reloadToken: 0)
        try await self.waitFor("pending second load bound") {
            gate.pendingCount == 2
        }
        XCTAssertEqual(recorder.loads.map(\.url), [firstURL, secondURL])

        let staleDecision = session.decidePolicy(
            for: URLRequest(url: try self.url("https://127.0.0.1:8080/stale")),
            isMainFrame: true
        )
        XCTAssertEqual(staleDecision, .allow)
        XCTAssertEqual(recorder.loads.count, 2)

        let currentDecision = session.decidePolicy(
            for: URLRequest(url: try self.url("https://127.0.0.1:9090/current")),
            isMainFrame: true
        )
        guard case .rewrite(let rewrittenURL) = currentDecision else {
            XCTFail("expected rewrite")
            return
        }
        XCTAssertEqual(recorder.loads.count, 3)
        XCTAssertEqual(recorder.loads.last?.url, rewrittenURL)
        session.teardown()
        gate.fireAll()
    }

    func testReloadTokenRetryLoadsSameURLOnceAndReturnsToLoading() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = URL(string: "http://127.0.0.1:8080/")!

        session.requestLoad(url: url, reloadToken: 0)
        try await self.waitFor("pending first retry-path bound") {
            gate.pendingCount == 1
        }
        session.didFail(navigationKey: nil, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
        XCTAssertTrue(recorder.states.containsLoadFailure)

        session.requestLoad(url: url, reloadToken: 1)
        try await self.waitFor("pending second retry-path bound") {
            gate.pendingCount == 2
        }
        XCTAssertEqual(recorder.loads.map(\.url), [url, url])
        XCTAssertEqual(recorder.states.last, .loading)
        session.teardown()
        gate.fireAll()
    }

    func testRequestLoadWithoutDidStartTimesOutWhenGateFires() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = try self.url("http://127.0.0.1:8080/")

        session.requestLoad(url: url, reloadToken: 0)
        try await self.waitFor("pending request-load timeout") {
            gate.pendingCount == 1
        }
        gate.fireNext()

        try await self.waitFor("request-load timeout error") {
            recorder.states.containsLoadFailure
        }
    }

    func testDidStartSupersedesRequestLoadBound() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = try self.url("http://127.0.0.1:8080/")
        let navigation = NavigationToken()

        session.requestLoad(url: url, reloadToken: 0)
        try await self.waitFor("pending request-load bound") {
            gate.pendingCount == 1
        }
        session.didStart(navigationKey: ObjectIdentifier(navigation))
        try await self.waitFor("pending did-start bound") {
            gate.pendingCount == 2
        }

        gate.fireNext()
        await Task.yield()
        XCTAssertFalse(recorder.states.containsLoadFailure)

        gate.fireNext()
        try await self.waitFor("did-start timeout error") {
            recorder.states.containsLoadFailure
        }
    }

    func testCancellationShapedFailuresDoNotChangeStateOrCancelBound() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let navigation = NavigationToken()
        let navigationKey = ObjectIdentifier(navigation)

        session.didStart(navigationKey: navigationKey)
        try await self.waitFor("pending timeout") {
            gate.pendingCount == 1
        }

        session.didFail(navigationKey: navigationKey, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        session.didFail(navigationKey: navigationKey, error: NSError(domain: "WebKitErrorDomain", code: 102))

        XCTAssertEqual(recorder.states, [.loading])
        XCTAssertEqual(gate.pendingCount, 1)

        gate.fireNext()
        try await self.waitFor("timeout error") {
            recorder.states.containsLoadFailure
        }
    }

    func testStaleFailureCannotOverwriteCurrentGeneration() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let staleNavigation = NavigationToken()
        let currentNavigation = NavigationToken()
        let staleKey = ObjectIdentifier(staleNavigation)
        let currentKey = ObjectIdentifier(currentNavigation)

        session.didStart(navigationKey: staleKey)
        session.didStart(navigationKey: currentKey)
        try await self.waitFor("two pending bounds") {
            gate.pendingCount == 2
        }

        session.didFail(
            navigationKey: staleKey,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        )
        XCTAssertFalse(recorder.states.containsLoadFailure)

        session.didFail(
            navigationKey: currentKey,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        )
        XCTAssertTrue(recorder.states.containsLoadFailure)
        gate.fireAll()
    }

    func testCurrentGenerationTimesOutWhenGateFires() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let navigation = NavigationToken()

        session.didStart(navigationKey: ObjectIdentifier(navigation))
        try await self.waitFor("pending timeout") {
            gate.pendingCount == 1
        }
        gate.fireNext()

        try await self.waitFor("timeout error") {
            recorder.states.containsLoadFailure
        }
    }

    func testSupersedingGenerationCancelsPriorBound() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let firstNavigation = NavigationToken()
        let secondNavigation = NavigationToken()

        session.didStart(navigationKey: ObjectIdentifier(firstNavigation))
        try await self.waitFor("first pending timeout") {
            gate.pendingCount == 1
        }
        session.didStart(navigationKey: ObjectIdentifier(secondNavigation))
        try await self.waitFor("second pending timeout") {
            gate.pendingCount == 2
        }

        gate.fireNext()
        await Task.yield()
        XCTAssertFalse(recorder.states.containsLoadFailure)

        gate.fireNext()
        try await self.waitFor("current timeout error") {
            recorder.states.containsLoadFailure
        }
    }

    func testCommitAndFinishCancelBoundAndStayLoaded() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let navigation = NavigationToken()
        let navigationKey = ObjectIdentifier(navigation)

        session.didStart(navigationKey: navigationKey)
        try await self.waitFor("pending timeout") {
            gate.pendingCount == 1
        }
        session.didCommit(navigationKey: navigationKey)
        XCTAssertEqual(recorder.states.last, .loaded)

        gate.fireNext()
        await Task.yield()
        XCTAssertEqual(recorder.states.last, .loaded)

        session.didFinish(navigationKey: navigationKey)
        XCTAssertEqual(recorder.states.last, .loaded)
    }

    func testTerminalSuccessFailsOpenWhenNavigationKeyIsNil() {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let navigation = NavigationToken()

        session.didStart(navigationKey: ObjectIdentifier(navigation))
        session.didCommit(navigationKey: nil)

        XCTAssertEqual(recorder.states.last, .loaded)
        session.teardown()
    }

    func testTeardownCancelsPendingBound() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let navigation = NavigationToken()

        session.didStart(navigationKey: ObjectIdentifier(navigation))
        try await self.waitFor("pending timeout") {
            gate.pendingCount == 1
        }
        session.teardown()
        gate.fireNext()
        await Task.yield()

        XCTAssertFalse(recorder.states.containsLoadFailure)
    }

    private func url(_ value: String) throws -> URL {
        try XCTUnwrap(URL(string: value))
    }

    private func waitFor(
        _ label: String,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(label)")
    }
}

@MainActor
private final class SessionRecorder {
    var loads: [URLRequest] = []
    var states: [JournalWebPresentation.LoadState] = []

    func makeSession() -> JournalWebNavigationSession {
        JournalWebNavigationSession(
            load: { request in
                self.loads.append(request)
            },
            setState: { state in
                self.states.append(state)
            }
        )
    }

    func makeSession(gate: CoalescerSleepGate) -> JournalWebNavigationSession {
        JournalWebNavigationSession(
            sleep: { duration in
                await gate.sleep(duration)
            },
            load: { request in
                self.loads.append(request)
            },
            setState: { state in
                self.states.append(state)
            }
        )
    }
}

private final class NavigationToken {}

private final class CoalescerSleepGate: @unchecked Sendable {
    private let continuations = OSAllocatedUnfairLock<[CheckedContinuation<Void, Never>]>(initialState: [])

    var pendingCount: Int {
        self.continuations.withLock { $0.count }
    }

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            self.continuations.withLock { $0.append(continuation) }
        }
    }

    func fireNext() {
        let continuation = self.continuations.withLock { continuations -> CheckedContinuation<Void, Never>? in
            guard !continuations.isEmpty else { return nil }
            return continuations.removeFirst()
        }
        continuation?.resume()
    }

    func fireAll() {
        let continuations = self.continuations.withLock { continuations -> [CheckedContinuation<Void, Never>] in
            let pending = continuations
            continuations.removeAll()
            return pending
        }
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private extension [JournalWebPresentation.LoadState] {
    var containsLoadFailure: Bool {
        self.contains { state in
            if case .error(let message) = state {
                return message == JournalWebPresentation.loadFailureMessage
            }
            return false
        }
    }
}

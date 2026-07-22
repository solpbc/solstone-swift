// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import WebKit
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

    func testPolicyRewriteFromLoadedPageArmsBoundAndTimesOutWithoutDidStart() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let initialNavigation = NavigationToken()
        let replacementNavigation = NavigationToken()

        recorder.enqueueLoadNavigation(initialNavigation)
        session.requestLoad(url: try self.url("http://127.0.0.1:8080/"), reloadToken: 0)
        try await self.waitFor("pending initial request-load bound") {
            gate.pendingCount == 1
        }
        session.didStart(navigation: initialNavigation)
        try await self.waitFor("pending initial navigation bound") {
            gate.pendingCount == 2
        }
        session.didFinish(navigation: initialNavigation)
        XCTAssertEqual(recorder.states.last, .loaded)

        recorder.enqueueLoadNavigation(replacementNavigation)
        let loadCountBeforeRewrite = recorder.loads.count
        let decision = session.decidePolicy(
            for: URLRequest(url: try self.url("https://127.0.0.1:8080/app/home")),
            isMainFrame: true
        )

        guard case .rewrite = decision else {
            XCTFail("expected rewrite")
            return
        }
        XCTAssertEqual(recorder.loads.count, loadCountBeforeRewrite + 1)
        XCTAssertEqual(recorder.states.last, .loading)
        try await self.waitFor("pending rewrite replacement bound") {
            gate.pendingCount == 3
        }

        gate.fireAll()
        try await self.waitFor("rewrite replacement timeout error") {
            recorder.states.loadFailureCount == 1
        }
        XCTAssertEqual(recorder.states.loadFailureCount, 1)
    }

    func testPolicyRewriteAfterTimeoutIsSuppressedButRetryRecovers() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = try self.url("http://127.0.0.1:8080/")
        let retryNavigation = NavigationToken()

        session.requestLoad(url: url, reloadToken: 0)
        try await self.waitFor("pending request-load timeout") {
            gate.pendingCount == 1
        }
        gate.fireNext()
        try await self.waitFor("request-load timeout error") {
            recorder.states.loadFailureCount == 1
        }
        let timeoutState = recorder.states.last
        let loadCountAfterTimeout = recorder.loads.count

        let decision = session.decidePolicy(
            for: URLRequest(url: try self.url("https://127.0.0.1:8080/app/home")),
            isMainFrame: true
        )

        guard case .rewrite = decision else {
            XCTFail("expected rewrite so the https navigation is cancelled")
            return
        }
        XCTAssertEqual(recorder.loads.count, loadCountAfterTimeout)
        XCTAssertEqual(recorder.states.last, timeoutState)
        XCTAssertEqual(gate.pendingCount, 0)
        gate.fireAll()
        await Task.yield()
        XCTAssertEqual(recorder.states.last, timeoutState)

        recorder.enqueueLoadNavigation(retryNavigation)
        session.requestLoad(url: url, reloadToken: 1)
        try await self.waitFor("pending retry request-load timeout") {
            gate.pendingCount == 1
        }
        XCTAssertEqual(recorder.states.last, .loading)

        session.didStart(navigation: retryNavigation)
        try await self.waitFor("pending retry navigation timeout") {
            gate.pendingCount == 2
        }
        session.didFinish(navigation: retryNavigation)

        XCTAssertEqual(recorder.states.last, .loaded)
        gate.fireAll()
    }

    func testPolicyRewriteAndReplacementStartLeaveOnlyCurrentBoundLive() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let initialNavigation = NavigationToken()
        let replacementNavigation = NavigationToken()

        recorder.enqueueLoadNavigation(initialNavigation)
        session.requestLoad(url: try self.url("http://127.0.0.1:8080/"), reloadToken: 0)
        try await self.waitFor("pending initial request-load bound") {
            gate.pendingCount == 1
        }
        session.didStart(navigation: initialNavigation)
        try await self.waitFor("pending initial navigation bound") {
            gate.pendingCount == 2
        }

        recorder.enqueueLoadNavigation(replacementNavigation)
        let decision = session.decidePolicy(
            for: URLRequest(url: try self.url("https://127.0.0.1:8080/app/home")),
            isMainFrame: true
        )

        guard case .rewrite = decision else {
            XCTFail("expected rewrite")
            return
        }
        try await self.waitFor("pending rewrite replacement bound") {
            gate.pendingCount == 3
        }
        session.didStart(navigation: replacementNavigation)
        try await self.waitFor("pending replacement navigation bound") {
            gate.pendingCount == 4
        }

        gate.fireAll()
        try await self.waitFor("current replacement timeout error") {
            recorder.states.loadFailureCount == 1
        }
        XCTAssertEqual(recorder.states.loadFailureCount, 1)
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

    func testRetiredNavigationCallbacksCannotClobberRequestLoadBeforeDidStart() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let firstURL = try self.url("http://127.0.0.1:8080/")
        let secondURL = try self.url("http://127.0.0.1:9090/")
        let navigation = NavigationToken()

        session.requestLoad(url: firstURL, reloadToken: 0)
        session.didStart(navigation: navigation)
        try await self.waitFor("pending first navigation bound") {
            gate.pendingCount == 2
        }
        session.requestLoad(url: secondURL, reloadToken: 0)
        try await self.waitFor("pending second request-load bound") {
            gate.pendingCount == 3
        }

        session.didFinish(navigation: navigation)
        XCTAssertEqual(recorder.states.last, .loading)

        session.didFail(
            navigation: navigation,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        )
        XCTAssertEqual(recorder.states.last, .loading)

        gate.fireAll()
        try await self.waitFor("second request-load timeout error") {
            recorder.states.containsLoadFailure
        }
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
        session.didStart(navigation: nil)
        try await self.waitFor("pending first retry-path navigation bound") {
            gate.pendingCount == 2
        }
        session.didFail(navigation: nil, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
        XCTAssertTrue(recorder.states.containsLoadFailure)

        session.requestLoad(url: url, reloadToken: 1)
        try await self.waitFor("pending second retry-path bound") {
            gate.pendingCount == 3
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

    func testUnkeyedTimeoutLateTerminalSuccessCannotOverwriteTimeoutError() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = try self.url("http://127.0.0.1:8080/")

        session.requestLoad(url: url, reloadToken: 0)
        try await self.waitFor("pending unkeyed request-load timeout") {
            gate.pendingCount == 1
        }
        gate.fireNext()
        try await self.waitFor("unkeyed timeout error") {
            recorder.states.loadFailureCount == 1
        }
        let timeoutState = recorder.states.last

        session.didCommit(navigation: nil)
        XCTAssertEqual(recorder.states.last, timeoutState)

        session.didFinish(navigation: nil)
        XCTAssertEqual(recorder.states.last, timeoutState)
    }

    func testLateDidStartAfterRequestLoadTimeoutCannotReviveStateAndRetryRecovers() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = try self.url("http://127.0.0.1:8080/")
        let timedOutNavigation = NavigationToken()
        let retryNavigation = NavigationToken()

        session.requestLoad(url: url, reloadToken: 0)
        try await self.waitFor("pending request-load timeout") {
            gate.pendingCount == 1
        }
        gate.fireNext()
        try await self.waitFor("request-load timeout error") {
            recorder.states.loadFailureCount == 1
        }
        let timeoutState = recorder.states.last

        session.didStart(navigation: timedOutNavigation)
        XCTAssertEqual(recorder.states.last, timeoutState)
        XCTAssertEqual(gate.pendingCount, 0)

        gate.fireAll()
        await Task.yield()
        XCTAssertEqual(recorder.states.last, timeoutState)

        session.didFinish(navigation: timedOutNavigation)
        XCTAssertEqual(recorder.states.last, timeoutState)

        session.requestLoad(url: url, reloadToken: 1)
        try await self.waitFor("pending retry request-load timeout") {
            gate.pendingCount == 1
        }
        XCTAssertEqual(recorder.states.last, .loading)

        session.didStart(navigation: retryNavigation)
        try await self.waitFor("pending retry navigation timeout") {
            gate.pendingCount == 2
        }
        session.didFinish(navigation: retryNavigation)
        XCTAssertEqual(recorder.states.last, .loaded)
        gate.fireAll()
    }

    func testExpectedNavigationRejectsLateStartFromPriorLoadAfterRetry() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = try self.url("http://127.0.0.1:8080/")
        let firstNavigation = NavigationToken()
        let secondNavigation = NavigationToken()

        recorder.enqueueLoadNavigation(firstNavigation)
        session.requestLoad(url: url, reloadToken: 0)
        try await self.waitFor("pending first request-load timeout") {
            gate.pendingCount == 1
        }
        gate.fireNext()
        try await self.waitFor("first request-load timeout error") {
            recorder.states.loadFailureCount == 1
        }

        recorder.enqueueLoadNavigation(secondNavigation)
        session.requestLoad(url: url, reloadToken: 1)
        try await self.waitFor("pending retry request-load timeout") {
            gate.pendingCount == 1
        }
        XCTAssertEqual(recorder.states.last, .loading)

        session.didStart(navigation: firstNavigation)
        XCTAssertEqual(recorder.states.last, .loading)
        XCTAssertEqual(gate.pendingCount, 1)

        session.didFinish(navigation: firstNavigation)
        XCTAssertEqual(recorder.states.last, .loading)

        session.didStart(navigation: secondNavigation)
        try await self.waitFor("pending retry navigation timeout") {
            gate.pendingCount == 2
        }
        session.didFinish(navigation: secondNavigation)
        XCTAssertEqual(recorder.states.last, .loaded)
        gate.fireAll()
    }

    func testRetiredExpectedNavigationLateStartAfterTokenConsumedCannotClobberCurrentLoad() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = try self.url("http://127.0.0.1:8080/")
        let firstNavigation = NavigationToken()
        let secondNavigation = NavigationToken()

        recorder.enqueueLoadNavigation(firstNavigation)
        session.requestLoad(url: url, reloadToken: 0)
        try await self.waitFor("pending first request-load timeout") {
            gate.pendingCount == 1
        }

        recorder.enqueueLoadNavigation(secondNavigation)
        session.requestLoad(url: url, reloadToken: 1)
        try await self.waitFor("pending second request-load timeout") {
            gate.pendingCount == 2
        }
        session.didStart(navigation: secondNavigation)
        try await self.waitFor("pending second navigation timeout") {
            gate.pendingCount == 3
        }
        XCTAssertEqual(recorder.states.last, .loading)

        session.didStart(navigation: firstNavigation)
        XCTAssertEqual(recorder.states.last, .loading)
        XCTAssertEqual(gate.pendingCount, 3)

        session.didFinish(navigation: firstNavigation)
        XCTAssertEqual(recorder.states.last, .loading)

        session.didFinish(navigation: secondNavigation)
        XCTAssertEqual(recorder.states.last, .loaded)
        gate.fireAll()
        await Task.yield()
        XCTAssertEqual(recorder.states.last, .loaded)
    }

    func testTimedOutExpectedNavigationLateStartAfterRetryTokenConsumedCannotClobberCurrentLoad() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = try self.url("http://127.0.0.1:8080/")
        let firstNavigation = NavigationToken()
        let secondNavigation = NavigationToken()

        recorder.enqueueLoadNavigation(firstNavigation)
        session.requestLoad(url: url, reloadToken: 0)
        try await self.waitFor("pending first request-load timeout") {
            gate.pendingCount == 1
        }
        gate.fireNext()
        try await self.waitFor("first request-load timeout error") {
            recorder.states.loadFailureCount == 1
        }

        recorder.enqueueLoadNavigation(secondNavigation)
        session.requestLoad(url: url, reloadToken: 1)
        try await self.waitFor("pending second request-load timeout") {
            gate.pendingCount == 1
        }
        session.didStart(navigation: secondNavigation)
        try await self.waitFor("pending second navigation timeout") {
            gate.pendingCount == 2
        }
        XCTAssertEqual(recorder.states.last, .loading)

        session.didStart(navigation: firstNavigation)
        XCTAssertEqual(recorder.states.last, .loading)
        XCTAssertEqual(gate.pendingCount, 2)

        session.didFinish(navigation: firstNavigation)
        XCTAssertEqual(recorder.states.last, .loading)

        session.didFinish(navigation: secondNavigation)
        XCTAssertEqual(recorder.states.last, .loaded)
        gate.fireAll()
        await Task.yield()
        XCTAssertEqual(recorder.states.last, .loaded)
    }

    func testInPageNavigationStartIsAcceptedAfterExpectedStartIsConsumed() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = try self.url("http://127.0.0.1:8080/")
        let initialNavigation = NavigationToken()
        let inPageNavigation = NavigationToken()

        recorder.enqueueLoadNavigation(initialNavigation)
        session.requestLoad(url: url, reloadToken: 0)
        try await self.waitFor("pending initial request-load timeout") {
            gate.pendingCount == 1
        }
        session.didStart(navigation: initialNavigation)
        try await self.waitFor("pending initial navigation timeout") {
            gate.pendingCount == 2
        }
        session.didFinish(navigation: initialNavigation)
        XCTAssertEqual(recorder.states.last, .loaded)

        session.didStart(navigation: inPageNavigation)
        try await self.waitFor("pending in-page navigation timeout") {
            gate.pendingCount == 3
        }
        XCTAssertEqual(recorder.states.last, .loading)
        gate.fireAll()
    }

    func testUnkeyedPriorCallbackCannotClobberRetryBeforeDidStart() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = try self.url("http://127.0.0.1:8080/")

        session.requestLoad(url: url, reloadToken: 0)
        session.didStart(navigation: nil)
        try await self.waitFor("pending first unkeyed navigation bound") {
            gate.pendingCount == 2
        }

        session.requestLoad(url: url, reloadToken: 1)
        try await self.waitFor("pending retry request-load bound") {
            gate.pendingCount == 3
        }
        XCTAssertEqual(recorder.states.last, .loading)

        session.didFinish(navigation: nil)
        XCTAssertEqual(recorder.states.last, .loading)

        gate.fireAll()
        try await self.waitFor("retry request-load timeout error") {
            recorder.states.loadFailureCount == 1
        }
    }

    func testUnkeyedTerminalSuccessAfterDidStartCanLoad() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = try self.url("http://127.0.0.1:8080/")

        session.requestLoad(url: url, reloadToken: 0)
        session.didStart(navigation: nil)
        try await self.waitFor("pending unkeyed navigation bound") {
            gate.pendingCount == 2
        }

        session.didFinish(navigation: nil)

        XCTAssertEqual(recorder.states.last, .loaded)
        gate.fireAll()
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
        session.didStart(navigation: navigation)
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

        session.didStart(navigation: navigation)
        try await self.waitFor("pending timeout") {
            gate.pendingCount == 1
        }

        session.didFail(navigation: navigation, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        session.didFail(navigation: navigation, error: NSError(domain: "WebKitErrorDomain", code: 102))

        XCTAssertEqual(recorder.states, [.loading])
        XCTAssertEqual(gate.pendingCount, 1)

        gate.fireNext()
        try await self.waitFor("timeout error") {
            recorder.states.containsLoadFailure
        }
    }

    func testAcceptedExplicitFailureRetiresNavigationSoLateFinishCannotLoad() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let navigation = NavigationToken()

        session.didStart(navigation: navigation)
        try await self.waitFor("pending timeout") {
            gate.pendingCount == 1
        }
        session.didFail(
            navigation: navigation,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        )
        try await self.waitFor("explicit failure error") {
            recorder.states.loadFailureCount == 1
        }
        let failureState = recorder.states.last

        session.didFinish(navigation: navigation)

        XCTAssertEqual(recorder.states.last, failureState)
        gate.fireAll()
    }

    func testAcceptedExplicitFailureUnkeyedLateDidStartCannotReviveState() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = try self.url("http://127.0.0.1:8080/")

        session.requestLoad(url: url, reloadToken: 0)
        try await self.waitFor("pending request-load bound") {
            gate.pendingCount == 1
        }
        session.didStart(navigation: nil)
        try await self.waitFor("pending unkeyed navigation bound") {
            gate.pendingCount == 2
        }
        session.didFail(navigation: nil, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
        try await self.waitFor("explicit failure error") {
            recorder.states.loadFailureCount == 1
        }
        let failureState = recorder.states.last
        let pendingAfterFailure = gate.pendingCount

        session.didStart(navigation: nil)

        XCTAssertEqual(recorder.states.last, failureState)
        XCTAssertEqual(recorder.states.loadFailureCount, 1)
        XCTAssertEqual(gate.pendingCount, pendingAfterFailure)
        gate.fireAll()
        await Task.yield()
        XCTAssertEqual(recorder.states.last, failureState)
        XCTAssertEqual(recorder.states.loadFailureCount, 1)
    }

    func testAcceptedExplicitFailureKeyedLateDidStartCannotReviveState() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let failedNavigation = NavigationToken()
        let lateNavigation = NavigationToken()

        session.didStart(navigation: failedNavigation)
        try await self.waitFor("pending failed navigation bound") {
            gate.pendingCount == 1
        }
        session.didFail(
            navigation: failedNavigation,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        )
        try await self.waitFor("explicit failure error") {
            recorder.states.loadFailureCount == 1
        }
        let failureState = recorder.states.last
        let pendingAfterFailure = gate.pendingCount

        session.didStart(navigation: lateNavigation)

        XCTAssertEqual(recorder.states.last, failureState)
        XCTAssertEqual(recorder.states.loadFailureCount, 1)
        XCTAssertEqual(gate.pendingCount, pendingAfterFailure)
        gate.fireAll()
        await Task.yield()
        XCTAssertEqual(recorder.states.last, failureState)
        XCTAssertEqual(recorder.states.loadFailureCount, 1)
    }

    func testAcceptedExplicitFailureLatePolicyRewriteIsSuppressed() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = try self.url("http://127.0.0.1:8080/")

        session.requestLoad(url: url, reloadToken: 0)
        try await self.waitFor("pending request-load bound") {
            gate.pendingCount == 1
        }
        session.didStart(navigation: nil)
        try await self.waitFor("pending unkeyed navigation bound") {
            gate.pendingCount == 2
        }
        session.didFail(navigation: nil, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
        try await self.waitFor("explicit failure error") {
            recorder.states.loadFailureCount == 1
        }
        let failureState = recorder.states.last
        let loadCountAfterFailure = recorder.loads.count
        gate.fireAll()
        await Task.yield()
        XCTAssertEqual(recorder.states.last, failureState)

        let decision = session.decidePolicy(
            for: URLRequest(url: try self.url("https://127.0.0.1:8080/app/home")),
            isMainFrame: true
        )

        guard case .rewrite = decision else {
            XCTFail("expected rewrite so the https navigation is cancelled")
            return
        }
        XCTAssertEqual(recorder.loads.count, loadCountAfterFailure)
        XCTAssertEqual(recorder.states.last, failureState)
        XCTAssertEqual(gate.pendingCount, 0)
        gate.fireAll()
        await Task.yield()
        XCTAssertEqual(recorder.states.last, failureState)
        XCTAssertEqual(recorder.states.loadFailureCount, 1)
    }

    func testAcceptedExplicitFailureRetryRecoversToLoaded() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = try self.url("http://127.0.0.1:8080/")
        let retryNavigation = NavigationToken()

        session.requestLoad(url: url, reloadToken: 0)
        try await self.waitFor("pending request-load bound") {
            gate.pendingCount == 1
        }
        session.didStart(navigation: nil)
        try await self.waitFor("pending unkeyed navigation bound") {
            gate.pendingCount == 2
        }
        session.didFail(navigation: nil, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
        try await self.waitFor("explicit failure error") {
            recorder.states.loadFailureCount == 1
        }

        recorder.enqueueLoadNavigation(retryNavigation)
        session.requestLoad(url: url, reloadToken: 1)
        XCTAssertEqual(recorder.states.last, .loading)
        try await self.waitFor("pending retry request-load bound") {
            gate.pendingCount == 3
        }

        session.didStart(navigation: retryNavigation)
        try await self.waitFor("pending retry navigation bound") {
            gate.pendingCount == 4
        }
        session.didFinish(navigation: retryNavigation)

        XCTAssertEqual(recorder.states.last, .loaded)
        XCTAssertEqual(recorder.states.loadFailureCount, 1)
        gate.fireAll()
    }

    func testStaleFailureCannotOverwriteCurrentGeneration() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let staleNavigation = NavigationToken()
        let currentNavigation = NavigationToken()

        session.didStart(navigation: staleNavigation)
        session.didStart(navigation: currentNavigation)
        try await self.waitFor("two pending bounds") {
            gate.pendingCount == 2
        }

        session.didFail(
            navigation: staleNavigation,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        )
        XCTAssertFalse(recorder.states.containsLoadFailure)

        session.didFail(
            navigation: currentNavigation,
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

        session.didStart(navigation: navigation)
        try await self.waitFor("pending timeout") {
            gate.pendingCount == 1
        }
        gate.fireNext()

        try await self.waitFor("timeout error") {
            recorder.states.containsLoadFailure
        }
    }

    func testTimedOutNavigationLateCallbacksCannotOverwriteTimeoutError() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let navigation = NavigationToken()

        session.didStart(navigation: navigation)
        try await self.waitFor("pending timeout") {
            gate.pendingCount == 1
        }
        gate.fireNext()
        try await self.waitFor("timeout error") {
            recorder.states.loadFailureCount == 1
        }
        let timeoutState = recorder.states.last

        session.didCommit(navigation: navigation)
        XCTAssertEqual(recorder.states.last, timeoutState)

        session.didFinish(navigation: navigation)
        XCTAssertEqual(recorder.states.last, timeoutState)

        session.didFail(
            navigation: navigation,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        )
        XCTAssertEqual(recorder.states.last, timeoutState)
    }

    func testTimedOutNavigationCannotCancelNewNavigationBound() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let firstNavigation = NavigationToken()
        let secondNavigation = NavigationToken()
        let secondURL = try self.url("http://127.0.0.1:9090/")

        session.didStart(navigation: firstNavigation)
        try await self.waitFor("pending first timeout") {
            gate.pendingCount == 1
        }
        gate.fireNext()
        try await self.waitFor("first timeout error") {
            recorder.states.loadFailureCount == 1
        }

        session.requestLoad(url: secondURL, reloadToken: 0)
        session.didStart(navigation: secondNavigation)
        try await self.waitFor("pending second navigation bound") {
            gate.pendingCount == 2
        }

        session.didFinish(navigation: firstNavigation)
        XCTAssertEqual(recorder.states.loadFailureCount, 1)
        XCTAssertEqual(recorder.states.last, .loading)

        gate.fireAll()
        try await self.waitFor("second timeout error") {
            recorder.states.loadFailureCount == 2
        }
    }

    func testSupersedingGenerationCancelsPriorBound() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let firstNavigation = NavigationToken()
        let secondNavigation = NavigationToken()

        session.didStart(navigation: firstNavigation)
        try await self.waitFor("first pending timeout") {
            gate.pendingCount == 1
        }
        session.didStart(navigation: secondNavigation)
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

        session.didStart(navigation: navigation)
        try await self.waitFor("pending timeout") {
            gate.pendingCount == 1
        }
        session.didCommit(navigation: navigation)
        XCTAssertEqual(recorder.states.last, .loaded)

        gate.fireNext()
        await Task.yield()
        XCTAssertEqual(recorder.states.last, .loaded)

        session.didFinish(navigation: navigation)
        XCTAssertEqual(recorder.states.last, .loaded)
    }

    func testTerminalSuccessFailsOpenWhenNoNavigationKeyIsCurrent() {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)

        session.didCommit(navigation: nil)

        XCTAssertEqual(recorder.states.last, .loaded)
        session.teardown()
    }

    func testNilTerminalSuccessDoesNotClobberKeyedNavigation() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let navigation = NavigationToken()

        session.didStart(navigation: navigation)
        try await self.waitFor("pending keyed navigation bound") {
            gate.pendingCount == 1
        }
        session.didCommit(navigation: nil)

        XCTAssertEqual(recorder.states.last, .loading)
        gate.fireNext()
        try await self.waitFor("keyed navigation timeout error") {
            recorder.states.containsLoadFailure
        }
    }

    func testTeardownCancelsPendingBound() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let navigation = NavigationToken()

        session.didStart(navigation: navigation)
        try await self.waitFor("pending timeout") {
            gate.pendingCount == 1
        }
        session.teardown()
        gate.fireNext()
        await Task.yield()

        XCTAssertFalse(recorder.states.containsLoadFailure)
    }

    func testSessionIgnoresCallbacksAfterTeardown() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let navigation = NavigationToken()

        session.teardown()
        session.didStart(navigation: navigation)
        session.didCommit(navigation: navigation)
        session.didFinish(navigation: navigation)
        session.didFail(navigation: navigation, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))

        XCTAssertEqual(recorder.states, [])
        XCTAssertEqual(gate.pendingCount, 0)
    }

    func testCoordinatorCallbacksDoNotRecreateSessionAfterTeardown() async throws {
        var states: [JournalWebPresentation.LoadState] = []
        let coordinator = JournalWebView.Coordinator { state in
            states.append(state)
        }
        let webView = WKWebView(frame: .zero)
        let url = try self.url("http://127.0.0.1:8080/")

        coordinator.requestLoad(url: url, reloadToken: 0, webView: webView)
        XCTAssertEqual(states, [.loading])
        coordinator.teardown()
        states.removeAll()

        coordinator.webView(webView, didStartProvisionalNavigation: nil)
        coordinator.webView(webView, didCommit: nil)
        coordinator.webView(webView, didFinish: nil)
        coordinator.webView(
            webView,
            didFailProvisionalNavigation: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        )
        coordinator.webView(
            webView,
            didFail: nil,
            withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        )
        await Task.yield()

        XCTAssertEqual(states, [])
    }

    func testExpectedNavigationIsRetainedUntilTeardown() throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = try self.url("http://127.0.0.1:8080/")
        weak var weakNavigation: NavigationToken?

        do {
            let navigation = NavigationToken()
            weakNavigation = navigation
            recorder.enqueueLoadNavigation(navigation)
            session.requestLoad(url: url, reloadToken: 0)
        }

        XCTAssertNotNil(weakNavigation)
        session.teardown()
        XCTAssertNil(weakNavigation)
        gate.fireAll()
    }

    func testRetiredNavigationReferencesSurviveNewStartsUntilTeardown() throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = try self.url("http://127.0.0.1:8080/")
        let currentNavigation = NavigationToken()
        weak var weakRetiredNavigation: NavigationToken?

        do {
            let retiredNavigation = NavigationToken()
            weakRetiredNavigation = retiredNavigation
            session.didStart(navigation: retiredNavigation)
            session.requestLoad(url: url, reloadToken: 0)
        }

        XCTAssertNotNil(weakRetiredNavigation)
        session.didStart(navigation: currentNavigation)
        XCTAssertNotNil(weakRetiredNavigation)
        session.teardown()
        XCTAssertNil(weakRetiredNavigation)
        gate.fireAll()
    }

    func testRetiredNavigationReferencesAreReleasedOnTeardown() throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let url = try self.url("http://127.0.0.1:8080/")
        weak var weakRetiredNavigation: NavigationToken?

        do {
            let retiredNavigation = NavigationToken()
            weakRetiredNavigation = retiredNavigation
            session.didStart(navigation: retiredNavigation)
            session.requestLoad(url: url, reloadToken: 0)
        }

        XCTAssertNotNil(weakRetiredNavigation)
        session.teardown()
        XCTAssertNil(weakRetiredNavigation)
        gate.fireAll()
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
    private var loadNavigations: [AnyObject?] = []

    func enqueueLoadNavigation(_ navigation: AnyObject?) {
        self.loadNavigations.append(navigation)
    }

    func makeSession(gate: CoalescerSleepGate) -> JournalWebNavigationSession {
        JournalWebNavigationSession(
            sleep: { duration in
                await gate.sleep(duration)
            },
            load: { request in
                self.loads.append(request)
                if self.loadNavigations.isEmpty {
                    return nil
                }
                return self.loadNavigations.removeFirst()
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

    var loadFailureCount: Int {
        self.filter { state in
            if case .error(let message) = state {
                return message == JournalWebPresentation.loadFailureMessage
            }
            return false
        }.count
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import SPLTunnel
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
            frame: .main
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
            frame: .main
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
            frame: .main
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
            frame: .main
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
            frame: .main
        )
        XCTAssertEqual(staleDecision, .cancel)
        XCTAssertEqual(recorder.loads.count, 2)

        let currentDecision = session.decidePolicy(
            for: URLRequest(url: try self.url("https://127.0.0.1:9090/current")),
            frame: .main
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

    func testExternalHandoffRestoresLoadedStateAndNewGenerationTimesOut() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let log = DiagnosticLog()
        let session = recorder.makeSession(gate: gate, diagnosticLog: log)
        let initialNavigation = NavigationToken()
        let provisionalNavigation = NavigationToken()
        let initialURL = try self.url("http://127.0.0.1:8080/")

        recorder.enqueueLoadNavigation(initialNavigation)
        session.requestLoad(url: initialURL, reloadToken: 0)
        try await self.waitFor("pending initial request-load bound") {
            gate.pendingCount == 1
        }
        session.didStart(navigation: initialNavigation)
        session.didFinish(navigation: initialNavigation)
        XCTAssertEqual(recorder.states.last, .loaded)

        session.didStart(navigation: provisionalNavigation)
        try await self.waitFor("pending provisional handoff bound") {
            gate.pendingCount == 3
        }
        let outsideURL = try self.url("https://example.test/outside?day=today")
        XCTAssertEqual(
            session.decidePolicy(for: URLRequest(url: outsideURL), frame: .main),
            .openExternally(outsideURL)
        )
        session.didFail(
            navigation: provisionalNavigation,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        )
        XCTAssertEqual(recorder.states.last, .loading)
        XCTAssertEqual(gate.pendingCount, 3)

        gate.fireAll()
        try await self.waitFor("handoff restoration") {
            log.events.contains { $0.category == .journal && $0.message == "handoff_restored" }
        }
        XCTAssertEqual(recorder.states.last, .loaded)
        XCTAssertFalse(recorder.states.containsLoadFailure)

        let nextURL = try self.url("http://127.0.0.1:9090/")
        let nextNavigation = NavigationToken()
        recorder.enqueueLoadNavigation(nextNavigation)
        session.requestLoad(url: nextURL, reloadToken: 0)
        try await self.waitFor("pending newer request-load bound") {
            gate.pendingCount == 1
        }
        session.didStart(navigation: nextNavigation)
        try await self.waitFor("pending newer navigation bound") {
            gate.pendingCount == 2
        }
        gate.fireAll()
        try await self.waitFor("new generation timeout") {
            recorder.states.containsLoadFailure
        }
        XCTAssertEqual(recorder.states.last, .error(message: JournalWebPresentation.loadFailureMessage))
        session.teardown()
    }

    func testProvisionalCancellationWithoutHandoffStillTimesOut() async throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(gate: gate)
        let initialNavigation = NavigationToken()
        let provisionalNavigation = NavigationToken()

        recorder.enqueueLoadNavigation(initialNavigation)
        session.requestLoad(url: try self.url("http://127.0.0.1:8080/"), reloadToken: 0)
        try await self.waitFor("pending initial request-load bound") {
            gate.pendingCount == 1
        }
        session.didStart(navigation: initialNavigation)
        session.didFinish(navigation: initialNavigation)
        XCTAssertEqual(recorder.states.last, .loaded)

        session.didStart(navigation: provisionalNavigation)
        try await self.waitFor("pending provisional failure bound") {
            gate.pendingCount == 3
        }
        session.didFail(
            navigation: provisionalNavigation,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        )
        XCTAssertEqual(recorder.states.last, .loading)
        XCTAssertEqual(gate.pendingCount, 3)

        gate.fireAll()
        try await self.waitFor("provisional timeout error") {
            recorder.states.containsLoadFailure
        }
        XCTAssertEqual(recorder.states.last, .error(message: JournalWebPresentation.loadFailureMessage))
        session.teardown()
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
            frame: .main
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

    func testLifecyclePersistsPrivacySafeJournalDiagnostics() throws {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let log = DiagnosticLog()
        let session = recorder.makeSession(gate: gate, diagnosticLog: log)
        let navigation = NavigationToken()

        recorder.enqueueLoadNavigation(navigation)
        session.requestLoad(
            url: try self.url("http://127.0.0.1:8080/private/path?token=secret#fragment"),
            reloadToken: 0
        )
        session.didStart(navigation: navigation)
        session.didReceiveServerRedirect(navigation: navigation)
        session.didCommit(navigation: navigation)
        session.didFinish(navigation: navigation)

        XCTAssertEqual(
            log.events.filter { $0.category == .journal }.map(\.message),
            ["load_requested", "start", "redirect", "commit", "finish"]
        )
        let exported = log.snapshot(tunnel: TunnelManager())
        XCTAssertTrue(exported.contains("[journal] load_requested"))
        XCTAssertTrue(exported.contains("port=8080"))
        XCTAssertFalse(exported.contains("private/path"))
        XCTAssertFalse(exported.contains("secret"))
        XCTAssertFalse(exported.contains("fragment"))
        session.teardown()
        gate.fireAll()
    }

    func testWebContentProcessTerminationBecomesActionableFailure() {
        let gate = CoalescerSleepGate()
        let recorder = SessionRecorder()
        let log = DiagnosticLog()
        let session = recorder.makeSession(gate: gate, diagnosticLog: log)

        session.webContentProcessDidTerminate()

        XCTAssertEqual(recorder.states.last, .error(message: JournalWebPresentation.loadFailureMessage))
        XCTAssertEqual(log.events.last?.category, .journal)
        XCTAssertEqual(log.events.last?.severity, .error)
        XCTAssertEqual(log.events.last?.message, "web_content_process_terminated")
        session.teardown()
        gate.fireAll()
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

    func testMarkedMainFrameRefusalRestoresCookieThenLoadsRefusedURL() async throws {
        let reasons = ["missing", "mismatch", "oversize", "other"]
        for reason in reasons {
            let gate = CookieStepGate()
            let recorder = SessionRecorder()
            let log = DiagnosticLog()
            let session = recorder.makeSession(
                restoreLoopbackCookie: { await gate.step() },
                diagnosticLog: log
            )
            let homeURL = try self.url("http://127.0.0.1:8080/app/home/")
            session.requestLoad(url: homeURL, reloadToken: 0)
            XCTAssertEqual(recorder.loads.count, 1)

            let refusedURL: URL
            if reason == "missing" || reason == "oversize" {
                refusedURL = try self.url("http://127.0.0.1:8080/app/elsewhere/")
            } else {
                refusedURL = homeURL
            }

            let decision = session.decideLoopbackResponse(
                isMainFrame: true,
                httpStatus: 403,
                refusalHeader: reason,
                responseURL: refusedURL,
                stillCurrent: { true }
            )
            XCTAssertEqual(decision, .cancel)

            let initialRecoveryEvents = log.events.filter { $0.category == .journal && $0.message == "loopback_recovery" }
            XCTAssertEqual(initialRecoveryEvents.count, 1)

            try await self.waitFor("cookie gate entered") {
                gate.entered
            }
            XCTAssertEqual(recorder.loads.count, 1)

            gate.release()

            try await self.waitFor("recovery load issued") {
                recorder.loads.count == 2
            }
            let recoveryRequest = recorder.loads[1]
            XCTAssertEqual(recoveryRequest.url, refusedURL)
            XCTAssertTrue(recoveryRequest.httpMethod == nil || recoveryRequest.httpMethod == "GET")

            session.requestLoad(url: homeURL, reloadToken: 0)
            XCTAssertEqual(recorder.loads.count, 2)

            let recoveryEvents = log.events.filter { $0.category == .journal && $0.message == "loopback_recovery" }
            XCTAssertEqual(recoveryEvents.count, 1)
            let detail = try XCTUnwrap(recoveryEvents.first?.detail)
            XCTAssertTrue(detail.contains("reason=\(reason)"))
            XCTAssertTrue(detail.contains("generation="))

            let secretHeaderValue = LoopbackCapability.process.cookieHeaderValue
            for event in log.events {
                XCTAssertFalse(event.message.contains(secretHeaderValue))
                XCTAssertFalse(event.message.contains("spl_loopback="))
                if let eventDetail = event.detail {
                    XCTAssertFalse(eventDetail.contains(secretHeaderValue))
                    XCTAssertFalse(eventDetail.contains("spl_loopback="))
                }
            }

            session.teardown()
        }
    }

    func testSecondMarkedRefusalInsideTenSecondsGivesUpAndCancelsBound() async throws {
        let probe = BoundSleepProbe()
        let recorder = SessionRecorder()
        let log = DiagnosticLog()
        let start = ContinuousClock.now
        var offset: Duration = .seconds(0)

        let session = recorder.makeSession(
            sleep: { duration in await probe.sleep(duration) },
            clock: { start.advanced(by: offset) },
            restoreLoopbackCookie: { },
            diagnosticLog: log
        )

        let url = try self.url("http://127.0.0.1:8080/app/home/")
        let token = NavigationToken()
        recorder.enqueueLoadNavigation(token)
        session.requestLoad(url: url, reloadToken: 0)
        session.didStart(navigation: token)

        try await self.waitFor("initial bound probe entered") {
            probe.entered == 1
        }

        // Offset 0
        offset = .seconds(0)
        let decision0 = session.decideLoopbackResponse(
            isMainFrame: true,
            httpStatus: 403,
            refusalHeader: "missing",
            responseURL: url,
            stillCurrent: { true }
        )
        XCTAssertEqual(decision0, .cancel)

        try await self.waitFor("recovery load and second bound armed") {
            recorder.loads.count == 2 && probe.entered == 2
        }
        let recoveryEventsAfterFirst = log.events.filter { $0.category == .journal && $0.message == "loopback_recovery" }
        XCTAssertEqual(recoveryEventsAfterFirst.count, 1)

        // Offset 5 seconds
        offset = .seconds(5)
        let decision5 = session.decideLoopbackResponse(
            isMainFrame: true,
            httpStatus: 403,
            refusalHeader: "oversize",
            responseURL: url,
            stillCurrent: { true }
        )
        XCTAssertEqual(decision5, .cancel)
        XCTAssertEqual(recorder.states.last, .error(message: JournalWebPresentation.loadFailureMessage))

        let giveUpEventsAfterSecond = log.events.filter { $0.category == .journal && $0.message == "loopback_give_up" }
        XCTAssertEqual(giveUpEventsAfterSecond.count, 1)
        XCTAssertTrue(giveUpEventsAfterSecond.first?.detail?.contains("reason=oversize") == true)

        if probe.cancelled < 2 {
            await Task.yield()
        }
        XCTAssertEqual(probe.cancelled, 2)

        session.didCommit(navigation: token)
        XCTAssertEqual(recorder.states.last, .error(message: JournalWebPresentation.loadFailureMessage))

        probe.resumePending()
        await Task.yield()
        XCTAssertEqual(recorder.states.last, .error(message: JournalWebPresentation.loadFailureMessage))
        XCTAssertTrue(log.events.filter { $0.category == .journal && $0.message == "timeout" }.isEmpty)

        // Offset exactly 10 seconds
        offset = .seconds(10)
        let decision10 = session.decideLoopbackResponse(
            isMainFrame: true,
            httpStatus: 403,
            refusalHeader: "mismatch",
            responseURL: url,
            stillCurrent: { true }
        )
        XCTAssertEqual(decision10, .cancel)
        XCTAssertEqual(recorder.states.last, .error(message: JournalWebPresentation.loadFailureMessage))
        let giveUpEventsAfterThird = log.events.filter { $0.category == .journal && $0.message == "loopback_give_up" }
        XCTAssertEqual(giveUpEventsAfterThird.count, 2)
        XCTAssertEqual(recorder.loads.count, 2)

        // Offset 11 seconds
        offset = .seconds(11)
        let decision11 = session.decideLoopbackResponse(
            isMainFrame: true,
            httpStatus: 403,
            refusalHeader: "missing",
            responseURL: url,
            stillCurrent: { true }
        )
        XCTAssertEqual(decision11, .cancel)

        try await self.waitFor("recovery load after 11 seconds") {
            recorder.loads.count == 3
        }

        let recoveryEventsFinal = log.events.filter { $0.category == .journal && $0.message == "loopback_recovery" }
        let giveUpEventsFinal = log.events.filter { $0.category == .journal && $0.message == "loopback_give_up" }
        XCTAssertEqual(recoveryEventsFinal.count, 2)
        XCTAssertEqual(giveUpEventsFinal.count, 2)

        let timeoutEvents = log.events.filter { $0.category == .journal && $0.message == "timeout" }
        XCTAssertTrue(timeoutEvents.isEmpty)

        probe.resumePending()
        await Task.yield()
        XCTAssertTrue(log.events.filter { $0.category == .journal && $0.message == "timeout" }.isEmpty)

        session.teardown()
    }

    func testSecondMarkerWhileCookieStepPendingDoesNotStartAnotherRecovery() async throws {
        let gate = CookieStepGate()
        let recorder = SessionRecorder()
        let log = DiagnosticLog()
        let session = recorder.makeSession(
            restoreLoopbackCookie: { await gate.step() },
            diagnosticLog: log
        )
        let url1 = try self.url("http://127.0.0.1:8080/app/first/")
        let url2 = try self.url("http://127.0.0.1:8080/app/second/")

        let decision1 = session.decideLoopbackResponse(
            isMainFrame: true,
            httpStatus: 403,
            refusalHeader: "missing",
            responseURL: url1,
            stillCurrent: { true }
        )
        XCTAssertEqual(decision1, .cancel)

        try await self.waitFor("cookie gate entered") {
            gate.entered
        }

        let decision2 = session.decideLoopbackResponse(
            isMainFrame: true,
            httpStatus: 403,
            refusalHeader: "mismatch",
            responseURL: url2,
            stillCurrent: { true }
        )
        XCTAssertEqual(decision2, .cancel)

        let recoveryEvents = log.events.filter { $0.category == .journal && $0.message == "loopback_recovery" }
        let giveUpEvents = log.events.filter { $0.category == .journal && $0.message == "loopback_give_up" }
        XCTAssertEqual(recoveryEvents.count, 1)
        XCTAssertEqual(giveUpEvents.count, 0)
        XCTAssertEqual(recorder.loads.count, 0)

        gate.release()

        try await self.waitFor("single recovery load") {
            recorder.loads.count == 1
        }
        XCTAssertEqual(recorder.loads.count, 1)
        XCTAssertEqual(recorder.loads.first?.url, url1)

        session.teardown()
    }

    func testNewerProgrammaticLoadSuppressesRecoveryLoad() async throws {
        let gate = CookieStepGate()
        let recorder = SessionRecorder()
        let log = DiagnosticLog()
        let session = recorder.makeSession(
            restoreLoopbackCookie: { await gate.step() },
            diagnosticLog: log
        )
        let urlA = try self.url("http://127.0.0.1:8080/app/a/")
        let urlB = try self.url("http://127.0.0.1:8080/app/b/")
        let urlC = try self.url("http://127.0.0.1:8080/app/c/")

        session.requestLoad(url: urlA, reloadToken: 0)
        XCTAssertEqual(recorder.loads.count, 1)

        var stillCurrent = true
        let decision = session.decideLoopbackResponse(
            isMainFrame: true,
            httpStatus: 403,
            refusalHeader: "missing",
            responseURL: urlB,
            stillCurrent: { stillCurrent }
        )
        XCTAssertEqual(decision, .cancel)

        try await self.waitFor("cookie gate entered") {
            gate.entered
        }
        XCTAssertEqual(recorder.loads.count, 1)

        stillCurrent = false
        session.requestLoad(url: urlC, reloadToken: 1)
        XCTAssertEqual(recorder.loads.count, 2)
        XCTAssertEqual(recorder.loads.last?.url, urlC)

        gate.release()
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertEqual(recorder.loads.count, 2)
        XCTAssertFalse(recorder.loads.contains { $0.url == urlB })

        let recoveryEvents = log.events.filter { $0.category == .journal && $0.message == "loopback_recovery" }
        let giveUpEvents = log.events.filter { $0.category == .journal && $0.message == "loopback_give_up" }
        XCTAssertEqual(recoveryEvents.count, 1)
        XCTAssertEqual(giveUpEvents.count, 0)

        session.teardown()
    }

    func testRecoveryLoadsWhenNotTornDown() async throws {
        let gate = CookieStepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(
            restoreLoopbackCookie: { await gate.step() }
        )
        let homeURL = try self.url("http://127.0.0.1:8080/app/home/")
        let refusedURL = try self.url("http://127.0.0.1:8080/app/refused/")

        session.requestLoad(url: homeURL, reloadToken: 0)
        XCTAssertEqual(recorder.loads.count, 1)

        let decision = session.decideLoopbackResponse(
            isMainFrame: true,
            httpStatus: 403,
            refusalHeader: "missing",
            responseURL: refusedURL,
            stillCurrent: { true }
        )
        XCTAssertEqual(decision, .cancel)

        try await self.waitFor("cookie gate entered") {
            gate.entered
        }
        XCTAssertEqual(recorder.loads.count, 1)

        gate.release()

        try await self.waitFor("recovery load issued") {
            recorder.loads.count == 2
        }
        XCTAssertEqual(recorder.loads.last?.url, refusedURL)

        session.teardown()
    }

    func testTeardownDuringCookieStepLoadsNothing() async throws {
        let gate = CookieStepGate()
        let recorder = SessionRecorder()
        let session = recorder.makeSession(
            restoreLoopbackCookie: { await gate.step() }
        )
        let homeURL = try self.url("http://127.0.0.1:8080/app/home/")
        let refusedURL = try self.url("http://127.0.0.1:8080/app/refused/")

        session.requestLoad(url: homeURL, reloadToken: 0)
        XCTAssertEqual(recorder.loads.count, 1)

        let decision = session.decideLoopbackResponse(
            isMainFrame: true,
            httpStatus: 403,
            refusalHeader: "missing",
            responseURL: refusedURL,
            stillCurrent: { true }
        )
        XCTAssertEqual(decision, .cancel)

        try await self.waitFor("cookie gate entered") {
            gate.entered
        }
        XCTAssertEqual(recorder.loads.count, 1)

        session.teardown()
        gate.release()

        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertEqual(recorder.loads.count, 1)
    }

    func testUnmarkedResponsesAreAllowed() async throws {
        let gate = CookieStepGate()
        let recorder = SessionRecorder()
        let log = DiagnosticLog()
        let session = recorder.makeSession(
            restoreLoopbackCookie: { await gate.step() },
            diagnosticLog: log
        )
        let sampleURL = try self.url("http://127.0.0.1:8080/app/sample/")

        let cases: [(isMainFrame: Bool, status: Int?, header: String?)] = [
            (isMainFrame: false, status: 403, header: "missing"),
            (isMainFrame: true, status: 403, header: nil),
            (isMainFrame: true, status: 200, header: "missing"),
            (isMainFrame: true, status: 431, header: nil),
            (isMainFrame: true, status: nil, header: nil),
        ]

        for testCase in cases {
            let decision = session.decideLoopbackResponse(
                isMainFrame: testCase.isMainFrame,
                httpStatus: testCase.status,
                refusalHeader: testCase.header,
                responseURL: sampleURL,
                stillCurrent: {
                    XCTFail("stillCurrent must not be evaluated for non-qualifying responses")
                    return true
                }
            )
            XCTAssertEqual(decision, .allow)
            XCTAssertFalse(gate.entered)
            XCTAssertEqual(recorder.loads.count, 0)
            XCTAssertTrue(log.events.filter { $0.category == .journal }.isEmpty)
        }

        // Marked main-frame 403 with responseURL nil
        let nilURLDecision = session.decideLoopbackResponse(
            isMainFrame: true,
            httpStatus: 403,
            refusalHeader: "missing",
            responseURL: nil,
            stillCurrent: {
                XCTFail("stillCurrent must not be evaluated when responseURL is nil")
                return true
            }
        )
        XCTAssertEqual(nilURLDecision, .cancel)
        XCTAssertFalse(gate.entered)
        XCTAssertEqual(recorder.loads.count, 0)
        XCTAssertTrue(log.events.filter { $0.category == .journal }.isEmpty)
        XCTAssertEqual(recorder.states.count, 0)

        // Later marked 403 with URL recovers (proving nil URL did not stamp)
        let recoverDecision = session.decideLoopbackResponse(
            isMainFrame: true,
            httpStatus: 403,
            refusalHeader: "missing",
            responseURL: sampleURL,
            stillCurrent: { true }
        )
        XCTAssertEqual(recoverDecision, .cancel)
        try await self.waitFor("cookie gate entered for later recovery") {
            gate.entered
        }
        XCTAssertEqual(recorder.loads.count, 0)

        gate.release()
        try await self.waitFor("recovery load issued") {
            recorder.loads.count == 1
        }
        XCTAssertEqual(recorder.loads.first?.url, sampleURL)

        session.teardown()
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

    func makeSession(
        gate: CoalescerSleepGate? = nil,
        sleep: (@Sendable (Duration) async -> Void)? = nil,
        clock: (@MainActor () -> ContinuousClock.Instant)? = nil,
        restoreLoopbackCookie: (@MainActor () async -> Void)? = nil,
        diagnosticLog: DiagnosticLog? = nil
    ) -> JournalWebNavigationSession {
        JournalWebNavigationSession(
            sleep: { duration in
                if let sleep {
                    await sleep(duration)
                } else if let gate {
                    await gate.sleep(duration)
                }
            },
            clock: clock ?? { ContinuousClock.now },
            restoreLoopbackCookie: restoreLoopbackCookie ?? { },
            load: { request in
                self.loads.append(request)
                if self.loadNavigations.isEmpty {
                    return nil
                }
                return self.loadNavigations.removeFirst()
            },
            setState: { state in
                self.states.append(state)
            },
            diagnosticLog: diagnosticLog
        )
    }
}

@MainActor
private final class CookieStepGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false

    func step() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.entered = true
            self.continuation = continuation
        }
    }

    func release() {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class BoundSleepProbe {
    private(set) var entered = 0
    private(set) var cancelled = 0
    private var pending: CheckedContinuation<Void, Never>?

    func sleep(_ duration: Duration) async {
        guard !Task.isCancelled else { return }
        let generation = self.entered + 1
        self.entered = generation
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.pending = continuation
            }
        } onCancel: {
            Task { @MainActor in
                if self.cancelled < generation {
                    self.cancelled = generation
                }
            }
        }
    }

    func resumePending() {
        let continuation = self.pending
        self.pending = nil
        continuation?.resume()
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

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import Network
import os
import WebKit
import XCTest

/// Runtime coverage for the production shape: loopback HTTP, a server redirect,
/// an external boot script, and an API fetch. State-machine tests cannot prove
/// that WebKit and its delegate actually carry this sequence end to end.
@MainActor
final class JournalWKWebViewRuntimeTests: XCTestCase {
    func testLoopbackRedirectAndBootGraphReachReadyDocument() async throws {
        let fixture = try LoopbackJournalFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }

        let log = DiagnosticLog()
        var states: [JournalWebPresentation.LoadState] = []
        let coordinator = JournalWebView.Coordinator(diagnosticLog: log) { state in
            states.append(state)
        }
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = coordinator
        defer {
            coordinator.teardown()
            webView.stopLoading()
            webView.navigationDelegate = nil
        }

        coordinator.requestLoad(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/")),
            reloadToken: 0,
            webView: webView
        )

        let title = try await self.waitForDocumentTitle("journal-ready", in: webView)
        XCTAssertEqual(title, "journal-ready")
        XCTAssertEqual(states.last, .loaded)
        XCTAssertTrue(log.events.contains { $0.category == .journal && $0.message == "redirect" })
        XCTAssertTrue(log.events.contains { $0.category == .journal && $0.message == "commit" })
        XCTAssertTrue(log.events.contains { $0.category == .journal && $0.message == "finish" })
        XCTAssertTrue(
            Set(fixture.requestedPaths).isSuperset(
                of: Set(["/", "/app/home/", "/static/boot.js", "/api/pulse"])
            ),
            "requested paths: \(fixture.requestedPaths)"
        )
    }

    func testExternalLocationActivationsAreHandedOffWithoutLoadFailure() async throws {
        let fixture = try LoopbackJournalFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let recorder = RuntimeJournalRecorder()
        let journal = try await self.makeJournal(port: port, recorder: recorder)
        defer { journal.teardown() }

        _ = try await journal.webView.evaluateJavaScript("window.location = 'https://example.test/script'")
        try await self.waitForOpenCount(1, recorder: recorder)
        XCTAssertEqual(recorder.openedURLs, [try XCTUnwrap(URL(string: "https://example.test/script"))])

        _ = try await journal.webView.evaluateJavaScript(
            "setTimeout(function(){ window.location = 'https://example.test/delayed'; }, 0)"
        )
        try await self.waitForOpenCount(2, recorder: recorder)
        XCTAssertEqual(recorder.openedURLs[1], try XCTUnwrap(URL(string: "https://example.test/delayed")))

        let repeatedURL = try XCTUnwrap(URL(string: "https://example.test/repeat"))
        _ = try await journal.webView.evaluateJavaScript(
            "window.location = 'https://example.test/repeat'; " +
                "setTimeout(function(){ window.location = 'https://example.test/repeat'; }, 150)"
        )
        try await self.waitForOpenCount(4, recorder: recorder)
        XCTAssertEqual(Array(recorder.openedURLs.suffix(2)), [repeatedURL, repeatedURL])

        let title = try await self.waitForDocumentTitle("journal-ready", in: journal.webView)
        XCTAssertEqual(title, "journal-ready")
        XCTAssertFalse(recorder.states.contains { state in
            if case .error(message: JournalWebPresentation.loadFailureMessage) = state { return true }
            return false
        })
    }

    func testRedirectToExternalAuthorityOpensWithoutCommittingForeignURL() async throws {
        let fixture = try LoopbackJournalFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let recorder = RuntimeJournalRecorder()
        let journal = try await self.makeJournal(port: port, recorder: recorder)
        defer { journal.teardown() }
        let foreignURL = try XCTUnwrap(URL(string: "https://example.test/foreign"))

        _ = try await journal.webView.evaluateJavaScript("window.location = '/redirect-foreign'")
        try await self.waitForOpenCount(1, recorder: recorder)
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(recorder.openedURLs, [foreignURL])
        XCTAssertNotEqual(journal.webView.url, foreignURL)
        let title = try await self.waitForDocumentTitle("journal-ready", in: journal.webView)
        XCTAssertEqual(title, "journal-ready")
        XCTAssertFalse(fixture.requestedPaths.contains("/foreign"))
    }

    func testBlankTargetAndWindowOpenHandoffAndSameAuthorityLoad() async throws {
        let fixture = try LoopbackJournalFixture()
        let port = try await fixture.start()
        defer { fixture.stop() }
        let recorder = RuntimeJournalRecorder()
        let journal = try await self.makeJournal(
            port: port,
            recorder: recorder,
            allowsJavaScriptWindows: true
        )
        defer { journal.teardown() }

        _ = try await journal.webView.evaluateJavaScript("document.getElementById('blank').click()")
        try await self.waitForOpenCount(1, recorder: recorder)
        XCTAssertEqual(recorder.openedURLs, [try XCTUnwrap(URL(string: "https://example.test/blank"))])

        _ = try await journal.webView.evaluateJavaScript("document.getElementById('blank').click()")
        try await self.waitForOpenCount(2, recorder: recorder)
        XCTAssertEqual(recorder.openedURLs.count, 2)

        _ = try await journal.webView.evaluateJavaScript("window.open('https://example.test/open')")
        try await self.waitForOpenCount(3, recorder: recorder)
        XCTAssertEqual(recorder.openedURLs[2], try XCTUnwrap(URL(string: "https://example.test/open")))

        _ = try await journal.webView.evaluateJavaScript("document.getElementById('same').click()")
        let title = try await self.waitForDocumentTitle("same-authority-target", in: journal.webView)
        XCTAssertEqual(title, "same-authority-target")
        XCTAssertEqual(recorder.openedURLs.count, 3)
    }

    private func makeJournal(
        port: UInt16,
        recorder: RuntimeJournalRecorder,
        allowsJavaScriptWindows: Bool = false
    ) async throws -> RuntimeJournal {
        let diagnosticLog = DiagnosticLog()
        let coordinator = JournalWebView.Coordinator(
            diagnosticLog: diagnosticLog,
            setState: { recorder.states.append($0) },
            opener: { url in
                recorder.openedURLs.append(url)
                return true
            }
        )
        let configuration = JournalWebHostContractConfiguration.make(diagnosticLog: diagnosticLog)
        if allowsJavaScriptWindows {
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        webView.frame = window.bounds
        window.addSubview(webView)
        window.makeKeyAndVisible()
        coordinator.observeForeground(of: webView)
        coordinator.requestLoad(
            url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/")),
            reloadToken: 0,
            webView: webView
        )
        _ = try await self.waitForDocumentTitle("journal-ready", in: webView)
        return RuntimeJournal(webView: webView, window: window, coordinator: coordinator)
    }

    private func waitForOpenCount(_ expected: Int, recorder: RuntimeJournalRecorder) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if recorder.openedURLs.count >= expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("expected \(expected) external opens, got \(recorder.openedURLs.count)")
    }

    private func waitForDocumentTitle(_ expected: String, in webView: WKWebView) async throws -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var lastTitle: String?
        while clock.now < deadline {
            lastTitle = try await webView.evaluateJavaScript("document.title") as? String
            if lastTitle == expected {
                return lastTitle
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("document title did not become \(expected); last=\(lastTitle ?? "nil")")
        return lastTitle
    }
}

@MainActor
private final class RuntimeJournalRecorder {
    var states: [JournalWebPresentation.LoadState] = []
    var openedURLs: [URL] = []
}

@MainActor
private struct RuntimeJournal {
    let webView: WKWebView
    let window: UIWindow
    let coordinator: JournalWebView.Coordinator

    func teardown() {
        self.coordinator.teardown()
        self.webView.stopLoading()
        self.webView.navigationDelegate = nil
        self.webView.uiDelegate = nil
        self.window.isHidden = true
    }
}

private final class LoopbackJournalFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.solstone.swift.tests.journal-loopback")
    private let paths = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let startup = OSAllocatedUnfairLock<CheckedContinuation<UInt16, any Error>?>(initialState: nil)

    var requestedPaths: [String] {
        self.paths.withLock { $0 }
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        self.listener = try NWListener(using: parameters)
        self.listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        self.listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port else {
                    self.resumeStartup(throwing: FixtureError.missingPort)
                    return
                }
                self.resumeStartup(returning: port.rawValue)
            case .failed(let error):
                self.resumeStartup(throwing: error)
            default:
                break
            }
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            self.startup.withLock { $0 = continuation }
            self.listener.start(queue: self.queue)
        }
    }

    func stop() {
        self.listener.cancel()
    }

    private func resumeStartup(returning port: UInt16) {
        let continuation = self.startup.withLock { continuation -> CheckedContinuation<UInt16, any Error>? in
            let value = continuation
            continuation = nil
            return value
        }
        continuation?.resume(returning: port)
    }

    private func resumeStartup(throwing error: any Error) {
        let continuation = self.startup.withLock { continuation -> CheckedContinuation<UInt16, any Error>? in
            let value = continuation
            continuation = nil
            return value
        }
        continuation?.resume(throwing: error)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: self.queue)
        self.receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var requestData = accumulated
            if let data {
                requestData.append(data)
            }
            let headersComplete = requestData.range(of: Data("\r\n\r\n".utf8)) != nil
            if !headersComplete, error == nil, !isComplete {
                self.receiveRequest(on: connection, accumulated: requestData)
                return
            }
            guard error == nil,
                  let request = String(data: requestData, encoding: .utf8),
                  let firstLine = request.components(separatedBy: "\r\n").first,
                  firstLine.hasPrefix("GET ")
            else {
                connection.cancel()
                return
            }
            let target = firstLine.split(separator: " ")[1]
            let path = String(target.split(separator: "?", maxSplits: 1)[0])
            self.paths.withLock { $0.append(path) }
            let response = self.response(for: path)
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for path: String) -> String {
        switch path {
        case "/":
            return Self.httpResponse(status: "302 Found", headers: ["Location: /app/home/"], body: "")
        case "/app/home/":
            return Self.httpResponse(
                status: "200 OK",
                headers: ["Content-Type: text/html; charset=utf-8"],
                body: """
                <!doctype html><html><head><title>journal-loading</title></head>
                <body><main id="surface">loading</main>
                <a id="blank" target="_blank" href="https://example.test/blank">outside</a>
                <a id="same" target="_blank" href="/same-authority-target">same authority</a>
                <script src="/static/boot.js"></script></body></html>
                """
            )
        case "/redirect-foreign":
            return Self.httpResponse(status: "302 Found", headers: ["Location: https://example.test/foreign"], body: "")
        case "/same-authority-target":
            return Self.httpResponse(
                status: "200 OK",
                headers: ["Content-Type: text/html; charset=utf-8"],
                body: "<!doctype html><html><head><title>same-authority-target</title></head><body>same</body></html>"
            )
        case "/static/boot.js":
            return Self.httpResponse(
                status: "200 OK",
                headers: ["Content-Type: application/javascript"],
                body: "fetch('/api/pulse').then(r => r.json()).then(() => { document.title = 'journal-ready'; });"
            )
        case "/api/pulse":
            return Self.httpResponse(
                status: "200 OK",
                headers: ["Content-Type: application/json"],
                body: "{\"ok\":true}"
            )
        default:
            return Self.httpResponse(status: "404 Not Found", headers: [], body: "not found")
        }
    }

    private static func httpResponse(status: String, headers: [String], body: String) -> String {
        let common = [
            "HTTP/1.1 \(status)",
            "Content-Length: \(body.utf8.count)",
            "Connection: close",
        ] + headers
        return common.joined(separator: "\r\n") + "\r\n\r\n" + body
    }
}

private enum FixtureError: Error {
    case missingPort
}

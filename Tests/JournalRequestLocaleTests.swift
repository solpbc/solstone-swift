// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import Network
import os
import SPLTunnel
import WebKit
import XCTest

@MainActor
final class JournalRequestLocaleTests: XCTestCase {
    func testHeaderValueOmitsEnglishAndNormalizesNonEnglish() {
        XCTAssertNil(JournalRequestLocale.headerValue(for: "en-US"))
        XCTAssertNil(JournalRequestLocale.headerValue(for: "en-us"))
        XCTAssertNil(JournalRequestLocale.headerValue(for: "en"))
        XCTAssertNil(JournalRequestLocale.headerValue(for: ""))
        XCTAssertNil(JournalRequestLocale.headerValue(for: "en-XA\r\nX-Injected: 1"))
        XCTAssertEqual(JournalRequestLocale.headerValue(for: "en-XA"), "en-XA")
        XCTAssertEqual(JournalRequestLocale.headerValue(for: "fr-FR"), "fr-FR")
    }

    func testURLRequestExtensionGatesOnOriginAndLanguage() throws {
        let pairedAuthority = try XCTUnwrap(
            JournalWebNavigationPolicy.authority(for: XCTUnwrap(URL(string: "http://127.0.0.1:41234/")))
        )

        var pairedNonEnglish = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:41234/app/home/")))
        pairedNonEnglish.attachJournalLocale(matching: pairedAuthority, language: "en-XA")
        XCTAssertEqual(pairedNonEnglish.value(forHTTPHeaderField: "X-Solstone-Locale"), "en-XA")

        var pairedEnglish = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:41234/app/home/")))
        pairedEnglish.attachJournalLocale(matching: pairedAuthority, language: "en-US")
        XCTAssertNil(pairedEnglish.value(forHTTPHeaderField: "X-Solstone-Locale"))

        var otherPort = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:49999/app/home/")))
        otherPort.attachJournalLocale(matching: pairedAuthority, language: "en-XA")
        XCTAssertNil(otherPort.value(forHTTPHeaderField: "X-Solstone-Locale"))

        var foreign = URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/")))
        foreign.attachJournalLocale(matching: pairedAuthority, language: "en-XA")
        XCTAssertNil(foreign.value(forHTTPHeaderField: "X-Solstone-Locale"))
        foreign.attachJournalLocale(language: "en-XA")
        XCTAssertNil(foreign.value(forHTTPHeaderField: "X-Solstone-Locale"))
    }

    func testNavigationSessionAndRouterTagFirstAndLaterSameOriginNavigationsOnly() async throws {
        var loadedRequests: [URLRequest] = []
        var openedExternally: [URL] = []
        let session = JournalWebNavigationSession(
            load: { request in
                loadedRequests.append(request)
                return NSObject()
            },
            setState: { _ in },
            localeLanguage: { "en-XA" }
        )
        let router = JournalWebActivationRouter(session: session) { url in
            openedExternally.append(url)
            return true
        }

        // First document request carries X-Solstone-Locale.
        let initialURL = try XCTUnwrap(URL(string: "http://127.0.0.1:41234/"))
        session.requestLoad(url: initialURL, reloadToken: 0)
        XCTAssertEqual(loadedRequests.count, 1)
        XCTAssertEqual(loadedRequests[0].value(forHTTPHeaderField: "X-Solstone-Locale"), "en-XA")

        // A later full-document link click without the header is cancelled and re-issued with the header.
        let nextURL = try XCTUnwrap(URL(string: "http://127.0.0.1:41234/app/health/"))
        var policies: [WKNavigationActionPolicy] = []
        await router.handleNavigationAction(frame: .main, request: URLRequest(url: nextURL)) { policy in
            policies.append(policy)
        }
        XCTAssertEqual(policies, [.cancel])
        XCTAssertEqual(loadedRequests.count, 2)
        XCTAssertEqual(loadedRequests[1].url, nextURL)
        XCTAssertEqual(loadedRequests[1].value(forHTTPHeaderField: "X-Solstone-Locale"), "en-XA")

        // The re-issued tagged request is allowed without looping.
        policies.removeAll()
        await router.handleNavigationAction(frame: .main, request: loadedRequests[1]) { policy in
            policies.append(policy)
        }
        XCTAssertEqual(policies, [.allow])
        XCTAssertEqual(loadedRequests.count, 2)

        // A foreign origin navigation opens externally and never loads with the header.
        let foreignURL = try XCTUnwrap(URL(string: "https://example.com/outside"))
        policies.removeAll()
        await router.handleNavigationAction(frame: .main, request: URLRequest(url: foreignURL)) { policy in
            policies.append(policy)
        }
        XCTAssertEqual(policies, [.cancel])
        XCTAssertEqual(openedExternally, [foreignURL])
        XCTAssertEqual(loadedRequests.count, 2)
    }

    func testNavigationSessionSendsNothingNewInEnglish() async throws {
        var loadedRequests: [URLRequest] = []
        let session = JournalWebNavigationSession(
            load: { request in
                loadedRequests.append(request)
                return NSObject()
            },
            setState: { _ in },
            localeLanguage: { "en-US" }
        )
        let router = JournalWebActivationRouter(session: session) { _ in true }

        let initialURL = try XCTUnwrap(URL(string: "http://127.0.0.1:41234/"))
        session.requestLoad(url: initialURL, reloadToken: 0)
        XCTAssertEqual(loadedRequests.count, 1)
        XCTAssertNil(loadedRequests[0].value(forHTTPHeaderField: "X-Solstone-Locale"))

        let nextURL = try XCTUnwrap(URL(string: "http://127.0.0.1:41234/app/health/"))
        var policies: [WKNavigationActionPolicy] = []
        await router.handleNavigationAction(frame: .main, request: URLRequest(url: nextURL)) { policy in
            policies.append(policy)
        }
        XCTAssertEqual(policies, [.allow])
        XCTAssertEqual(loadedRequests.count, 1)
        XCTAssertNil(JournalRequestLocale.fetchLocaleScript(origin: "http://127.0.0.1:41234", language: "en-US"))
    }

    func testWKWebViewCarriesLocaleAcrossFirstDocumentLaterNavigationAndFetchNotOtherOrigin() async throws {
        let journal = try LocaleCaptureServer()
        let journalPort = try await journal.start()
        defer { journal.stop() }

        let other = try LocaleCaptureServer()
        let otherPort = try await other.start()
        defer { other.stop() }

        let origin = "http://127.0.0.1:\(journalPort)"
        let otherURL = "http://127.0.0.1:\(otherPort)/foreign-fetch"

        let config = WKWebViewConfiguration()
        let script = try XCTUnwrap(
            JournalRequestLocale.fetchLocaleScript(origin: origin, language: "en-XA")
        )
        config.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        let log = DiagnosticLog()
        let coordinator = JournalWebView.Coordinator(
            diagnosticLog: log,
            localeLanguage: { "en-XA" },
            setState: { _ in }
        )
        webView.navigationDelegate = coordinator
        defer {
            coordinator.teardown()
            webView.stopLoading()
            webView.navigationDelegate = nil
        }

        // 1. Initial document load
        coordinator.requestLoad(
            url: try XCTUnwrap(URL(string: "\(origin)/?other=\(otherPort)")),
            reloadToken: 0,
            webView: webView
        )
        try await self.waitUntil {
            journal.recorded.contains { $0.path == "/api/localized" }
        }
        // 2. Cross-origin fetch from the page must NOT carry X-Solstone-Locale
        _ = try? await webView.evaluateJavaScript(
            "fetch('\(otherURL)', { mode: 'no-cors' }).catch(function () {}); true"
        )
        try await self.waitUntil {
            other.recorded.contains { $0.path == "/foreign-fetch" }
        }
        // 3. Later full-document link click navigation must carry X-Solstone-Locale
        _ = try await webView.evaluateJavaScript("document.getElementById('next-link').click(); true")
        try await self.waitUntil {
            journal.recorded.contains { $0.path == "/app/next" }
        }

        let initialRecord = try XCTUnwrap(journal.recorded.first { $0.path.hasPrefix("/?") })
        XCTAssertEqual(initialRecord.localeHeader, "en-XA")

        let fetchRecord = try XCTUnwrap(journal.recorded.first { $0.path == "/api/localized" })
        XCTAssertEqual(fetchRecord.localeHeader, "en-XA")

        let nextRecord = try XCTUnwrap(journal.recorded.first { $0.path == "/app/next" })
        XCTAssertEqual(nextRecord.localeHeader, "en-XA")

        let otherRecord = try XCTUnwrap(other.recorded.first { $0.path == "/foreign-fetch" })
        XCTAssertNil(otherRecord.localeHeader)
    }

    func testWKWebViewInEnglishSendsNoLocaleHeader() async throws {
        let journal = try LocaleCaptureServer()
        let journalPort = try await journal.start()
        defer { journal.stop() }

        let origin = "http://127.0.0.1:\(journalPort)"
        let config = WKWebViewConfiguration()
        XCTAssertNil(JournalRequestLocale.fetchLocaleScript(origin: origin, language: "en-US"))

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        let log = DiagnosticLog()
        let coordinator = JournalWebView.Coordinator(
            diagnosticLog: log,
            localeLanguage: { "en-US" },
            setState: { _ in }
        )
        webView.navigationDelegate = coordinator
        defer {
            coordinator.teardown()
            webView.stopLoading()
            webView.navigationDelegate = nil
        }

        coordinator.requestLoad(
            url: try XCTUnwrap(URL(string: "\(origin)/?other=0")),
            reloadToken: 0,
            webView: webView
        )
        try await self.waitUntil {
            journal.recorded.contains { $0.path == "/api/localized" }
        }
        _ = try await webView.evaluateJavaScript("document.getElementById('next-link').click(); true")
        try await self.waitUntil {
            journal.recorded.contains { $0.path == "/app/next" }
        }

        for record in journal.recorded {
            XCTAssertNil(record.localeHeader, "Unexpected X-Solstone-Locale on \(record.path)")
        }
    }

    func testHomePulsePollerSendsLocaleOnlyOutsideEnglish() async {
        URLProtocol.registerClass(LocaleTestURLProtocol.self)
        defer {
            LocaleTestURLProtocol.handler = nil
            URLProtocol.unregisterClass(LocaleTestURLProtocol.self)
        }

        let captured = OSAllocatedUnfairLock<[String?]>(initialState: [])
        LocaleTestURLProtocol.handler = { request in
            captured.withLock { $0.append(request.value(forHTTPHeaderField: "X-Solstone-Locale")) }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"welcome_framing":"hello"}"#.utf8)
            )
        }

        let xa = await HomePulsePoller(localeLanguage: { "en-XA" }).fetch(localPort: 7071)
        XCTAssertEqual(xa, "hello")
        let en = await HomePulsePoller(localeLanguage: { "en-US" }).fetch(localPort: 7071)
        XCTAssertEqual(en, "hello")

        XCTAssertEqual(captured.withLock { $0 }, ["en-XA", nil])
    }

    func testTransferTransportSendsLocaleOnlyOutsideEnglish() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LocaleTestURLProtocol.self]
        defer { LocaleTestURLProtocol.handler = nil }

        let captured = OSAllocatedUnfairLock<[String?]>(initialState: [])
        LocaleTestURLProtocol.handler = { request in
            captured.withLock { $0.append(request.value(forHTTPHeaderField: "X-Solstone-Locale")) }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"status":"ok"}"#.utf8)
            )
        }

        let bodyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("locale-transfer-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: bodyFile)
        defer { try? FileManager.default.removeItem(at: bodyFile) }

        let itemID = UUID()
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let manifest = TransferManifest(
            itemID: itemID,
            source: "share-import",
            createdAt: now,
            priority: TransferPriorityInputs(basePriority: .normal, sourceKey: "share-import"),
            payloadParts: [],
            endpoint: TransferEndpointDescriptor(
                destinationKind: .saveThenStart,
                path: "/app/import/api/save",
                startPath: "/app/import/api/start"
            ),
            meta: .object(["kind": .string("test")])
        )
        let storedItem = TransferStoredItem(
            manifest: manifest,
            directoryURL: bodyFile.deletingLastPathComponent()
        )
        let endpoint = TransferResolvedEndpoint(
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:7072")),
            port: 7072
        )

        let xaTransport = TransferTransport(sessionConfiguration: config, localeLanguage: { "en-XA" })
        let xaResult = await xaTransport.send(item: storedItem, bodyURL: bodyFile, endpoint: endpoint, phase: .save)
        XCTAssertEqual(xaResult.statusCode, 200)

        let enTransport = TransferTransport(sessionConfiguration: config, localeLanguage: { "en-US" })
        let enResult = await enTransport.send(item: storedItem, bodyURL: bodyFile, endpoint: endpoint, phase: .save)
        XCTAssertEqual(enResult.statusCode, 200)

        XCTAssertEqual(captured.withLock { $0 }, ["en-XA", nil])
    }

    private func waitUntil(
        timeout: Duration = .seconds(10),
        condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for expected request")
    }
}

private final class LocaleTestURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let box = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    static var handler: Handler? {
        get { self.box.withLock { $0 } }
        set { self.box.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
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

private final class LocaleCaptureServer: @unchecked Sendable {
    struct RequestRecord: Sendable {
        let path: String
        let localeHeader: String?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.solstone.swift.tests.locale-capture")
    private let records = OSAllocatedUnfairLock<[RequestRecord]>(initialState: [])
    private let startup = OSAllocatedUnfairLock<CheckedContinuation<UInt16, any Error>?>(initialState: nil)

    var recorded: [RequestRecord] {
        self.records.withLock { $0 }
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
                guard let port = self.listener.port else { return }
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
        let c = self.startup.withLock { v -> CheckedContinuation<UInt16, any Error>? in
            defer { v = nil }
            return v
        }
        c?.resume(returning: port)
    }

    private func resumeStartup(throwing error: any Error) {
        let c = self.startup.withLock { v -> CheckedContinuation<UInt16, any Error>? in
            defer { v = nil }
            return v
        }
        c?.resume(throwing: error)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: self.queue)
        self.receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if error == nil, !isComplete {
                    self.receive(on: connection, accumulated: buffer)
                } else {
                    connection.cancel()
                }
                return
            }
            guard let text = String(data: buffer, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let lines = text.components(separatedBy: "\r\n")
            let path = lines.first?.components(separatedBy: " ").dropFirst().first ?? "/"
            var localeHeader: String?
            for line in lines.dropFirst() {
                if line.isEmpty { break }
                if let sep = line.firstIndex(of: ":") {
                    let name = line[..<sep].trimmingCharacters(in: .whitespaces).lowercased()
                    if name == "x-solstone-locale" {
                        localeHeader = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            let capturedLocale = localeHeader
            self.records.withLock { $0.append(RequestRecord(path: path, localeHeader: capturedLocale)) }

            let body: String
            let contentType: String
            if path.hasPrefix("/api/localized") {
                contentType = "application/json"
                body = #"{"locale":"\#(localeHeader ?? "en-US")"}"#
            } else if path == "/app/next" {
                contentType = "text/html; charset=utf-8"
                body = "<!doctype html><html><head><title>next-page</title></head><body>next</body></html>"
            } else if path == "/foreign-fetch" {
                contentType = "text/plain"
                body = "ok"
            } else {
                contentType = "text/html; charset=utf-8"
                body = """
                <!doctype html>
                <html><head><title>home-page</title></head>
                <body>
                  <a id="next-link" href="/app/next">Next</a>
                  <script>fetch('/api/localized').catch(function () {});</script>
                </body></html>
                """
            }
            let bodyData = Data(body.utf8)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
            var wire = Data(response.utf8)
            wire.append(bodyData)
            connection.send(content: wire, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

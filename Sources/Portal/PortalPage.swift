// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import WebKit
import os

private let log = Logger(subsystem: "app.solstone.swift", category: "portal")

private let tunnelDeadErrorCodes: Set<Int> = [
    NSURLErrorCannotConnectToHost,
    NSURLErrorNetworkConnectionLost,
    NSURLErrorNotConnectedToInternet,
]
private let devMockPortalPath = "/dev/mock-portal"

@Observable
final class PortalPage: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var currentRoute: String = ""
    var isReady: Bool = false

    @ObservationIgnored let tunnelManager: TunnelManager
    @ObservationIgnored let brainStatusMonitor: BrainStatusMonitor
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let cache: PortalCache
    @ObservationIgnored private let injectedEngine: (any PortalWebEngine)?
    @ObservationIgnored private var currentPort: Int = 0
    @ObservationIgnored lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "solstone")

        let webView: WKWebView = .init(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.underPageBackgroundColor = .systemBackground
        webView.navigationDelegate = self
        return webView
    }()
    @ObservationIgnored private var engine: any PortalWebEngine { self.injectedEngine ?? self.webView }

    init(
        tunnelManager: TunnelManager,
        brainStatusMonitor: BrainStatusMonitor,
        session: URLSession = .shared,
        cache: PortalCache = PortalCache(),
        webEngine: (any PortalWebEngine)? = nil
    ) {
        self.tunnelManager = tunnelManager
        self.brainStatusMonitor = brainStatusMonitor
        self.session = session
        self.cache = cache
        self.injectedEngine = webEngine
        super.init()
    }

    func load(port: Int) {
        guard port > 0, port != self.currentPort else { return }
        self.currentPort = port
        self.isReady = false
        self.currentRoute = ""
        self.brainStatusMonitor.reset()

        guard let url = URL(string: "http://127.0.0.1:\(port)\(devMockPortalPath)") else { return }
        if self.loadCachedHTMLIfAvailable(for: url) {
            return
        }
        log.info("[solstone-swift] portal: loading \(url.absoluteString, privacy: .public)")
        self.engine.load(URLRequest(url: url))
        Task {
            await self.warmCache(for: url)
        }
    }

    func navigate(to route: String) {
        guard route != self.currentRoute else { return }
        let escapedRoute = Self.javaScriptEscaped(route)
        self.currentRoute = route
        self.engine.evaluateJavaScript("window.location.hash = '\(escapedRoute)'") { _, error in
            if let error {
                log.error("[solstone-swift] portal: route navigation failed \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func navigate(toPath path: String) {
        guard path != self.currentRoute else { return }
        let escapedPath = Self.javaScriptEscaped(path)
        self.currentRoute = path
        self.engine.evaluateJavaScript("window.location.href = '\(escapedPath)'") { _, error in
            if let error {
                log.error("[solstone-swift] portal: path navigation failed \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func applyNavHint(_ hash: String) {
        log.info("[solstone-swift] portal: nav hint applied: \(hash, privacy: .public)")
        self.navigate(to: hash)
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor [weak self] in
            guard let self,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String
            else { return }

            switch type {
            case "ready":
                self.isReady = true
                log.info("[solstone-swift] portal: spa ready")
            case "route":
                guard let data = body["data"] as? [String: Any],
                      let route = data["route"] as? String
                else { return }
                self.currentRoute = route
                log.info("[solstone-swift] portal: route \(route, privacy: .public)")
            case "brain":
                guard let data = body["data"],
                      JSONSerialization.isValidJSONObject(data),
                      let jsonData = try? JSONSerialization.data(withJSONObject: data),
                      let jsonString = String(data: jsonData, encoding: .utf8)
                else { return }
                self.brainStatusMonitor.update(from: jsonString)
            case "get_cache_age":
                let data = body["data"] as? [String: Any]
                let requestedPath = data?["path"] as? String ?? self.currentRoute
                self.replyCacheAge(for: requestedPath)
            default:
                log.info("[solstone-swift] portal: unknown message \(type, privacy: .public)")
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        Task { @MainActor in
            log.info("[solstone-swift] portal: page loaded \(webView.url?.absoluteString ?? "unknown", privacy: .public)")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.handleNavigationFailure(error: error, kind: "provisional navigation")
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.handleNavigationFailure(error: error, kind: "navigation")
        }
    }
}

extension PortalPage {
    private static func javaScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    func handleNavigationFailure(error: Error, kind: String) {
        log.error("[solstone-swift] portal: \(kind, privacy: .public) failed \(error.localizedDescription, privacy: .public)")
        if let url = URL(string: "http://127.0.0.1:\(self.currentPort)\(devMockPortalPath)"),
           self.loadCachedHTMLIfAvailable(for: url)
        {
            return
        }
        let code = (error as NSError).code
        if tunnelDeadErrorCodes.contains(code) {
            Task {
                await self.tunnelManager.handleTunnelFailure()
            }
        } else {
            self.loadErrorPage(error: error)
        }
    }

    private func loadErrorPage(error: Error) {
        let description = error.localizedDescription
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        // Portal error-page palette mirrors the sol brand canon (orange-on-cream).
        let html = """
        <!doctype html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                :root {
                    color-scheme: light dark;
                }
                body {
                    margin: 0;
                    min-height: 100vh;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    padding: 24px;
                    background: #FFFFFF;
                    color: #1C1C1E;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                }
                .card {
                    max-width: 420px;
                    text-align: center;
                }
                h1 {
                    margin: 0 0 12px;
                    font-size: 28px;
                }
                p {
                    margin: 0 0 24px;
                    font-size: 14px;
                    line-height: 1.5;
                    opacity: 0.8;
                }
                a {
                    border-radius: 12px;
                    padding: 12px 20px;
                    background: #b06a1a;
                    color: #FFFFFF;
                    font-size: 16px;
                    font-weight: 600;
                    text-decoration: none;
                    display: inline-block;
                }
                a:active {
                    opacity: 0.7;
                }
                @media (prefers-color-scheme: dark) {
                    body {
                        background: #1C1C1E;
                        color: #F2F2F7;
                    }
                    a {
                        background: #E8923A;
                        color: #F2F2F7;
                    }
                }
            </style>
        </head>
        <body>
            <div class="card">
                <h1>couldn't reach the portal</h1>
                <p>\(description)</p>
                <a href="http://127.0.0.1:\(self.currentPort)\(devMockPortalPath)">reload</a>
            </div>
        </body>
        </html>
        """
        self.engine.loadHTMLString(html, baseURL: nil)
    }

    private func warmCache(for url: URL) async {
        do {
            let (data, response) = try await self.session.data(from: url)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return }
            guard let html = String(data: data, encoding: .utf8) else { return }
            try self.cache.storeHTML(html, path: url.path, etag: http.value(forHTTPHeaderField: "ETag"))
        } catch {
            log.debug("[solstone-swift] portal: cache warm failed \(String(describing: error), privacy: .public)")
        }
    }

    private func replyCacheAge(for path: String) {
        let cachePath = path.isEmpty ? devMockPortalPath : path
        let hours = self.cache.cacheAgeHours(path: cachePath) ?? -1
        let escapedPath = cachePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        self.engine.evaluateJavaScript(
            "window.__solstone && window.__solstone.cacheAge && window.__solstone.cacheAge('\(escapedPath)', \(hours))",
            completionHandler: nil
        )
    }

    @discardableResult
    private func loadCachedHTMLIfAvailable(for url: URL) -> Bool {
        guard self.tunnelManager.isNetworkSatisfied == false,
              let cached = self.cache.cachedHTML(path: url.path)
        else {
            return false
        }

        self.isReady = true
        let ageHours = self.cache.cacheAgeHours(path: url.path) ?? -1
        log.info("[solstone-swift] portal: loading cached html age=\(ageHours)h")
        self.engine.loadHTMLString(cached.html, baseURL: url)
        return true
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import WebKit

final class MockPortalWebEngine: PortalWebEngine {
    var loadCallCount = 0
    var lastLoadedURL: URL?
    var evaluateJavaScriptCallCount = 0
    var lastEvaluatedScript: String?
    var loadHTMLStringCallCount = 0
    var lastLoadedHTML: String?
    var lastLoadedBaseURL: URL?

    func load(_ request: URLRequest) -> WKNavigation? {
        self.loadCallCount += 1
        self.lastLoadedURL = request.url
        return nil
    }

    func evaluateJavaScript(
        _ javaScriptString: String,
        completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)?
    ) {
        self.evaluateJavaScriptCallCount += 1
        self.lastEvaluatedScript = javaScriptString
        completionHandler?(nil, nil)
    }

    func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        self.loadHTMLStringCallCount += 1
        self.lastLoadedHTML = string
        self.lastLoadedBaseURL = baseURL
        return nil
    }
}

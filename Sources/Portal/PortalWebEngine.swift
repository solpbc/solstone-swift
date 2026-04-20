// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import WebKit

@MainActor
protocol PortalWebEngine: AnyObject {
    @discardableResult
    func load(_ request: URLRequest) -> WKNavigation?

    func evaluateJavaScript(
        _ javaScriptString: String,
        completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)?
    )

    @discardableResult
    func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation?
}

extension WKWebView: PortalWebEngine {}

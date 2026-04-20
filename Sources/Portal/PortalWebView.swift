// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import WebKit

struct PortalWebView: UIViewRepresentable {
    let portalPage: PortalPage

    func makeUIView(context: Context) -> WKWebView {
        self.portalPage.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

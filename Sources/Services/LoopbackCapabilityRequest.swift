// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

nonisolated extension URLRequest {
    /// Proves to the SPL loopback proxy that this request comes from this app.
    ///
    /// The proxy refuses any local connection whose first request lacks the
    /// process's capability, because another app or a web page on the phone can
    /// reach the same port. Attached only for `127.0.0.1`: the capability is a
    /// secret, and any other host would receive it in cleartext. Cookie handling
    /// is off so the cookie jar can never replace the header.
    mutating func attachLoopbackCapability() {
        guard self.url?.host == "127.0.0.1" else { return }
        self.setValue(LoopbackCapability.process.cookieHeaderValue, forHTTPHeaderField: "Cookie")
        self.httpShouldHandleCookies = false
    }
}

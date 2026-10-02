// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum JournalWebNavigationPolicy {
    struct Authority: Equatable, Sendable {
        let scheme: String
        let host: String
        let port: Int
    }

    enum Decision: Equatable, Sendable {
        case allow
        case cancel
        case rewrite(to: URL)
        /// A main-frame or new-window navigation to another site. It opens outside the
        /// journal view, so no third-party page runs in the web view that holds
        /// the loopback capability and its admitted connections.
        case openExternally(URL)
    }

    enum Frame: Equatable, Sendable {
        case main
        case noTarget
        case subframe
    }

    enum SchemeClass: String, Equatable, Sendable {
        case https
        case http
        case other
        case missing
    }

    static func authority(for liveURL: URL) -> Authority? {
        guard let scheme = self.normalizedScheme(liveURL.scheme),
              let host = self.normalizedHost(liveURL.host),
              let port = self.effectivePort(for: liveURL)
        else {
            return nil
        }

        return Authority(scheme: scheme, host: host, port: port)
    }

    static func decision(
        requestURL: URL?,
        httpMethod: String?,
        frame: Frame,
        liveAuthority: Authority?
    ) -> Decision {
        guard frame != .subframe else { return .allow }
        guard let requestURL,
              let scheme = self.normalizedScheme(requestURL.scheme),
              scheme == "http" || scheme == "https",
              let host = self.normalizedHost(requestURL.host),
              !self.hasEmbeddedAuthorityPrefix(in: requestURL)
        else {
            return .cancel
        }

        if scheme == "https",
           liveAuthority?.scheme == "http",
           self.isRewritableMethod(httpMethod),
           self.hostPortMatches(requestURL: requestURL, liveAuthority: liveAuthority),
           var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) {
            components.scheme = "http"
            guard let rewrittenURL = components.url else { return .cancel }
            return .rewrite(to: rewrittenURL)
        }

        if let liveAuthority,
           host == liveAuthority.host,
           self.effectivePort(for: requestURL) == liveAuthority.port {
            return .allow
        }

        guard !self.isLoopbackHost(host) else {
            return liveAuthority == nil ? .allow : .cancel
        }

        return .openExternally(requestURL)
    }

    static func replacementRequest(from original: URLRequest, rewrittenURL: URL) -> URLRequest {
        var request = URLRequest(
            url: rewrittenURL,
            cachePolicy: original.cachePolicy,
            timeoutInterval: original.timeoutInterval
        )
        request.httpMethod = original.httpMethod
        request.allHTTPHeaderFields = original.allHTTPHeaderFields
        return request
    }

    static func schemeClass(for url: URL?) -> SchemeClass {
        guard let scheme = self.normalizedScheme(url?.scheme) else {
            return .missing
        }
        switch scheme {
        case "https":
            return .https
        case "http":
            return .http
        default:
            return .other
        }
    }

    static func hostPortMatches(requestURL: URL?, liveAuthority: Authority?) -> Bool {
        guard let requestURL,
              let liveAuthority,
              let host = self.normalizedHost(requestURL.host),
              let port = self.effectivePort(for: requestURL)
        else {
            return false
        }

        return host == liveAuthority.host && port == liveAuthority.port
    }

    private static func hasEmbeddedAuthorityPrefix(in url: URL) -> Bool {
        let specifier = (url as NSURL).resourceSpecifier ?? ""
        guard specifier.hasPrefix("//") else { return false }

        let authorityStart = specifier.index(specifier.startIndex, offsetBy: 2)
        let authorityEnd = specifier[authorityStart...].firstIndex { character in
            character == "/" || character == "?" || character == "#"
        } ?? specifier.endIndex

        return specifier[authorityStart..<authorityEnd].contains("@")
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private static func isRewritableMethod(_ method: String?) -> Bool {
        let normalized = (method ?? "get").lowercased()
        return normalized == "get" || normalized == "head"
    }

    private static func normalizedScheme(_ scheme: String?) -> String? {
        guard let scheme, !scheme.isEmpty else { return nil }
        return scheme.lowercased()
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        return switch self.normalizedScheme(url.scheme) {
        case "http": 80
        case "https": 443
        default: nil
        }
    }

    private static func normalizedHost(_ host: String?) -> String? {
        guard var normalized = host?.lowercased(), !normalized.isEmpty else {
            return nil
        }
        while normalized.last == "." {
            normalized.removeLast()
        }
        return normalized.isEmpty ? nil : normalized
    }
}

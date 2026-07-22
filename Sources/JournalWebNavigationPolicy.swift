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
        case rewrite(to: URL)
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
              let port = liveURL.port
        else {
            return nil
        }

        return Authority(scheme: scheme, host: host, port: port)
    }

    static func decision(
        requestURL: URL?,
        httpMethod: String?,
        isMainFrame: Bool,
        liveAuthority: Authority?
    ) -> Decision {
        guard isMainFrame,
              let liveAuthority,
              liveAuthority.scheme == "http",
              let requestURL,
              self.schemeClass(for: requestURL) == .https,
              !self.hasEmbeddedAuthorityPrefix(in: requestURL),
              self.isRewritableMethod(httpMethod),
              self.hostPortMatches(requestURL: requestURL, liveAuthority: liveAuthority),
              var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        else {
            return .allow
        }

        components.scheme = "http"
        guard let rewrittenURL = components.url else {
            return .allow
        }
        return .rewrite(to: rewrittenURL)
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
              let port = requestURL.port
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

    private static func isRewritableMethod(_ method: String?) -> Bool {
        let normalized = (method ?? "get").lowercased()
        return normalized == "get" || normalized == "head"
    }

    private static func normalizedScheme(_ scheme: String?) -> String? {
        guard let scheme, !scheme.isEmpty else { return nil }
        return scheme.lowercased()
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

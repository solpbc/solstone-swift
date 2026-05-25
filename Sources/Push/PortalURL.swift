// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum PortalURL {
    static let defaultBaseURL = URL(string: "https://services.solstone.app")!
    static let enablePushPath = "/enable/push"
    static let handoffPushPath = "/handoff/push"

    static func baseURL(arguments: [String] = ProcessInfo.processInfo.arguments) -> URL {
#if DEBUG
        if let override = arguments.first(where: { $0.hasPrefix("--portal-url=") }) {
            let rawValue = String(override.dropFirst("--portal-url=".count))
            if let url = URL(string: rawValue), url.scheme != nil {
                return url
            }
        }
#endif
        return self.defaultBaseURL
    }

    static func enablePushURL(
        nonce: String,
        deviceToken: String,
        bundleId: String = "app.solstone.swift",
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> URL? {
        self.url(
            path: self.enablePushPath,
            queryItems: [
                URLQueryItem(name: "nonce", value: nonce),
                URLQueryItem(name: "device_token", value: deviceToken),
                URLQueryItem(name: "platform", value: "ios"),
                URLQueryItem(name: "bundle_id", value: bundleId),
            ],
            arguments: arguments
        )
    }

    static func handoffPushURL(
        nonce: String,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> URL? {
        self.url(
            path: self.handoffPushPath,
            queryItems: [URLQueryItem(name: "nonce", value: nonce)],
            arguments: arguments
        )
    }

    private static func url(
        path: String,
        queryItems: [URLQueryItem],
        arguments: [String]
    ) -> URL? {
        guard var components = URLComponents(
            url: self.baseURL(arguments: arguments),
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        components.path = path
        components.queryItems = queryItems
        return components.url
    }
}

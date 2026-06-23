// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// Builds loopback URLs into the connected journal's convey web UI, opened in
/// system Safari (never embedded). Mirrors `VoiceServerURL`.
nonisolated enum ConveyURL {
    /// Journal root (`/`). Returns nil when there is no live loopback port.
    static func rootURL(activeLocalPort: Int?) -> URL? {
        guard let port = activeLocalPort else { return nil }
        return self.url(localPort: port, path: "/")
    }

    static func url(localPort: Int, path: String) -> URL? {
        guard var components = URLComponents(url: self.baseURL(localPort: localPort), resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = path
        return components.url
    }

    private static func baseURL(localPort: Int) -> URL {
        let processInfo = ProcessInfo.processInfo

        if processInfo.arguments.contains("--integration-test-live"),
           let server = processInfo.environment["LIVE_SERVER"],
           let url = self.normalize(server: server, port: localPort)
        {
            return url
        }

        if processInfo.arguments.contains("--integration-test"),
           let mockPort = Int(processInfo.environment["MOCK_CONVEY_PORT"] ?? "")
        {
            return URL(string: "http://127.0.0.1:\(mockPort)")!
        }

        return URL(string: "http://127.0.0.1:\(localPort)")!
    }

    private static func normalize(server: String, port: Int) -> URL? {
        if let url = URL(string: server), url.scheme != nil {
            guard url.port == nil, port > 0 else { return url }
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url
            }
            components.port = port
            return components.url
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = server
        components.port = port > 0 ? port : nil
        return components.url
    }
}

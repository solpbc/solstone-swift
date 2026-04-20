// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum PushServerURL {
    static func url(path: String, localPort: Int) -> URL? {
        guard var components = URLComponents(
            url: self.baseURL(localPort: localPort),
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }

        components.path = path
        return components.url
    }

    static func baseURL(localPort: Int) -> URL {
        let processInfo = ProcessInfo.processInfo

        if processInfo.arguments.contains("--integration-test-live"),
           let server = processInfo.environment["LIVE_SERVER"],
           let port = Int(processInfo.environment["LIVE_PORT"] ?? "") ?? (localPort > 0 ? localPort : nil),
           let url = self.normalize(server: server, port: port)
        {
            return url
        }

        if processInfo.arguments.contains("--integration-test"),
           let mockPort = Int(processInfo.environment["MOCK_PUSH_PORT"] ?? "")
        {
            return URL(string: "http://127.0.0.1:\(mockPort)")!
        }

        return URL(string: "http://127.0.0.1:\(localPort)")!
    }

    private static func normalize(server: String, port: Int?) -> URL? {
        if let url = URL(string: server), url.scheme != nil {
            guard url.port == nil, let port, port > 0 else { return url }
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url
            }
            components.port = port
            return components.url
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = server
        components.port = port
        return components.url
    }
}

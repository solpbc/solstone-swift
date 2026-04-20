// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private struct NavHintResponse: Decodable {
    let hints: [String]
    let consumed: Bool
}

nonisolated struct NavHintPoller: NavHintPolling {
    func fetch(localPort: Int, callId: String) async -> [String] {
        let log = Logger(subsystem: "org.solpbc.solstone-swift", category: "voice")
        guard let url = VoiceServerURL.url(
            localPort: localPort,
            path: "/api/voice/nav-hints",
            queryItems: [URLQueryItem(name: "call_id", value: callId)]
        ) else {
            log.debug("[solstone-swift] nav hints skipped: invalid URL")
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                log.debug("[solstone-swift] nav hints unavailable: HTTP \(status)")
                return []
            }

            let hints = try JSONDecoder().decode(NavHintResponse.self, from: data).hints
            return hints
        } catch {
            log.debug("[solstone-swift] nav hints unavailable: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}

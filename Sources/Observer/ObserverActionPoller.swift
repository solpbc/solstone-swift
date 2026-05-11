// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private nonisolated struct ObserverActionResponse: Decodable {
    let actions: [Payload]
    let consumed: Bool

    struct Payload: Decodable {
        let type: String
        let mode: ObserverMode?
    }
}

nonisolated struct ObserverActionPoller: ObserverActionPolling {
    func fetchActions(localPort: Int, callId: String) async -> [ObserverAction] {
        let log = Logger(subsystem: "app.solstone.swift", category: "observer-actions")
        guard let url = VoiceServerURL.url(
            localPort: localPort,
            path: "/api/voice/observer-actions",
            queryItems: [URLQueryItem(name: "call_id", value: callId)]
        ) else {
            log.debug("observer actions skipped: invalid URL")
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                log.debug("observer actions unavailable: HTTP \(status, privacy: .public)")
                return []
            }

            let payload = try JSONDecoder().decode(ObserverActionResponse.self, from: data)
            return payload.actions.compactMap { action in
                switch action.type {
                case "start_observer":
                    guard let mode = action.mode else {
                        log.debug("observer action dropped: missing mode")
                        return nil
                    }
                    return .startObserver(mode: mode)
                default:
                    log.debug("observer action dropped: unknown type \(action.type, privacy: .public)")
                    return nil
                }
            }
        } catch {
            log.debug("observer actions unavailable: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}

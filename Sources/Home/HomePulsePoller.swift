// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private nonisolated struct HomePulseResponse: Decodable {
    let journalAgeDays: Int?
    let homeState: String?
    let welcomeFraming: String?

    enum CodingKeys: String, CodingKey {
        case journalAgeDays = "journal_age_days"
        case homeState = "home_state"
        case welcomeFraming = "welcome_framing"
    }
}

nonisolated struct HomePulsePoller {
    func fetch(localPort: Int) async -> String? {
        let log = Logger(subsystem: "app.solstone.swift", category: "home")
        guard let url = ConveyURL.url(localPort: localPort, path: "/app/home/api/pulse") else {
            log.debug("[solstone-swift] home pulse skipped: invalid URL")
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                log.debug("[solstone-swift] home pulse unavailable: HTTP \(status)")
                return nil
            }
            let decoded = try JSONDecoder().decode(HomePulseResponse.self, from: data)
            guard let framing = decoded.welcomeFraming?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !framing.isEmpty
            else {
                return nil
            }
            return framing
        } catch {
            log.debug("[solstone-swift] home pulse unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

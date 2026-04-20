// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let log = Logger(subsystem: "org.solpbc.solstone-swift", category: "voice")

nonisolated struct SidebandNotifier: SidebandNotifying {
    func notify(callId: String, localPort: Int) async {
        guard let url = URL(string: "http://127.0.0.1:\(localPort)/api/voice/connect") else {
            log.error("[solstone-swift] invalid sideband URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(["call_id": callId])
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300 ~= http.statusCode) {
                log.error("[solstone-swift] sideband notify failed: HTTP \(http.statusCode)")
            }
        } catch {
            log.error("[solstone-swift] sideband notify failed: \(String(describing: error))")
        }
    }
}

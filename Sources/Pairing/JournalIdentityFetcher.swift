// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private nonisolated struct JournalIdentityResponse: Decodable {
    let committed: Bool
    let instanceID: String?
    let mark: JournalMark?

    enum CodingKeys: String, CodingKey {
        case committed
        case instanceID = "instance_id"
        case mark
    }
}

nonisolated struct JournalIdentityFetcher {
    func fetch(localPort: Int) async -> JournalMark? {
        let log = Logger(subsystem: "app.solstone.swift", category: "journal-mark")
        guard let url = ConveyURL.url(localPort: localPort, path: "/app/link/api/identity") else {
            log.debug("[solstone-swift] journal mark skipped: invalid URL")
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                log.debug("[solstone-swift] journal mark unavailable: HTTP \(status)")
                return nil
            }
            let decoded = try JSONDecoder().decode(JournalIdentityResponse.self, from: data)
            guard decoded.committed,
                  let mark = decoded.mark,
                  let valid = JournalMark.validate(mark)
            else {
                log.debug("[solstone-swift] journal mark unavailable: uncommitted, missing, or invalid")
                return nil
            }
            return valid
        } catch is CancellationError {
            log.debug("[solstone-swift] journal mark cancelled")
            return nil
        } catch {
            log.debug("[solstone-swift] journal mark unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

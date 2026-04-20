// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct EphemeralKeyFetcher: EphemeralKeyFetching {
    func fetchKey(localPort: Int) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:\(localPort)/api/voice/session") else {
            throw FetchError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let response = response as? HTTPURLResponse, 200..<300 ~= response.statusCode else {
            throw FetchError.invalidResponse
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(EphemeralKeyResponse.self, from: data).ephemeralKey
    }
}

private extension EphemeralKeyFetcher {
    enum FetchError: Error {
        case invalidRequest
        case invalidResponse
    }

    struct EphemeralKeyResponse: Decodable {
        let ephemeralKey: String
    }
}

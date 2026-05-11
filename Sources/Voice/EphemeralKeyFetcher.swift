// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

private nonisolated struct EphemeralKeyResponse: Decodable {
    let ephemeralKey: String
}

private nonisolated struct ServerErrorResponse: Decodable {
    let error: String
}

nonisolated struct EphemeralKeyFetcher: EphemeralKeyFetching {
    func fetchKey(localPort: Int) async throws -> String {
        guard let url = VoiceServerURL.url(localPort: localPort, path: "/api/voice/session") else {
            throw FetchError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let response = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }

        guard 200..<300 ~= response.statusCode else {
            if let serverError = try? JSONDecoder().decode(ServerErrorResponse.self, from: data).error,
               !serverError.isEmpty
            {
                throw VoiceError.ephemeralKeyFailed(serverError)
            }
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
}

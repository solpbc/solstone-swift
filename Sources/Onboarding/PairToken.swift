// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum PairTokenError: LocalizedError, Equatable {
    case invalidURL
    case invalidScheme
    case invalidHost
    case missingToken
    case missingHost

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "invalid pairing URL."
        case .invalidScheme:
            "pairing URL must start with solstone://."
        case .invalidHost:
            "pairing URL must target solstone://pair."
        case .missingToken:
            "pairing URL is missing its token."
        case .missingHost:
            "pairing URL is missing its host."
        }
    }
}

struct PairToken: Equatable, Sendable {
    let token: String
    let host: URL

    static func parse(_ rawValue: String) throws -> PairToken {
        guard let components = URLComponents(string: rawValue) else {
            throw PairTokenError.invalidURL
        }
        guard components.scheme == "solstone" else {
            throw PairTokenError.invalidScheme
        }
        guard components.host == "pair" else {
            throw PairTokenError.invalidHost
        }

        let queryItems = components.queryItems ?? []
        guard let token = queryItems.first(where: { $0.name == "token" })?.value,
              !token.isEmpty
        else {
            throw PairTokenError.missingToken
        }
        guard let hostValue = queryItems.first(where: { $0.name == "host" })?.value,
              let host = URL(string: hostValue)
        else {
            throw PairTokenError.missingHost
        }

        return PairToken(token: token, host: host)
    }
}

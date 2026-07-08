// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated protocol TransferEndpointResolver: Sendable {
    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution
}

nonisolated enum TransferEndpointResolution: Equatable, Sendable {
    case available(TransferResolvedEndpoint)
    case unavailable(String)
}

nonisolated struct TransferResolvedEndpoint: Equatable, Sendable {
    var baseURL: URL
    var port: Int?
    var detail: String?

    init(baseURL: URL, port: Int? = nil, detail: String? = nil) {
        self.baseURL = baseURL
        self.port = port
        self.detail = detail
    }

    func url(path: String) -> URL? {
        guard var components = URLComponents(url: self.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        return components.url
    }
}

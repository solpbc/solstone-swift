// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated protocol TransferEndpointResolver: Sendable {
    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution
    func isCurrent(_ endpoint: TransferResolvedEndpoint) async -> Bool
    func startRequest(
        _ endpoint: TransferResolvedEndpoint,
        start: @Sendable () -> Void
    ) async -> Bool
}

extension TransferEndpointResolver {
    func isCurrent(_ endpoint: TransferResolvedEndpoint) async -> Bool { true }

    func startRequest(
        _ endpoint: TransferResolvedEndpoint,
        start: @Sendable () -> Void
    ) async -> Bool {
        guard await self.isCurrent(endpoint) else { return false }
        start()
        return true
    }
}

nonisolated enum TransferEndpointResolution: Equatable, Sendable {
    case available(TransferResolvedEndpoint)
    case unavailable(String)
}

nonisolated struct TransferResolvedEndpoint: Equatable, Sendable {
    var baseURL: URL
    var port: Int?
    var detail: String?
    var dispatchOwner: TransferDispatchOwner?

    init(
        baseURL: URL,
        port: Int? = nil,
        detail: String? = nil,
        dispatchOwner: TransferDispatchOwner? = nil
    ) {
        self.baseURL = baseURL
        self.port = port
        self.detail = detail
        self.dispatchOwner = dispatchOwner
    }

    func url(path: String) -> URL? {
        guard var components = URLComponents(url: self.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        return components.url
    }
}

nonisolated struct TransferDispatchOwner: Equatable, Sendable {
    let pairingGeneration: UInt64
    let ownerID: UUID
    let credentialCID: String
    var admissionGeneration: UInt64 = 0
}

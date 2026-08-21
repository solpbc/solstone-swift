// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated final class TransferTransport: @unchecked Sendable {
    private let session: URLSession

    init(sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        sessionConfiguration.timeoutIntervalForRequest = 60
        sessionConfiguration.timeoutIntervalForResource = 30 * 60
        self.session = URLSession(configuration: sessionConfiguration)
    }

    func send(
        item: TransferStoredItem,
        bodyURL: URL,
        endpoint: TransferResolvedEndpoint,
        phase: TransferEndpointPhase
    ) async -> TransferHTTPResult {
        let path: String
        switch phase {
        case .observerIngest, .save:
            path = item.manifest.endpoint.path
        case .start:
            path = item.manifest.endpoint.startPath ?? item.manifest.endpoint.path
        }
        guard let url = endpoint.url(path: path) else {
            return TransferHTTPResult(statusCode: nil, issue: .transport("invalid url"))
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            switch phase {
            case .observerIngest:
                request.setValue(
                    "multipart/form-data; boundary=\(Self.boundary(for: item.manifest.itemID))",
                    forHTTPHeaderField: "Content-Type"
                )
                request.setValue(
                    ObserverServerURL.ingestProtocolVersion,
                    forHTTPHeaderField: ObserverServerURL.protocolVersionHeaderName
                )
            case .save:
                request.setValue(
                    "multipart/form-data; boundary=\(Self.boundary(for: item.manifest.itemID))",
                    forHTTPHeaderField: "Content-Type"
                )
            case .start:
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let (data, response) = try await self.session.upload(for: request, fromFile: bodyURL)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            return TransferHTTPResult(statusCode: statusCode, data: data)
        } catch {
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut:
                    return TransferHTTPResult(statusCode: nil, issue: .timeout)
                case .cancelled:
                    return TransferHTTPResult(statusCode: nil, issue: .cancelled)
                default:
                    return TransferHTTPResult(statusCode: nil, issue: .transport(urlError.localizedDescription))
                }
            }
            if error is CancellationError {
                return TransferHTTPResult(statusCode: nil, issue: .cancelled)
            }
            return TransferHTTPResult(statusCode: nil, issue: .transport(String(describing: error)))
        }
    }

    static func boundary(for itemID: UUID) -> String {
        "Boundary-\(itemID.uuidString)"
    }
}

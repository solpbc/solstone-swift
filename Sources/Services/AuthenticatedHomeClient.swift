// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated final class JournalVersionRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

nonisolated struct ClientsSelfReported: Codable, Equatable, Sendable {
    let name: String?
    let platform: String?
    let deviceType: String?
    let appID: String?
    let appVersion: String?

    enum CodingKeys: String, CodingKey {
        case name
        case platform
        case deviceType = "device_type"
        case appID = "app_id"
        case appVersion = "app_version"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.platform, forKey: .platform)
        try container.encode(self.deviceType, forKey: .deviceType)
        try container.encode(self.appID, forKey: .appID)
        try container.encode(self.appVersion, forKey: .appVersion)
    }
}

nonisolated struct ClientsSelfJournal: Codable, Equatable, Sendable {
    let name: String?
    let version: String?
}

nonisolated struct ClientsSelfResource: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let revision: Int
    let reported: ClientsSelfReported?
    let ownerLabel: String?
    let displayLabel: String?
    let updatedAt: String?
    let journal: ClientsSelfJournal?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case revision
        case reported
        case ownerLabel = "owner_label"
        case displayLabel = "display_label"
        case updatedAt = "updated_at"
        case journal
    }
}

nonisolated struct ClientsSelfPutPayload: Encodable, Sendable {
    let protocolVersion: Int = 1
    let expectedRevision: Int
    let reported: ClientsSelfReported

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case expectedRevision = "expected_revision"
        case reported
    }
}

nonisolated enum ClientsSelfFetchResult: Sendable, Equatable {
    case success(ClientsSelfResource)
    case notFound
    case unsupported
    case conflict(Int?)
    case malformedOrFailed
}

nonisolated enum ClientsSelfPutResult: Sendable, Equatable {
    case success
    case conflict
    case notFound
    case failed
}

nonisolated struct RelayAccessReadyPayload: Decodable, Sendable, Equatable {
    let protocolVersion: Int
    let status: String
    let relayOrigin: String
    let instanceID: String
    let deviceToken: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case status
        case relayOrigin = "relay_origin"
        case instanceID = "instance_id"
        case deviceToken = "device_token"
        case expiresAt = "expires_at"
    }
}

nonisolated enum RelayAccessFetchResult: Sendable, Equatable {
    case ready(RelayAccessReadyPayload)
    case notConfigured
    case unavailable(Int)
    case notFound
    case malformedOrFailed
}

nonisolated final class AuthenticatedHomeClient: Sendable {
    private static let maxBodyBytes = 65_536

    private static func timeInterval(for duration: Duration) -> TimeInterval {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
        return max(0.05, seconds)
    }

    public static let defaultSessionFactory: @Sendable (Duration) -> URLSession = { timeout in
        let configuration = URLSessionConfiguration.ephemeral
        let interval = AuthenticatedHomeClient.timeInterval(for: timeout)
        configuration.timeoutIntervalForRequest = interval
        configuration.timeoutIntervalForResource = interval
        configuration.connectionProxyDictionary = [:]
        return URLSession(
            configuration: configuration,
            delegate: JournalVersionRedirectDelegate(),
            delegateQueue: nil
        )
    }

    private let sessionFactory: @Sendable (Duration) -> URLSession

    init(sessionFactory: (@Sendable (Duration) -> URLSession)? = nil) {
        self.sessionFactory = sessionFactory ?? Self.defaultSessionFactory
    }

    func fetchStatus(localPort: Int, timeout: Duration = .seconds(5)) async -> String? {
        guard (1...65535).contains(localPort),
              let url = URL(string: "http://127.0.0.1:\(localPort)/api/system/status") else { return nil }
        let session = self.sessionFactory(timeout)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeInterval(for: timeout))
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= Self.maxBodyBytes,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let status = try? JSONDecoder().decode(StatusEnvelope.self, from: data) else {
                return nil
            }
            return sanitizedJournalVersion(status.version.current)
        } catch {
            return nil
        }
    }

    func fetchClientsSelf(localPort: Int, timeout: Duration = .seconds(5)) async -> ClientsSelfFetchResult {
        guard (1...65535).contains(localPort),
              let url = URL(string: "http://127.0.0.1:\(localPort)/app/network/api/clients/self") else {
            return .malformedOrFailed
        }
        let session = self.sessionFactory(timeout)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeInterval(for: timeout))
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= Self.maxBodyBytes,
                  let httpResponse = response as? HTTPURLResponse else {
                return .malformedOrFailed
            }
            if httpResponse.statusCode == 200 {
                guard let resource = try? JSONDecoder().decode(ClientsSelfResource.self, from: data),
                      resource.protocolVersion == 1,
                      resource.revision >= 0 else {
                    return .malformedOrFailed
                }
                return .success(resource)
            } else if httpResponse.statusCode == 404 {
                return .notFound
            } else if httpResponse.statusCode == 409 {
                let revision = (try? JSONDecoder().decode(RevisionContainer.self, from: data))?.revision
                return .conflict(revision)
            } else if httpResponse.statusCode == 501 || httpResponse.statusCode == 400 {
                return .unsupported
            } else {
                return .malformedOrFailed
            }
        } catch {
            return .malformedOrFailed
        }
    }

    func putClientsSelf(localPort: Int, payload: ClientsSelfPutPayload, timeout: Duration = .seconds(5)) async -> ClientsSelfPutResult {
        guard (1...65535).contains(localPort),
              let url = URL(string: "http://127.0.0.1:\(localPort)/app/network/api/clients/self") else {
            return .failed
        }
        let session = self.sessionFactory(timeout)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeInterval(for: timeout))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let encoded = try? JSONEncoder().encode(payload) else {
            return .failed
        }
        request.httpBody = encoded
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= Self.maxBodyBytes,
                  let httpResponse = response as? HTTPURLResponse else {
                return .failed
            }
            if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 {
                return .success
            } else if httpResponse.statusCode == 409 {
                return .conflict
            } else if httpResponse.statusCode == 404 {
                return .notFound
            } else {
                return .failed
            }
        } catch {
            return .failed
        }
    }

    func fetchRelayAccess(localPort: Int, timeout: Duration = .seconds(5)) async -> RelayAccessFetchResult {
        guard (1...65535).contains(localPort),
              let url = URL(string: "http://127.0.0.1:\(localPort)/app/network/api/relay/access") else {
            return .malformedOrFailed
        }
        let session = self.sessionFactory(timeout)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeInterval(for: timeout))
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= Self.maxBodyBytes,
                  let httpResponse = response as? HTTPURLResponse else {
                return .malformedOrFailed
            }
            if httpResponse.statusCode == 200 {
                guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .malformedOrFailed
                }
                guard let protocolVersion = jsonObject["protocol_version"] as? Int, protocolVersion == 2,
                      let status = jsonObject["status"] as? String else {
                    return .malformedOrFailed
                }
                if status == "ready" {
                    guard let ready = try? JSONDecoder().decode(RelayAccessReadyPayload.self, from: data) else {
                        return .malformedOrFailed
                    }
                    return .ready(ready)
                } else if status == "not_configured" {
                    // Exact match: only protocol_version and status keys allowed
                    let keys = Set(jsonObject.keys)
                    guard keys == Set(["protocol_version", "status"]) else {
                        return .malformedOrFailed
                    }
                    return .notConfigured
                } else {
                    return .malformedOrFailed
                }
            } else if httpResponse.statusCode == 503 {
                return .unavailable(503)
            } else if httpResponse.statusCode == 404 {
                return .notFound
            } else {
                return .malformedOrFailed
            }
        } catch {
            return .malformedOrFailed
        }
    }

    private struct StatusEnvelope: Decodable {
        struct Version: Decodable { let current: String }
        let version: Version
    }

    private struct RevisionContainer: Decodable {
        let revision: Int?
    }
}

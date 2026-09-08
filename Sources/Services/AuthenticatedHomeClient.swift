// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

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

    init(name: String? = nil, platform: String? = nil, deviceType: String? = nil, appID: String? = nil, appVersion: String? = nil) {
        self.name = name
        self.platform = platform
        self.deviceType = deviceType
        self.appID = appID
        self.appVersion = appVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.name),
              container.contains(.platform),
              container.contains(.deviceType),
              container.contains(.appID),
              container.contains(.appVersion) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing required key in reported object"))
        }
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.platform = try container.decodeIfPresent(String.self, forKey: .platform)
        self.deviceType = try container.decodeIfPresent(String.self, forKey: .deviceType)
        self.appID = try container.decodeIfPresent(String.self, forKey: .appID)
        self.appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
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
    let version: String

    enum CodingKeys: String, CodingKey {
        case name
        case version
    }

    init(name: String?, version: String) {
        self.name = name
        self.version = version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.name), container.contains(.version) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing required key in journal object"))
        }
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.version = try container.decode(String.self, forKey: .version)
    }
}

nonisolated struct ClientsSelfResource: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let revision: UInt64
    let reported: ClientsSelfReported?
    let ownerLabel: String?
    let displayLabel: String
    let updatedAt: String?
    let journal: ClientsSelfJournal

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case revision
        case reported
        case ownerLabel = "owner_label"
        case displayLabel = "display_label"
        case updatedAt = "updated_at"
        case journal
    }

    init(
        protocolVersion: Int = 1,
        revision: UInt64,
        reported: ClientsSelfReported?,
        ownerLabel: String?,
        displayLabel: String,
        updatedAt: String?,
        journal: ClientsSelfJournal
    ) {
        self.protocolVersion = protocolVersion
        self.revision = revision
        self.reported = reported
        self.ownerLabel = ownerLabel
        self.displayLabel = displayLabel
        self.updatedAt = updatedAt
        self.journal = journal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.protocolVersion),
              container.contains(.revision),
              container.contains(.reported),
              container.contains(.ownerLabel),
              container.contains(.displayLabel),
              container.contains(.updatedAt),
              container.contains(.journal) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing required key in ClientsSelfResource"))
        }
        self.protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        guard self.protocolVersion == 1 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "protocol_version must be 1"))
        }
        self.revision = try container.decode(UInt64.self, forKey: .revision)
        self.reported = try container.decodeIfPresent(ClientsSelfReported.self, forKey: .reported)
        self.ownerLabel = try container.decodeIfPresent(String.self, forKey: .ownerLabel)
        self.displayLabel = try container.decode(String.self, forKey: .displayLabel)
        self.updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        self.journal = try container.decode(ClientsSelfJournal.self, forKey: .journal)
    }
}

nonisolated struct ClientsSelfPutPayload: Encodable, Sendable {
    let protocolVersion: Int = 1
    let expectedRevision: UInt64
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
    case conflict(UInt64?)
    case malformedOrFailed
}

nonisolated enum ClientsSelfPutResult: Sendable, Equatable {
    case success(ClientsSelfResource)
    case conflict
    case notFound
    case failed
}

nonisolated enum RelayAccessFetchResult: Sendable, Equatable {
    case ready(ReadyRelayAccess)
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

    private static func fetchCappedData(for request: URLRequest, in session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let (asyncBytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            asyncBytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        var data = Data()
        data.reserveCapacity(min(4096, maxBodyBytes))
        do {
            for try await byte in asyncBytes {
                data.append(byte)
                if data.count > maxBodyBytes {
                    asyncBytes.task.cancel()
                    throw URLError(.dataLengthExceedsMaximum)
                }
            }
        } catch {
            asyncBytes.task.cancel()
            throw error
        }
        return (data, httpResponse)
    }

    func fetchStatus(localPort: Int, timeout: Duration = .seconds(5)) async -> String? {
        guard (1...65535).contains(localPort),
              let url = URL(string: "http://127.0.0.1:\(localPort)/api/system/status") else { return nil }
        let session = self.sessionFactory(timeout)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeInterval(for: timeout))
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, httpResponse) = try await Self.fetchCappedData(for: request, in: session)
            guard httpResponse.statusCode == 200,
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
            let (data, httpResponse) = try await Self.fetchCappedData(for: request, in: session)
            if httpResponse.statusCode == 200 {
                guard let resource = try? JSONDecoder().decode(ClientsSelfResource.self, from: data) else {
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
            let (data, httpResponse) = try await Self.fetchCappedData(for: request, in: session)
            if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 {
                guard let resource = try? JSONDecoder().decode(ClientsSelfResource.self, from: data) else {
                    return .failed
                }
                return .success(resource)
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

    func fetchRelayAccess(
        localPort: Int,
        expectedInstanceID: String,
        now: Date = Date(),
        timeout: Duration = .seconds(5)
    ) async -> RelayAccessFetchResult {
        guard (1...65535).contains(localPort),
              let url = URL(string: "http://127.0.0.1:\(localPort)/app/network/api/relay/access") else {
            return .malformedOrFailed
        }
        let session = self.sessionFactory(timeout)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeInterval(for: timeout))
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, httpResponse) = try await Self.fetchCappedData(for: request, in: session)
            if httpResponse.statusCode == 200 {
                do {
                    let status = try RelayAccessValidation.decode(data, expectedInstanceID: expectedInstanceID, now: now)
                    switch status {
                    case .ready(let ready):
                        return .ready(ready)
                    case .notConfigured:
                        return .notConfigured
                    }
                } catch {
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
        let revision: UInt64?
    }
}


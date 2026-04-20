// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let pairingLog = Logger(subsystem: "org.solpbc.solstone-swift", category: "pairing")

@MainActor
protocol PairingClient: AnyObject, Sendable {
    func confirm(
        token: String,
        publicKey: String,
        deviceName: String,
        platform: String,
        bundleID: String,
        appVersion: String
    ) async throws -> PairConfirmResponse
    func unpair(deviceID: String, sessionKey: String) async throws
    func setBriefingTime(hour: Int, minute: Int, tzIdentifier: String, sessionKey: String) async throws
    func progressToday(sessionKey: String) async throws -> ProgressSnapshot
}

enum PairingClientError: Error, Equatable {
    case invalidToken
    case expiredToken
    case network
    case server(status: Int, body: String)
    case decoding
    case missingPairingHost
    case missingJournalRoot
}

struct PairConfirmResponse: Equatable, Sendable {
    let sessionKey: String
    let deviceID: String
    let journalRoot: String
    let ownerIdentity: String
    let serverVersion: String?
    let host: String
    let port: Int

    init(
        sessionKey: String,
        deviceID: String,
        journalRoot: String,
        ownerIdentity: String,
        serverVersion: String?,
        host: String,
        port: Int
    ) {
        self.sessionKey = sessionKey
        self.deviceID = deviceID
        self.journalRoot = journalRoot
        self.ownerIdentity = ownerIdentity
        self.serverVersion = serverVersion
        self.host = host
        self.port = port
    }
}

struct ProgressSnapshot: Decodable, Equatable, Sendable {
    let segmentsObserved: Int
    let meetingsDetected: Int
    let entitiesIdentified: Int
    let percent: Int
    let briefingReady: Bool?

    init(
        segmentsObserved: Int,
        meetingsDetected: Int,
        entitiesIdentified: Int,
        percent: Int,
        briefingReady: Bool? = nil
    ) {
        self.segmentsObserved = segmentsObserved
        self.meetingsDetected = meetingsDetected
        self.entitiesIdentified = entitiesIdentified
        self.percent = percent
        self.briefingReady = briefingReady
    }

    private enum CodingKeys: String, CodingKey {
        case segmentsObserved = "segments_observed"
        case meetingsDetected = "meetings_detected"
        case entitiesIdentified = "entities_identified"
        case percent
        case briefingReady = "briefing_ready"
        case hasBriefing = "has_briefing"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.segmentsObserved = try container.decode(Int.self, forKey: .segmentsObserved)
        self.meetingsDetected = try container.decode(Int.self, forKey: .meetingsDetected)
        self.entitiesIdentified = try container.decode(Int.self, forKey: .entitiesIdentified)
        self.percent = try container.decode(Int.self, forKey: .percent)
        self.briefingReady = try container.decodeIfPresent(Bool.self, forKey: .briefingReady)
            ?? container.decodeIfPresent(Bool.self, forKey: .hasBriefing)
    }
}

@MainActor
final class LivePairingClient: PairingClient {
    private struct PairConfirmPayload: Decodable {
        let sessionKey: String
        let deviceID: String
        let journalRoot: String
        let ownerIdentity: String
        let serverVersion: String?

        enum CodingKeys: String, CodingKey {
            case sessionKey = "session_key"
            case deviceID = "device_id"
            case journalRoot = "journal_root"
            case ownerIdentity = "owner_identity"
            case serverVersion = "server_version"
        }
    }

    private struct ConfirmRequest: Encodable {
        let token: String
        let publicKey: String
        let deviceName: String
        let platform: String
        let bundleID: String
        let appVersion: String

        enum CodingKeys: String, CodingKey {
            case token
            case publicKey = "public_key"
            case deviceName = "device_name"
            case platform
            case bundleID = "bundle_id"
            case appVersion = "app_version"
        }
    }

    private struct BriefingRequest: Encodable {
        let hour: Int
        let minute: Int
        let tzIdentifier: String

        enum CodingKeys: String, CodingKey {
            case hour
            case minute
            case tzIdentifier = "tz_identifier"
        }
    }

    private let session: URLSession
    private let retryDelays: [UInt64]
    private let sleep: @Sendable (UInt64) async -> Void
    private let journalRootProvider: @Sendable () -> String
    private var pairingHost: URL?

    init(
        session: URLSession = .shared,
        retryDelays: [UInt64] = [2_000_000_000, 4_000_000_000, 8_000_000_000],
        sleep: @escaping @Sendable (UInt64) async -> Void = { delay in try? await Task.sleep(nanoseconds: delay) },
        journalRootProvider: @escaping @Sendable () -> String
    ) {
        self.session = session
        self.retryDelays = retryDelays
        self.sleep = sleep
        self.journalRootProvider = journalRootProvider
    }

    func setPairingHost(_ url: URL) {
        self.pairingHost = url
    }

    func confirm(
        token: String,
        publicKey: String,
        deviceName: String,
        platform: String,
        bundleID: String,
        appVersion: String
    ) async throws -> PairConfirmResponse {
        guard let pairingHost = self.pairingHost else {
            throw PairingClientError.missingPairingHost
        }
        let url = try Self.endpointURL(base: pairingHost, path: "/api/pairing/confirm")
        let payload = ConfirmRequest(
            token: token,
            publicKey: publicKey,
            deviceName: deviceName,
            platform: platform,
            bundleID: bundleID,
            appVersion: appVersion
        )
        let data = try await self.perform(
            url: url,
            method: "POST",
            sessionKey: nil,
            body: try JSONEncoder().encode(payload),
            retryable: true
        )

        do {
            let decoded = try JSONDecoder().decode(PairConfirmPayload.self, from: data)
            return PairConfirmResponse(
                sessionKey: decoded.sessionKey,
                deviceID: decoded.deviceID,
                journalRoot: decoded.journalRoot,
                ownerIdentity: decoded.ownerIdentity,
                serverVersion: decoded.serverVersion,
                host: pairingHost.host ?? "",
                port: pairingHost.port ?? 22
            )
        } catch {
            pairingLog.error("pair confirm decode failed: \(String(describing: error), privacy: .public)")
            throw PairingClientError.decoding
        }
    }

    func unpair(deviceID: String, sessionKey: String) async throws {
        let base = try self.requireJournalRoot()
        let url = try Self.endpointURL(base: base, path: "/api/pairing/devices/\(deviceID)")
        _ = try await self.perform(url: url, method: "DELETE", sessionKey: sessionKey, body: nil, retryable: false)
    }

    func setBriefingTime(hour: Int, minute: Int, tzIdentifier: String, sessionKey: String) async throws {
        let base = try self.requireJournalRoot()
        let url = try Self.endpointURL(base: base, path: "/api/settings/briefing-time")
        let payload = BriefingRequest(hour: hour, minute: minute, tzIdentifier: tzIdentifier)
        _ = try await self.perform(
            url: url,
            method: "PUT",
            sessionKey: sessionKey,
            body: try JSONEncoder().encode(payload),
            retryable: true
        )
    }

    func progressToday(sessionKey: String) async throws -> ProgressSnapshot {
        let base = try self.requireJournalRoot()
        let url = try Self.endpointURL(base: base, path: "/api/home/progress-today")
        let data = try await self.perform(url: url, method: "GET", sessionKey: sessionKey, body: nil, retryable: false)

        do {
            return try JSONDecoder().decode(ProgressSnapshot.self, from: data)
        } catch {
            pairingLog.error("progress decode failed: \(String(describing: error), privacy: .public)")
            throw PairingClientError.decoding
        }
    }

    private func requireJournalRoot() throws -> URL {
        guard let url = URL(string: self.journalRootProvider()), !self.journalRootProvider().isEmpty else {
            throw PairingClientError.missingJournalRoot
        }
        return url
    }

    private func perform(
        url: URL,
        method: String,
        sessionKey: String?,
        body: Data?,
        retryable: Bool
    ) async throws -> Data {
        var lastError: PairingClientError = .network

        for attempt in 0...self.retryDelays.count {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if let sessionKey {
                    request.setValue("Bearer \(sessionKey)", forHTTPHeaderField: "Authorization")
                }
                request.httpBody = body

                let (data, response) = try await self.session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw PairingClientError.network
                }
                guard 200..<300 ~= http.statusCode else {
                    let error = Self.classify(statusCode: http.statusCode, body: data)
                    if retryable,
                       case .server(let status, _) = error,
                       (500..<600).contains(status),
                       attempt < self.retryDelays.count
                    {
                        await self.sleep(self.retryDelays[attempt])
                        lastError = error
                        continue
                    }
                    throw error
                }
                return data
            } catch let error as PairingClientError {
                if retryable,
                   error == .network,
                   attempt < self.retryDelays.count
                {
                    await self.sleep(self.retryDelays[attempt])
                    lastError = error
                    continue
                }
                throw error
            } catch {
                if retryable, attempt < self.retryDelays.count {
                    await self.sleep(self.retryDelays[attempt])
                    lastError = .network
                    continue
                }
                throw PairingClientError.network
            }
        }

        throw lastError
    }

    private static func endpointURL(base: URL, path: String) throws -> URL {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw PairingClientError.network
        }
        return url
    }

    private static func classify(statusCode: Int, body: Data) -> PairingClientError {
        let bodyText = String(data: body, encoding: .utf8) ?? ""
        let lowered = bodyText.lowercased()
        if statusCode == 404 || statusCode == 410 || lowered.contains("expired") {
            return .expiredToken
        }
        if statusCode == 400 || statusCode == 401 || lowered.contains("invalid") {
            return .invalidToken
        }
        return .server(status: statusCode, body: bodyText)
    }
}

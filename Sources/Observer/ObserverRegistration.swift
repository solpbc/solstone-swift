// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let log = Logger(subsystem: "app.solstone.swift", category: "registration")

@MainActor
@Observable
final class ObserverRegistration {
    enum State: Equatable {
        case idle
        case registering
        case registered
        case failed(reason: String)
    }

    private struct RegistrationRequest: Encodable {
        let platform: String
        let hostname: String
        let streamType: String
        let version: String
        let label: String?

        enum CodingKeys: String, CodingKey {
            case platform
            case hostname
            case streamType = "stream_type"
            case version
            case label
        }
    }

    private struct RegistrationResponse: Decodable {
        let name: String
        let key: String
        let prefix: String
    }

    private(set) var state: State = .idle
    var activeLocalPort: Int?

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let urlBuilder: @Sendable (Int) -> URL?
    @ObservationIgnored private let hostname: String
    @ObservationIgnored private let version: String
    @ObservationIgnored private let streamType: String
    @ObservationIgnored private let label: String?
    @ObservationIgnored private let retryDelays: [UInt64]
    @ObservationIgnored private let sleep: @Sendable (UInt64) async -> Void
    @ObservationIgnored private let loadKey: @Sendable () throws -> String?
    @ObservationIgnored private let saveKey: @Sendable (String) throws -> Void
    @ObservationIgnored private let deleteKey: @Sendable () throws -> Void
    @ObservationIgnored private var registrationTask: Task<String, Error>?

    init(
        hostname: String,
        version: String,
        streamType: String = "mobile",
        label: String? = nil,
        session: URLSession = .shared,
        urlBuilder: @escaping @Sendable (Int) -> URL? = { ObserverServerURL.registrationURL(localPort: $0) },
        retryDelays: [UInt64] = [2_000_000_000, 4_000_000_000, 8_000_000_000, 16_000_000_000],
        sleep: @escaping @Sendable (UInt64) async -> Void = { delay in try? await Task.sleep(nanoseconds: delay) },
        loadKey: @escaping @Sendable () throws -> String? = { try ObserverKeychain.loadObserverIngestKey() },
        saveKey: @escaping @Sendable (String) throws -> Void = { try ObserverKeychain.saveObserverIngestKey($0) },
        deleteKey: @escaping @Sendable () throws -> Void = { try ObserverKeychain.deleteObserverIngestKey() }
    ) {
        self.session = session
        self.urlBuilder = urlBuilder
        self.hostname = hostname
        self.version = version
        self.streamType = streamType
        self.label = label
        self.retryDelays = retryDelays
        self.sleep = sleep
        self.loadKey = loadKey
        self.saveKey = saveKey
        self.deleteKey = deleteKey
        self.restorePersistedState()
    }

    func ensureRegistered() async throws -> String {
        if case .registered = self.state,
           let existing = try self.loadKey(),
           !existing.isEmpty
        {
            return existing
        }

        if let existing = try self.loadKey(), !existing.isEmpty {
            self.state = .registered
            return existing
        }

        if let registrationTask = self.registrationTask {
            return try await registrationTask.value
        }

        let registrationTask = Task { @MainActor in
            try await self.registerWithServer()
        }
        self.registrationTask = registrationTask

        do {
            let key = try await registrationTask.value
            self.registrationTask = nil
            return key
        } catch {
            self.registrationTask = nil
            throw error
        }
    }

    private func registerWithServer() async throws -> String {
        if let existing = try self.loadKey(), !existing.isEmpty {
            self.state = .registered
            return existing
        }

        guard let localPort = self.activeLocalPort else {
            let reason = "observer registration unavailable: missing active local port"
            self.state = .failed(reason: reason)
            throw ObserverRegistrationError.missingLocalPort
        }

        guard let url = self.urlBuilder(localPort) else {
            let reason = "observer registration unavailable: invalid url"
            self.state = .failed(reason: reason)
            throw ObserverRegistrationError.invalidURL
        }

        var lastError = "observer registration failed"
        for (index, delay) in self.retryDelays.enumerated() {
            try Task.checkCancellation()
            self.state = .registering

            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(RegistrationRequest(
                    platform: "ios",
                    hostname: self.hostname,
                    streamType: self.streamType,
                    version: self.version,
                    label: self.label
                ))

                let (data, response) = try await self.session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastError = "invalid response"
                    throw ObserverRegistrationError.invalidResponse
                }
                guard 200..<300 ~= http.statusCode else {
                    lastError = "HTTP \(http.statusCode)"
                    throw ObserverRegistrationError.http(http.statusCode)
                }

                let payload = try JSONDecoder().decode(RegistrationResponse.self, from: data)
                try self.saveKey(payload.key)
                self.state = .registered
                log.info("observer registration succeeded (key length=\(payload.key.count, privacy: .public))")
                return payload.key
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                if index == self.retryDelays.count - 1 {
                    break
                }
                log.debug("observer registration retry \(index + 1, privacy: .public)")
                await self.sleep(delay)
            }
        }

        self.state = .failed(reason: lastError)
        log.error("observer registration failed: \(lastError, privacy: .public)")
        throw ObserverRegistrationError.registrationFailed(lastError)
    }

    func reset() {
        do {
            self.registrationTask?.cancel()
            self.registrationTask = nil
            try self.deleteKey()
            self.state = .idle
            log.info("observer registration reset")
        } catch {
            let detail = error.localizedDescription
            self.state = .failed(reason: detail)
            log.error("observer registration reset failed: \(detail, privacy: .public)")
        }
    }
}

private extension ObserverRegistration {
    func restorePersistedState() {
        if let key = try? self.loadKey(), !key.isEmpty {
            self.state = .registered
        }
    }
}

enum ObserverRegistrationError: Error {
    case missingLocalPort
    case invalidURL
    case invalidResponse
    case http(Int)
    case registrationFailed(String)
}

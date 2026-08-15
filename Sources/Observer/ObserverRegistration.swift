// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let log = Logger(subsystem: "app.solstone.swift", category: "registration")

nonisolated enum ObserverRegistrationRefreshChange: Equatable, Sendable {
    case minted
    case replaced
    case confirmedCurrent
    case unchanged
}

nonisolated struct ObserverRegistrationRefreshResult: Equatable, Sendable {
    let key: String
    let change: ObserverRegistrationRefreshChange
}

@MainActor
@Observable
// Observer ingest keys are device-local registrations (keychain
// AfterFirstUnlockThisDeviceOnly, do not survive device restore) and serve as the
// per-physical-device marker. The SPL journal pairing is backup-migratable and is
// not reset on restore.
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

    private struct RegistrationErrorResponse: Decodable {
        let reasonCode: String?

        enum CodingKeys: String, CodingKey {
            case reasonCode = "reason_code"
        }
    }

    private enum RegistrationOperation: String, Sendable {
        case ensure
        case refresh
    }

    private struct RegistrationDiagnosticFailure: Sendable {
        let reason: String
        let httpStatus: Int?
        let reasonCode: String?
    }

    private struct RegistrationTaskResult: Sendable {
        let key: String
        let serverConfirmed: Bool
        let diagnosticFailure: RegistrationDiagnosticFailure?
    }

    private(set) var state: State = .idle
    private(set) var registrationPrefix: String?
    var activeLocalPort: Int?

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let urlBuilder: @Sendable (Int) -> URL?
    @ObservationIgnored private let resolveDescriptor: @MainActor @Sendable () -> DeviceRegistrationDescriptor?
    @ObservationIgnored let version: String
    @ObservationIgnored let streamType: String
    @ObservationIgnored private let diagnosticLog: DiagnosticLog?
    @ObservationIgnored private let retryDelays: [UInt64]
    @ObservationIgnored private let sleep: @Sendable (UInt64) async -> Void
    @ObservationIgnored private let loadKey: @Sendable () throws -> String?
    @ObservationIgnored private let saveKey: @Sendable (String) throws -> Void
    @ObservationIgnored private let deleteKey: @Sendable () throws -> Void
    @ObservationIgnored private let loadPrefix: @Sendable () throws -> String?
    @ObservationIgnored private let savePrefix: @Sendable (String) throws -> Void
    @ObservationIgnored private let deletePrefix: @Sendable () throws -> Void
    @ObservationIgnored private var registrationTask: Task<RegistrationTaskResult, Error>?

    init(
        resolveDescriptor: @escaping @MainActor @Sendable () -> DeviceRegistrationDescriptor?,
        version: String,
        streamType: String = "mobile",
        diagnosticLog: DiagnosticLog? = nil,
        session: URLSession = .shared,
        urlBuilder: @escaping @Sendable (Int) -> URL? = { ObserverServerURL.registrationURL(localPort: $0) },
        retryDelays: [UInt64] = [2_000_000_000, 4_000_000_000, 8_000_000_000, 16_000_000_000],
        sleep: @escaping @Sendable (UInt64) async -> Void = { delay in try? await Task.sleep(nanoseconds: delay) },
        loadKey: @escaping @Sendable () throws -> String? = { try ObserverKeychain.loadObserverIngestKey() },
        saveKey: @escaping @Sendable (String) throws -> Void = { try ObserverKeychain.saveObserverIngestKey($0) },
        deleteKey: @escaping @Sendable () throws -> Void = { try ObserverKeychain.deleteObserverIngestKey() },
        loadPrefix: @escaping @Sendable () throws -> String? = { IngestPrefixStore().load(.observer) },
        savePrefix: @escaping @Sendable (String) throws -> Void = { IngestPrefixStore().save($0, for: .observer) },
        deletePrefix: @escaping @Sendable () throws -> Void = { IngestPrefixStore().clear(.observer) }
    ) {
        self.session = session
        self.urlBuilder = urlBuilder
        self.resolveDescriptor = resolveDescriptor
        self.version = version
        self.streamType = streamType
        self.diagnosticLog = diagnosticLog
        self.retryDelays = retryDelays
        self.sleep = sleep
        self.loadKey = loadKey
        self.saveKey = saveKey
        self.deleteKey = deleteKey
        self.loadPrefix = loadPrefix
        self.savePrefix = savePrefix
        self.deletePrefix = deletePrefix
        self.restorePersistedState()
    }

    func ensureRegistered() async throws -> String {
        if case .registered = self.state,
           let existing = try self.loadKey(),
           !existing.isEmpty
        {
            self.restorePersistedPrefixIfNeeded()
            return existing
        }

        if let existing = try self.loadKey(), !existing.isEmpty {
            self.state = .registered
            self.restorePersistedPrefixIfNeeded()
            return existing
        }

        return try await self.runRegistrationTask(operation: .ensure) { descriptor in
            RegistrationTaskResult(
                key: try await self.mintRegistration(descriptor: descriptor),
                serverConfirmed: true,
                diagnosticFailure: nil
            )
        }.key
    }

    func refreshRegistration() async throws -> String {
        try await self.refreshRegistrationResult().key
    }

    func refreshRegistrationResult() async throws -> ObserverRegistrationRefreshResult {
        let cachedKey = try self.loadKey().flatMap { $0.isEmpty ? nil : $0 }

        let refresh = try await self.runRegistrationTask(operation: .refresh) { descriptor in
            try await self.refreshWithServer(cachedKey: cachedKey, descriptor: descriptor)
        }
        let change: ObserverRegistrationRefreshChange
        if let cachedKey {
            if refresh.key != cachedKey {
                change = .replaced
            } else {
                change = refresh.serverConfirmed ? .confirmedCurrent : .unchanged
            }
        } else {
            change = refresh.serverConfirmed ? .minted : .unchanged
        }
        return ObserverRegistrationRefreshResult(key: refresh.key, change: change)
    }

    func registeredHandle() -> String? {
        guard case .registered = self.state,
              let existing = try? self.loadKey(),
              !existing.isEmpty
        else {
            return nil
        }
        return existing
    }

    private func mintRegistration(descriptor: DeviceRegistrationDescriptor?) async throws -> String {
        self.state = .registering
        // With no local ingest key, any persisted prefix can only be a backup-restored stale
        // prefix; a real key would have taken ensureRegistered()'s fast path.
        try? self.deletePrefix()

        let payload: RegistrationResponse
        do {
            payload = try await self.requestRegistration(descriptor: descriptor)
        } catch {
            self.failRegistration(error)
            throw error
        }

        do {
            try self.savePrefix(payload.prefix)
        } catch {
            self.failRegistration(reason: "prefix cache save failed")
            throw error
        }

        do {
            try self.saveKey(payload.key)
        } catch {
            self.failRegistration(reason: "key commit save failed")
            throw error
        }

        self.registrationPrefix = payload.prefix
        self.state = .registered
        log.info("observer registration succeeded (key length=\(payload.key.count, privacy: .public))")
        return payload.key
    }

    private func refreshWithServer(
        cachedKey: String?,
        descriptor: DeviceRegistrationDescriptor?
    ) async throws -> RegistrationTaskResult {
        if cachedKey == nil {
            self.state = .registering
        }

        let payload: RegistrationResponse
        do {
            payload = try await self.requestRegistration(descriptor: descriptor)
        } catch {
            return try self.finishRefreshFailure(
                error,
                cachedKey: cachedKey,
                reason: self.failureReason(for: error)
            )
        }

        do {
            try self.saveKey(payload.key)
        } catch {
            return try self.finishRefreshFailure(
                error,
                cachedKey: cachedKey,
                reason: "key commit save failed"
            )
        }

        let committedKey: String?
        do {
            committedKey = try self.loadKey()
        } catch {
            return try self.finishRefreshFailure(
                error,
                cachedKey: cachedKey,
                reason: "key commit verification failed"
            )
        }

        guard let committedKey, !committedKey.isEmpty else {
            return try self.finishRefreshFailure(
                ObserverRegistrationError.keyCommitReadBackMismatch,
                cachedKey: cachedKey,
                reason: "key commit verification failed"
            )
        }

        if committedKey == payload.key {
            return RegistrationTaskResult(
                key: self.publishRefreshedRegistration(committedKey),
                serverConfirmed: true,
                diagnosticFailure: nil
            )
        }

        if committedKey == cachedKey {
            return try self.finishRefreshFailure(
                ObserverRegistrationError.keyCommitReadBackMismatch,
                cachedKey: cachedKey,
                reason: "key commit read-back mismatch"
            )
        }

        log.error(
            "observer registration refresh key commit read-back anomaly (key length=\(committedKey.count, privacy: .public))"
        )
        return RegistrationTaskResult(
            key: self.publishRefreshedRegistration(committedKey),
            serverConfirmed: true,
            diagnosticFailure: nil
        )
    }

    private func publishRefreshedRegistration(_ committedKey: String) -> String {
        // A keychain key that saved and read back is authoritative. The app-group
        // defaults prefix is a repairable cache, so refresh derives it from that key.
        let derivedPrefix = String(committedKey.prefix(8))
        do {
            try self.savePrefix(derivedPrefix)
        } catch {
            log.error("observer registration refresh prefix cache failed")
        }
        self.registrationPrefix = derivedPrefix
        self.state = .registered
        log.info("observer registration refresh succeeded (key length=\(committedKey.count, privacy: .public))")
        return committedKey
    }

    private func requestRegistration(
        descriptor: DeviceRegistrationDescriptor?
    ) async throws -> RegistrationResponse {
        guard let descriptor else {
            throw ObserverRegistrationError.missingVendorIdentifier
        }
        guard let localPort = self.activeLocalPort else {
            throw ObserverRegistrationError.missingLocalPort
        }

        guard let url = self.urlBuilder(localPort) else {
            throw ObserverRegistrationError.invalidURL
        }

        var terminalError: Error = ObserverRegistrationError.registrationFailed("observer registration failed")
        for (index, delay) in self.retryDelays.enumerated() {
            try Task.checkCancellation()

            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(RegistrationRequest(
                    platform: "ios",
                    hostname: descriptor.hostname,
                    streamType: self.streamType,
                    version: self.version,
                    label: descriptor.displayName
                ))

                let (data, response) = try await self.session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ObserverRegistrationError.invalidResponse
                }
                guard 200..<300 ~= http.statusCode else {
                    let decoded = try? JSONDecoder().decode(RegistrationErrorResponse.self, from: data)
                    throw ObserverRegistrationError.http(
                        http.statusCode,
                        reasonCode: Self.allowedReasonCode(decoded?.reasonCode)
                    )
                }

                guard !data.isEmpty else {
                    throw ObserverRegistrationError.emptyResponse
                }
                let payload: RegistrationResponse
                do {
                    payload = try JSONDecoder().decode(RegistrationResponse.self, from: data)
                } catch {
                    throw ObserverRegistrationError.invalidResponse
                }
                guard !payload.key.isEmpty else {
                    throw ObserverRegistrationError.emptyKey
                }
                return payload
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                if let registrationError = error as? ObserverRegistrationError {
                    terminalError = registrationError
                } else {
                    terminalError = ObserverRegistrationError.registrationFailed("transport error")
                }
                if index == self.retryDelays.count - 1 {
                    break
                }
                log.debug("observer registration retry \(index + 1, privacy: .public)")
                await self.sleep(delay)
            }
        }

        throw terminalError
    }

    func reset() {
        do {
            self.registrationTask?.cancel()
            self.registrationTask = nil
            try self.deleteKey()
            try self.deletePrefix()
            self.registrationPrefix = nil
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
    private func runRegistrationTask(
        operation: RegistrationOperation,
        _ body: @escaping @MainActor @Sendable (DeviceRegistrationDescriptor?) async throws -> RegistrationTaskResult
    ) async throws -> RegistrationTaskResult {
        if let registrationTask = self.registrationTask {
            return try await registrationTask.value
        }

        let registrationTask = Task { @MainActor in
            let descriptor = self.resolveDescriptor()
            do {
                let result = try await body(descriptor)
                self.emitRegistrationDiagnostic(
                    operation: operation,
                    descriptor: descriptor,
                    result: result
                )
                return result
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                self.emitRegistrationDiagnostic(
                    operation: operation,
                    descriptor: descriptor,
                    failure: Self.diagnosticFailure(for: error)
                )
                throw error
            }
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

    func failRegistration(_ error: Error) {
        self.failRegistration(reason: self.failureReason(for: error))
    }

    func failRegistration(reason: String) {
        self.state = .failed(reason: reason)
        log.error("observer registration failed: \(reason, privacy: .public)")
    }

    private func finishRefreshFailure(
        _ error: Error,
        cachedKey: String?,
        reason: String
    ) throws -> RegistrationTaskResult {
        if let cachedKey {
            self.logRefreshFailure(reason: reason)
            return RegistrationTaskResult(
                key: cachedKey,
                serverConfirmed: false,
                diagnosticFailure: Self.diagnosticFailure(for: error)
            )
        }
        self.failRegistration(reason: reason)
        throw error
    }

    func logRefreshFailure(reason: String) {
        log.error("observer registration refresh failed: \(reason, privacy: .public)")
    }

    func failureReason(for error: Error) -> String {
        switch error {
        case ObserverRegistrationError.missingVendorIdentifier:
            "observer registration unavailable: missing vendor identifier"
        case ObserverRegistrationError.missingLocalPort:
            "observer registration unavailable: missing active local port"
        case ObserverRegistrationError.invalidURL:
            "observer registration unavailable: invalid url"
        case ObserverRegistrationError.invalidResponse:
            "invalid response"
        case ObserverRegistrationError.emptyResponse:
            "empty response"
        case ObserverRegistrationError.emptyKey:
            "empty key"
        case ObserverRegistrationError.keyCommitReadBackMismatch:
            "key commit read-back mismatch"
        case ObserverRegistrationError.http(let status, _):
            "HTTP \(status)"
        case ObserverRegistrationError.registrationFailed(let reason):
            reason
        default:
            "unexpected registration error"
        }
    }

    private static func allowedReasonCode(_ value: String?) -> String? {
        guard let value,
              [
                  "invalid_segment_or_stream",
                  "local_request_only",
                  "missing_required_field",
                  "settings_operation_failed",
                  "pl_revoked",
              ].contains(value)
        else {
            return nil
        }
        return value
    }

    private static func diagnosticFailure(for error: Error) -> RegistrationDiagnosticFailure {
        switch error {
        case ObserverRegistrationError.missingVendorIdentifier:
            RegistrationDiagnosticFailure(reason: "missing_vendor_identifier", httpStatus: nil, reasonCode: nil)
        case ObserverRegistrationError.missingLocalPort:
            RegistrationDiagnosticFailure(reason: "missing_local_port", httpStatus: nil, reasonCode: nil)
        case ObserverRegistrationError.invalidURL:
            RegistrationDiagnosticFailure(reason: "invalid_url", httpStatus: nil, reasonCode: nil)
        case ObserverRegistrationError.invalidResponse:
            RegistrationDiagnosticFailure(reason: "invalid_response", httpStatus: nil, reasonCode: nil)
        case ObserverRegistrationError.emptyResponse:
            RegistrationDiagnosticFailure(reason: "empty_response", httpStatus: nil, reasonCode: nil)
        case ObserverRegistrationError.emptyKey:
            RegistrationDiagnosticFailure(reason: "empty_key", httpStatus: nil, reasonCode: nil)
        case ObserverRegistrationError.keyCommitReadBackMismatch:
            RegistrationDiagnosticFailure(reason: "key_commit_read_back_mismatch", httpStatus: nil, reasonCode: nil)
        case ObserverRegistrationError.http(let status, let reasonCode):
            RegistrationDiagnosticFailure(reason: "http", httpStatus: status, reasonCode: reasonCode)
        case ObserverRegistrationError.registrationFailed(let reason):
            RegistrationDiagnosticFailure(
                reason: reason == "transport error" ? "transport_error" : "registration_failed",
                httpStatus: nil,
                reasonCode: nil
            )
        default:
            RegistrationDiagnosticFailure(reason: "unexpected_error", httpStatus: nil, reasonCode: nil)
        }
    }

    private func emitRegistrationDiagnostic(
        operation: RegistrationOperation,
        descriptor: DeviceRegistrationDescriptor?,
        result: RegistrationTaskResult
    ) {
        if let failure = result.diagnosticFailure {
            self.emitRegistrationDiagnostic(
                operation: operation,
                descriptor: descriptor,
                failure: failure,
                retainedKey: result.key
            )
            return
        }
        self.diagnosticLog?.append(
            category: .network,
            message: "journal registration succeeded",
            detail: self.registrationDiagnosticDetail(
                operation: operation,
                outcome: "success",
                descriptor: descriptor,
                prefix: String(result.key.prefix(8)),
                failure: nil
            )
        )
    }

    private func emitRegistrationDiagnostic(
        operation: RegistrationOperation,
        descriptor: DeviceRegistrationDescriptor?,
        failure: RegistrationDiagnosticFailure,
        retainedKey: String? = nil
    ) {
        self.diagnosticLog?.append(
            category: .network,
            severity: retainedKey == nil ? .error : .warning,
            message: retainedKey == nil
                ? "journal registration failed"
                : "journal registration refresh failed",
            detail: self.registrationDiagnosticDetail(
                operation: operation,
                outcome: retainedKey == nil ? "failure" : "saved_key_retained",
                descriptor: descriptor,
                prefix: retainedKey.map { String($0.prefix(8)) },
                failure: failure
            )
        )
    }

    private func registrationDiagnosticDetail(
        operation: RegistrationOperation,
        outcome: String,
        descriptor: DeviceRegistrationDescriptor?,
        prefix: String?,
        failure: RegistrationDiagnosticFailure?
    ) -> String {
        var fields = [
            "source=\(self.streamType)",
            "operation=\(operation.rawValue)",
            "outcome=\(outcome)",
        ]
        if let descriptor {
            fields.append("hostname=\(descriptor.hostname)")
            fields.append("idfv=\(descriptor.vendorIdentifier)")
        }
        if let prefix {
            fields.append("prefix=\(prefix)")
        }
        if let failure {
            fields.append("reason=\(failure.reason)")
            if let status = failure.httpStatus {
                fields.append("http=\(status)")
            }
            if let reasonCode = failure.reasonCode {
                fields.append("reason_code=\(reasonCode)")
            }
        }
        return fields.joined(separator: " ")
    }

    func restorePersistedState() {
        if let key = try? self.loadKey(), !key.isEmpty {
            self.state = .registered
            self.restorePersistedPrefixIfNeeded()
        }
    }

    func restorePersistedPrefixIfNeeded() {
        if self.registrationPrefix == nil {
            self.registrationPrefix = try? self.loadPrefix()
        }
        // Backfill: a device with a cached ingest key but no persisted prefix
        // (registered before prefixes were tracked) derives the prefix locally the
        // same way the server does (key[:8]) and persists it, so diagnostics and the
        // health beacon stop rendering prefix=unknown. Gated on a key being present,
        // so it never interferes with the fresh-mint path that clears the prefix first.
        if self.registrationPrefix?.isEmpty != false,
           let key = try? self.loadKey(), !key.isEmpty {
            let derived = String(key.prefix(8))
            self.registrationPrefix = derived
            try? self.savePrefix(derived)
        }
    }
}

enum ObserverRegistrationError: Error {
    case missingVendorIdentifier
    case missingLocalPort
    case invalidURL
    case invalidResponse
    case emptyResponse
    case emptyKey
    case keyCommitReadBackMismatch
    case http(Int, reasonCode: String?)
    case registrationFailed(String)
}

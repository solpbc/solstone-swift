// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import UIKit
import UserNotifications
import os

private let log = Logger(subsystem: "app.solstone.swift", category: "push")

@MainActor
@Observable
final class PushNotificationManager {
    enum PermissionState: Equatable {
        case notDetermined
        case authorized
        case denied
        case provisional
    }

    enum RegistrationState: Equatable {
        case idle
        case registering
        case registered(token: String)
        case failed(reason: String)
    }

    private enum DefaultsKey {
        static let pendingRegistrationToken = "push.pendingRegistrationToken"
        static let lastRegisteredToken = "push.lastRegisteredToken"
        static let lastRegisteredEnvironment = "push.lastRegisteredEnvironment"
    }

    private(set) var permissionState: PermissionState = .notDetermined
    private(set) var registrationState: RegistrationState = .idle
    private(set) var deviceToken: String?
    var activeLocalPort: Int?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let retryDelays: [UInt64]
    @ObservationIgnored private let sleep: @Sendable (UInt64) async -> Void
    @ObservationIgnored private let bundleIdentifierOverride: String?
    @ObservationIgnored private let environmentOverride: String?
    @ObservationIgnored private var tokenContinuations: [UUID: AsyncStream<String>.Continuation] = [:]

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        self.retryDelays = [
            2_000_000_000,
            4_000_000_000,
            8_000_000_000,
        ]
        self.sleep = { delay in
            try? await Task.sleep(nanoseconds: delay)
        }
        self.bundleIdentifierOverride = nil
        self.environmentOverride = nil
        self.restorePersistedState()
    }

    init(
        defaults: UserDefaults,
        session: URLSession,
        retryDelays: [UInt64],
        sleep: @escaping @Sendable (UInt64) async -> Void,
        bundleIdentifierOverride: String? = nil,
        environmentOverride: String? = nil
    ) {
        self.defaults = defaults
        self.session = session
        self.retryDelays = retryDelays
        self.sleep = sleep
        self.bundleIdentifierOverride = bundleIdentifierOverride
        self.environmentOverride = environmentOverride
        self.restorePersistedState()
    }

    func refreshPermissionState() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        self.permissionState = switch settings.authorizationStatus {
        case .authorized, .ephemeral:
            .authorized
        case .provisional:
            .provisional
        case .denied:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .notDetermined
        }
    }

    func requestAuthorization() async {
#if DEBUG
        if let granted = self.integrationTestAuthorizationDecision {
            self.permissionState = granted ? .authorized : .denied
            if granted {
                if self.activeLocalPort == nil,
                   let localPort = Self.integrationTestPairingPort
                {
                    self.activeLocalPort = localPort
                }
                log.info("push authorization granted (integration)")
                await self.submitToken(Self.integrationTestToken())
            } else {
                log.info("push authorization denied (integration)")
            }
            return
        }
#endif
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            await self.refreshPermissionState()
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
                log.info("push authorization granted")
            } else {
                log.info("push authorization denied")
            }
        } catch {
            let detail = error.localizedDescription
            self.registrationState = .failed(reason: detail)
            log.error("push authorization failed: \(detail, privacy: .public)")
        }
    }

    func submitToken(_ token: Data) async {
        let hexToken = Self.hexEncode(token)
        self.deviceToken = hexToken
        if !hexToken.isEmpty {
            self.yieldDeviceToken(hexToken)
        }

        guard !hexToken.isEmpty else {
            self.registrationState = .failed(reason: "empty device token")
            log.error("push registration failed: empty device token")
            return
        }

        if self.shouldSkipRegistration(for: hexToken) {
            self.defaults.removeObject(forKey: DefaultsKey.pendingRegistrationToken)
            self.registrationState = .registered(token: hexToken)
            log.debug("push registration skipped: token unchanged")
            return
        }

        guard let localPort = self.activeLocalPort else {
            self.defaults.set(hexToken, forKey: DefaultsKey.pendingRegistrationToken)
            self.registrationState = .idle
            log.debug("push registration deferred: awaiting tunnel connection")
            return
        }

        await self.register(token: hexToken, localPort: localPort)
    }

    func handleTunnelConnected(localPort: Int) async {
        self.activeLocalPort = localPort

        if let pendingToken = self.defaults.string(forKey: DefaultsKey.pendingRegistrationToken),
           !pendingToken.isEmpty
        {
            if self.shouldSkipRegistration(for: pendingToken) {
                self.defaults.removeObject(forKey: DefaultsKey.pendingRegistrationToken)
                self.registrationState = .registered(token: pendingToken)
                log.debug("push registration replay skipped: token unchanged")
                return
            }

            await self.register(token: pendingToken, localPort: localPort)
        }
    }

    func sendTestNotification() async -> Bool {
        guard let localPort = self.activeLocalPort,
              let url = PushServerURL.url(path: "/api/push/test", localPort: localPort)
        else {
            log.error("push test failed: missing active local port")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        do {
            let (_, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                log.error("push test failed: invalid response")
                return false
            }
            if 200..<300 ~= http.statusCode {
                log.info("push test notification queued on port \(localPort)")
                return true
            }
            log.error("push test failed: HTTP \(http.statusCode)")
            return false
        } catch {
            log.error("push test failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func deregister() async {
        guard let token = self.deviceToken ?? self.defaults.string(forKey: DefaultsKey.lastRegisteredToken) else {
            return
        }
        guard let localPort = self.activeLocalPort,
              let url = PushServerURL.url(path: "/api/push/register", localPort: localPort)
        else {
            log.error("push deregistration failed: missing active local port")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = self.registrationBody(token: token)

        do {
            let (_, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                log.error("push deregistration failed: invalid response")
                return
            }
            guard 200..<300 ~= http.statusCode else {
                log.error("push deregistration failed: HTTP \(http.statusCode)")
                return
            }

            self.defaults.removeObject(forKey: DefaultsKey.pendingRegistrationToken)
            self.defaults.removeObject(forKey: DefaultsKey.lastRegisteredToken)
            self.defaults.removeObject(forKey: DefaultsKey.lastRegisteredEnvironment)
            self.registrationState = .idle
            log.info("push deregistered on port \(localPort)")
        } catch {
            log.error("push deregistration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func handleRemoteRegistrationFailure(_ error: any Error) {
        let detail = error.localizedDescription
        self.registrationState = .failed(reason: detail)
        log.error("remote registration failed: \(detail, privacy: .public)")
    }

    func deviceTokenStream() -> AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            self.tokenContinuations[id] = continuation
            if let deviceToken = self.deviceToken, !deviceToken.isEmpty {
                continuation.yield(deviceToken)
            }
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor [weak self] in
                    self?.tokenContinuations.removeValue(forKey: id)
                }
            }
        }
    }
}

private extension PushNotificationManager {
    var bundleIdentifier: String {
        self.bundleIdentifierOverride
            ?? Bundle.main.bundleIdentifier
            ?? "app.solstone.swift"
    }

    var environmentName: String {
        if let environmentOverride = self.environmentOverride {
            return environmentOverride
        }
#if DEBUG
        return "development"
#else
        return "production"
#endif
    }

    func restorePersistedState() {
        if let pendingToken = self.defaults.string(forKey: DefaultsKey.pendingRegistrationToken),
           !pendingToken.isEmpty
        {
            self.deviceToken = pendingToken
            self.registrationState = .idle
            return
        }

        if let lastToken = self.defaults.string(forKey: DefaultsKey.lastRegisteredToken),
           self.defaults.string(forKey: DefaultsKey.lastRegisteredEnvironment) == self.environmentName
        {
            self.deviceToken = lastToken
            self.registrationState = .registered(token: lastToken)
        }
    }

    func shouldSkipRegistration(for token: String) -> Bool {
        self.defaults.string(forKey: DefaultsKey.lastRegisteredToken) == token
            && self.defaults.string(forKey: DefaultsKey.lastRegisteredEnvironment) == self.environmentName
    }

    func register(token: String, localPort: Int) async {
        guard let url = PushServerURL.url(path: "/api/push/register", localPort: localPort) else {
            self.defaults.set(token, forKey: DefaultsKey.pendingRegistrationToken)
            self.registrationState = .failed(reason: "invalid registration url")
            log.error("push registration failed: invalid URL")
            return
        }

        var lastFailure = "push registration failed"
        for (index, delay) in self.retryDelays.enumerated() {
            self.registrationState = .registering

            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = self.registrationBody(token: token)

                let (_, response) = try await self.session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastFailure = "invalid response"
                    throw PushRegistrationError.invalidResponse
                }

                guard 200..<300 ~= http.statusCode else {
                    lastFailure = "HTTP \(http.statusCode)"
                    throw PushRegistrationError.http(http.statusCode)
                }

                self.defaults.removeObject(forKey: DefaultsKey.pendingRegistrationToken)
                self.defaults.set(token, forKey: DefaultsKey.lastRegisteredToken)
                self.defaults.set(self.environmentName, forKey: DefaultsKey.lastRegisteredEnvironment)
                self.deviceToken = token
                self.registrationState = .registered(token: token)
                log.info("push registered on port \(localPort)")
                return
            } catch {
                if index == self.retryDelays.count - 1 {
                    break
                }
                log.debug("push registration retry \(index + 1) on port \(localPort)")
                await self.sleep(delay)
            }
        }

        self.defaults.set(token, forKey: DefaultsKey.pendingRegistrationToken)
        self.registrationState = .failed(reason: lastFailure)
        log.error("push registration failed on port \(localPort): \(lastFailure, privacy: .public)")
    }

    func registrationBody(token: String) -> Data? {
        let payload: [String: String] = [
            "device_token": token,
            "bundle_id": self.bundleIdentifier,
            "environment": self.environmentName,
            "platform": "ios",
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    var integrationTestAuthorizationDecision: Bool? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--integration-test-onboarding-grant-notifications") {
            return true
        }
        if arguments.contains("--integration-test-onboarding-deny-notifications") {
            return false
        }
        return nil
    }

    static var integrationTestPairingPort: Int? {
        Int(ProcessInfo.processInfo.environment["MOCK_PAIRING_PORT"] ?? "")
    }

    static func integrationTestToken() -> Data {
        Data("integration-push-token".utf8)
    }

    static func hexEncode(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    func yieldDeviceToken(_ token: String) {
        for continuation in self.tokenContinuations.values {
            continuation.yield(token)
        }
    }
}

private enum PushRegistrationError: Error {
    case invalidResponse
    case http(Int)
}

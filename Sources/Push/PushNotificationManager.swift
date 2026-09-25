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
        static let registeredEnvironment = "push.registeredEnvironment"
        static let ownerEnabled = "push.ownerEnabled"
        static let pendingUnregisterToken = "push.pendingUnregisterToken"
    }

    private(set) var permissionState: PermissionState = .notDetermined
    private(set) var registrationState: RegistrationState = .idle
    private(set) var deviceToken: String?
    /// The owner's own turn-on, per device. Off until they turn it on; nothing registers while off.
    private(set) var ownerEnabled = false
    var activeLocalPort: Int?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let keyStore: PushKeyStore
    @ObservationIgnored private let retryDelays: [UInt64]
    @ObservationIgnored private let sleep: @Sendable (UInt64) async -> Void
    @ObservationIgnored private let bundleIdentifierOverride: String?
    @ObservationIgnored private let environmentOverride: String?
    @ObservationIgnored private let register: @MainActor @Sendable () -> Void
    @ObservationIgnored private let isSimulator: Bool
    @ObservationIgnored private let profileBytes: @Sendable () -> Data?
    @ObservationIgnored private var tokenContinuations: [UUID: AsyncStream<String>.Continuation] = [:]

    convenience init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        keyStore: PushKeyStore = .production()
    ) {
        self.init(
            defaults: defaults,
            session: session,
            keyStore: keyStore,
            retryDelays: [
                2_000_000_000,
                4_000_000_000,
                8_000_000_000,
            ],
            sleep: { delay in
                try? await Task.sleep(nanoseconds: delay)
            }
        )
    }

    init(
        defaults: UserDefaults,
        session: URLSession,
        keyStore: PushKeyStore = .production(),
        retryDelays: [UInt64],
        sleep: @escaping @Sendable (UInt64) async -> Void,
        bundleIdentifierOverride: String? = nil,
        environmentOverride: String? = nil,
        register: @escaping @MainActor @Sendable () -> Void = { UIApplication.shared.registerForRemoteNotifications() },
        isSimulator: Bool = {
#if targetEnvironment(simulator)
            true
#else
            false
#endif
        }(),
        profileBytes: @escaping @Sendable () -> Data? = {
            guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else { return nil }
            return try? Data(contentsOf: url)
        }
    ) {
        self.defaults = defaults
        self.session = session
        self.keyStore = keyStore
        self.retryDelays = retryDelays
        self.sleep = sleep
        self.bundleIdentifierOverride = bundleIdentifierOverride
        self.environmentOverride = environmentOverride
        self.register = register
        self.isSimulator = isSimulator
        self.profileBytes = profileBytes
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

    func reregisterIfAuthorized() {
        guard self.ownerEnabled else { return }
        switch self.permissionState {
        case .authorized, .provisional:
            self.register()
        case .denied, .notDetermined:
            break
        }
    }

    func turnOn() async {
        self.setOwnerEnabled(true)
        self.defaults.removeObject(forKey: DefaultsKey.pendingUnregisterToken)
        log.info("push turned on by owner")
        switch self.permissionState {
        case .notDetermined:
            await self.requestAuthorization()
        case .authorized, .provisional:
            self.register()
        case .denied:
            break
        }
    }

    func turnOff() async {
        self.setOwnerEnabled(false)
        self.defaults.removeObject(forKey: DefaultsKey.pendingRegistrationToken)
        let held = self.defaults.string(forKey: DefaultsKey.lastRegisteredToken) ?? self.deviceToken
        if let held, !held.isEmpty {
            self.defaults.set(held, forKey: DefaultsKey.pendingUnregisterToken)
        }
        self.registrationState = .idle
        log.info("push turned off by owner")
        if let localPort = self.activeLocalPort {
            await self.unregisterPending(localPort: localPort)
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
                self.register()
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

        guard self.ownerEnabled else {
            log.debug("push token received; not registering, owner has not turned push on")
            return
        }

        guard !hexToken.isEmpty else {
            self.registrationState = .failed(reason: "empty device token")
            log.error("push registration failed: empty device token")
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

        guard self.ownerEnabled else {
            // An install that registered before the owner turn-on existed is removed from the journal here, once.
            if self.defaults.string(forKey: DefaultsKey.pendingUnregisterToken) == nil,
               let lastToken = self.defaults.string(forKey: DefaultsKey.lastRegisteredToken),
               !lastToken.isEmpty
            {
                self.defaults.set(lastToken, forKey: DefaultsKey.pendingUnregisterToken)
            }
            await self.unregisterPending(localPort: localPort)
            return
        }

        if let pendingToken = self.defaults.string(forKey: DefaultsKey.pendingRegistrationToken),
           !pendingToken.isEmpty
        {
            await self.register(token: pendingToken, localPort: localPort)
        } else if let token = self.deviceToken, !token.isEmpty {
            await self.register(token: token, localPort: localPort)
        } else if let lastToken = self.defaults.string(forKey: DefaultsKey.lastRegisteredToken),
                  !lastToken.isEmpty
        {
            await self.register(token: lastToken, localPort: localPort)
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
            request.attachLoopbackCapability()
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

    nonisolated static func apsEnvironment(fromProfile profile: Data) -> String? {
        let openTag = Data("<plist".utf8)
        let closeTag = Data("</plist>".utf8)
        guard let start = profile.range(of: openTag)?.lowerBound else { return nil }
        guard let closeRange = profile.range(of: closeTag, in: start..<profile.endIndex) else { return nil }

        let plistData = Data(profile[start..<closeRange.upperBound])
        let entitlementsKey = "entitlements".capitalized
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
               let dict = plist as? [String: Any],
               let entitlements = dict[entitlementsKey] as? [String: Any],
               let environment = entitlements["aps-environment"] as? String,
               !environment.isEmpty
        else {
            return nil
        }
        return environment
    }

#if DEBUG
    func setPermissionStateForTesting(_ permissionState: PermissionState) {
        self.permissionState = permissionState
    }

    func setOwnerEnabledForTesting(_ enabled: Bool) {
        self.setOwnerEnabled(enabled)
    }
#endif
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
        if self.isSimulator {
            return "development"
        }
        if let profile = self.profileBytes(),
           let environment = Self.apsEnvironment(fromProfile: profile)
        {
            return environment
        }
        return "production"
    }

    func setOwnerEnabled(_ enabled: Bool) {
        self.ownerEnabled = enabled
        self.defaults.set(enabled, forKey: DefaultsKey.ownerEnabled)
    }

    func restorePersistedState() {
        self.ownerEnabled = self.defaults.bool(forKey: DefaultsKey.ownerEnabled)
        guard self.ownerEnabled else {
            self.registrationState = .idle
            return
        }

        if let pendingToken = self.defaults.string(forKey: DefaultsKey.pendingRegistrationToken),
           !pendingToken.isEmpty
        {
            self.deviceToken = pendingToken
            self.registrationState = .idle
            return
        }

        if let lastToken = self.defaults.string(forKey: DefaultsKey.lastRegisteredToken),
           !lastToken.isEmpty
        {
            let registeredEnvironment = self.defaults.string(forKey: DefaultsKey.registeredEnvironment)
            if registeredEnvironment == self.environmentName {
                self.deviceToken = lastToken
                self.registrationState = .registered(token: lastToken)
            }
        }
    }

    func register(token: String, localPort: Int) async {
        let pushKey: Data
        do {
            pushKey = try self.keyStore.loadOrCreate()
        } catch PushKeyStoreError.badPrefix {
            self.defaults.set(token, forKey: DefaultsKey.pendingRegistrationToken)
            self.registrationState = .failed(reason: "no_key")
            log.error("push registration failed: bad prefix (no_key)")
            return
        } catch PushKeyStoreError.interactionNotAllowed {
            self.defaults.set(token, forKey: DefaultsKey.pendingRegistrationToken)
            self.registrationState = .failed(reason: "key_unavailable")
            log.error("push registration failed: keychain locked (key_unavailable)")
            return
        } catch {
            self.defaults.set(token, forKey: DefaultsKey.pendingRegistrationToken)
            self.registrationState = .failed(reason: "push_key_failed")
            log.error("push registration failed: push key error (\(error.localizedDescription, privacy: .public))")
            return
        }

        guard let url = PushServerURL.url(path: "/api/push/register", localPort: localPort) else {
            self.defaults.set(token, forKey: DefaultsKey.pendingRegistrationToken)
            self.registrationState = .failed(reason: "invalid registration url")
            log.error("push registration failed: invalid URL")
            return
        }

        var lastFailure = "push registration failed"
        for (index, delay) in self.retryDelays.enumerated() {
            guard self.ownerEnabled else {
                self.registrationState = .idle
                return
            }
            self.registrationState = .registering

            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = self.registrationBody(token: token, pushKey: pushKey)

                request.attachLoopbackCapability()
                let (_, response) = try await self.session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastFailure = "invalid response"
                    throw PushRegistrationError.invalidResponse
                }

                guard 200..<300 ~= http.statusCode else {
                    lastFailure = "HTTP \(http.statusCode)"
                    throw PushRegistrationError.http(http.statusCode)
                }

                guard self.ownerEnabled else {
                    // Turned off while this registration was in flight: the journal now holds the row, so remove it.
                    self.defaults.set(token, forKey: DefaultsKey.pendingUnregisterToken)
                    self.registrationState = .idle
                    await self.unregisterPending(localPort: localPort)
                    return
                }
                self.defaults.removeObject(forKey: DefaultsKey.pendingRegistrationToken)
                self.defaults.set(token, forKey: DefaultsKey.lastRegisteredToken)
                self.defaults.set(self.environmentName, forKey: DefaultsKey.registeredEnvironment)
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

        guard self.ownerEnabled else {
            self.registrationState = .idle
            return
        }
        self.defaults.set(token, forKey: DefaultsKey.pendingRegistrationToken)
        self.registrationState = .failed(reason: lastFailure)
        log.error("push registration failed on port \(localPort): \(lastFailure, privacy: .public)")
    }

    func unregisterPending(localPort: Int) async {
        guard let token = self.defaults.string(forKey: DefaultsKey.pendingUnregisterToken),
              !token.isEmpty,
              let url = PushServerURL.url(path: "/api/push/register", localPort: localPort)
        else {
            return
        }

        for (index, delay) in self.retryDelays.enumerated() {
            guard !self.ownerEnabled else { return }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "DELETE"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: [
                    "platform": "ios",
                    "device_token": token,
                ])

                request.attachLoopbackCapability()
                let (_, response) = try await self.session.data(for: request)
                guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                    throw PushRegistrationError.invalidResponse
                }
                guard !self.ownerEnabled else { return }
                self.defaults.removeObject(forKey: DefaultsKey.pendingUnregisterToken)
                if self.defaults.string(forKey: DefaultsKey.lastRegisteredToken) == token {
                    self.defaults.removeObject(forKey: DefaultsKey.lastRegisteredToken)
                    self.defaults.removeObject(forKey: DefaultsKey.registeredEnvironment)
                }
                log.info("push unregistered on port \(localPort)")
                return
            } catch {
                if index == self.retryDelays.count - 1 {
                    break
                }
                await self.sleep(delay)
            }
        }
        log.error("push unregister failed on port \(localPort); will retry on the next connection")
    }

    func registrationBody(token: String, pushKey: Data) -> Data? {
        let payload: [String: String] = [
            "device_token": token,
            "bundle_id": self.bundleIdentifier,
            "environment": self.environmentName,
            "platform": "ios",
            "push_key": pushKey.base64URLEncodedString(),
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

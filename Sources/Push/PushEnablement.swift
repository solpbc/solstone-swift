// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import UserNotifications
import os

private let pushEnableLog = Logger(subsystem: "app.solstone.swift", category: "push-enable")

@MainActor
@Observable
final class PushEnablement {
    enum State: Equatable {
        case idle
        case requestingPermission
        case registeringAPNs
        case mintingNonce
        case openingWebAuthSession
        case polling
        case enabled
        case failed(message: String)

        var isWorking: Bool {
            switch self {
            case .requestingPermission, .registeringAPNs, .mintingNonce, .openingWebAuthSession, .polling:
                true
            case .idle, .enabled, .failed:
                false
            }
        }
    }

    private(set) var state: State

    @ObservationIgnored private let pushManager: PushNotificationManager
    @ObservationIgnored private let keychain: PushEnablementKeychain
    @ObservationIgnored private let webAuth: any WebAuthSessionStarting
    @ObservationIgnored private let pollSession: URLSession
    @ObservationIgnored private let sleep: @Sendable (UInt64) async -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let pollBudget: TimeInterval
    @ObservationIgnored private let retryDelayNanoseconds: UInt64

    init(
        pushManager: PushNotificationManager,
        keychain: PushEnablementKeychain = PushEnablementKeychain(),
        webAuth: (any WebAuthSessionStarting)? = nil,
        pollSession: URLSession = .shared,
        sleep: @escaping @Sendable (UInt64) async -> Void = { delay in
            try? await Task.sleep(nanoseconds: delay)
        },
        now: @escaping @Sendable () -> Date = { Date() },
        pollBudget: TimeInterval = 15 * 60,
        retryDelayNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.pushManager = pushManager
        self.keychain = keychain
        self.webAuth = webAuth ?? ASWebAuthSessionWrapper()
        self.pollSession = pollSession
        self.sleep = sleep
        self.now = now
        self.pollBudget = pollBudget
        self.retryDelayNanoseconds = retryDelayNanoseconds
        self.state = ((try? keychain.load()) != nil) ? .enabled : .idle
    }

    func isPushEnabled() -> Bool {
        (try? self.keychain.load()) != nil
    }

    func pushDeviceId() -> String? {
        (try? self.keychain.load())?.deviceId
    }

    func pushDispatchToken() -> String? {
        (try? self.keychain.load())?.dispatchToken
    }

    func pushAccountId() -> String? {
        (try? self.keychain.load())?.accountId
    }

    func enablePush(bundleId: String = "app.solstone.swift") async throws {
        do {
            let deviceToken = try await self.apnsDeviceToken()
            try Task.checkCancellation()

            self.state = .mintingNonce
            let nonce = EnablePushConstants.mintNonce()

            guard let enableURL = PortalURL.enablePushURL(
                nonce: nonce,
                deviceToken: deviceToken,
                bundleId: bundleId
            ) else {
                throw PushEnablementError.invalidURL
            }

            self.state = .openingWebAuthSession
            try self.webAuth.start(url: enableURL) { result in
                switch result {
                case .success:
                    pushEnableLog.debug("web session completed")
                case .failure:
                    pushEnableLog.debug("web session dismissed or failed")
                }
            }

            self.state = .polling
            let credential = try await self.pollForHandoff(nonce: nonce)
            try self.keychain.save(credential)
            self.state = .enabled
            pushEnableLog.info("solstone push enabled")
        } catch is CancellationError {
            self.state = self.isPushEnabled() ? .enabled : .idle
            throw CancellationError()
        } catch {
            let message = PushEnablementError.message(for: error)
            self.state = .failed(message: message)
            throw error
        }
    }

    func disablePush() throws {
        do {
            try self.keychain.delete()
            self.state = .idle
            pushEnableLog.info("solstone push disabled locally")
        } catch {
            self.state = .failed(message: "didn't hear back from the portal")
            throw error
        }
    }

    private func apnsDeviceToken() async throws -> String {
        if let token = self.pushManager.deviceToken, !token.isEmpty {
            return token
        }

        let stream = self.pushManager.deviceTokenStream()
        let tokenTask = Task<String, Error> {
            for await token in stream where !token.isEmpty {
                return token
            }
            throw CancellationError()
        }

        self.state = .requestingPermission
        await self.pushManager.requestAuthorization()
        await self.pushManager.refreshPermissionState()

        switch self.pushManager.permissionState {
        case .denied:
            tokenTask.cancel()
            throw PushEnablementError.notificationPermissionDenied
        case .authorized, .provisional:
            self.state = .registeringAPNs
            return try await tokenTask.value
        case .notDetermined:
            tokenTask.cancel()
            throw PushEnablementError.notificationPermissionDenied
        }
    }

    private func pollForHandoff(nonce: String) async throws -> EnabledPushRecord {
        let deadline = self.now().addingTimeInterval(self.pollBudget)

        while self.now() < deadline {
            try Task.checkCancellation()
            guard let url = PortalURL.handoffPushURL(nonce: nonce) else {
                throw PushEnablementError.invalidURL
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 35

            do {
                let (data, response) = try await self.pollSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    pushEnableLog.debug("push handoff poll invalid response")
                    await self.sleep(self.retryDelayNanoseconds)
                    continue
                }

                switch http.statusCode {
                case 200:
                    return try Self.decodeRecord(from: data)
                case 204:
                    continue
                case 400:
                    throw PushEnablementError.portalRejected
                case 410:
                    throw PushEnablementError.consentLinkExpired
                case 500...599:
                    pushEnableLog.debug("push handoff poll retrying after remote error status=\(http.statusCode)")
                    await self.sleep(self.retryDelayNanoseconds)
                default:
                    pushEnableLog.debug("push handoff poll retrying after status=\(http.statusCode)")
                    await self.sleep(self.retryDelayNanoseconds)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PushEnablementError {
                throw error
            } catch {
                pushEnableLog.debug("push handoff poll retrying after network error")
                await self.sleep(self.retryDelayNanoseconds)
            }
        }

        throw PushEnablementError.portalTimeout
    }

    private static func decodeRecord(from data: Data) throws -> EnabledPushRecord {
        do {
            return try JSONDecoder().decode(EnabledPushRecord.self, from: data)
        } catch {
            throw PushEnablementError.invalidResponse
        }
    }
}

nonisolated enum PushEnablementError: Error, Equatable, Sendable {
    case notificationPermissionDenied
    case consentLinkExpired
    case portalRejected
    case portalTimeout
    case invalidURL
    case invalidResponse

    static func message(for error: any Error) -> String {
        guard let error = error as? PushEnablementError else {
            return "didn't hear back from the portal"
        }

        switch error {
        case .notificationPermissionDenied:
            return "solstone push needs notification permission. enable it in Settings > Notifications > solstone."
        case .consentLinkExpired:
            return "consent link expired"
        case .portalRejected:
            return "the portal rejected the request"
        case .portalTimeout, .invalidURL, .invalidResponse:
            return "didn't hear back from the portal"
        }
    }
}

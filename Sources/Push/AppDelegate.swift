// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import UIKit
import UserNotifications
import os

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let pushManager = PushNotificationManager()
    lazy var pushEnablement = PushEnablement(pushManager: self.pushManager)
    let pendingRoute = PendingNotificationRouteState()
    weak var observerUploader: ObserverUploader?
    weak var importQueue: ImportQueue?
    lazy var tapRouter = NotificationTapRouter { [weak self] route in
        self?.pendingRoute.route = route
    }

    nonisolated func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let center = UNUserNotificationCenter.current()
            center.delegate = self.tapRouter
            center.setNotificationCategories(PushCategory.unCategories())
            await self.pushManager.refreshPermissionState()

#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--integration-test-push-register") {
                try? await Task.sleep(for: .seconds(1))
                let syntheticToken = Self.integrationTestToken()
                await self.pushManager.submitToken(syntheticToken)
            }
            if ProcessInfo.processInfo.arguments.contains("--integration-test-onboarding") {
                UserDefaults.standard.set(true, forKey: "integration.onboarding.enabled")
            }
            if let pairingArgument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--onboarding-mock-pair-token=") }) {
                UserDefaults.standard.set(
                    String(pairingArgument.dropFirst("--onboarding-mock-pair-token=".count)),
                    forKey: "integration.onboarding.mockToken"
                )
            }
            if let tapArgument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--integration-test-push-tap=") }) {
                try? await Task.sleep(for: .seconds(1))
                let kind = String(tapArgument.dropFirst("--integration-test-push-tap=".count))
                self.tapRouter.debugSynthesizeTap(kind)
            }
#endif
        }
        return true
    }

    nonisolated func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken token: Data
    ) {
        Task { @MainActor [weak self] in
            await self?.pushManager.submitToken(token)
        }
    }

    nonisolated func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.pushManager.handleRemoteRegistrationFailure(error)
        }
    }

    nonisolated func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        let completion: @MainActor @Sendable () -> Void = {
            completionHandler()
        }

        if identifier == ObserverUploader.backgroundSessionIdentifier {
            Task { @MainActor [weak self] in
                self?.observerUploader?.handleBackgroundURLSessionEvents(completionHandler: completion)
            }
            return
        }

        if identifier == ImportQueue.backgroundSessionIdentifier {
            Task { @MainActor [weak self] in
                self?.importQueue?.handleBackgroundURLSessionEvents(completionHandler: completion)
            }
            return
        }

        completionHandler()
    }
}

#if DEBUG
private extension AppDelegate {
    nonisolated static func integrationTestToken() -> Data {
        var value = UInt64(Date().timeIntervalSince1970 * 1_000).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
#endif

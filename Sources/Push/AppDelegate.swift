// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import UIKit
import UserNotifications
import os

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    let pushManager = PushNotificationManager()
    let pendingRoute = PendingNotificationRouteState()
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
}

#if DEBUG
private extension AppDelegate {
    nonisolated static func integrationTestToken() -> Data {
        var value = UInt64(Date().timeIntervalSince1970 * 1_000).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
#endif

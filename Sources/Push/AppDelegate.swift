// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AppIntents
import UIKit
import UserNotifications
import os

#if DEBUG
nonisolated private let appIntentProbeLog = Logger(subsystem: "app.solstone.swift", category: "app-intents")
#endif

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    nonisolated private static let retiredShareUploadSessionIdentifier = [
        "app.solstone.swift",
        ["share", "upload"].joined(separator: "-"),
    ].joined(separator: ".")

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
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--integration-test-observer-dependency") {
                do {
                    try await ObserverManagerDependencyProbeIntent()(donate: false)
                } catch {
                    appIntentProbeLog.error("integration observer dependency resolve failed: \(String(describing: error), privacy: .public)")
                }
            }
#endif
            let center = UNUserNotificationCenter.current()
            center.delegate = self.tapRouter
            await self.pushManager.refreshPermissionState()
            self.pushManager.reregisterIfAuthorized()

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

    // TODO(push-cutover): add silent cross-device dedup through application(_:didReceiveRemoteNotification:fetchCompletionHandler:).

    nonisolated func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        if identifier == Self.retiredShareUploadSessionIdentifier {
            // A previous app version uploaded shares through the `share-upload` background URLSession. iOS can still wake this binary with `handleEventsForBackgroundURLSession` for that identifier, carrying outstanding tasks from that older binary, even though no code creates the session anymore. Always call the completion handler for an identifier we do not own — the system waits on it otherwise.
            completionHandler()
            return
        }

        completionHandler()
    }

    // Returns UISceneConfiguration (NS_SWIFT_UI_ACTOR), so this cannot be nonisolated and cannot Task-hop.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SolstoneSceneDelegate.self
        return configuration
    }
}

#if DEBUG
private struct ObserverManagerDependencyProbeIntent: AppIntent {
    static var title: LocalizedStringResource { "observer dependency probe" }

    @Dependency private var observerManager: ObserverManager

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let observerManager = self.observerManager
        await MainActor.run {
            _ = ObjectIdentifier(observerManager)
        }
        appIntentProbeLog.info("integration observer dependency resolve succeeded")
        return .result(value: "resolved")
    }
}

private extension AppDelegate {
    nonisolated static func integrationTestToken() -> Data {
        var value = UInt64(Date().timeIntervalSince1970 * 1_000).bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
#endif

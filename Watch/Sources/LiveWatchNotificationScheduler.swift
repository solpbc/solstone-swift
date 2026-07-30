// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UserNotifications

@MainActor
final class LiveWatchNotificationScheduler: NSObject, WatchNotificationScheduling, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
    }

    func authorizationStatus() async -> WatchNotificationAuthorizationStatus {
        let settings = await self.center.notificationSettings()
        return Self.authorizationStatus(from: settings.authorizationStatus)
    }

    func alertSetting() async -> WatchNotificationAlertSetting {
        let settings = await self.center.notificationSettings()
        return Self.alertSetting(from: settings.alertSetting)
    }

    func requestAuthorization() async throws -> WatchNotificationAuthorizationStatus {
        _ = try await self.center.requestAuthorization(options: [.alert])
        return await self.authorizationStatus()
    }

    func add(identifier: String, title: String, body: String, triggerDate: Date?) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let trigger = triggerDate.map { date in
            UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: date
                ),
                repeats: false
            )
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try await self.center.add(request)
    }

    func removePending(identifier: String) {
        self.center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Self.presentationOptions(from: watchNoticePresentationOptions()))
    }
}

private extension LiveWatchNotificationScheduler {
    nonisolated static func authorizationStatus(
        from status: UNAuthorizationStatus
    ) -> WatchNotificationAuthorizationStatus {
        switch status {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .authorized:
            .authorized
        case .provisional:
            .provisional
        case .ephemeral:
            .ephemeral
        @unknown default:
            .notDetermined
        }
    }

    nonisolated static func alertSetting(from setting: UNNotificationSetting) -> WatchNotificationAlertSetting {
        switch setting {
        case .enabled:
            .enabled
        case .disabled:
            .disabled
        case .notSupported:
            .notSupported
        @unknown default:
            .disabled
        }
    }

    nonisolated static func presentationOptions(
        from options: Set<WatchNotificationPresentationOption>
    ) -> UNNotificationPresentationOptions {
        var presentationOptions: UNNotificationPresentationOptions = []
        if options.contains(.banner) {
            presentationOptions.insert(.banner)
        }
        if options.contains(.list) {
            presentationOptions.insert(.list)
        }
        return presentationOptions
    }
}

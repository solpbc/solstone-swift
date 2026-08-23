// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct NotificationsPane: View {
    @Environment(PushNotificationManager.self) private var pushManager

    private var permissionStatusText: String {
        switch self.pushManager.permissionState {
        case .notDetermined:
            "system: not requested"
        case .authorized:
            "system: authorized"
        case .denied:
            "system: denied"
        case .provisional:
            "system: provisional"
        }
    }

    private var registrationStatusText: String {
        switch self.pushManager.registrationState {
        case .idle:
            "registration: idle"
        case .registering:
            "registration: registering"
        case .registered:
            "registration: registered"
        case .failed(let reason):
            "registration: failed — \(reason)"
        }
    }

    var body: some View {
        List {
            LabeledContent("permission", value: self.permissionStatusText)
                .accessibilityLabel(self.permissionStatusText)

            LabeledContent("registration", value: self.registrationStatusText)
                .accessibilityLabel(self.registrationStatusText)

            Button("enable notifications") {
                Task {
                    await self.pushManager.requestAuthorization()
                }
            }
            .disabled(self.pushManager.permissionState == .authorized || self.pushManager.permissionState == .provisional)
            .accessibilityLabel("enable notifications")
            .hoverEffect(.highlight)

            Button("send test notification") {
                Task {
                    _ = await self.pushManager.sendTestNotification()
                }
            }
            .disabled(self.pushManager.activeLocalPort == nil)
            .accessibilityLabel("send test notification")
            .hoverEffect(.highlight)
        }
    }
}

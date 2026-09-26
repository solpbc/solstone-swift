// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit

struct NotificationsPane: View {
    @Environment(PushNotificationManager.self) private var pushManager
    @AccessibilityFocusState private var headingFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var testSend: TestSend = .idle

    enum TestSend: Equatable {
        case idle
        case sending
        case sent
        case failed

        var message: String? {
            switch self {
            case .idle: nil
            case .sending: "sending…"
            case .sent: "sent. it should show up on this device in a moment."
            case .failed: "couldn't send a test notification. try again in a moment."
            }
        }
    }

    private var ownerSwitch: Binding<Bool> {
        Binding(
            get: { self.pushManager.ownerEnabled },
            set: { on in
                Task {
                    if on {
                        await self.pushManager.turnOn()
                    } else {
                        await self.pushManager.turnOff()
                    }
                }
            }
        )
    }

    private var statusText: String {
        switch self.pushManager.registrationState {
        case .registered:
            "on"
        case .registering:
            "turning on…"
        case .failed:
            "couldn't turn on. try again in a moment."
        case .idle:
            "waiting for your journal"
        }
    }

    private var isRegistered: Bool {
        if case .registered = self.pushManager.registrationState { return true }
        return false
    }

    var body: some View {
        List {
            Section {
                Toggle("notifications from your journal", isOn: self.ownerSwitch)
                    .accessibilityIdentifier("shell.notifications.journalToggle")

                if self.pushManager.ownerEnabled {
                    if self.pushManager.permissionState == .denied {
                        Text("ios has notifications turned off for solstone.")
                            .foregroundStyle(.secondary)
                        Button("open settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .hoverEffect(.highlight)
                    } else {
                        Text(self.statusText)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("shell.notifications.journalStatus")
                    }

                    if self.isRegistered {
                        Button("send a test notification") {
                            self.testSend = .sending
                            Task {
                                let sent = await self.pushManager.sendTestNotification()
                                self.testSend = sent ? .sent : .failed
                                if let message = self.testSend.message {
                                    UIAccessibility.post(notification: .announcement, argument: message)
                                }
                            }
                        }
                        .disabled(self.pushManager.activeLocalPort == nil || self.testSend == .sending)
                        .hoverEffect(.highlight)

                        if let message = self.testSend.message {
                            Text(message)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("shell.notifications.testResult")
                        }
                    }
                }
            } footer: {
                Text("off until you turn it on. your journal encrypts each notification to this device's own key.")
            }
        }
        .task {
            await self.pushManager.refreshPermissionState()
        }
        .onChange(of: self.pushManager.ownerEnabled) {
            self.testSend = .idle
        }
        .onChange(of: self.scenePhase) { _, phase in
            // Coming back from iOS Settings: pick up a permission the owner just granted.
            guard phase == .active else { return }
            Task {
                await self.pushManager.refreshPermissionState()
                self.pushManager.reregisterIfAuthorized()
            }
        }
        .navigationTitle(ShellDestination.shelfNotifications.shelfTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(ShellDestination.shelfNotifications.shelfTitle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("shell.pane.shelfNotifications.heading")
                    .accessibilityFocused(self.$headingFocused)
            }
        }
        .onAppear { self.headingFocused = true }
    }
}

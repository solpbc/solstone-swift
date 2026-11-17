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
            case .sending: AppStrings.ios_home_message2()
            case .sent: AppStrings.ios_home_message3()
            case .failed: AppStrings.ios_home_message()
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
            AppStrings.ios_app_on()
        case .registering:
            AppStrings.ios_home_statustext2()
        case .failed:
            AppStrings.ios_home_statustext()
        case .idle:
            AppStrings.ios_home_statustext3()
        }
    }

    private var isRegistered: Bool {
        if case .registered = self.pushManager.registrationState { return true }
        return false
    }

    var body: some View {
        List {
            Section {
                Toggle(AppStrings.ios_home_body49(), isOn: self.ownerSwitch)
                    .accessibilityIdentifier("shell.notifications.journalToggle")

                if self.pushManager.ownerEnabled {
                    if self.pushManager.permissionState == .denied {
                        Text(AppStrings.ios_home_body14())
                            .foregroundStyle(.secondary)
                        Button(AppStrings.ios_home_opensettings()) {
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
                        Button(AppStrings.ios_home_body57()) {
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
                VStack(alignment: .leading, spacing: 0) {
                    Text(AppStrings.ios_home_body64())
                    Text(AppStrings.ios_home_body2())
                    Text(AppStrings.ios_home_body50())
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
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

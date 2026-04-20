// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let onboardingNotificationsLog = Logger(subsystem: "org.solpbc.solstone-swift", category: "onboarding")

struct NotificationsScreen: View {
    @Environment(PushNotificationManager.self) private var pushManager

    let onBack: () -> Void
    let onNext: (Bool) -> Void
    @State private var didAutoAdvance = false

    var body: some View {
        OnboardingScaffold(
            title: "Allow notifications",
            subtitle: "So sol can reach you for your morning briefing and meeting prep. No ads, no marketing, no third parties."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Button("Allow notifications") {
                    Task {
                        await self.pushManager.requestAuthorization()
                        await self.pushManager.refreshPermissionState()
                        self.onNext(self.pushManager.permissionState == .authorized || self.pushManager.permissionState == .provisional)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityHint("Requests iOS notification permission")

                Button("Skip for now") {
                    self.onNext(false)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityHint("Continues without enabling notifications")

                Button("Back", action: self.onBack)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint("Returns to the pairing step")
            }
        }
        .onAppear {
            guard !self.didAutoAdvance else { return }
            guard ProcessInfo.processInfo.arguments.contains("--integration-test-onboarding") else { return }
            self.didAutoAdvance = true
            Task {
                if ProcessInfo.processInfo.arguments.contains("--integration-test-onboarding-grant-notifications") {
                    onboardingNotificationsLog.info("onboarding auto-requesting notification grant")
                    await self.pushManager.requestAuthorization()
                    self.onNext(self.pushManager.permissionState == .authorized || self.pushManager.permissionState == .provisional)
                } else {
                    onboardingNotificationsLog.info("onboarding auto-advancing notifications with deny path")
                    self.onNext(false)
                }
            }
        }
    }
}

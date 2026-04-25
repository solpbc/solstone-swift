// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let onboardingWelcomeLog = Logger(subsystem: "app.solstone.swift", category: "onboarding")

struct WelcomeScreen: View {
    let onGetStarted: () -> Void
    @State private var didAutoAdvance = false

    var body: some View {
        OnboardingScaffold(
            title: "welcome to solstone",
            subtitle: "pair this phone with your journal, choose notifications, and set your morning briefing time."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Label("private by design", systemImage: "lock.fill")
                    .font(.headline)
                Label("no ads, no analytics, no third parties", systemImage: "hand.raised.fill")
                    .font(.headline)
                Label("your phone can resume where you left off if onboarding is interrupted", systemImage: "arrow.clockwise")
                    .font(.headline)

                Button("get started", action: self.onGetStarted)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityHint("Opens the pairing step")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .navigationTitle("")
        .onAppear {
            guard !self.didAutoAdvance else { return }
            guard ProcessInfo.processInfo.arguments.contains("--integration-test-onboarding") else { return }
            self.didAutoAdvance = true
            onboardingWelcomeLog.info("onboarding auto-advancing welcome")
            self.onGetStarted()
        }
    }
}

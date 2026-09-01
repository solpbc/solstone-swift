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
            title: "welcome to solstone.",
            subtitle: "the solstone app takes in what you share with it, and all of it goes into your journal.",
            showsBrandMark: true,
            ground: .deckGround,
            alignment: .center
        ) {
            VStack(alignment: .center, spacing: 16) {
                Text("your journal is always private, only yours.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("get started", action: self.onGetStarted)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityHint("finishes setup and opens your day")
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

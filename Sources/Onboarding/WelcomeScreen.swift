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
            title: "this is sol, part of solstone.",
            subtitle: "sol lives on your devices, experiences your day with you, and keeps it all in your journal. your journal is always private, only yours.",
            showsBrandMark: true,
            ground: Color.solCream,
            alignment: .center
        ) {
            VStack(alignment: .center, spacing: 16) {
                Label("private by design", systemImage: "lock.fill")
                    .font(.headline)
                Label("no ads, no analytics", systemImage: "hand.raised.fill")
                    .font(.headline)

                Button("get started", action: self.onGetStarted)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityHint("finishes setup and opens your day")
            }
        }
        .preferredColorScheme(.light)
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

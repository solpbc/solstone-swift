// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let onboardingWelcomeLog = Logger(subsystem: "app.solstone.swift", category: "onboarding")

struct WelcomeScreen: View {
    @Environment(OnboardingFlow.self) private var onboardingFlow
    @Environment(AppConfig.self) private var appConfig
    @State private var isShowingPairFlow = false
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

                JournalSetupRoute {
                    Button {
                        self.isShowingPairFlow = true
                    } label: {
                        JournalSetupPairLabel()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("welcome.alreadyHaveOne")
                }

                Button("not now") {
                    WelcomeSetup.notNow(onboarding: self.onboardingFlow)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("welcome.notNow")
                .accessibilityHint("opens your day without connecting a journal")
            }
        }
        .navigationDestination(isPresented: self.$isShowingPairFlow) {
            PairFlowView(
                onBack: {
                    self.isShowingPairFlow = false
                },
                onComplete: {
                    WelcomeSetup.finishIfMarkConfirmed(
                        onboarding: self.onboardingFlow,
                        appConfig: self.appConfig
                    )
                }
            )
        }
        .navigationTitle("")
        .onAppear {
            guard !self.didAutoAdvance else { return }
            guard ProcessInfo.processInfo.arguments.contains("--integration-test-onboarding") else { return }
            self.didAutoAdvance = true
            onboardingWelcomeLog.info("onboarding auto-advancing welcome")
            WelcomeSetup.notNow(onboarding: self.onboardingFlow)
        }
    }
}

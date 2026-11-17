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
            title: AppStrings.ios_onboarding_body7(),
            subtitle: AppStrings.ios_onboarding_body5(),
            showsBrandMark: true,
            ground: .deckGround,
            alignment: .center
        ) {
            VStack(alignment: .center, spacing: 16) {
                Text(AppStrings.ios_onboarding_journallivespromise())
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                JournalSetupRoute(showsMark: false) {
                    Button {
                        self.isShowingPairFlow = true
                    } label: {
                        JournalSetupPairLabel()
                    }
                    .accessibilityIdentifier("welcome.alreadyHaveOne")
                }

                Button(AppStrings.ios_migration_choice_defer()) {
                    WelcomeSetup.notNow(onboarding: self.onboardingFlow)
                }
                .buttonStyle(BrandQuietButtonStyle())
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("welcome.notNow")
                .accessibilityHint(AppStrings.ios_onboarding_body2())
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

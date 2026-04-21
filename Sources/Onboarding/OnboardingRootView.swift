// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let onboardingRootLog = Logger(subsystem: "app.solstone.swift", category: "onboarding")

struct OnboardingRootView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(OnboardingFlow.self) private var onboardingFlow
    @Environment(PushNotificationManager.self) private var pushManager

    let pairingClient: any PairingClient

    var body: some View {
        NavigationStack {
            switch self.onboardingFlow.step {
            case .welcome:
                WelcomeScreen {
                    self.onboardingFlow.advanceFromWelcome()
                }
            case .pair:
                PairScreen(
                    pairingClient: self.pairingClient,
                    onBack: { self.onboardingFlow.goBack() },
                    onPaired: {
                        self.onboardingFlow.completePairing()
                    }
                )
            case .notifications:
                NotificationsScreen(
                    onBack: { self.onboardingFlow.goBack() },
                    onNext: { granted in
                        self.onboardingFlow.completeNotifications(granted: granted)
                    }
                )
                .environment(self.pushManager)
            case .briefingTime:
                BriefingTimeScreen(
                    pairingClient: self.pairingClient,
                    onBack: { self.onboardingFlow.goBack() },
                    onComplete: {
                        self.onboardingFlow.completeBriefingTime()
                    }
                )
            case .done:
                Color.clear
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            onboardingRootLog.info("OnboardingRootView presenting \(self.onboardingFlow.step.rawValue, privacy: .public) screen")
        }
        .onChange(of: self.onboardingFlow.step) { _, newStep in
            onboardingRootLog.info("OnboardingRootView presenting \(newStep.rawValue, privacy: .public) screen")
        }
    }
}

struct OnboardingScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(self.title)
                        .font(.largeTitle.weight(.bold))
                    Text(self.subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                self.content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(Color(.systemGroupedBackground))
    }
}

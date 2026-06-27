// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let onboardingRootLog = Logger(subsystem: "app.solstone.swift", category: "onboarding")

struct OnboardingRootView: View {
    @Environment(OnboardingFlow.self) private var onboardingFlow

    var body: some View {
        NavigationStack {
            switch self.onboardingFlow.step {
            case .welcome:
                WelcomeScreen {
                    self.onboardingFlow.advanceFromWelcome()
                }
            case .firstSource:
                FirstSourceScreen()
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
    let titleAccessibilityIdentifier: String?
    let showsBrandMark: Bool
    let content: Content

    init(
        title: String,
        subtitle: String,
        titleAccessibilityIdentifier: String? = nil,
        showsBrandMark: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.titleAccessibilityIdentifier = titleAccessibilityIdentifier
        self.showsBrandMark = showsBrandMark
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if self.showsBrandMark {
                    Image("SolWordmark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 12) {
                    self.titleView
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

    @ViewBuilder
    private var titleView: some View {
        if let titleAccessibilityIdentifier {
            Text(self.title)
                .font(.largeTitle.weight(.bold))
                .accessibilityIdentifier(titleAccessibilityIdentifier)
        } else {
            Text(self.title)
                .font(.largeTitle.weight(.bold))
        }
    }
}

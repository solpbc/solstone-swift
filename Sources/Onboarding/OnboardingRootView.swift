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
                    self.onboardingFlow.completeOnboarding()
                }
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
    let ground: Color
    let alignment: HorizontalAlignment
    let content: Content

    init(
        title: String,
        subtitle: String,
        titleAccessibilityIdentifier: String? = nil,
        showsBrandMark: Bool = false,
        ground: Color = Color(.systemGroupedBackground),
        alignment: HorizontalAlignment = .leading,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.titleAccessibilityIdentifier = titleAccessibilityIdentifier
        self.showsBrandMark = showsBrandMark
        self.ground = ground
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: self.alignment, spacing: 24) {
                if self.showsBrandMark {
                    Image("SolWordmark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 104, height: 104)
                        .accessibilityHidden(true)
                }

                VStack(alignment: self.alignment, spacing: 12) {
                    self.titleView
                    self.subtitleView
                }

                self.content
            }
            .frame(maxWidth: .infinity, alignment: self.frameAlignment)
            .padding(24)
        }
        .background(self.ground)
    }

    private var isCentered: Bool {
        self.alignment == .center
    }

    private var frameAlignment: Alignment {
        self.isCentered ? .center : .leading
    }

    @ViewBuilder
    private var titleView: some View {
        if let titleAccessibilityIdentifier {
            self.titleText
                .accessibilityIdentifier(titleAccessibilityIdentifier)
        } else {
            self.titleText
        }
    }

    @ViewBuilder
    private var titleText: some View {
        if self.isCentered {
            Text(self.title)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
        } else {
            Text(self.title)
                .font(.largeTitle.weight(.bold))
        }
    }

    @ViewBuilder
    private var subtitleView: some View {
        if self.isCentered {
            Text(self.subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            Text(self.subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}

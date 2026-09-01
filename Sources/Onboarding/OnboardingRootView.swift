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
        ground: Color = .deckGround,
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
        .background(self.ground.ignoresSafeArea())
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

    /// Onboarding is the first surface an owner sees, so it carries the brand face
    /// rather than the system's — the same pairing the shell uses everywhere else:
    /// Comfortaa names the thing, SF carries what has to be read closely.
    @ViewBuilder
    private var titleText: some View {
        if self.isCentered {
            Text(self.title)
                .font(ShellFont.display(30, relativeTo: .largeTitle))
                .multilineTextAlignment(.center)
        } else {
            Text(self.title)
                .font(ShellFont.display(30, relativeTo: .largeTitle))
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

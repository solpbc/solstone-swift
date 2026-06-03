// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let onboardingFirstSourceLog = Logger(subsystem: "app.solstone.swift", category: "onboarding")

struct FirstSourceScreen: View {
    @Environment(OnboardingFlow.self) private var onboardingFlow

    @State private var didAutoAdvance = false

    var body: some View {
        OnboardingScaffold(
            title: "start with a source",
            subtitle: "choose what solstone should keep on this phone first.",
            titleAccessibilityIdentifier: "onboarding.firstSource"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                self.sourceRow(
                    title: "audio",
                    subtitle: "listens alongside you when you turn it on.",
                    systemImage: "ear"
                ) {
                    self.onboardingFlow.completeFirstSource(choseSource: true)
                }
                .accessibilityIdentifier("onboarding.firstSource.audio")

                self.sourceRow(
                    title: "location",
                    subtitle: "notices the places of your day when you turn it on.",
                    systemImage: "location"
                ) {
                    self.onboardingFlow.completeFirstSource(choseSource: true)
                }
                .accessibilityIdentifier("onboarding.firstSource.location")

                Button("look around first") {
                    self.onboardingFlow.completeFirstSource(choseSource: false)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("onboarding.lookAround")

                Button("back") {
                    self.onboardingFlow.goBack()
                }
                .frame(minWidth: 44, minHeight: 44)
            }
        }
        .onAppear {
            guard !self.didAutoAdvance else { return }
            guard ProcessInfo.processInfo.arguments.contains("--integration-test-onboarding") else { return }
            self.didAutoAdvance = true
            onboardingFirstSourceLog.info("onboarding auto-advancing first source")
            self.onboardingFlow.completeFirstSource(choseSource: false)
        }
    }

    private func sourceRow(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.solOrangeAccessible)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

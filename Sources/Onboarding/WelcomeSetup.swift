// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
enum WelcomeSetup {
    static func setOneUp(onboarding: OnboardingFlow, appConfig: AppConfig) -> URL {
        JournalSetupLink.installURL
    }

    static func shareLink(onboarding: OnboardingFlow, appConfig: AppConfig) -> URL {
        JournalSetupLink.installURL
    }

    static func cancelPairing(onboarding: OnboardingFlow) {
        // writes nothing (does not set isCompleted)
    }

    static func notNow(onboarding: OnboardingFlow) {
        onboarding.completeOnboarding()
    }

    @discardableResult
    static func finishIfMarkConfirmed(onboarding: OnboardingFlow, appConfig: AppConfig) -> Bool {
        if OnboardingPairingReconciliation.shouldComplete(
            isPaired: appConfig.isPaired,
            journalSendConfirmed: appConfig.journalSendConfirmed,
            isOnboardingCompleted: onboarding.isCompleted
        ) {
            onboarding.completeOnboarding()
            return true
        }
        return false
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let onboardingFlowLog = Logger(subsystem: "org.solpbc.solstone-swift", category: "onboarding")

@MainActor
@Observable
final class OnboardingFlow {
    enum Step: String, Sendable {
        case welcome
        case pair
        case notifications
        case briefingTime = "briefing_time"
        case done
    }

    private enum DefaultsKey {
        static let step = "onboarding.step"
        static let completed = "onboarding.completed"
    }

    var step: Step = .welcome
    var isCompleted = false
    var notificationsGranted: Bool?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.restore()
    }

    func restore() {
        self.isCompleted = self.defaults.bool(forKey: DefaultsKey.completed)
        if self.isCompleted {
            self.step = .done
            return
        }
        if let rawStep = self.defaults.string(forKey: DefaultsKey.step),
           let restoredStep = Step(rawValue: rawStep)
        {
            self.step = restoredStep
        } else {
            self.step = .welcome
        }
    }

    func reset() {
        self.notificationsGranted = nil
        self.isCompleted = false
        self.step = .welcome
        onboardingFlowLog.info("onboarding reset")
        self.persist()
    }

    func advanceFromWelcome() {
        self.step = .pair
        self.persist()
    }

    func completePairing() {
        self.step = .notifications
        self.persist()
    }

    func completeNotifications(granted: Bool) {
        self.notificationsGranted = granted
        self.step = .briefingTime
        self.persist()
    }

    func completeBriefingTime() {
        self.step = .done
        self.isCompleted = true
        self.persist()
        onboardingFlowLog.info("onboarding completed")
    }

    func goBack() {
        switch self.step {
        case .welcome, .done:
            break
        case .pair:
            self.step = .welcome
        case .notifications:
            self.step = .pair
        case .briefingTime:
            self.step = .notifications
        }
        self.persist()
    }

    func markCompletedForUITest() {
        self.step = .done
        self.isCompleted = true
        self.persist()
    }

    func seedUITest(step: Step) {
        self.step = step
        self.isCompleted = step == .done
        self.persist()
    }

    private func persist() {
        self.defaults.set(self.step.rawValue, forKey: DefaultsKey.step)
        self.defaults.set(self.isCompleted, forKey: DefaultsKey.completed)
        onboardingFlowLog.info("onboarding step \(self.step.rawValue, privacy: .public)")
    }
}

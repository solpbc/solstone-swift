// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let onboardingFlowLog = Logger(subsystem: "app.solstone.swift", category: "onboarding")

@MainActor
@Observable
final class OnboardingFlow {
    enum Step: String, Sendable {
        case welcome
        case firstSource = "first_source"
        case done
    }

    private enum DefaultsKey {
        static let step = "onboarding.step"
        static let completed = "onboarding.completed"
    }

    var step: Step = .welcome
    var isCompleted = false
    var choseFirstSource = false

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

        if let rawStep = self.defaults.string(forKey: DefaultsKey.step) {
            switch rawStep {
            case "pair":
                self.step = .welcome
                self.persist()
                return
            case "notifications", "briefing_time":
                self.step = .done
                self.isCompleted = true
                self.persist()
                return
            default:
                if let restoredStep = Step(rawValue: rawStep) {
                    self.step = restoredStep
                    return
                }
            }
        }

        self.step = .welcome
    }

    func reset() {
        self.choseFirstSource = false
        self.isCompleted = false
        self.step = .welcome
        onboardingFlowLog.info("onboarding reset")
        self.persist()
    }

    func advanceFromWelcome() {
        self.step = .firstSource
        self.persist()
    }

    func completeFirstSource(choseSource: Bool) {
        self.choseFirstSource = choseSource
        self.step = .done
        self.isCompleted = true
        self.persist()
        onboardingFlowLog.info("onboarding completed")
    }

    func completeViaPairing() {
        self.choseFirstSource = false
        self.step = .done
        self.isCompleted = true
        onboardingFlowLog.info("onboarding completed via pairing")
        self.persist()
    }

    func goBack() {
        switch self.step {
        case .welcome, .done:
            break
        case .firstSource:
            self.step = .welcome
        }
        self.persist()
    }

    func markCompletedForUITest() {
        self.choseFirstSource = false
        self.step = .done
        self.isCompleted = true
        self.persist()
    }

    func seedUITest(step: Step) {
        self.step = step
        self.isCompleted = step == .done
        self.choseFirstSource = false
        self.persist()
    }

    private func persist() {
        self.defaults.set(self.step.rawValue, forKey: DefaultsKey.step)
        self.defaults.set(self.isCompleted, forKey: DefaultsKey.completed)
        onboardingFlowLog.info("onboarding step \(self.step.rawValue, privacy: .public)")
    }
}

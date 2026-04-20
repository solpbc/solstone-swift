// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let onboardingBriefingLog = Logger(subsystem: "org.solpbc.solstone-swift", category: "onboarding")

struct BriefingTimeScreen: View {
    @Environment(AppConfig.self) private var appConfig

    let pairingClient: any PairingClient
    let onBack: () -> Void
    let onComplete: () -> Void

    @State private var selectedTime = Self.defaultTime
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var didAutoSave = false

    private static let defaultTime: Date = Calendar.current.date(
        bySettingHour: 7,
        minute: 0,
        second: 0,
        of: .now
    ) ?? .now

    var body: some View {
        OnboardingScaffold(
            title: "Set your briefing time",
            subtitle: "When would you like your morning briefing?"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                DatePicker(
                    "Briefing time",
                    selection: self.$selectedTime,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Morning briefing time")

                if let errorMessage {
                    Text(errorMessage)
                        .font(.body)
                        .foregroundStyle(.red)
                }

                Button(self.isSaving ? "Saving…" : "Get started") {
                    Task {
                        await self.saveSelectedTime()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(self.isSaving)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityHint("Saves your morning briefing time")

                Button("Use 7:00 AM") {
                    self.selectedTime = Self.defaultTime
                    Task {
                        await self.saveSelectedTime()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityHint("Uses the default 7 AM briefing time")

                Button("Back", action: self.onBack)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint("Returns to the notifications step")
            }
        }
        .onAppear {
            guard !self.didAutoSave else { return }
            guard ProcessInfo.processInfo.arguments.contains("--integration-test-onboarding") else { return }
            self.didAutoSave = true
            onboardingBriefingLog.info("onboarding auto-saving briefing time")
            Task {
                await self.saveSelectedTime()
            }
        }
    }
}

private extension BriefingTimeScreen {
    func saveSelectedTime() async {
        guard let sessionKey = self.appConfig.currentSessionKey() else {
            self.errorMessage = "Missing pairing session."
            onboardingBriefingLog.error("onboarding briefing save missing session")
            return
        }

        self.isSaving = true
        defer { self.isSaving = false }

        let components = Calendar.current.dateComponents([.hour, .minute], from: self.selectedTime)

        do {
            try await self.pairingClient.setBriefingTime(
                hour: components.hour ?? 7,
                minute: components.minute ?? 0,
                tzIdentifier: TimeZone.current.identifier,
                sessionKey: sessionKey
            )
            self.errorMessage = nil
            onboardingBriefingLog.info("onboarding briefing time saved")
            self.onComplete()
        } catch let error as PairingClientError {
            onboardingBriefingLog.error("onboarding briefing save failed: \(String(describing: error), privacy: .public)")
            switch error {
            case .server(_, let body):
                self.errorMessage = body.isEmpty ? "Unable to save your briefing time." : body
            default:
                self.errorMessage = "Unable to save your briefing time."
            }
        } catch {
            onboardingBriefingLog.error("onboarding briefing save failed: \(String(describing: error), privacy: .public)")
            self.errorMessage = "Unable to save your briefing time."
        }
    }
}

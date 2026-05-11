// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct SettingsView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(OnboardingFlow.self) private var onboardingFlow
    @Environment(TunnelManager.self) private var tunnelManager

    @State private var showingForgetConfirm = false
    @State private var showingPairNewConfirm = false
    @State private var showingPairFlow = false

    var body: some View {
        Form {
            Section("your solstone") {
                LabeledContent("label", value: self.appConfig.homeLabel.isEmpty ? "unpaired" : self.appConfig.homeLabel)
                LabeledContent("fingerprint", value: self.shortFingerprint)
                LabeledContent("paired", value: self.pairedAtText)

                Button("forget this solstone", role: .destructive) {
                    self.showingForgetConfirm = true
                }
                .disabled(!self.appConfig.isPaired)

                Button("pair a new solstone") {
                    self.showingPairNewConfirm = true
                }
            }

            Section("diagnostics") {
                Toggle("show technical details", isOn: Binding(
                    get: { UserSettings.verboseErrors },
                    set: { UserSettings.verboseErrors = $0 }
                ))
            }

            Section("version") {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                LabeledContent("app version", value: "\(version) (\(build))")
            }
        }
        .navigationTitle("settings")
        .alert("forget this solstone?", isPresented: self.$showingForgetConfirm) {
            Button("cancel", role: .cancel) {}
            Button("forget", role: .destructive) {
                Task {
                    await self.clearPairingAndReturnToOnboarding()
                }
            }
        } message: {
            Text("this removes the pairing from this phone.")
        }
        .alert("pair a new solstone?", isPresented: self.$showingPairNewConfirm) {
            Button("cancel", role: .cancel) {}
            Button("continue", role: .destructive) {
                Task {
                    await self.clearPairingForNewPair()
                }
            }
        } message: {
            Text("this forgets the current solstone before pairing another one.")
        }
        .sheet(isPresented: self.$showingPairFlow) {
            NavigationStack {
                PairFlowView(
                    onBack: {
                        self.showingPairFlow = false
                    },
                    onComplete: {
                        self.showingPairFlow = false
                        self.onboardingFlow.completePairing()
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("cancel") {
                            self.showingPairFlow = false
                        }
                    }
                }
            }
        }
    }
}

private extension SettingsView {
    var shortFingerprint: String {
        guard !self.appConfig.caFingerprintHex.isEmpty else {
            return "unpaired"
        }
        return String(self.appConfig.caFingerprintHex.prefix(8))
    }

    var pairedAtText: String {
        guard let pairedAt = self.appConfig.pairedAt else {
            return "unpaired"
        }
        return pairedAt.formatted(date: .abbreviated, time: .shortened)
    }

    func clearPairingAndReturnToOnboarding() async {
        self.appConfig.clearPairing()
        self.onboardingFlow.reset()
        await self.tunnelManager.disconnect()
    }

    func clearPairingForNewPair() async {
        self.appConfig.clearPairing()
        self.onboardingFlow.reset()
        await self.tunnelManager.disconnect()
        self.showingPairFlow = true
    }
}

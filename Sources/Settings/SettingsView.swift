// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct SettingsView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(OnboardingFlow.self) private var onboardingFlow
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(PushEnablement.self) private var pushEnablement

    @State private var showingForgetConfirm = false
    @State private var showingPairNewConfirm = false
    @State private var showingPairFlow = false
    @State private var enablePushTask: Task<Void, Never>?

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

            Section("notifications") {
                if self.pushEnablement.isPushEnabled() {
                    Label("solstone push is on.", systemImage: "checkmark")

                    Button("disable solstone push", role: .destructive) {
                        self.disableSolstonePush()
                    }
                    .disabled(self.pushEnablement.state.isWorking)
                } else {
                    if let statusText = self.pushStatusText {
                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }

                    Button("enable solstone push") {
                        self.enableSolstonePush()
                    }
                    .disabled(self.pushEnablement.state.isWorking)
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
        .onDisappear {
            self.enablePushTask?.cancel()
            self.enablePushTask = nil
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
        await self.tunnelManager.disconnect()
        self.showingPairFlow = true
    }

    var pushStatusText: String? {
        switch self.pushEnablement.state {
        case .requestingPermission, .registeringAPNs:
            "opening..."
        case .mintingNonce, .openingWebAuthSession:
            "opening..."
        case .polling:
            "waiting for portal..."
        case .failed(let message):
            message
        case .idle, .enabled:
            nil
        }
    }

    func enableSolstonePush() {
        self.enablePushTask?.cancel()
        self.enablePushTask = Task {
            do {
                try await self.pushEnablement.enablePush()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func disableSolstonePush() {
        do {
            try self.pushEnablement.disablePush()
        } catch {
            return
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import SwiftUI
import UIKit
import os

private let onboardingLog = Logger(subsystem: "org.solpbc.solstone-swift", category: "onboarding")

struct PairScreen: View {
    @Environment(AppConfig.self) private var appConfig

    let pairingClient: any PairingClient
    let onBack: () -> Void
    let onPaired: () -> Void

    @State private var pastedURL = ""
    @State private var errorMessage: String?
    @State private var showScanner = false
    @State private var cameraPermissionDenied = false
    @State private var isPairing = false
    @State private var didAutoPair = false

    var body: some View {
        OnboardingScaffold(
            title: "Pair your journal",
            subtitle: "Open /app/pairing/ on your desktop convey and scan the QR code, or paste the pairing URL below."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Button("Scan pairing code") {
                    self.showScanner = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityHint("Opens the camera to scan a pairing code")

                TextField("solstone://pair?token=...&host=...", text: self.$pastedURL, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Pairing URL")
                    .accessibilityHint("Paste the pairing URL from your desktop")

                Button(self.isPairing ? "Pairing…" : "Pair this device") {
                    Task {
                        await self.confirmPairing(rawValue: self.pastedURL)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(self.isPairing || self.pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityHint("Pairs this phone with your journal using the pasted URL")

                if self.cameraPermissionDenied {
                    Text("Camera access is unavailable on this device. Paste the pairing URL instead.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.body)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Pairing error: \(errorMessage)")
                }

                Button("Back", action: self.onBack)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint("Returns to the welcome screen")
            }
        }
        .sheet(isPresented: self.$showScanner) {
            QRScannerController(
                onResult: { value in
                    self.showScanner = false
                    self.pastedURL = value
                    Task {
                        await self.confirmPairing(rawValue: value)
                    }
                },
                onPermissionDenied: {
                    self.showScanner = false
                    self.cameraPermissionDenied = true
                }
            )
            .ignoresSafeArea()
        }
        .onAppear {
            self.prefillIntegrationURLIfNeeded()
            guard !self.didAutoPair else { return }
            guard ProcessInfo.processInfo.arguments.contains("--integration-test-onboarding") else { return }
            guard !self.pastedURL.isEmpty else { return }
            self.didAutoPair = true
            onboardingLog.info("onboarding auto-pairing with pasted URL")
            Task {
                await self.confirmPairing(rawValue: self.pastedURL)
            }
        }
    }
}

private extension PairScreen {
    func confirmPairing(rawValue: String) async {
        self.isPairing = true
        defer { self.isPairing = false }

        do {
            onboardingLog.info("onboarding pairing started")
            let pairToken = try PairToken.parse(rawValue)
            if let livePairingClient = self.pairingClient as? LivePairingClient {
                livePairingClient.setPairingHost(pairToken.host)
            }

            let privateKey = try KeychainStore.loadOrCreatePairIdentity()
            let publicKey = Data(privateKey.publicKey.rawRepresentation).base64EncodedString()
            let deviceName = "\(UIDevice.current.name)'s \(UIDevice.current.model)"
            let bundleID = Bundle.main.bundleIdentifier ?? "org.solpbc.solstone-swift"
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            let response = try await self.pairingClient.confirm(
                token: pairToken.token,
                publicKey: publicKey,
                deviceName: deviceName,
                platform: "ios",
                bundleID: bundleID,
                appVersion: appVersion
            )
            try self.appConfig.applyPairConfirm(response)
            self.errorMessage = nil
            onboardingLog.info("onboarding pairing confirmed for \(response.host, privacy: .public)")
            self.onPaired()
        } catch let error as PairTokenError {
            self.errorMessage = error.localizedDescription
            onboardingLog.error("onboarding pairing token parse failed: \(String(describing: error), privacy: .public)")
        } catch let error as PairingClientError {
            self.errorMessage = self.message(for: error)
            onboardingLog.error("onboarding pairing request failed: \(String(describing: error), privacy: .public)")
        } catch {
            self.errorMessage = "Pairing failed. Try again."
            onboardingLog.error("onboarding pairing failed: \(String(describing: error), privacy: .public)")
        }
    }

    func message(for error: PairingClientError) -> String {
        switch error {
        case .invalidToken:
            "This pairing token is invalid."
        case .expiredToken:
            "This pairing token has expired."
        case .network:
            "Network error while pairing."
        case .server(_, let body):
            body.isEmpty ? "The server rejected this pairing request." : body
        case .decoding:
            "The server returned an unreadable pairing response."
        case .missingPairingHost:
            "Pairing URL is missing its host."
        case .missingJournalRoot:
            "The journal root is not available yet."
        }
    }

    func prefillIntegrationURLIfNeeded() {
        guard self.pastedURL.isEmpty else { return }
        guard UserDefaults.standard.bool(forKey: "integration.onboarding.enabled")
            || ProcessInfo.processInfo.arguments.contains("--integration-test-onboarding")
        else { return }
        let token: String
        if let stored = UserDefaults.standard.string(forKey: "integration.onboarding.mockToken"), !stored.isEmpty {
            token = stored
        } else if let tokenArgument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--onboarding-mock-pair-token=") }) {
            token = String(tokenArgument.dropFirst("--onboarding-mock-pair-token=".count))
        } else {
            return
        }
        let port = Int(ProcessInfo.processInfo.environment["MOCK_PAIRING_PORT"] ?? "") ?? 8676
        self.pastedURL = "solstone://pair?token=\(token)&host=http://127.0.0.1:\(port)"
        onboardingLog.info("onboarding prefilled integration pairing URL on port \(port)")
    }
}

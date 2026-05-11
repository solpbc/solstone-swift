// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SPLTunnel
import SwiftUI
import os

private let pairFlowViewLog = Logger(subsystem: "app.solstone.swift", category: "pair-flow")

@MainActor
@Observable
final class PairingHandoffState {
    var pairURL: PairURL?
}

struct PairFlowView: View {
    enum EntryMode: String, CaseIterable, Identifiable {
        case scan
        case code
        case paste

        var id: String { rawValue }
    }

    @Environment(AppConfig.self) private var appConfig
    @Environment(PairingHandoffState.self) private var handoff

    let onBack: () -> Void
    let onComplete: () -> Void

    @State private var coordinator = PairFlowCoordinator()
    @State private var mode: EntryMode = .scan
    @State private var pastedURL = ""
    @State private var errorMessage: String?
    @State private var didAutoPair = false

    var body: some View {
        OnboardingScaffold(
            title: "pair your solstone",
            subtitle: "scan the pairing code, enter the short code, or paste the pairing link from your solstone."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Picker("pairing method", selection: self.$mode) {
                    Text("scan").tag(EntryMode.scan)
                    Text("code").tag(EntryMode.code)
                    Text("paste").tag(EntryMode.paste)
                }
                .pickerStyle(.segmented)

                switch self.mode {
                case .scan:
                    QRScannerView(
                        onURL: { url in
                            Task {
                                await self.handle(url)
                            }
                        },
                        onUnavailable: {
                            self.errorMessage = "camera access is unavailable on this device. Type a code instead."
                            self.mode = .code
                        }
                    )
                    .frame(minHeight: 320)
                case .code:
                    ManualCodeEntryView { pairURL in
                        Task {
                            await self.handle(pairURL)
                        }
                    }
                case .paste:
                    TextField("https://link.solpbc.org/p#...", text: self.$pastedURL, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    Button(self.coordinator.state == .pairing ? "pairing..." : "pair this device") {
                        Task {
                            await self.handlePastedURL()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(self.pastedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.coordinator.state == .pairing)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.body)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Pairing error: \(errorMessage)")
                }

                Button("back", action: self.onBack)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .onAppear {
            guard !self.didAutoPair else { return }
            if ProcessInfo.processInfo.arguments.contains("--integration-test-onboarding") {
                self.didAutoPair = true
                Task {
                    await self.completeIntegrationPairing()
                }
            } else if let pairURL = self.handoff.pairURL {
                self.didAutoPair = true
                self.handoff.pairURL = nil
                Task {
                    await self.handle(pairURL)
                }
            }
        }
        .onChange(of: self.handoff.pairURL) { _, pairURL in
            guard let pairURL else { return }
            self.handoff.pairURL = nil
            Task {
                await self.handle(pairURL)
            }
        }
    }

    private func handlePastedURL() async {
        let trimmed = self.pastedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            self.errorMessage = "enter a valid pairing link."
            return
        }
        await self.handle(url)
    }

    private func handle(_ url: URL) async {
        guard let pairURL = UniversalLinkRouter.route(url) else {
            self.errorMessage = "enter a valid pairing link."
            return
        }
        await self.handle(pairURL)
    }

    private func handle(_ pairURL: PairURL) async {
        do {
            try await self.coordinator.handlePairURL(pairURL)
            if let pairing = try SPLKeychain.load() {
                try self.appConfig.applyPairing(pairing)
            }
            self.errorMessage = nil
            self.onComplete()
        } catch {
            self.errorMessage = self.message(for: error)
        }
    }

    private func completeIntegrationPairing() async {
#if DEBUG
        let port = Int(ProcessInfo.processInfo.environment["MOCK_PAIRING_PORT"] ?? "") ?? 8676
        await Self.recordIntegrationPairConfirm(port: port)
        self.appConfig.seedUITestPairing(
            journalRoot: "http://127.0.0.1:\(port)",
            deviceID: "integration-test-device",
            sessionKey: "integration-test-session"
        )
        pairFlowViewLog.info("onboarding integration SPL pairing seeded on port \(port)")
        self.onComplete()
#endif
    }

    private static func recordIntegrationPairConfirm(port: Int) async {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/pairing/confirm") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = """
        {"token":"integration","public_key":"integration","device_name":"integration","platform":"ios","bundle_id":"app.solstone.swift","app_version":"0"}
        """.data(using: .utf8)
        do {
            _ = try await URLSession.shared.data(for: request)
        } catch {
            pairFlowViewLog.error("integration pair confirm failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func message(for error: Error) -> String {
        switch error {
        case PairError.lanCAFingerprintMismatch:
            return "this isn't your solstone — re-pair if you intended to."
        case PairError.nonceExpired:
            return "this pairing code has expired."
        default:
            return "pairing failed. Try again."
        }
    }
}

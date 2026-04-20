// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import NIOSSH
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppConfig.self) private var appConfig
    var keyManager: any KeyManaging = KeyManager()

    @State private var publicKeyString = ""
    @State private var hostKeyFingerprint = ""
    @State private var showRegenerateAlert = false
    @State private var showRegenerateError = false
    @State private var regenerateErrorMessage = ""
    @State private var justCopied = false
    @State private var copyTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("identity key") {
                LabeledContent("public key") {
                    Group {
                        if self.publicKeyString.isEmpty {
                            Text("unavailable")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(self.publicKeyString)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                .accessibilityLabel("ssh public key")
                .accessibilityHint("tap copy public key to transfer to your server")

                Button {
                    UIPasteboard.general.string = self.publicKeyString
                    if UserSettings.haptics {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    self.copyTask?.cancel()
                    withAnimation(.easeInOut) {
                        self.justCopied = true
                    }
                    self.copyTask = Task {
                        try? await Task.sleep(for: .seconds(2))
                        if !Task.isCancelled {
                            withAnimation(.easeInOut) {
                                self.justCopied = false
                            }
                        }
                    }
                } label: {
                    if self.justCopied {
                        Label("copied", systemImage: "checkmark")
                    } else {
                        Text("copy public key")
                    }
                }
                .disabled(self.publicKeyString.isEmpty)
                .accessibilityHint("copies ssh public key to clipboard")
            }

            Section("known host") {
                Group {
                    if self.hostKeyFingerprint.isEmpty {
                        Text("none stored")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(self.hostKeyFingerprint)
                            .font(.footnote.monospaced())
                    }
                }
                Button("forget") {
                    try? self.keyManager.deleteHostKey()
                    self.loadHostKeyFingerprint()
                }
                .accessibilityHint("removes the saved server key")
            }

            Section("connection") {
                LabeledContent("host") {
                    Text("\(self.appConfig.host):\(self.appConfig.port)")
                        .font(.footnote.monospaced())
                }
                LabeledContent("journal root") {
                    Text(self.appConfig.journalRoot.isEmpty ? "unpaired" : self.appConfig.journalRoot)
                        .font(.footnote.monospaced())
                }
                LabeledContent("identity") {
                    Text(self.appConfig.ownerIdentity.isEmpty ? "unpaired" : self.appConfig.ownerIdentity)
                        .font(.footnote.monospaced())
                }
            }

            Section("advanced") {
                Button("regenerate key", role: .destructive) {
                    self.showRegenerateAlert = true
                }
                .accessibilityHint("creates a new ssh key, invalidating server authorization")
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
        .onAppear {
            self.loadPublicKeyString()
            self.loadHostKeyFingerprint()
        }
        .onDisappear {
            self.copyTask?.cancel()
        }
        .alert("regenerate SSH key", isPresented: self.$showRegenerateAlert) {
            Button("cancel", role: .cancel) {}
            Button("regenerate", role: .destructive) {
                self.regenerateKey()
            }
        } message: {
            Text("existing server authorization for this device will stop working until the new public key is installed.")
        }
        .alert("error", isPresented: self.$showRegenerateError) {
            Button("ok", role: .cancel) {}
        } message: {
            Text(self.regenerateErrorMessage)
        }
    }
}

private extension SettingsView {
    func regenerateKey() {
        do {
            try self.keyManager.deleteIdentityKey()
            try self.keyManager.deleteHostKey()
            _ = try self.keyManager.loadOrCreateIdentityKey()
            if UserSettings.haptics {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        } catch {
            self.regenerateErrorMessage = "key regeneration failed — your previous key may have been deleted, check settings"
            self.showRegenerateError = true
        }
        self.loadPublicKeyString()
        self.loadHostKeyFingerprint()
    }

    func loadPublicKeyString() {
        do {
            let identityKey = try self.keyManager.loadOrCreateIdentityKey()

            let publicKey = NIOSSHPrivateKey(ed25519Key: identityKey).publicKey
            self.publicKeyString = "\(String(openSSHPublicKey: publicKey)) solstone-swift"
        } catch {
            self.publicKeyString = ""
        }
    }

    func loadHostKeyFingerprint() {
        do {
            guard let hostKey = try self.keyManager.loadHostKey() else {
                self.hostKeyFingerprint = ""
                return
            }

            let components = String(openSSHPublicKey: hostKey).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard components.count == 2 else {
                self.hostKeyFingerprint = "stored"
                return
            }

            let base64 = String(components[1])
            let prefix = base64.prefix(20)
            self.hostKeyFingerprint = "\(components[0]) \(prefix)..."
        } catch {
            self.hostKeyFingerprint = "unavailable"
        }
    }
}

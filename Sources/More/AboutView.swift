// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

@MainActor
struct AboutView: View {
    @Environment(AppConfig.self) private var appConfig

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    private var server: String {
        self.appConfig.serverVersion.isEmpty ? "unknown" : self.appConfig.serverVersion
    }

    private var owner: String {
        self.appConfig.ownerIdentity.isEmpty ? "unpaired" : self.appConfig.ownerIdentity
    }

    private var device: String {
        DeviceRegistrationDescriptor.currentDisplayName()
    }

    private var journalRoot: String {
        self.appConfig.journalRoot.isEmpty ? "unpaired" : self.appConfig.journalRoot
    }

    var body: some View {
        GeometryReader { proxy in
            List {
                Section {
                    VStack(spacing: 16) {
                        Image("SolWordmark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120)

                        Text("sol pbc · agpl-3.0")
                            .font(.custom("Comfortaa-Bold", size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, max(proxy.size.height * 0.08, 32))
                }
                .listRowBackground(Color.clear)

                Section {
                    LabeledContent("version", value: self.version)
                    LabeledContent("build", value: self.build)
                    LabeledContent("journal", value: self.server)
                    LabeledContent("owner", value: self.owner)
                    LabeledContent("device", value: self.device)
                    LabeledContent("journal root", value: self.journalRoot)
                }
            }
            .navigationTitle("about")
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let offlineLog = Logger(subsystem: "app.solstone.swift", category: "offline")

struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text("offline — safe on this phone · your journal will catch up")
                .font(.body.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.yellow.opacity(0.18))
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Offline. Safe on this phone; your journal will catch up.")
        .onAppear {
            offlineLog.info("offline banner visible")
        }
        .onDisappear {
            offlineLog.info("offline banner hidden")
        }
    }
}

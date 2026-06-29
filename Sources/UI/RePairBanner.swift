// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let rePairLog = Logger(subsystem: "app.solstone.swift", category: "re-pair")

struct RePairBanner: View {
    let onRePair: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .accessibilityHidden(true)
            Text(SourceVocabulary.rePairLine)
                .font(.body.weight(.semibold))
            Spacer(minLength: 12)
            Button(SourceVocabulary.rePairAction) {
                self.onRePair()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.14))
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .onAppear {
            rePairLog.info("re-pair banner visible")
        }
        .onDisappear {
            rePairLog.info("re-pair banner hidden")
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

@MainActor
struct VoiceHUDOverlay: View {
    let voiceManager: VoiceManager
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(PortalPage.self) private var portalPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isVisible: Bool {
        guard self.tunnelManager.state.isConnected, self.portalPage.isReady else { return false }
        switch self.voiceManager.state {
        case .listening, .speaking:
            return true
        case .idle, .connecting, .error:
            return false
        }
    }

    var body: some View {
        Group {
            if self.isVisible {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(self.voiceManager.state == .speaking ? Color.solOrange : .green)
                        .frame(width: self.reduceMotion ? 28 : 40, height: 6)
                        .scaleEffect(x: self.voiceManager.state == .speaking && !self.reduceMotion ? 1.2 : 1, y: 1)
                        .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: self.voiceManager.state)

                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(self.elapsedText(now: context.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.primary)
                    }

                    Button("stop") {
                        self.voiceManager.endSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 8)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("voice session active")
                .accessibilityValue(self.elapsedText(now: Date()))
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }
}

private extension VoiceHUDOverlay {
    func elapsedText(now: Date) -> String {
        guard let start = self.voiceManager.lastSession?.startTime else { return "0s" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return "\(seconds)s"
    }
}

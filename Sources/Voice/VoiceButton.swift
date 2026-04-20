// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit

struct VoiceButton: View {
    @Environment(VoiceManager.self) private var voiceManager
    @Environment(BrainStatusMonitor.self) private var brainStatusMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false
    @State private var isBrainPulsing = false
    let stateOverride: VoiceState?
    let brainStatusOverride: BrainStatus?
    let onTap: () -> Void
    let onDebugLongPress: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    self.onTap()
                } label: {
                    self.voiceContent
                        .frame(width: 56, height: 56)
                        .background(self.buttonColor)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        .scaleEffect(self.isPulsing && !self.reduceMotion ? 1.08 : 1)
                        .animation(self.pulseAnimation, value: self.isPulsing)
                        .overlay(alignment: .topTrailing) {
                            if self.effectiveBrainStatus == .refreshing {
                                Circle()
                                    .fill(.blue)
                                    .frame(width: 10, height: 10)
                                    .opacity(self.isBrainPulsing && !self.reduceMotion ? 0.6 : 1.0)
                                    .animation(
                                        self.reduceMotion ? nil : .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                                        value: self.isBrainPulsing
                                    )
                                    .onAppear {
                                        if !self.reduceMotion {
                                            self.isBrainPulsing = true
                                        }
                                    }
                                    .onDisappear {
                                        self.isBrainPulsing = false
                                    }
                                    .accessibilityLabel("brain refreshing")
                            }
                        }
                }
                .accessibilityLabel(self.accessibilityLabel)
                .accessibilityHint(self.accessibilityHint)
#if DEBUG
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 1)
                        .onEnded { _ in
                            self.onDebugLongPress()
                        }
                )
#endif
                .padding(.trailing, 20)
                .padding(.bottom, 20)
            }
        }
        .onAppear {
            self.updatePulse(for: self.effectiveState)
        }
        .onChange(of: self.effectiveState) { _, newState in
            self.updatePulse(for: newState)
            self.playHaptic(for: newState)
        }
    }
}

private extension VoiceButton {
    var effectiveState: VoiceState {
        self.stateOverride ?? self.voiceManager.state
    }

    var effectiveBrainStatus: BrainStatus {
        self.brainStatusOverride ?? self.brainStatusMonitor.status
    }

    @ViewBuilder
    var voiceContent: some View {
        switch self.effectiveState {
        case .connecting:
            ProgressView()
                .tint(.white)
        case .error:
            Image(systemName: "info.circle")
                .font(.title2)
                .foregroundStyle(.white)
        case .idle:
            if self.hasRecentSession {
                Image(systemName: "info.circle")
                    .font(.title2)
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
        case .speaking:
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.white)
        case .listening:
            Image(systemName: "mic.fill")
                .font(.title2)
                .foregroundStyle(.white)
        }
    }

    var buttonColor: Color {
        switch self.effectiveState {
        case .idle:
            .solOrange
        case .connecting:
            Color.solOrange.opacity(0.7)
        case .listening:
            .green
        case .speaking:
            .solOrange
        case .error:
            .red
        }
    }

    var pulseAnimation: Animation? {
        self.shouldPulse && !self.reduceMotion
            ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
            : nil
    }

    var shouldPulse: Bool {
        switch self.effectiveState {
        case .listening, .speaking:
            true
        case .idle, .connecting, .error:
            false
        }
    }

    var hasRecentSession: Bool {
        guard let session = self.voiceManager.lastSession,
              let endTime = session.endTime
        else { return false }
        return Date().timeIntervalSince(endTime) < 60
    }

    var accessibilityLabel: String {
        switch self.effectiveState {
        case .idle:
            return self.hasRecentSession ? "voice" : "voice"
        case .connecting:
            return "voice"
        case .listening:
            return "voice"
        case .speaking:
            return "voice is speaking"
        case .error:
            return "voice"
        }
    }

    var accessibilityHint: String {
        switch self.effectiveState {
        case .idle:
            "starts a voice session"
        case .connecting:
            "voice session is starting"
        case .listening, .speaking:
            "voice session is active"
        case .error:
            "shows the last voice error"
        }
    }

    func updatePulse(for state: VoiceState) {
        if self.reduceMotion {
            self.isPulsing = false
            return
        }

        switch state {
        case .listening, .speaking:
            self.isPulsing = true
        case .idle, .connecting, .error:
            self.isPulsing = false
        }
    }

    func playHaptic(for state: VoiceState) {
        switch state {
        case .listening:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .speaking:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .idle, .connecting:
            break
        }
    }
}

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
    @State private var showSessionDetail = false
    let localPort: Int

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button {
                    self.handleTap()
                } label: {
                    self.voiceContent
                        .frame(width: 56, height: 56)
                        .background(self.buttonColor)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        .scaleEffect(self.isPulsing && !self.reduceMotion ? 1.08 : 1)
                        .animation(self.pulseAnimation, value: self.isPulsing)
                        .overlay(alignment: .topTrailing) {
                            if self.brainStatusMonitor.status == .refreshing {
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
                .sheet(isPresented: self.$showSessionDetail) {
                    if let session = self.voiceManager.lastSession {
                        VoiceSessionDetailSheet(session: session) {
                            Task {
                                await self.voiceManager.startSession(localPort: self.localPort)
                            }
                        }
                        .presentationDetents([.height(320)])
                    }
                }
                .padding(.trailing, 20)
                .padding(.bottom, 20)
            }
        }
        .onAppear {
            self.updatePulse(for: self.voiceManager.state)
        }
        .onChange(of: self.voiceManager.state) { oldState, newState in
            self.updatePulse(for: newState)
            self.announceTransition(from: oldState, to: newState)
            self.playHaptic(for: newState)
        }
    }
}

private extension VoiceButton {
    @ViewBuilder
    var voiceContent: some View {
        switch self.voiceManager.state {
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
        switch self.voiceManager.state {
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
        switch self.voiceManager.state {
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
        switch self.voiceManager.state {
        case .idle:
            return self.hasRecentSession ? "view session details" : "start voice conversation"
        case .connecting:
            return "starting voice conversation"
        case .listening:
            return "end voice conversation"
        case .speaking:
            return "voice is speaking"
        case .error:
            return "view session details"
        }
    }

    var accessibilityHint: String {
        switch self.voiceManager.state {
        case .idle:
            return self.hasRecentSession
                ? "double-tap to view session details"
                : "double-tap to start voice session"
        case .error:
            return "double-tap to view session details"
        case .connecting, .listening, .speaking:
            return "double-tap to end voice session"
        }
    }

    func handleTap() {
        switch self.voiceManager.state {
        case .idle:
            if self.hasRecentSession {
                self.showSessionDetail = true
            } else {
                Task {
                    await self.voiceManager.startSession(localPort: self.localPort)
                }
            }
        case .error:
            self.showSessionDetail = true
        case .connecting, .listening, .speaking:
            self.voiceManager.endSession()
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

    func announceTransition(from oldState: VoiceState, to newState: VoiceState) {
        let message: String? = switch newState {
        case .connecting:
            "starting voice session"
        case .listening:
            "voice session active, listening"
        case .speaking:
            "voice is speaking"
        case .error(let error):
            "voice error, \(error.userMessage)"
        case .idle:
            oldState == .idle ? nil : "voice session ended"
        }

        if let message {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }
}

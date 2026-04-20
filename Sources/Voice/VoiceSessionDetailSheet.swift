// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit

struct VoiceSessionDetailSheet: View, Sendable {
    let session: VoiceSession
    let onStartNewSession: @Sendable () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var justCopied = false
    @State private var copyTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("session details")
                    .font(.headline)
                Spacer()
                Button {
                    self.dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("close")
            }

            if let duration = self.session.duration {
                LabeledContent("duration") {
                    Text(self.formatDuration(duration))
                        .font(.body.monospacedDigit())
                }
            }

            LabeledContent("status") {
                if let error = self.session.errorDetail {
                    Text("error — \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                } else if self.session.endTime != nil {
                    Text("ended normally")
                        .foregroundStyle(.secondary)
                } else {
                    Text("in progress")
                        .foregroundStyle(.secondary)
                }
            }

            if let callId = self.session.callId {
                LabeledContent("call id") {
                    HStack(spacing: 8) {
                        Text(callId)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            UIPasteboard.general.string = callId
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
                            Image(systemName: self.justCopied ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                        }
                        .accessibilityLabel(self.justCopied ? "copied" : "copy call id")
                    }
                }
            }

            LabeledContent("started") {
                Text(self.session.startTime, style: .relative)
                    .font(.caption)
            }

            if let endTime = self.session.endTime {
                LabeledContent("ended") {
                    Text(endTime, style: .relative)
                        .font(.caption)
                }
            }

            Spacer()

            Button {
                self.dismiss()
                self.onStartNewSession()
            } label: {
                Text("start new session")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.solOrange)
        }
        .padding()
        .onDisappear {
            self.copyTask?.cancel()
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

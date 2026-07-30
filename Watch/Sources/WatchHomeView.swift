// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI

struct WatchHomeView: View {
    let model: WatchSessionModel
    let captureModel: WatchCaptureModel

    var body: some View {
        let face = watchFaceModel(
            for: self.captureModel.presentation,
            isReachable: self.model.isReachable
        )
        // Wrist alert assurance is presentation-only here; this UI does not render it yet.

        ScrollView {
            VStack(alignment: .center, spacing: 14) {
                self.statusHeader(face)

                self.controlButton

                Divider()
                    .overlay(self.secondaryTextColor.opacity(0.45))
                    .padding(.vertical, 2)

                VStack(alignment: .leading, spacing: 9) {
                    ForEach(face.detailRows, id: \.label) { row in
                        HStack(spacing: 10) {
                            Text(row.label)
                            Spacer(minLength: 8)
                            Text("\(row.value)")
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(self.secondaryTextColor)
                    }

                    if let trustLine = face.trustLine {
                        Text(trustLine)
                            .font(.caption2)
                            .foregroundStyle(self.secondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 6) {
                        Circle()
                            .fill(face.linkInRange ? Color.green : self.color(for: .calm))
                            .frame(width: 7, height: 7)
                        Text(face.linkLine)
                            .font(.caption2)
                            .foregroundStyle(self.secondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(face.linkLine)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(Color.black)
    }
}

private extension WatchHomeView {
    var primaryTextColor: Color {
        .white
    }

    var secondaryTextColor: Color {
        Color(white: 0.56)
    }

    var controlLabel: String {
        self.captureModel.isRunning ? "stop" : "start"
    }

    var controlHint: String {
        self.captureModel.isRunning ? "turns sol off" : "turns sol on"
    }

    var controlFill: Color {
        self.captureModel.isRunning ? Color(white: 0.16) : self.color(for: .live)
    }

    var controlButton: some View {
        Button {
            if self.captureModel.isRunning {
                self.captureModel.stop()
            } else {
                self.captureModel.start()
            }
        } label: {
            Text(self.controlLabel)
                .font(.headline.weight(.semibold))
                .foregroundStyle(self.primaryTextColor)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(self.controlFill, in: Capsule())
        .accessibilityLabel(self.controlLabel)
        .accessibilityHint(self.controlHint)
    }

    func statusHeader(_ face: WatchFaceModel) -> some View {
        VStack(spacing: 7) {
            self.markView(face.markVariant)

            Text(face.stateWord)
                .font(.title3.weight(.bold))
                .foregroundStyle(self.color(for: face.stateColorRole))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.72)
                .lineLimit(2)

            if face.showsElapsed, let start = self.captureModel.presentation.sessionStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsedText(from: start, now: context.date))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(self.secondaryTextColor)
                }
            }

            if let handoff = face.compactHandoff {
                VStack(spacing: 3) {
                    Text(handoff.line)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(self.color(for: handoff.role))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)
                        .lineLimit(2)
                    if let subtext = handoff.subtext {
                        Text(subtext)
                            .font(.caption2)
                            .foregroundStyle(self.secondaryTextColor)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.8)
                            .lineLimit(2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.statusAccessibilityLabel(face))
    }

    @ViewBuilder
    func markView(_ markVariant: WatchFaceMark) -> some View {
        let image = Image(self.imageName(for: markVariant))
            .resizable()
            .scaledToFit()
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)

        if markVariant == .activeDimmed {
            image
                .opacity(0.32)
                .grayscale(0.55)
        } else {
            image
        }
    }

    func imageName(for markVariant: WatchFaceMark) -> String {
        switch markVariant {
        case .active, .activeDimmed:
            "SolRingActive"
        case .alert:
            "SolRingAlert"
        }
    }

    func color(for role: WatchFaceColorRole) -> Color {
        switch role {
        case .live:
            Color(red: 0.910, green: 0.573, blue: 0.227)
        case .flight:
            Color(red: 0.961, green: 0.659, blue: 0.259)
        case .calm:
            Color(red: 0.604, green: 0.604, blue: 0.627)
        case .alert:
            Color(red: 1.000, green: 0.271, blue: 0.227)
        }
    }

    func statusAccessibilityLabel(_ face: WatchFaceModel) -> String {
        var parts = [face.stateWord]
        if face.showsElapsed, let start = self.captureModel.presentation.sessionStartedAt {
            parts.append(Self.elapsedText(from: start, now: Date()))
        }
        if let handoff = face.compactHandoff {
            parts.append(handoff.line)
            if let subtext = handoff.subtext {
                parts.append(subtext)
            }
        }
        return parts.joined(separator: ", ")
    }

    static func elapsedText(from start: Date, now: Date) -> String {
        let totalSeconds = max(0, Int(now.timeIntervalSince(start)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

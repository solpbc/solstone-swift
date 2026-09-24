// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI

struct WatchHomeView: View {
    let model: WatchSessionModel
    let captureModel: WatchCaptureModel
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let face = watchFaceModel(
            for: self.captureModel.presentation,
            isReachable: self.model.isReachable
        )
        let hero = watchHomeHero(
            model: face,
            status: self.captureModel.presentation.status,
            sessionStartedAt: self.captureModel.presentation.sessionStartedAt,
            now: Date()
        )

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .center, spacing: 14) {
                    self.heroView(hero: hero, face: face)

                    Divider()
                        .overlay(Color(watchHex: WatchHomePalette.calm).opacity(0.45))
                        .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(face.detailRows, id: \.label) { row in
                            HStack(spacing: 10) {
                                Text(row.label)
                                    .minimumScaleFactor(0.7)
                                Spacer(minLength: 8)
                                Text("\(row.value)")
                                    .monospacedDigit()
                                    .minimumScaleFactor(0.7)
                            }
                            .font(.caption)
                            .foregroundStyle(Color(watchHex: WatchHomePalette.calm))
                        }

                        Text("journal version \(self.model.journalVersion.displayValue)")
                            .font(.caption2)
                            .foregroundStyle(Color(watchHex: WatchHomePalette.calm))
                            .minimumScaleFactor(0.7)
                            .fixedSize(horizontal: false, vertical: true)

                        if let trustLine = face.trustLine {
                            Text(trustLine)
                                .font(.caption2)
                                .foregroundStyle(Color(watchHex: WatchHomePalette.calm))
                                .minimumScaleFactor(0.7)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text(face.linkLine)
                            .font(.caption2)
                            .foregroundStyle(Color(watchHex: WatchHomePalette.calm))
                            .minimumScaleFactor(0.7)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            // Fade the scroll out above the pinned control, so a line cut by the viewport reads as
            // "more below" rather than as a broken line.
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 18)
                }
            }

            self.controlButton
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
        }
        .background(Color.clear)
        .onChange(of: self.scenePhase) { _, newPhase in
            if newPhase == .active {
                self.captureModel.handleOwnerVisibleRaise()
            }
        }
    }
}

private extension WatchHomeView {
    @ViewBuilder
    func heroView(hero: WatchHomeHero, face: WatchFaceModel) -> some View {
        VStack(spacing: 4) {
            Text(hero.title)
                .font(hero.titleIsLarge ? .title2.weight(.bold) : .headline.weight(.semibold))
                .foregroundStyle(Color(watchHex: hero.titleHex))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .lineLimit(hero.titleLineLimit)

            if hero.elapsedDisplay != nil, let start = self.captureModel.presentation.sessionStartedAt {
                TimelineView(WatchHomeElapsedSchedule(
                    sessionStart: start,
                    sceneActive: self.scenePhase == .active,
                    luminanceReduced: self.isLuminanceReduced
                )) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(start)))
                    Text(watchElapsedDisplay(seconds: elapsed))
                        .font(.largeTitle.monospacedDigit())
                        .foregroundStyle(Color(watchHex: hero.elapsedHex))
                        .minimumScaleFactor(0.6)
                }
            }

            if let handoff = face.compactHandoff, let handoffLineHex = hero.handoffLineHex {
                VStack(spacing: 2) {
                    Text(handoff.line)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(watchHex: handoffLineHex))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)
                        .lineLimit(2)

                    if let subtext = handoff.subtext {
                        Text(subtext)
                            .font(.caption2)
                            .foregroundStyle(Color(watchHex: hero.handoffSubtextHex))
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.8)
                            .lineLimit(2)
                    }
                }
                .padding(.top, 2)
            }

            Text(hero.linkLine)
                .font(.caption2)
                .foregroundStyle(Color(watchHex: hero.linkHex))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.heroAccessibilityLabel(hero: hero, face: face))
    }

    func heroAccessibilityLabel(hero: WatchHomeHero, face: WatchFaceModel) -> String {
        var parts = [hero.title]
        if hero.elapsedDisplay != nil, let start = self.captureModel.presentation.sessionStartedAt {
            let elapsed = max(0, Int(Date().timeIntervalSince(start)))
            parts.append(watchElapsedSpoken(seconds: elapsed))
        }
        if let handoff = face.compactHandoff {
            parts.append(handoff.line)
            if let subtext = handoff.subtext {
                parts.append(subtext)
            }
        }
        parts.append(hero.linkLine)
        return parts.joined(separator: ", ")
    }

    var controlHint: String {
        self.captureModel.isRunning ? "turns the solstone app off" : "turns the solstone app on"
    }

    var controlButton: some View {
        let style = watchHomeControlStyle(isRunning: self.captureModel.isRunning)

        return Button {
            if self.captureModel.isRunning {
                self.captureModel.stop()
            } else {
                self.captureModel.start()
            }
        } label: {
            Text(style.label)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color(watchHex: style.labelHex).opacity(style.labelAlpha))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: WatchHomeControlStyle.minHeight)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            if let fillHex = style.fillHex {
                Capsule().fill(Color(watchHex: fillHex))
            }
        }
        .overlay {
            if let strokeHex = style.strokeHex {
                Capsule()
                    .strokeBorder(
                        Color(watchHex: strokeHex).opacity(style.strokeAlpha),
                        lineWidth: style.strokeLineWidth
                    )
            }
        }
        .accessibilityLabel(style.label)
        .accessibilityHint(self.controlHint)
    }
}

nonisolated struct WatchHomeElapsedSchedule: TimelineSchedule {
    let sessionStart: Date
    let sceneActive: Bool
    let luminanceReduced: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(
            sessionStart: self.sessionStart,
            sceneActive: self.sceneActive,
            luminanceReduced: self.luminanceReduced,
            current: startDate
        )
    }

    struct Entries: Sequence, IteratorProtocol {
        let sessionStart: Date
        let sceneActive: Bool
        let luminanceReduced: Bool
        var current: Date?

        mutating func next() -> Date? {
            guard let now = self.current else { return nil }
            let nextDate = watchHomeElapsedNextFire(
                sessionStart: self.sessionStart,
                now: now,
                sceneActive: self.sceneActive,
                luminanceReduced: self.luminanceReduced
            )
            self.current = nextDate
            return now
        }
    }
}

private extension Color {
    init(watchHex hex: String) {
        let rgb = SunArcOKLab.rgb(fromHex: hex)
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI
import WatchKit

/// The active face (2026-10-29). The first screen is the sun arc, an error pill when something
/// needs attention, and the one control. Everything else, the time running included, is in one
/// panel below the fold, reached with the Crown or by tapping the error pill. Text only
/// ever sits on an underlay: a standard material behind the pill and the panel, and system glass
/// on the control.
struct WatchHomeView: View {
    let model: WatchSessionModel
    let captureModel: WatchCaptureModel
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private static let panelID = "watchHome.panel"

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
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            if face.stateColorRole == .alert {
                                self.attentionPill(face.stateWord) {
                                    withAnimation {
                                        reader.scrollTo(Self.panelID, anchor: .top)
                                    }
                                }
                                .padding(.bottom, 8)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .containerRelativeFrame(.vertical)

                        self.panel(hero: hero, face: face)
                            .id(Self.panelID)
                            .padding(.bottom, 8)
                    }
                    .padding(.horizontal, 8)
                }
#if DEBUG && targetEnvironment(simulator)
                .task {
                    guard WatchFaceDebugScene.isScrolled(from: ProcessInfo.processInfo.arguments) else { return }
                    try? await Task.sleep(for: .milliseconds(400))
                    reader.scrollTo(Self.panelID, anchor: .top)
                }
#endif
            }

            // The scroll ends above the control, so only the sun arc is ever behind its glass.
            self.controlButton
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 2)
        }
        .onChange(of: self.scenePhase) { _, newPhase in
            if newPhase == .active {
                self.captureModel.handleOwnerVisibleRaise()
            }
        }
    }
}

private extension WatchHomeView {
    /// A standard material behind text over the sun arc, or an opaque fill under Reduce Transparency.
    @ViewBuilder
    func underlay(_ shape: some Shape) -> some View {
        if self.reduceTransparency {
            shape.fill(Color(watchHex: WatchHomePalette.underlayOpaque))
        } else {
            shape.fill(.regularMaterial)
        }
    }

    /// The error, small, on the first screen. A tap scrolls the details panel into view.
    func attentionPill(_ message: String, showDetails: @escaping () -> Void) -> some View {
        Button(action: showDetails) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(watchHex: WatchHomePalette.alertDot))
                    .frame(width: 7, height: 7)
                Text(message)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(watchHex: WatchHomePalette.alert))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background { self.underlay(Capsule()) }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("watchHome.attentionPill")
    }

    func panel(hero: WatchHomeHero, face: WatchFaceModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            self.panelHeader(hero: hero, face: face)

            self.rule

            VStack(alignment: .leading, spacing: 5) {
                ForEach(face.detailRows, id: \.label) { row in
                    HStack(spacing: 8) {
                        Text(row.label)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 6)
                        Text("\(row.value)")
                            .monospacedDigit()
                            .minimumScaleFactor(0.7)
                    }
                    .font(.caption)
                    .foregroundStyle(Color(watchHex: WatchHomePalette.calm))
                }

                if let subtext = face.compactHandoff?.subtext {
                    self.smallLine(subtext)
                }

                Text(face.linkLine)
                    .font(.caption)
                    .foregroundStyle(Color(watchHex: WatchHomePalette.calm))
                    .minimumScaleFactor(0.7)
            }

            self.rule

            VStack(alignment: .leading, spacing: 4) {
                if let trustLine = face.trustLine {
                    self.smallLine(trustLine)
                }
                self.smallLine(AboutBlock.line(
                    name: "watch app",
                    version: AppVersion.shortVersion,
                    build: AppVersion.build,
                    os: "watchos",
                    osVersion: WKInterfaceDevice.current().systemVersion
                ))
                self.smallLine(AboutBlock.line(
                    name: "journal",
                    version: self.model.journalVersion.version ?? "",
                    build: self.model.journalVersion.journalBuild ?? "",
                    os: self.model.journalVersion.journalOS ?? "",
                    osVersion: self.model.journalVersion.journalOSVersion ?? "",
                    arch: self.model.journalVersion.journalArch ?? "",
                    isCurrent: self.model.journalVersion.isCurrent,
                    observedAt: self.model.journalVersion.versionObservedAt,
                    now: Date()
                ))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { self.underlay(RoundedRectangle(cornerRadius: 18, style: .continuous)) }
    }

    /// The panel's lead: the time running while it's on, otherwise the state in a word, or the error.
    @ViewBuilder
    func panelHeader(hero: WatchHomeHero, face: WatchFaceModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
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
                        .lineLimit(1)
                }
                Text(SourceVocabulary.watchPanelRunning)
                    .font(.footnote)
                    .foregroundStyle(Color(watchHex: WatchHomePalette.calm))
            } else {
                Text(hero.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(watchHex: hero.titleHex))
                    .minimumScaleFactor(0.6)
                    .lineLimit(hero.titleLineLimit)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.headerAccessibilityLabel(hero: hero, face: face))
    }

    func headerAccessibilityLabel(hero: WatchHomeHero, face: WatchFaceModel) -> String {
        if hero.elapsedDisplay != nil, let start = self.captureModel.presentation.sessionStartedAt {
            let elapsed = max(0, Int(Date().timeIntervalSince(start)))
            return "\(SourceVocabulary.watchPanelRunning), \(watchElapsedSpoken(seconds: elapsed))"
        }
        return hero.title
    }

    var rule: some View {
        Rectangle()
            .fill(Color(watchHex: WatchHomePalette.calm).opacity(0.28))
            .frame(height: 1)
            .padding(.top, 9)
            .padding(.bottom, 7)
    }

    func smallLine(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(Color(watchHex: WatchHomePalette.calm))
            .minimumScaleFactor(0.7)
            .fixedSize(horizontal: false, vertical: true)
    }

    var controlHint: String {
        self.captureModel.isRunning ? "turns the solstone app off" : "turns the solstone app on"
    }

    /// The one control, in the bottom bar: prominent glass tinted orange to start, plain glass to stop.
    @ViewBuilder
    var controlButton: some View {
        let style = watchHomeControlStyle(isRunning: self.captureModel.isRunning)
        let button = Button {
            if self.captureModel.isRunning {
                self.captureModel.stop()
            } else {
                self.captureModel.start()
            }
        } label: {
            Text(style.label)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color(watchHex: style.labelHex))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: WatchHomeControlStyle.minHeight)
        }
        .buttonBorderShape(.capsule)
        .accessibilityLabel(style.label)
        .accessibilityHint(self.controlHint)

        if let tintHex = style.tintHex {
            button
                .buttonStyle(.glassProminent)
                .tint(Color(watchHex: tintHex))
        } else {
            button
                .buttonStyle(.glass)
        }
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

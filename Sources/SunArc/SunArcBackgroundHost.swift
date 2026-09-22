// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI

/// The host surface's day ground. Its night counterpart is always the canonical SunArc mix;
/// callers cannot provide a mismatched dark token.
nonisolated struct SunArcGroundPalette: Sendable, Equatable {
    let dayGroundHex: String

    init(dayGroundHex: String) {
        self.dayGroundHex = dayGroundHex
    }
}

#if DEBUG
/// A deterministic presentation scene for simulator screenshots. This is compiled out of
/// release builds, and does not affect any capture or location state.
nonisolated struct SunArcBackgroundDebugOverride: Sendable {
    let date: Date
    let timeZone: TimeZone
    let presentationCoordinate: SunArcCoordinate?
}

nonisolated enum SunArcBackgroundDebugScene {
    static func sceneOverride(for arguments: [String]) -> SunArcBackgroundDebugOverride? {
        if arguments.contains("--ui-test-sun-arc-denver-dawn") {
            return SunArcBackgroundDebugOverride(
                date: Date(timeIntervalSince1970: 1_789_820_040),
                timeZone: TimeZone(identifier: "America/Denver")!,
                presentationCoordinate: nil
            )
        }
        if arguments.contains("--ui-test-sun-arc-denver-midday") {
            return SunArcBackgroundDebugOverride(
                date: Date(timeIntervalSince1970: 1_789_843_980),
                timeZone: TimeZone(identifier: "America/Denver")!,
                presentationCoordinate: nil
            )
        }
        if arguments.contains("--ui-test-sun-arc-denver-night") {
            return SunArcBackgroundDebugOverride(
                date: Date(timeIntervalSince1970: 1_789_876_800),
                timeZone: TimeZone(identifier: "America/Denver")!,
                presentationCoordinate: nil
            )
        }
        if arguments.contains("--ui-test-sun-arc-held-coordinate") {
            return SunArcBackgroundDebugOverride(
                date: Date(timeIntervalSince1970: 1_789_840_800),
                timeZone: TimeZone(identifier: "America/Denver")!,
                presentationCoordinate: SunArcCoordinate(latitude: -33.87, longitude: 151.22)
            )
        }
        if arguments.contains("--ui-test-sun-arc-timezone-only") {
            return SunArcBackgroundDebugOverride(
                date: Date(timeIntervalSince1970: 1_789_786_800),
                timeZone: TimeZone(identifier: "Asia/Tokyo")!,
                presentationCoordinate: nil
            )
        }
        if arguments.contains("--ui-test-sun-arc-unknown-zone") {
            return SunArcBackgroundDebugOverride(
                date: Date(timeIntervalSince1970: 1_789_819_200),
                timeZone: TimeZone(secondsFromGMT: 0)!,
                presentationCoordinate: nil
            )
        }
        return nil
    }
}
#endif

private nonisolated struct SunArcBackgroundMoment: Sendable {
    let time: SunArcTime
    let groundHex: String
    let isDark: Bool
    let envelope: Double

    static func resolve(
        date: Date,
        timeZone: TimeZone,
        palette: SunArcGroundPalette,
        presentationCoordinate: SunArcCoordinate?
    ) -> SunArcBackgroundMoment {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        let solar = SunArcSolar.pair(
            for: date,
            heldLocation: presentationCoordinate,
            timeZone: timeZone
        )
        let time = SunArcTime.compute(
            minutes: SunArcTime.minutesSinceMidnight(date, calendar: calendar),
            riseMinutes: solar.riseMinutes,
            setMinutes: solar.setMinutes
        )
        let groundHex = SunArcGround.currentGround(
            dayGroundHex: palette.dayGroundHex,
            night: time.night
        )
        return SunArcBackgroundMoment(
            time: time,
            groundHex: groundHex,
            isDark: SunArcGround.isDark(groundHex: groundHex),
            envelope: SunArcEnvelope.value(at: time.t)
        )
    }
}

/// The sun, all day — one Canvas behind a native surface and one minute clock shared by its
/// ground, mark, and content appearance.
///
/// Two callers share this one engine and drawing routine:
/// - `SunArcBackgroundHost` wraps arbitrary content in a `ZStack`, for a root shell with no
///   separate native container layer of its own — watchOS's `WindowGroup` root.
/// - `SunArcBackgroundSurface` renders the ground/glow/mark alone, installed as a
///   `NavigationStack`'s or `NavigationSplitView`'s own `.containerBackground(for:)` content
///   on iOS/iPadOS. That container paints its background in its own separately hosted layer;
///   an outer `ZStack` sibling — all `SunArcBackgroundHost` alone can offer there — never
///   reaches it, and neither does clearing that layer to a plain colour: there is nothing
///   behind it to reveal. Installing this view AS that layer's content is what actually
///   paints there.
struct SunArcBackgroundHost<Content: View>: View {
    private let palette: SunArcGroundPalette
    private let presentationCoordinate: SunArcCoordinate?
#if DEBUG
    private let debugOverride: SunArcBackgroundDebugOverride?
#endif
    private let content: () -> Content

    init(
        palette: SunArcGroundPalette,
        presentationCoordinate: SunArcCoordinate?,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.palette = palette
        self.presentationCoordinate = presentationCoordinate
#if DEBUG
        self.debugOverride = nil
#endif
        self.content = content
    }

#if DEBUG
    init(
        palette: SunArcGroundPalette,
        presentationCoordinate: SunArcCoordinate?,
        debugOverride: SunArcBackgroundDebugOverride?,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.palette = palette
        self.presentationCoordinate = presentationCoordinate
        self.debugOverride = debugOverride
        self.content = content
    }
#endif

    var body: some View {
#if DEBUG
        SunArcBackgroundTimeline(
            palette: self.palette,
            presentationCoordinate: self.presentationCoordinate,
            debugOverride: self.debugOverride
        ) { moment in
            ZStack {
                SunArcGroundCanvas(moment: moment)
                self.content()
            }
        }
#else
        SunArcBackgroundTimeline(
            palette: self.palette,
            presentationCoordinate: self.presentationCoordinate
        ) { moment in
            ZStack {
                SunArcGroundCanvas(moment: moment)
                self.content()
            }
        }
#endif
    }
}

/// The ground/glow/mark alone, with no content of its own — see `SunArcBackgroundHost`'s
/// doc comment for why iOS/iPadOS installs this as a navigation container's own
/// `.containerBackground(for:)` content instead of wrapping the shell in a
/// `SunArcBackgroundHost`-style `ZStack`.
struct SunArcBackgroundSurface: View {
    private let palette: SunArcGroundPalette
    private let presentationCoordinate: SunArcCoordinate?
#if DEBUG
    private let debugOverride: SunArcBackgroundDebugOverride?
#endif

    init(
        palette: SunArcGroundPalette,
        presentationCoordinate: SunArcCoordinate?
    ) {
        self.palette = palette
        self.presentationCoordinate = presentationCoordinate
#if DEBUG
        self.debugOverride = nil
#endif
    }

#if DEBUG
    init(
        palette: SunArcGroundPalette,
        presentationCoordinate: SunArcCoordinate?,
        debugOverride: SunArcBackgroundDebugOverride?
    ) {
        self.palette = palette
        self.presentationCoordinate = presentationCoordinate
        self.debugOverride = debugOverride
    }
#endif

    var body: some View {
#if DEBUG
        SunArcBackgroundTimeline(
            palette: self.palette,
            presentationCoordinate: self.presentationCoordinate,
            debugOverride: self.debugOverride
        ) { moment in
            SunArcGroundCanvas(moment: moment)
        }
#else
        SunArcBackgroundTimeline(
            palette: self.palette,
            presentationCoordinate: self.presentationCoordinate
        ) { moment in
            SunArcGroundCanvas(moment: moment)
        }
#endif
    }
}

/// Shared per-minute clock: resolves the current `SunArcBackgroundMoment` once and hands it
/// to `content`, so ground/glow/mark and appearance can never drift from each other or from
/// whatever a caller draws with that same moment. `content` is rendered as part of whatever
/// hosts this timeline — a `ZStack` sibling for `SunArcBackgroundHost`, a container's own
/// background layer for `SunArcBackgroundSurface` — so `.preferredColorScheme` applied here
/// follows that same placement rather than needing its own separate mechanism.
private struct SunArcBackgroundTimeline<ClockContent: View>: View {
    let palette: SunArcGroundPalette
    let presentationCoordinate: SunArcCoordinate?
#if DEBUG
    let debugOverride: SunArcBackgroundDebugOverride?
#endif
    let content: (SunArcBackgroundMoment) -> ClockContent

    init(
        palette: SunArcGroundPalette,
        presentationCoordinate: SunArcCoordinate?,
        @ViewBuilder content: @escaping (SunArcBackgroundMoment) -> ClockContent
    ) {
        self.palette = palette
        self.presentationCoordinate = presentationCoordinate
#if DEBUG
        self.debugOverride = nil
#endif
        self.content = content
    }

#if DEBUG
    init(
        palette: SunArcGroundPalette,
        presentationCoordinate: SunArcCoordinate?,
        debugOverride: SunArcBackgroundDebugOverride?,
        @ViewBuilder content: @escaping (SunArcBackgroundMoment) -> ClockContent
    ) {
        self.palette = palette
        self.presentationCoordinate = presentationCoordinate
        self.debugOverride = debugOverride
        self.content = content
    }
#endif

    var body: some View {
        TimelineView(.everyMinute) { context in
#if DEBUG
            let date = self.debugOverride?.date ?? context.date
            let timeZone = self.debugOverride?.timeZone ?? .autoupdatingCurrent
            let coordinate = self.debugOverride != nil
                ? self.debugOverride?.presentationCoordinate
                : self.presentationCoordinate
#else
            let date = context.date
            let timeZone = TimeZone.autoupdatingCurrent
            let coordinate = self.presentationCoordinate
#endif
            let moment = SunArcBackgroundMoment.resolve(
                date: date,
                timeZone: timeZone,
                palette: self.palette,
                presentationCoordinate: coordinate
            )

            self.content(moment)
                .preferredColorScheme(moment.isDark ? .dark : .light)
        }
    }
}

private struct SunArcGroundCanvas: View {
    let moment: SunArcBackgroundMoment

    var body: some View {
        Canvas { context, size in
            SunArcBackgroundDrawing.draw(moment: self.moment, in: &context, size: size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private enum SunArcBackgroundDrawing {
    static func draw(
        moment: SunArcBackgroundMoment,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard size.width > 0, size.height > 0 else { return }
        let diameter = SunArc.phi * Double(min(size.width, size.height))
        let tipRadius = diameter / 2
        let placement = SunArcPlacement(size: size, tipRadius: tipRadius)
        let clampedT = min(1, max(0, moment.time.t))
        let position = placement.position(at: clampedT)
        let onVisible = moment.time.t > -0.02 && moment.time.t < 1.02
        let opacity = onVisible
            ? SunArc.peakOpacity * moment.envelope * (1 - moment.time.night)
            : 0

        // Ground → glow → mark is the locked visual layer order.
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Color(sunArcHex: moment.groundHex))
        )

        let glow = SunArcGlow.compute(
            time: moment.time,
            sunPosition: position,
            envelope: moment.envelope,
            onVisible: onVisible,
            placement: placement
        )
        if glow.alpha > 0.002 {
            let glowRadius = SunArc.phi * tipRadius
            let glowColor = Color(sunArcHex: SunArc.goldHex)
            let gradient = Gradient(stops: [
                .init(color: glowColor.opacity(glow.alpha), location: 0),
                .init(
                    color: glowColor.opacity(glow.alpha * SunArc.gradientMidRatio),
                    location: SunArc.gradientMidStop
                ),
                .init(color: glowColor.opacity(0), location: 1),
            ])
            context.fill(
                Path(ellipseIn: CGRect(
                    x: glow.position.x - glowRadius,
                    y: glow.position.y - glowRadius,
                    width: glowRadius * 2,
                    height: glowRadius * 2
                )),
                with: .radialGradient(
                    gradient,
                    center: glow.position,
                    startRadius: 0,
                    endRadius: glowRadius
                )
            )
        }

        guard onVisible, opacity > 0.001 else { return }
        context.drawLayer { layer in
            layer.opacity = opacity
            layer.translateBy(x: position.x, y: position.y)
            let scale = diameter / Double(SunArcMark.span)
            layer.scaleBy(x: scale, y: scale)
            layer.translateBy(x: -SunArcMark.center.x, y: -SunArcMark.center.y)
            layer.fill(
                SunArcMark.beamsPath(),
                with: .color(Color(sunArcHex: SunArc.goldHex))
            )
            layer.stroke(
                SunArcMark.ringPath(),
                with: .color(Color(sunArcHex: SunArc.orangeHex)),
                lineWidth: SunArcMark.ringLineWidth
            )
        }
    }
}

private extension Color {
    init(sunArcHex hex: String) {
        let rgb = SunArcOKLab.rgb(fromHex: hex)
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }
}

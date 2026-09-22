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

nonisolated struct SunArcBackgroundMoment: Sendable {
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
/// The host resolves one moment for the whole surface. watchOS draws the root canvas
/// directly. iOS/iPadOS navigation content reads the same moment and viewport through the
/// environment and draws the clipped part of that one scene inside each native navigation
/// host. That keeps one sun across an iPad split without reaching into private UIKit hosts.
struct SunArcBackgroundHost<Content: View>: View {
    private let palette: SunArcGroundPalette
    private let presentationCoordinate: SunArcCoordinate?
#if DEBUG
    private let debugOverride: SunArcBackgroundDebugOverride?
#endif
    private let content: () -> Content
    @State private var viewportFrame = CGRect.zero

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
                    .environment(
                        \.sunArcBackgroundContext,
                        SunArcBackgroundContext(moment: moment, viewportFrame: self.viewportFrame)
                    )
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { self.viewportFrame = $0 }
        }
#else
        SunArcBackgroundTimeline(
            palette: self.palette,
            presentationCoordinate: self.presentationCoordinate
        ) { moment in
            ZStack {
                SunArcGroundCanvas(moment: moment)
                self.content()
                    .environment(
                        \.sunArcBackgroundContext,
                        SunArcBackgroundContext(moment: moment, viewportFrame: self.viewportFrame)
                    )
            }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { self.viewportFrame = $0 }
        }
#endif
    }
}

/// The clipped portion of the root SunArc scene belonging behind one native navigation
/// content host. Every instance uses the root host's moment and global viewport, so the two
/// iPad columns meet as one drawing rather than each growing its own sun.
struct SunArcContentBackground: View {
    @Environment(\.sunArcBackgroundContext) private var context

    @ViewBuilder
    var body: some View {
        if let context {
            SunArcGroundCanvas(moment: context.moment, viewportFrame: context.viewportFrame)
        } else {
            Color.clear
        }
    }
}

struct SunArcBackgroundContext: Sendable {
    let moment: SunArcBackgroundMoment
    let viewportFrame: CGRect
}

private struct SunArcBackgroundContextKey: EnvironmentKey {
    static let defaultValue: SunArcBackgroundContext? = nil
}

extension EnvironmentValues {
    var sunArcBackgroundContext: SunArcBackgroundContext? {
        get { self[SunArcBackgroundContextKey.self] }
        set { self[SunArcBackgroundContextKey.self] = newValue }
    }
}

/// Shared per-minute clock: resolves the current `SunArcBackgroundMoment` once and hands it
/// to `content`, so ground/glow/mark and appearance can never drift from each other. The
/// root host also passes that exact moment to native navigation content through the
/// environment; `.preferredColorScheme` therefore follows the same clock.
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
    var viewportFrame: CGRect?

    init(moment: SunArcBackgroundMoment, viewportFrame: CGRect? = nil) {
        self.moment = moment
        self.viewportFrame = viewportFrame
    }

    /// `GeometryReader`, with the `Canvas` explicitly framed to its measured
    /// `proxy.size`, rather than trusting `Canvas`'s own closure-provided size.
    ///
    /// The root and every clipped navigation-content copy need their host's exact bounds;
    /// `.frame(maxWidth: .infinity, maxHeight: .infinity)` alone leaves a background Canvas
    /// with no content-derived ideal size. `GeometryReader` supplies those bounds without
    /// changing the foreground proposal.
    var body: some View {
        GeometryReader { proxy in
            let localFrame = proxy.frame(in: .global)
            if let sceneFrame = SunArcSceneFrame.resolve(
                viewportFrame: self.viewportFrame,
                localFrame: localFrame
            ) {
                Canvas { context, _ in
                    SunArcBackgroundDrawing.draw(
                        moment: self.moment,
                        in: &context,
                        size: proxy.size,
                        sceneSize: sceneFrame.size,
                        sceneOffset: CGSize(
                            width: localFrame.minX - sceneFrame.minX,
                            height: localFrame.minY - sceneFrame.minY
                        )
                    )
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                // The root viewport arrives from `onGeometryChange` before the next
                // display pass. Until then, paint only the shared ground: drawing a
                // local mark in each iPad column would briefly create two suns.
                Color(sunArcHex: self.moment.groundHex)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

}

nonisolated enum SunArcSceneFrame {
    /// `nil` means the root canvas and therefore uses its own measured bounds. An
    /// explicit but empty viewport means a navigation-content slice is awaiting the
    /// root measurement and must draw ground only, never an independent local sun.
    static func resolve(viewportFrame: CGRect?, localFrame: CGRect) -> CGRect? {
        guard let viewportFrame else { return localFrame }
        guard viewportFrame.width > 0, viewportFrame.height > 0 else { return nil }
        return viewportFrame
    }
}

private enum SunArcBackgroundDrawing {
    static func draw(
        moment: SunArcBackgroundMoment,
        in context: inout GraphicsContext,
        size: CGSize,
        sceneSize: CGSize,
        sceneOffset: CGSize
    ) {
        guard size.width > 0, size.height > 0,
              sceneSize.width > 0, sceneSize.height > 0
        else { return }
        let diameter = SunArc.phi * Double(min(sceneSize.width, sceneSize.height))
        let tipRadius = diameter / 2
        let placement = SunArcPlacement(size: sceneSize, tipRadius: tipRadius)
        let clampedT = min(1, max(0, moment.time.t))
        let scenePosition = placement.position(at: clampedT)
        let position = CGPoint(
            x: scenePosition.x - sceneOffset.width,
            y: scenePosition.y - sceneOffset.height
        )
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
            sunPosition: scenePosition,
            envelope: moment.envelope,
            onVisible: onVisible,
            placement: placement
        )
        if glow.alpha > 0.002 {
            let glowRadius = SunArc.phi * tipRadius
            let glowPosition = CGPoint(
                x: glow.position.x - sceneOffset.width,
                y: glow.position.y - sceneOffset.height
            )
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
                    x: glowPosition.x - glowRadius,
                    y: glowPosition.y - glowRadius,
                    width: glowRadius * 2,
                    height: glowRadius * 2
                )),
                with: .radialGradient(
                    gradient,
                    center: glowPosition,
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

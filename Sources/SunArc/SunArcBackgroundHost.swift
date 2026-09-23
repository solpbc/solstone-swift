// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SwiftUI

/// The one per-surface choice §6 allows: the light appearance's day ground (another F3 ground,
/// such as the deck's tile cream). The light night and true dark, and the whole dark row, are
/// the table's; callers cannot provide a mismatched token.
nonisolated struct SunArcGroundPalette: Sendable, Equatable {
    let lightDayHex: String

    init(lightDayHex: String = SunArc.surfaceCreamHex) {
        self.lightDayHex = lightDayHex
    }

    func grounds(for appearance: SunArcAppearance) -> SunArcGrounds {
        switch appearance {
        case .light: SunArcGrounds.light(day: self.lightDayHex)
        case .dark: SunArcGrounds.dark
        }
    }
}

extension SunArcAppearance {
    /// The owner's system appearance, as SwiftUI reports it. §6 / §10: read it, never set it.
    init(_ colorScheme: ColorScheme) {
        self = colorScheme == .dark ? .dark : .light
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
    /// `--ui-test-sun-arc-denver-0923=HH:MM`: that wall-clock minute on 2026-09-23 in Denver,
    /// the day of the spec's §4a worked numbers.
    static let denver0923Prefix = "--ui-test-sun-arc-denver-0923="

    static func denver0923(_ value: String) -> Date? {
        let parts = value.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: hour, minute: minute))
    }

    static func sceneOverride(for arguments: [String]) -> SunArcBackgroundDebugOverride? {
        if let raw = arguments.first(where: { $0.hasPrefix(Self.denver0923Prefix) }),
           let date = Self.denver0923(String(raw.dropFirst(Self.denver0923Prefix.count))) {
            return SunArcBackgroundDebugOverride(
                date: date,
                timeZone: TimeZone(identifier: "America/Denver")!,
                presentationCoordinate: nil
            )
        }
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

/// A fixed instant and zone the timeline draws instead of the clock. Only the DEBUG
/// screenshot scenes ever build one.
nonisolated struct SunArcBackgroundScene: Sendable {
    let date: Date
    let timeZone: TimeZone
    let presentationCoordinate: SunArcCoordinate?
}

nonisolated struct SunArcBackgroundMoment: Sendable {
    let time: SunArcTime
    let envelope: Double
    let twilight: SunArcTwilight
    let appearance: SunArcAppearance
    let grounds: SunArcGrounds
    let groundHex: String

    static func resolve(
        date: Date,
        timeZone: TimeZone,
        palette: SunArcGroundPalette,
        appearance: SunArcAppearance,
        presentationCoordinate: SunArcCoordinate?
    ) -> SunArcBackgroundMoment {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        let solar = SunArcSolar.pair(
            for: date,
            heldLocation: presentationCoordinate,
            timeZone: timeZone
        )
        return Self.at(
            minutes: SunArcTime.minutesSinceMidnight(date, calendar: calendar),
            riseMinutes: solar.riseMinutes,
            setMinutes: solar.setMinutes,
            grounds: palette.grounds(for: appearance),
            appearance: appearance
        )
    }

    /// The pure core of `resolve`: one clock minute, the day's sunrise and sunset, and the
    /// owner's appearance → everything a frame needs. `SUNARC.both()`'s inputs, less the size
    /// (which `sunArcCanvasDrawing` takes). The worked-numbers tests call this same function.
    static func at(
        minutes: Double,
        riseMinutes: Double,
        setMinutes: Double,
        grounds: SunArcGrounds,
        appearance: SunArcAppearance
    ) -> SunArcBackgroundMoment {
        let time = SunArcTime.compute(minutes: minutes, riseMinutes: riseMinutes, setMinutes: setMinutes)
        let envelope = SunArcEnvelope.value(at: time.t)
        let twilight = SunArcTwilight.compute(time: time, envelope: envelope)
        return SunArcBackgroundMoment(
            time: time,
            envelope: envelope,
            twilight: twilight,
            appearance: appearance,
            grounds: grounds,
            groundHex: SunArcGround.current(grounds: grounds, night: time.night, twilightWeight: twilight.w)
        )
    }
}

/// The sun, all day — one Canvas behind a native surface and one minute clock shared by its
/// ground, glows and mark.
///
/// The host resolves one moment for the whole surface. watchOS draws the root canvas
/// directly. iOS/iPadOS navigation content reads the same moment and viewport through the
/// environment and draws the clipped part of that one scene inside each native navigation
/// host. That keeps one sun across an iPad split without reaching into private UIKit hosts.
///
/// 🔒 The appearance is the owner's (2026-09-23): the host reads `\.colorScheme` and never
/// sets it. The watch, which has no light mode, passes `fixedAppearance: .dark`.
struct SunArcBackgroundHost<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let palette: SunArcGroundPalette
    private let presentationCoordinate: SunArcCoordinate?
    private let fixedAppearance: SunArcAppearance?
#if DEBUG
    private let debugOverride: SunArcBackgroundDebugOverride?
#endif
    private let content: () -> Content
    private let luminanceReduced: Bool
    @State private var viewportFrame = CGRect.zero

    init(
        palette: SunArcGroundPalette,
        presentationCoordinate: SunArcCoordinate?,
        fixedAppearance: SunArcAppearance? = nil,
        luminanceReduced: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.palette = palette
        self.presentationCoordinate = presentationCoordinate
        self.fixedAppearance = fixedAppearance
        self.luminanceReduced = luminanceReduced
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
        fixedAppearance: SunArcAppearance? = nil,
        luminanceReduced: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.palette = palette
        self.presentationCoordinate = presentationCoordinate
        self.debugOverride = debugOverride
        self.fixedAppearance = fixedAppearance
        self.luminanceReduced = luminanceReduced
        self.content = content
    }
#endif

    private var appearance: SunArcAppearance {
        self.fixedAppearance ?? SunArcAppearance(self.colorScheme)
    }

    var body: some View {
        SunArcBackgroundTimeline(
            palette: self.palette,
            appearance: self.appearance,
            presentationCoordinate: self.presentationCoordinate,
            scene: self.debugScene
        ) { moment in
            ZStack {
                SunArcGroundCanvas(
                    moment: moment,
                    luminanceReduced: self.luminanceReduced
                )
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
    }

    /// A fixed presentation scene for simulator screenshots; always `nil` in release builds.
    private var debugScene: SunArcBackgroundScene? {
#if DEBUG
        self.debugOverride.map {
            SunArcBackgroundScene(
                date: $0.date,
                timeZone: $0.timeZone,
                presentationCoordinate: $0.presentationCoordinate
            )
        }
#else
        nil
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
/// to `content`, so ground, glows and mark can never drift from each other. The root host
/// also passes that exact moment to native navigation content through the environment. The
/// clock picks the time of day only; ⛔ it never picks the appearance.
private struct SunArcBackgroundTimeline<ClockContent: View>: View {
    let palette: SunArcGroundPalette
    let appearance: SunArcAppearance
    let presentationCoordinate: SunArcCoordinate?
    let scene: SunArcBackgroundScene?
    @ViewBuilder let content: (SunArcBackgroundMoment) -> ClockContent

    var body: some View {
        TimelineView(.everyMinute) { context in
            let date = self.scene?.date ?? context.date
            let timeZone = self.scene?.timeZone ?? .autoupdatingCurrent
            let coordinate = self.scene != nil
                ? self.scene?.presentationCoordinate
                : self.presentationCoordinate
            self.content(SunArcBackgroundMoment.resolve(
                date: date,
                timeZone: timeZone,
                palette: self.palette,
                appearance: self.appearance,
                presentationCoordinate: coordinate
            ))
        }
    }
}

private struct SunArcGroundCanvas: View {
    let moment: SunArcBackgroundMoment
    var viewportFrame: CGRect?
    var luminanceReduced: Bool

    init(
        moment: SunArcBackgroundMoment,
        viewportFrame: CGRect? = nil,
        luminanceReduced: Bool = false
    ) {
        self.moment = moment
        self.viewportFrame = viewportFrame
        self.luminanceReduced = luminanceReduced
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
                        ),
                        luminanceReduced: self.luminanceReduced
                    )
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                // The root viewport arrives from `onGeometryChange` before the next
                // display pass. Until then, paint only the shared ground: drawing a
                // local mark in each iPad column would briefly create two suns.
                Color(sunArcHex: self.luminanceReduced ? "#000000" : self.moment.groundHex)
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

extension SunArcBackgroundMoment {
    /// This moment drawn on a scene of `sceneSize`: the one frame function the Canvas and the
    /// tests share.
    func drawing(
        sceneSize: CGSize,
        luminanceReduced: Bool = false
    ) -> (placement: SunArcPlacement, drawing: SunArcCanvasDrawing) {
        let diameter = SunArc.phi * Double(min(sceneSize.width, sceneSize.height))
        let placement = SunArcPlacement(size: sceneSize, tipRadius: diameter / 2)
        return (placement, sunArcCanvasDrawing(
            time: self.time,
            envelope: self.envelope,
            twilight: self.twilight,
            placement: placement,
            grounds: self.grounds,
            appearance: self.appearance,
            luminanceReduced: luminanceReduced
        ))
    }
}

private enum SunArcBackgroundDrawing {
    static func draw(
        moment: SunArcBackgroundMoment,
        in context: inout GraphicsContext,
        size: CGSize,
        sceneSize: CGSize,
        sceneOffset: CGSize,
        luminanceReduced: Bool
    ) {
        guard size.width > 0, size.height > 0,
              sceneSize.width > 0, sceneSize.height > 0
        else { return }
        let (placement, drawing) = moment.drawing(
            sceneSize: sceneSize,
            luminanceReduced: luminanceReduced
        )
        let diameter = 2 * placement.tipRadius

        // Ground → glows → mark is the locked visual layer order.
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Color(sunArcHex: drawing.groundHex))
        )

        for glow in drawing.glows where glow.alpha > 0.002 {
            let center = CGPoint(
                x: glow.center.x - sceneOffset.width,
                y: glow.center.y - sceneOffset.height
            )
            let color = Color(sunArcHex: glow.colorHex)
            let gradient = Gradient(stops: [
                .init(color: color.opacity(glow.alpha), location: 0),
                .init(
                    color: color.opacity(glow.alpha * SunArc.gradientMidRatio),
                    location: SunArc.gradientMidStop
                ),
                .init(color: color.opacity(0), location: 1),
            ])
            context.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - glow.radius,
                    y: center.y - glow.radius,
                    width: glow.radius * 2,
                    height: glow.radius * 2
                )),
                with: .radialGradient(
                    gradient,
                    center: center,
                    startRadius: 0,
                    endRadius: glow.radius
                )
            )
        }

        guard drawing.drawSun else { return }
        let scenePosition = placement.position(at: min(1, max(0, moment.time.t)))
        let position = CGPoint(
            x: scenePosition.x - sceneOffset.width,
            y: scenePosition.y - sceneOffset.height
        )
        context.drawLayer { layer in
            layer.opacity = drawing.sunOpacity
            layer.translateBy(x: position.x, y: position.y)
            let scale = diameter / Double(SunArcMark.span)
            layer.scaleBy(x: scale, y: scale)
            layer.translateBy(x: -SunArcMark.center.x, y: -SunArcMark.center.y)
            layer.fill(
                SunArcMark.beamsPath(),
                with: .color(Color(sunArcHex: drawing.beamHex))
            )
            layer.stroke(
                SunArcMark.ringPath(),
                with: .color(Color(sunArcHex: drawing.ringHex)),
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

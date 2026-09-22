// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit

/// The Day Home background follows the deck's established light ground, while its night
/// counterpart remains the locked SunArc OKLab mix.
nonisolated enum DeckSunArcPalette {
    static let value = SunArcGroundPalette(dayGroundHex: "#FCF3E4")
}

/// The shell's usage tokens: the ground it sits on, the surfaces that sit on the
/// ground, and the measurements both are laid out from.
///
/// Identity values (sol orange, gold, cream) are CMO's and live in `Colors.swift`,
/// mirrored by `make brand-sync`. Everything here is *usage* — how those values are
/// applied on a product surface — which is VPX's to set. Nothing below introduces a
/// new brand colour; the dark grounds are the warm neutrals sol cream implies, so a
/// surface reads as the same product in either appearance.
///
/// Why this exists: the shell had been drawing itself on `systemGroupedBackground`,
/// which is a neutral grey in both appearances. That is a competent iOS app and it is
/// nobody's product. The deck is the one surface an owner sees every day.
extension Color {
    /// The ground the deck sits on. Warm cream by day, a warm near-black by night —
    /// both carry the same hue family as sol orange, so the app never goes grey.
    static let deckGround = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.071, green: 0.063, blue: 0.051, alpha: 1)   // #121010
            : UIColor(red: 0.988, green: 0.953, blue: 0.894, alpha: 1)   // sol cream
    })

    /// A tile, a grouped row, a card: the surface that sits *on* the ground.
    static let deckSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.125, green: 0.114, blue: 0.098, alpha: 1)   // #201D19
            : UIColor(red: 0.996, green: 0.988, blue: 0.973, alpha: 1)   // sol cream bright
    })

    /// A surface raised one step above `deckSurface` — the row inside a card, the
    /// selected state. Kept distinct so nesting never has to reuse the same fill.
    static let deckSurfaceRaised = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.169, green: 0.153, blue: 0.129, alpha: 1)   // #2B2721
            : UIColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1)
    })

    /// The hairline that separates a surface from the ground. Carries a little warmth
    /// so the edge does not read as a grey system separator.
    static let deckHairline = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.000, green: 0.882, blue: 0.729, alpha: 0.10)
            : UIColor(red: 0.427, green: 0.318, blue: 0.169, alpha: 0.14)
    })

    /// Orange that stays legible as a *tint* in both appearances. On the dark ground
    /// the brand orange is bright enough to use directly; on cream it needs the ink
    /// value to clear contrast. `textOrangeAA` is normal-size text on light ground.
    static let solOrangeAdaptive = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.949, green: 0.643, blue: 0.318, alpha: 1)
            : UIColor(red: 0.690, green: 0.416, blue: 0.102, alpha: 1)   // orange ink
    })
}

/// Measurements the shell is laid out from. One place, so a margin cannot drift
/// between the deck, a pane and a detail view.
nonisolated enum ShellMetrics {
    /// The gutter every surface uses against the screen edge.
    static let screenMargin: CGFloat = 16
    /// Between two tiles, and between two cards.
    static let gutter: CGFloat = 12
    /// Inside a card.
    static let surfacePadding: CGFloat = 16
    /// Inside a deck tile. Tighter than a card's: the deck's job is to show every
    /// source at once, and at 16 the seven-tile deck overflowed the screen by about
    /// half a row — which reads as broken rather than as scrollable.
    static let tilePadding: CGFloat = 12
    /// The container radius the deck sits within.
    static let containerRadius: CGFloat = 28

    /// A tile's corner.
    ///
    /// ⚠ Deliberately a uniform radius rather than `ConcentricRectangle`, and this is
    /// a correction to the shell contract rather than a shortcut. Concentric corners
    /// are defined *relative to the container and the view's inset from it*: they are
    /// right for one view sitting inside a rounded container, and wrong for a grid,
    /// because every tile more than `containerRadius` away from the container's corner
    /// resolves to a radius of zero. That is precisely what shipped — the deck drew
    /// `ConcentricRectangle` with no container shape at all and every tile came out
    /// hard-cornered. A grid of peers needs one radius, applied uniformly.
    static let tileRadius: CGFloat = 22
    static var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: self.tileRadius, style: .continuous)
    }

    /// A grouped card inside a pane or a detail view. Slightly tighter than a tile so
    /// nesting a card inside a pane never reads as two tiles.
    static let cardRadius: CGFloat = 18
    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: self.cardRadius, style: .continuous)
    }
    /// Vertical rhythm between a section's heading and its content.
    static let sectionSpacing: CGFloat = 8
    /// Between two sections.
    static let sectionGap: CGFloat = 24
}

/// Puts a surface on the shell's accent, with a transparent ground.
///
/// Applied once at the shell's destination container rather than per-view, so a pane
/// cannot be added later and quietly arrive on `systemGroupedBackground` with a
/// system-green switch — which is exactly how the five shelf panes had drifted from
/// the deck they open from.
///
/// The ground is `.clear`, not `deckGround`: every native pane root sits above the
/// shared SunArc surface (`RootShellView.sunArcShell`'s outer `SunArcBackgroundHost`),
/// and an opaque ground here would paint over it on every pushed phone destination and
/// regular-width iPad detail pane. Cards and tiles keep their own explicit
/// `deckSurface`/`deckSurfaceRaised` backgrounds, so they read the same as before —
/// only the ground behind them changed. The journal is the one exception:
/// `InAppJournalView` sets its own opaque `deckGround` background directly, because a
/// `WKWebView` needs an opaque backdrop underneath it.
///
/// This alone is not sufficient to reveal that shared surface: `NavigationStack` and
/// `NavigationSplitView` paint an opaque background on their own hosting
/// `UINavigationController`/`UISplitViewController`, entirely apart from anything any
/// SwiftUI content declares — proven twice over by direct screenshot: once showing a
/// `.containerBackground(for:)`-installed copy of the SunArc surface never composited
/// into what's visible at all, and once showing that exact same surface render
/// correctly the moment it was a plain full-screen overlay outside any navigation
/// container. `TransparentNavigationHostProbe` below is what actually clears the
/// opaque UIKit layer — this ground only has to stay out of the way once it does.
///
/// `scrollContentBackground(.hidden)` is what lets a `List` show the ground through;
/// without it the List paints its own grouped grey over everything below.
struct ShellSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Color.clear.ignoresSafeArea())
            .background(TransparentNavigationHostProbe())
            .tint(.solOrange)
    }
}

extension View {
    func shellSurface() -> some View {
        self.modifier(ShellSurface())
    }
}

/// Clears the opaque background UIKit paints on the `UINavigationController` /
/// `UISplitViewController` / `UIHostingController` instances hosting this pane, so the
/// shared SunArc surface behind the shell shows through.
///
/// Walks the RESPONDER chain (view-controller containment), not the view hierarchy —
/// this reaches exactly the navigation/hosting controllers between this pane and the
/// window, in view-controller-containment order, and nothing else: never a card's or
/// tile's own `deckSurface` fill (those are plain views, not view controllers, so they
/// are never matched), and never a `UIAppearance` proxy (which would mutate every
/// instance app-wide rather than just this shell's own controllers).
///
/// Re-clears on every `didMoveToWindow` and `updateUIView` — both event-driven, not a
/// timer — because SwiftUI can reuse or recreate the underlying hosting controllers
/// across navigation pushes/pops and size-class changes, each of which can hand back a
/// freshly-opaque `view.backgroundColor`.
struct TransparentNavigationHostProbe: UIViewRepresentable {
    final class ProbeView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            self.clearHostBackgroundsIfWindowed()
        }

        func clearHostBackgroundsIfWindowed() {
            guard self.window != nil else { return }
            var responder: UIResponder? = self
            while let current = responder {
                if let viewController = current as? UIViewController,
                   Self.isRelevantHost(viewController)
                {
                    viewController.view.backgroundColor = .clear
                }
                responder = current.next
            }
        }

        private static func isRelevantHost(_ viewController: UIViewController) -> Bool {
            if viewController is UINavigationController { return true }
            if viewController is UISplitViewController { return true }
            // `UIHostingController<Content>` is generic over the SwiftUI content it
            // hosts, which is unknown here, so a direct `is` check can never match —
            // the class-name prefix is the only way to recognize it regardless of
            // its generic parameter.
            return String(describing: type(of: viewController)).hasPrefix("UIHostingController")
        }
    }

    func makeUIView(context: Context) -> UIView {
        let view = ProbeView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? ProbeView)?.clearHostBackgroundsIfWindowed()
    }
}

/// The shelf drawer's measurements.
///
/// Taken from a working reference the founder supplied (Bluesky on iPhone, screen
/// recording sampled frame by frame 2026-09-01), because the shelf is one of the few
/// surfaces where a widely-used app has already answered the question and an owner
/// arrives with the expectation already formed.
///
/// Measured there: panel **320 pt of a 402 pt screen** (~80%), the shell **translated
/// right by exactly the panel width** rather than being covered, a black scrim at
/// **~0.41** over the displaced shell, a row pitch of ~54 pt, and the whole motion
/// settling in roughly **0.3 s**. No close button anywhere — the dimmed shell is the
/// way back, which is the part every owner already knows.
nonisolated enum ShelfMetrics {
    /// The scrim leaves the shell clearly legible while making it plainly inactive.
    static let scrimOpacity: Double = 0.4
    static let openDuration: Double = 0.3
    /// A row: glyph, label, and room to hit.
    static let rowHeight: CGFloat = 54
    /// The gutter the panel's content sits in.
    static let panelPadding: CGFloat = 20
    /// How much shell stays visible beside the panel. It has to be worth tapping and
    /// worth reading — a sliver reads as a rendering artefact rather than as "your
    /// day is still there". ⚠ A UI test independently requires at least 24 pt.
    static let minimumShellSliver: CGFloat = 72

    static func panelWidth(containerWidth: CGFloat) -> CGFloat {
        max(240, min(320, containerWidth - self.minimumShellSliver))
    }
}

/// The brand display face, and where it is allowed.
///
/// Comfortaa is bundled and was already being used for a few block titles, but the
/// surfaces an owner actually looks at — the greeting, the tile names, the pane
/// titles — were all system text. A display/text pairing is what makes a shell read
/// as a product rather than a settings app: Comfortaa carries the *names* of things,
/// SF carries everything the owner has to read closely (state, sub-lines, values,
/// long copy), where its legibility and its Dynamic Type behaviour are worth more.
nonisolated enum ShellFont {
    /// The large navigation title: the greeting, a pane's name.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom("Comfortaa-Bold", size: size, relativeTo: style)
    }

    /// A tile's or a row's name.
    static var tileName: Font { self.display(17, relativeTo: .headline) }
    /// A section heading inside a pane or a detail view.
    static var sectionTitle: Font { self.display(18, relativeTo: .headline) }
    /// The navigation large title.
    static var largeTitle: Font { self.display(32, relativeTo: .largeTitle) }

    /// Put the brand face on every navigation bar title.
    ///
    /// SwiftUI has no modifier for the large-title font, so this is the appearance
    /// proxy — called once at launch. Both the large and inline titles are set, so a
    /// pane that collapses its title mid-scroll does not change typeface on the way.
    /// ⚠ Scaled through `UIFontMetrics`, so Dynamic Type still moves it.
    @MainActor
    static func applyNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()

        if let large = UIFont(name: "Comfortaa-Bold", size: 32) {
            // Capped, the way Apple's own large titles are: a navigation title is a
            // single truncating line, so letting it grow the full accessibility range
            // turns `good evening` into `good eveni…` and loses the word. Everything
            // below it still scales without a ceiling.
            appearance.largeTitleTextAttributes = [
                .font: UIFontMetrics(forTextStyle: .largeTitle)
                    .scaledFont(for: large, maximumPointSize: 40),
            ]
        }
        if let inline = UIFont(name: "Comfortaa-Bold", size: 17) {
            appearance.titleTextAttributes = [
                .font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: inline),
            ]
        }

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
}

/// The glyph that stands for a source, everywhere it appears.
///
/// The shell had no source iconography at all: every tile was a word and a switch,
/// which is what made the deck read as a settings list rather than a set of things
/// the owner owns. One glyph per kind, resolved here so the tile, the add-more row
/// and the status breakdown cannot drift apart.
nonisolated extension SourceKind {
    var glyph: String {
        switch self {
        case .observer: "waveform"
        case .location: "mappin.and.ellipse"
        case .screencast: "display"
        case .watch: "applewatch"
        }
    }
}

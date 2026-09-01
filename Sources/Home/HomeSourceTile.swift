// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

nonisolated enum HomeSourceTileControl: Equatable {
    case none
    case toggle
}

/// The deck tile.
///
/// Composition is the approved mock's, which the shipped build had flattened to a
/// name, a switch and a state word: glyph and control on the top line, then the
/// source's name, then the state (dot + word), then the state's own sub-line. The
/// sub-line is `SourceState.subtext(...)` — it already existed in the vocabulary and
/// simply was not being drawn, which is what left every tile two lines tall and the
/// grid ragged.
///
/// Every tile fills its row (`maxHeight: .infinity`), so a row of tiles is one band
/// rather than a set of differently-sized cards top-aligned against each other.
struct HomeSourceTile: View {
    let source: Source
    let route: SourceRoute
    let control: HomeSourceTileControl
    var isOn: Binding<Bool> = .constant(false)
    var presentsScreencastPicker: Bool = false
    var onScreencastWillOpen: @MainActor @Sendable () -> Void = {}

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ShellNavModel.self) private var nav
    @ScaledMetric(relativeTo: .headline) private var glyphSize: CGFloat = 20

    var body: some View {
        Button {
            self.nav.selectFromDeck(ShellDestination.source(self.route))
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                self.topLine
                self.caption
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(ShellMetrics.tilePadding)
            // The tile is far larger than the floor in every real layout; stating the
            // floor keeps that true at the smallest text size and smallest window.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(ShellMetrics.tileShape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(self.source.displayName)
        .accessibilityValue(self.source.state.label)
        .accessibilityIdentifier("dayHome.tile.\(self.source.id)")
        .background(Color.deckSurface, in: ShellMetrics.tileShape)
        .overlay {
            ShellMetrics.tileShape.stroke(Color.deckHairline, lineWidth: 0.5)
        }
        .hoverEffect(.highlight)
    }

    /// Glyph and control share the top line. At accessibility sizes the control drops
    /// below the glyph rather than squeezing it.
    @ViewBuilder
    private var topLine: some View {
        if self.dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                self.glyph
                if self.control == .toggle { self.switchSlot }
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                self.glyph
                Spacer(minLength: 4)
                if self.control == .toggle { self.switchSlot }
            }
            .frame(minHeight: 22)
        }
    }

    private var glyph: some View {
        Image(systemName: self.source.kind.glyph)
            .font(.system(size: self.glyphSize, weight: .medium))
            .foregroundStyle(self.glyphTint)
            .symbolRenderingMode(.hierarchical)
            .accessibilityHidden(true)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.source.displayName)
                .font(ShellFont.tileName)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                HomeSourceStateDot(state: self.source.state)
                Text(self.source.state.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(self.stateLabelColor)
            }
            if self.source.showsSubtext, let subtext = self.subtext {
                Text(subtext)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityHidden(true)
    }

    /// An override only earns the sub-line if it says something the state word did
    /// not. `screen` supplies `off` as its own override, which under the state word
    /// `off` renders the tile as "off / off"; a sub-line that restates the line above
    /// it is noise, so it falls through to the state's own compact text.
    private var subtext: String? {
        if let override = self.source.subtextOverride, override != self.source.state.label {
            return override
        }
        return self.source.state.compactSubtext(activeSubtext: self.source.activeSubtext)
    }

    @ViewBuilder
    private var switchSlot: some View {
        ZStack {
            Toggle("", isOn: self.isOn)
                .labelsHidden()
                .tint(.solOrange)
                .allowsHitTesting(!self.presentsScreencastPicker)

            if self.presentsScreencastPicker {
                ScreencastPickerView(onWillOpen: self.onScreencastWillOpen)
                    .frame(width: 44, height: 44)
            }
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityLabel(self.source.displayName)
        .accessibilityValue(self.source.state.label)
    }

    /// The glyph carries the source's liveness: lit while it is taking something in,
    /// quiet otherwise. It is the same information the dot carries, at the size the
    /// eye lands on first.
    private var glyphTint: Color {
        switch self.source.state {
        case .active, .enrolling:
            .solOrangeAdaptive
        case .needsAttention:
            .red
        case .off, .paused, .readyToSetUp, .checking:
            .secondary
        }
    }

    private var stateLabelColor: Color {
        switch self.source.state {
        case .readyToSetUp:
            self.colorScheme == .dark ? .primary : .textOrangeAA
        case .active, .enrolling:
            .primary
        case .off, .checking, .paused, .needsAttention:
            .secondary
        }
    }
}

/// `import` and `add more` are destinations, not sources: no state word and no
/// control, per the shell contract. They share the source tile's shape and rhythm so
/// the deck reads as one grid.
private struct HomeDestinationTile: View {
    let glyph: String
    let title: String
    let subline: String
    let badgeVisible: Bool
    let identifier: String
    /// An empty slot rather than a thing the owner has: drawn as a dashed outline on
    /// the ground, so `add more` never reads as a sixth source at a glance.
    var isSlot: Bool = false
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var glyphSize: CGFloat = 20

    var body: some View {
        Button(action: self.action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: self.glyph)
                    .font(.system(size: self.glyphSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 22, alignment: .top)
                    .overlay(alignment: .topTrailing) {
                        if self.badgeVisible {
                            Circle()
                                .fill(Color.solOrange)
                                .frame(width: 8, height: 8)
                                .offset(x: 6, y: -2)
                        }
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.title)
                        .font(ShellFont.tileName)
                        .foregroundStyle(.primary)
                    Text(self.subline)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(ShellMetrics.tilePadding)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(ShellMetrics.tileShape)
        }
        .buttonStyle(.plain)
        .background(self.isSlot ? Color.clear : Color.deckSurface, in: ShellMetrics.tileShape)
        .overlay {
            if self.isSlot {
                ShellMetrics.tileShape.stroke(
                    Color.deckHairline,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
            } else {
                ShellMetrics.tileShape.stroke(Color.deckHairline, lineWidth: 0.5)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(self.title)
        .accessibilityValue(self.subline)
        .accessibilityIdentifier(self.identifier)
        .hoverEffect(.highlight)
    }
}

struct HomeAddMoreTile: View {
    var badgeVisible: Bool
    let onTap: () -> Void

    var body: some View {
        HomeDestinationTile(
            glyph: "plus",
            title: SourceVocabulary.addMoreTitle,
            subline: SourceVocabulary.addMoreSubline,
            badgeVisible: self.badgeVisible,
            identifier: "dayHome.sourcesEntry",
            isSlot: true,
            action: self.onTap
        )
    }
}

struct HomeImportTile: View {
    @Environment(ShellNavModel.self) private var nav

    var body: some View {
        HomeDestinationTile(
            glyph: "square.and.arrow.down",
            title: SourceVocabulary.importTitle,
            subline: SourceVocabulary.importSubline,
            badgeVisible: false,
            identifier: "dayHome.importEntry",
            action: { self.nav.selectFromDeck(ShellDestination.import) }
        )
    }
}

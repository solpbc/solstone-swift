// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

enum JournalSetupLink {
    static let installURL = URL(string: "https://solstone.app/install#start")!
}

/// The one way to get from no journal to a journal, drawn the same everywhere it appears:
/// the setup pane, the journal pane, status, and welcome.
///
/// Two doors of equal weight, in the deck's own tile language: set one up, or connect the
/// one you have. Then the data line, said once. The caller supplies the connect control,
/// because where pairing opens differs by surface (a pushed screen, the pair-flow router);
/// this view gives it the door's button style.
struct JournalSetupRoute<PairControl: View>: View {
    /// Whether to lead with the generic mark. Off where the surface's own title already is the
    /// mark (the journal pane), so the mark never appears twice.
    var showsMark: Bool = true
    @ViewBuilder var pairControl: () -> PairControl

    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                if self.showsMark {
                    JournalMarkView(identity: .generic, side: 40)
                }
                Text(SourceVocabulary.journalSetupLead)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("journalSetup.lead")
            }

            self.doors

            Text(SourceVocabulary.journalSetupDataLine)
                .font(.footnote)
                .foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("journalSetup.dataLine")
        }
        .frame(maxWidth: 560)
    }

    /// Side by side where there is room for both; stacked on a phone and at accessibility sizes.
    @ViewBuilder
    private var doors: some View {
        if self.horizontalSizeClass == .regular && !self.dynamicTypeSize.isAccessibilitySize {
            HStack(alignment: .top, spacing: ShellMetrics.gutter) {
                self.newJournalDoor
                self.haveOneDoor
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: ShellMetrics.gutter) {
                self.newJournalDoor
                self.haveOneDoor
            }
        }
    }

    private var newJournalDoor: some View {
        JournalSetupDoor(
            glyph: "desktopcomputer",
            title: SourceVocabulary.journalSetupNewTitle,
            subline: nil,
            identifier: "journalSetup.newDoor"
        ) {
            Button {
                self.openURL(JournalSetupLink.installURL)
            } label: {
                Text(SourceVocabulary.journalSetupOpenPage)
            }
            .buttonStyle(JournalSetupPrimaryButtonStyle())
            .accessibilityIdentifier("journalSetup.setOneUp")

            ShareLink(item: JournalSetupLink.installURL) {
                Label {
                    Text(SourceVocabulary.journalSetupShareLink)
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(Color.solOrangeAdaptive)
                }
            }
            .buttonStyle(JournalSetupSecondaryButtonStyle())
            .accessibilityIdentifier("journalSetup.shareLink")
        }
    }

    private var haveOneDoor: some View {
        JournalSetupDoor(
            glyph: "qrcode.viewfinder",
            title: SourceVocabulary.journalSetupHaveOneTitle,
            subline: SourceVocabulary.journalSetupHaveOneSubline,
            identifier: "journalSetup.haveOneDoor"
        ) {
            self.pairControl()
                .buttonStyle(JournalSetupSecondaryButtonStyle())
        }
    }
}

/// One door: a deck-tile card with a glyph, a name, an optional sub-line, and its actions
/// pinned to the bottom so two doors side by side line their buttons up.
private struct JournalSetupDoor<Actions: View>: View {
    let glyph: String
    let title: String
    let subline: String?
    let identifier: String
    @ViewBuilder var actions: () -> Actions

    @ScaledMetric(relativeTo: .headline) private var glyphSize: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: self.glyph)
                .font(.system(size: self.glyphSize, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(self.title)
                    .font(ShellFont.tileName)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subline = self.subline {
                    Text(subline)
                        .font(.footnote)
                        .foregroundStyle(Color.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            VStack(spacing: 8) {
                self.actions()
            }
        }
        .padding(ShellMetrics.surfacePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.deckSurface, in: ShellMetrics.tileShape)
        .overlay {
            ShellMetrics.tileShape.stroke(Color.deckHairline, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(self.identifier)
    }
}

/// The brand button: ink on sol orange, 7.08:1 in either appearance.
struct JournalSetupPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.inkOnBrand)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 12)
            .background(Capsule().fill(Color.solOrange.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Capsule())
    }
}

/// The quieter button beside it: ink on the raised surface, with an edge you can see.
struct JournalSetupSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 12)
            .background(Capsule().fill(Color.deckSurfaceRaised.opacity(configuration.isPressed ? 0.6 : 1)))
            .overlay(Capsule().stroke(Color.primary.opacity(0.22), lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// The connect control's label. The door above it already says "i already have one".
struct JournalSetupPairLabel: View {
    var body: some View {
        Text(SourceVocabulary.journalLivesConnectAction)
    }
}

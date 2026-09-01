// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct SourceRowView: View {
    let source: Source
    let onTap: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: self.onTap) {
            // Top-aligned, not centred: a row whose sub-line runs to three lines left
            // the glyph floating in the middle of the card, unattached to the name it
            // belongs to.
            HStack(alignment: .top, spacing: 14) {
                // The source's own glyph, not the state's. Every row was rendering
                // `state.symbol`, so five different sources showed the same power
                // icon and the list read as one repeated thing.
                Image(systemName: self.source.kind.glyph)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(self.indicatorColor)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 28, height: 24, alignment: .center)

                VStack(alignment: .leading, spacing: 5) {
                    Text(self.source.displayName)
                        .font(ShellFont.tileName)
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            HomeSourceStateDot(state: self.source.state)
                            Text(self.source.state.label)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(self.stateLabelColor)
                        }
                        if let rowSubtext = self.source.rowSubtext {
                            Text(rowSubtext)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        // VPX: tune row telemetry density once Omi readings are visible on device.
                        if let detailSubtext = self.source.detailSubtext {
                            Text(detailSubtext)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 12)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(height: 24)
            }
            .padding(ShellMetrics.surfacePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(ShellMetrics.cardShape)
            .background(Color.deckSurface, in: ShellMetrics.cardShape)
            .overlay {
                ShellMetrics.cardShape.stroke(Color.deckHairline, lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(self.source.displayName). \(self.source.voiceOverText)")
        .accessibilityIdentifier("source.row.\(self.source.id)")
        .accessibilityAction {
            self.onTap()
        }
    }
}

private extension SourceRowView {
    var indicatorColor: Color {
        switch self.source.state {
        case .needsAttention:
            .red
        case .active, .enrolling, .readyToSetUp:
            .solOrange
        case .off, .paused, .checking:
            .secondary
        }
    }

    var stateLabelColor: Color {
        switch self.source.state {
        case .readyToSetUp:
            self.colorScheme == .dark ? .primary : .textOrangeAA
        case .off, .enrolling, .checking, .active, .paused, .needsAttention:
            .primary
        }
    }
}

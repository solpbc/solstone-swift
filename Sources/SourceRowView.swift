// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct SourceRowView: View {
    let source: Source
    let onTap: () -> Void

    var body: some View {
        Button(action: self.onTap) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: self.source.state.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(self.indicatorColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 5) {
                    Text(self.source.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(self.source.state.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(self.stateLabelColor)
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
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            .orangeInk
        case .off, .enrolling, .checking, .active, .paused, .needsAttention:
            .primary
        }
    }
}

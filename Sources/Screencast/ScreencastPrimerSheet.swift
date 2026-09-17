// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct ScreencastPrimerSheet: View {
    @Environment(ScreencastManager.self) private var screencastManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: ShellMetrics.sectionGap) {
                    ScreencastPrimerIllustration()
                        .frame(maxWidth: .infinity)

                    Text(SourceVocabulary.screencastPrimerBody)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    self.actionRow
                }
                .padding(ShellMetrics.screenMargin)
            }
            .background(Color.deckGround.ignoresSafeArea())
            .navigationTitle(LocationVocabulary.alwaysPrimerHeader)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("dismiss") {
                        self.dismiss()
                    }
                    .tint(.solOrange)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("screencast.primer.sheet")
    }

    private var actionRow: some View {
        ZStack {
            HStack {
                Spacer()
                Text(SourceVocabulary.screencastOpenSystemSheet)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.solOrange, in: Capsule())
            .allowsHitTesting(false)

            ScreencastPickerView {
                self.screencastManager.beginStarting()
            }
            .opacity(0.015)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("screencast.primer.action")
        .accessibilityLabel(SourceVocabulary.screencastOpenSystemSheet)
    }
}

private struct ScreencastPrimerIllustration: View {
    @ScaledMetric(relativeTo: .body) private var titleHeight: CGFloat = 8
    @ScaledMetric(relativeTo: .body) private var destinationHeight: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var actionHeight: CGFloat = 36
    @ScaledMetric(relativeTo: .body) private var ringLineWidth: CGFloat = 2
    @ScaledMetric(relativeTo: .body) private var padding: CGFloat = ShellMetrics.tilePadding

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = proxy.size.width
            VStack(spacing: 12) {
                Capsule()
                    .fill(Color.deckSurfaceRaised)
                    .frame(width: cardWidth * 0.40, height: self.titleHeight)
                    .frame(maxWidth: .infinity)

                Spacer(minLength: 0)

                ShellMetrics.cardShape
                    .fill(Color.deckSurfaceRaised)
                    .frame(height: self.destinationHeight)

                Capsule()
                    .fill(Color.solOrange)
                    .frame(height: self.actionHeight)
                    .overlay(
                        Capsule()
                            .stroke(Color.solOrangeAdaptive, lineWidth: self.ringLineWidth)
                            .padding(-4)
                    )
            }
            .padding(self.padding)
        }
        .aspectRatio(3 / 2, contentMode: .fit)
        .frame(maxWidth: 280)
        .background(Color.deckSurface)
        .clipShape(ShellMetrics.cardShape)
        .overlay(
            ShellMetrics.cardShape
                .stroke(Color.deckHairline, lineWidth: 0.5)
        )
        .accessibilityIdentifier("screencast.primer.illustration")
        .accessibilityLabel(SourceVocabulary.screencastPrimerBody)
    }
}

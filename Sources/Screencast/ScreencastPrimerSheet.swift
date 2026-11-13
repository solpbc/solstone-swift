// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct ScreencastPrimerSheet: View {
    @Environment(ScreencastManager.self) private var screencastManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UserSettings.screencastPrimerSeenKey) private var primerSeen = false
    @State private var contentHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0

    var body: some View {
        let primerBody = SourceVocabulary.screencastPrimerBody(state: self.screencastManager.state)

        return NavigationStack {
            ScrollView {
                VStack(spacing: ShellMetrics.sectionGap) {
                    ScreencastPrimerIllustration(primerBody: primerBody)
                        .frame(maxWidth: .infinity)

                    Text(primerBody)
                        .accessibilityIdentifier("screencast.primer.body")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    self.actionRow
                }
                .padding(ShellMetrics.screenMargin)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { self.contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            // The title bar above and the home indicator below.
            .onGeometryChange(for: CGFloat.self) {
                $0.safeAreaInsets.top + $0.safeAreaInsets.bottom
            } action: { self.chromeHeight = $0 }
            .background(Color.deckGround.ignoresSafeArea())
            .navigationTitle(SourceVocabulary.screencastPrimerTitle)
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
        .presentationDetents(self.detents)
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("screencast.primer.sheet")
        .onAppear { self.primerSeen = true }
    }

    /// One detent the height of what the sheet holds, so its action is never cut off
    /// on iPad and nothing is left empty on iPhone. The system caps it at the screen,
    /// and past that the content scrolls.
    private var detents: Set<PresentationDetent> {
        guard self.contentHeight > 0 else { return [.medium] }
        return [.height((self.chromeHeight + self.contentHeight).rounded(.up))]
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
                self.screencastManager.notePickerWillOpen()
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
    let primerBody: String
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
                    .fill(Color.secondary)
                    .frame(width: cardWidth * 0.40, height: self.titleHeight)
                    .frame(maxWidth: .infinity)

                Spacer(minLength: 0)

                ShellMetrics.cardShape
                    .fill(Color.secondary)
                    .frame(height: self.destinationHeight)

                Capsule()
                    .fill(Color.primary)
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
        .accessibilityLabel(self.primerBody)
    }
}

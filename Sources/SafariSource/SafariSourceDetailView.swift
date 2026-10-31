// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// The Safari source's page: how to turn the extension on until it has answered, then
/// its state, its pause, and whether anything is still waiting on this device.
struct SafariSourceDetailView: View {
    @Environment(SafariSourceModel.self) private var model
    @Environment(AppConfig.self) private var appConfig
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let status = SafariSourceStatus(snapshot: self.model.snapshot)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(SafariVocabulary.valueLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.deckSurface, in: ShellMetrics.cardShape)
                    .accessibilityIdentifier("safari.page.valueLine")
                if status.sourceState == .readyToSetUp {
                    SourceDetailBlock(title: SafariVocabulary.setUpHeader) { self.setUpBlock }
                } else {
                    SourceDetailBlock(title: LocationVocabulary.stateBlockTitle) { self.stateBlock(status) }
                    if self.model.snapshot != nil {
                        SourceDetailBlock(title: LocationVocabulary.deliveryBlockTitle) { self.deliveryBlock }
                    }
                }
                SourceHomeTileControl(sourceID: "safari")
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("safari.page")
#if DEBUG
        .overlay(alignment: .topLeading) {
            UITestStateProbe(identifier: "safari.page.state.\(status.sourceState)")
        }
#endif
        .navigationTitle(SafariVocabulary.label)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // The extension writes the store from another process; read it while shown.
            while !Task.isCancelled {
                self.model.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: self.scenePhase) { _, phase in
            if phase == .active { self.model.refresh() }
        }
    }

    private var setUpBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(SafariVocabulary.setUpStepOne, systemImage: "1.circle")
                .accessibilityIdentifier("safari.page.stepOne")
            Label(SafariVocabulary.setUpStepTwo, systemImage: "2.circle")
                .accessibilityIdentifier("safari.page.stepTwo")
            Text(SafariVocabulary.whileClosed)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("safari.page.whileClosed")
            Text(SafariVocabulary.setUpFootnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func stateBlock(_ status: SafariSourceStatus) -> some View {
        let source = safariSourceModel(snapshot: self.model.snapshot, isJournalPaired: self.appConfig.isPaired)
        let paused = self.model.snapshot?.paused == true
        return VStack(alignment: .leading, spacing: 12) {
            SourceDetailVerdictLine(state: status.sourceState)
            if let subtext = status.attention ?? source.subtext {
                Text(subtext)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("safari.page.subtext")
            }
            if status.sourceState == .active {
                Text(SafariVocabulary.whileClosed)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("safari.page.whileClosed")
            }
            Text(SafariVocabulary.privateBrowsing)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if self.model.snapshot != nil {
                Button(paused ? SourceVocabulary.resume : SourceVocabulary.pause) {
                    self.model.setPaused(!paused)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityHint(paused ? SafariVocabulary.resumeHint : SafariVocabulary.pauseHint)
                .accessibilityIdentifier("safari.pauseResume")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var deliveryBlock: some View {
        let snapshot = self.model.snapshot
        let waiting = (snapshot?.heldBytes ?? 0) + (snapshot?.queuedBytes ?? 0) > 0
        return VStack(alignment: .leading, spacing: 8) {
            Text(waiting ? SafariVocabulary.waiting : SafariVocabulary.nothingWaiting)
                .font(.subheadline)
                .accessibilityIdentifier(waiting ? "safari.page.waiting" : "safari.page.nothingWaiting")
            if let last = snapshot?.lastAccepted {
                Text(SafariVocabulary.lastPage(last))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("safari.page.lastPage")
            } else {
                Text(SafariVocabulary.noPageYet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

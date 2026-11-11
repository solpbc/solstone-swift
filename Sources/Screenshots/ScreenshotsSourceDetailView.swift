// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit

struct ScreenshotsSourceDetailView: View {
    @Environment(ScreenshotsSourceHandle.self) private var handle

    var body: some View {
        ScreenshotsPage(source: self.handle.source)
    }
}

private struct ScreenshotsPage: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    let source: ScreenshotsSourceEngine

    var body: some View {
        let snapshot = self.source.snapshot
        let view = snapshot.view
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(ScreenshotsVocabulary.whatItTakesIn)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.deckSurface, in: ShellMetrics.cardShape)
                    .accessibilityIdentifier("screenshots.page.valueLine")

                Text(ScreenshotsVocabulary.honestyLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("screenshots.page.honesty")

                if view.showChooser {
                    self.chooser(snapshot)
                } else if view.showTurnOn {
                    self.turnOnButton
                }

                if let reason = view.pageReason {
                    SourceDetailReasonLine(message: reason)
                        .accessibilityIdentifier("screenshots.page.reason")
                    if view.opensSettings { self.settingsButton }
                }

                if view.showOnControls || snapshot.everOn {
                    self.stateBlock(snapshot)
                }

                self.facts(snapshot)

                ForEach(snapshot.finals) { final in
                    self.finalRow(final)
                }
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("screenshots.page")
        .navigationTitle(ScreenshotsVocabulary.label)
        .navigationBarTitleDisplayMode(.inline)
        .task { await self.source.foreground() }
        .onChange(of: self.scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await self.source.foreground() }
        }
    }

    @ViewBuilder
    private func chooser(_ snapshot: ScreenshotsSnapshot) -> some View {
        SourceDetailBlock(title: ScreenshotsVocabulary.spanHeader) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ScreenshotsVocabulary.spanOrder, id: \.self) { span in
                    self.spanOption(span, selected: snapshot.selectedSpan)
                }
                Text(ScreenshotsVocabulary.spanFootnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("screenshots.page.spanFootnote")
                if snapshot.view.showS17 {
                    Text(ScreenshotsVocabulary.alreadyInJournal)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("screenshots.page.alreadyInJournal")
                }
            }
        }
        switch snapshot.confirm {
        case .failed:
            SourceDetailReasonLine(message: ScreenshotsVocabulary.countFailed)
                .accessibilityIdentifier("screenshots.page.countFailed")
            Button(ScreenshotsVocabulary.tryAgain) {
                Task { await self.source.chooseSpan(snapshot.selectedSpan) }
            }
            .buttonStyle(BrandQuietButtonStyle())
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .accessibilityIdentifier("screenshots.tryAgain")
        case .checking:
            Button(SourceVocabulary.sourceStateCheckingLabel) {}
                .buttonStyle(BrandProminentButtonStyle())
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(true)
                .accessibilityIdentifier("screenshots.confirm")
        case .ready(let span, let count):
            Button(ScreenshotsVocabulary.confirmTitle(span: span, count: count)) {
                Task { await self.source.confirm() }
            }
            .buttonStyle(BrandProminentButtonStyle())
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("screenshots.confirm")
        }
    }

    private func spanOption(_ span: ScreenshotsSpan, selected: ScreenshotsSpan) -> some View {
        let isSelected = span == selected
        return Button {
            Task { await self.source.chooseSpan(span) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.solOrange : .secondary)
                    .frame(width: 24)
                Text(ScreenshotsVocabulary.spanLabel(span))
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("screenshots.span.\(span.rawValue)")
    }

    private var turnOnButton: some View {
        Button(ScreenshotsVocabulary.turnOn) {
            Task { await self.source.turnOn() }
        }
        .buttonStyle(BrandProminentButtonStyle())
        .controlSize(.large)
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityHint(ScreenshotsVocabulary.turnOnHint)
        .accessibilityIdentifier("screenshots.turnOn")
    }

    private var settingsButton: some View {
        Button(SourceVocabulary.openSettings) {
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        }
        .buttonStyle(BrandProminentButtonStyle())
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityIdentifier("screenshots.openSettings")
    }

    @ViewBuilder
    private func stateBlock(_ snapshot: ScreenshotsSnapshot) -> some View {
        SourceDetailBlock(title: LocationVocabulary.stateBlockTitle) {
            VStack(alignment: .leading, spacing: 12) {
                SourceDetailVerdictLine(state: snapshot.view.sourceState)
                Toggle(ScreenshotsVocabulary.label, isOn: Binding(
                    get: { snapshot.enabled && !snapshot.needsSpan },
                    set: { on in
                        Task {
                            if on { await self.source.turnOn() } else { self.source.turnOff() }
                        }
                    }
                ))
                .tint(.solOrange)
                .frame(minHeight: 44)
                .accessibilityIdentifier("screenshots.toggle")

                if snapshot.view.showProgress {
                    Text(ScreenshotsVocabulary.progress(done: snapshot.progressDone, total: snapshot.progressTotal, onPage: true))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("screenshots.page.progress")
                }
                if snapshot.view.showS21 {
                    SourceDetailReasonLine(message: ScreenshotsVocabulary.waitingForJournalUpdate)
                        .accessibilityIdentifier("screenshots.page.journalUpdate")
                }
                if snapshot.view.showOnControls {
                    Button(snapshot.paused ? SourceVocabulary.resume : SourceVocabulary.pause) {
                        Task {
                            if snapshot.paused { await self.source.resume() } else { self.source.pause() }
                        }
                    }
                    .buttonStyle(BrandQuietButtonStyle())
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("screenshots.pause")
                }
            }
        }
    }

    @ViewBuilder
    private func facts(_ snapshot: ScreenshotsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ScreenshotsVocabulary.staysIfDeletedFromPhotos)
            Text(ScreenshotsVocabulary.keepsWhatsIn)
            if let checked = snapshot.lastChecked {
                Text("\(ScreenshotsVocabulary.lastCheckedLabel) · \(SourceIntakeFormat.relative(checked, now: Date(), calendar: .current))")
                    .accessibilityIdentifier("screenshots.page.lastChecked")
            }
            if snapshot.waiting > 0 {
                Text("\(ScreenshotsVocabulary.waitingLabel) · \(snapshot.waiting)")
                    .accessibilityIdentifier("screenshots.page.waiting")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("screenshots.page.facts")
        SourceIntakeFacts(source: .screenshots)
        SourceHomeTileControl(sourceID: "screenshots")
    }

    @ViewBuilder
    private func finalRow(_ final: ScreenshotsFinal) -> some View {
        if let message = ScreenshotsVocabulary.finalMessage(final.phase) {
            VStack(alignment: .leading, spacing: 8) {
                SourceDetailReasonLine(message: message)
                if ScreenshotsVocabulary.finalCanRetry(final.phase) {
                    Button(ScreenshotsVocabulary.tryAgain) {
                        Task { await self.source.retry(final.localIdentifier) }
                    }
                    .buttonStyle(BrandQuietButtonStyle())
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
            .accessibilityIdentifier("screenshots.final.\(final.localIdentifier)")
        }
    }
}

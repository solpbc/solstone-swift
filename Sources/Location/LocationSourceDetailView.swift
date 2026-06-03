// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit

struct LocationSourceDetailView: View {
    @Environment(LocationManager.self) private var locationManager
    @Environment(LocationUploader.self) private var locationUploader
    @Environment(ObserverRegistration.self) private var observerRegistration
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var recentResult: LocationRecentResult?

    private let recentSource: any LocationRecentProviding = LocationRecentSource()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if self.locationManager.sourceState == .off {
                    LocationEnrollmentContent(manager: self.locationManager)
                } else {
                    self.stateContent
                }
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(LocationVocabulary.sourceDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: self.observerRegistration.activeLocalPort) {
            await self.loadRecent()
        }
    }
}

private extension LocationSourceDetailView {
    @ViewBuilder
    var stateContent: some View {
        SourceDetailBlock(title: LocationVocabulary.stateBlockTitle) {
            self.stateBlock
        }

        SourceDetailBlock(title: LocationVocabulary.tierBlockTitle) {
            self.tierBlock
        }

        SourceDetailBlock(title: LocationVocabulary.recentBlockTitle) {
            self.recentBlock
        }

        SourceDetailBlock(title: LocationVocabulary.deliveryBlockTitle) {
            self.deliveryBlock
        }

        SourceDetailBlock(title: SourceVocabulary.delete) {
            self.deleteBlock
        }
    }

    var stateBlock: some View {
        let sourceState = self.locationManager.sourceState
        let recoveryActions = self.locationManager.recoveryActions

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: sourceState.symbol)
                Text(sourceState.label)
            }
            .font(.headline)

            Text(sourceState.subtext(activeSubtext: LocationVocabulary.activeSubtext))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let attention = self.locationManager.sourceAttention {
                Text(attention.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !recoveryActions.isEmpty {
                HStack {
                    ForEach(Array(recoveryActions.enumerated()), id: \.offset) { _, action in
                        Button(LocationDetailPresentation.recoveryButtonLabel(for: action)) {
                            self.handleRecovery(action)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            Button(self.pauseResumeLabel) {
                Task {
                    await self.handlePauseResumeTap()
                }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
    }

    var tierBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(self.locationManager.tier.label)
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(LocationTier.allCases, id: \.self) { tier in
                    self.tierButton(tier)
                }
            }

            Text(LocationDetailPresentation.tierFraming)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(LocationVocabulary.batteryHonesty)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    var recentBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch self.recentResult {
            case .none:
                ProgressView()
            case .loaded(let items):
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.timeLabel)
                                .font(.headline)
                            Text(SourceVocabulary.shareDeliveredProgress)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            case .loadedEmpty:
                Text(SourceVocabulary.recentEmpty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .failed:
                Text(SourceVocabulary.recentFailed)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            self.openJournalBlock
        }
    }

    var deliveryBlock: some View {
        let summary = LocationDetailPresentation.deliverySummary(
            pending: self.locationUploader.pendingCount,
            failed: self.locationUploader.failedCount,
            lastUploadAt: self.locationUploader.lastUploadAt
        )

        return VStack(alignment: .leading, spacing: 10) {
            Text(summary.line)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if summary.showsRetry {
                Button(SourceVocabulary.retry) {
                    Task {
                        await self.locationUploader.retryFailed()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    var deleteBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(LocationVocabulary.deleteConfirmButton) {}
                .buttonStyle(.bordered)
                .disabled(true)

            Text(LocationVocabulary.deleteSeamLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    var openJournalBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(SourceVocabulary.openJournalInConvey) {
                if let url = self.journalURL {
                    self.openURL(url)
                }
            }
            .buttonStyle(.bordered)
            .disabled(self.journalURL == nil)
            .accessibilityLabel(SourceVocabulary.openJournalInConvey)
            .accessibilityHint("Opens your journal in the browser.")

            if self.journalURL == nil {
                Text(SourceVocabulary.notConnectedRowAffordance)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var journalURL: URL? {
        ConveyURL.dayURL(
            activeLocalPort: self.observerRegistration.activeLocalPort,
            day: self.todayDayString
        )
    }

    var todayDayString: String {
        LocationRecentSource.dayString(for: Date())
    }

    var pauseResumeLabel: String {
        self.locationManager.sourceState == .paused ? SourceVocabulary.resume : SourceVocabulary.pause
    }

    func tierButton(_ tier: LocationTier) -> some View {
        let isSelected = self.locationManager.tier == tier
        return Button {
            Task {
                await self.locationManager.changeTier(tier)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.solOrangeAccessible : .secondary)
                    .frame(width: 24)

                Text(tier.label)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    func handlePauseResumeTap() async {
        if self.locationManager.sourceState == .paused {
            await self.locationManager.resume()
        } else {
            await self.locationManager.pause()
        }
    }

    func handleRecovery(_ recovery: LocationRecovery) {
        switch recovery {
        case .openSettings:
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        case .matchToAllowed:
            Task {
                await self.locationManager.matchToAllowed()
            }
        }
    }

    func loadRecent() async {
        self.recentResult = nil

        guard let localPort = self.observerRegistration.activeLocalPort else {
            self.recentResult = .loadedEmpty
            return
        }

        guard let key = try? await self.observerRegistration.ensureRegistered() else {
            self.recentResult = .failed
            return
        }

        self.recentResult = await self.recentSource.fetchToday(localPort: localPort, key: key)
    }
}

private struct LocationEnrollmentContent: View {
    @State private var coordinator: LocationEnrollmentCoordinator

    private let presentation = LocationEnrollmentPresentation.current

    init(manager: LocationManager) {
        self._coordinator = State(initialValue: LocationEnrollmentCoordinator(manager: manager))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            self.valueBlock

            SourceDetailBlock(title: self.presentation.tierDialHeader) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(self.presentation.tierDialSubhead)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(LocationTier.allCases, id: \.self) { tier in
                        self.tierOption(tier)
                    }

                    Text(self.presentation.batteryHonesty)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button(self.presentation.turnOnLocation) {
                        Task {
                            await self.coordinator.confirm()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(self.coordinator.showingPrimer)
                }
            }

            if self.coordinator.showingPrimer {
                SourceDetailBlock(title: self.presentation.alwaysPrimerHeader) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(self.presentation.alwaysBackgroundPrimer)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button(self.presentation.alwaysPrimerContinue) {
                            Task {
                                await self.coordinator.acknowledgePrimer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                }
            }
        }
    }
}

private extension LocationEnrollmentContent {
    var valueBlock: some View {
        Text(self.presentation.preEnrollmentValue)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    func tierOption(_ tier: LocationTier) -> some View {
        let isSelected = self.coordinator.selectedTier == tier
        return Button {
            self.coordinator.selectTier(tier)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.solOrangeAccessible : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(tier.label)
                            .font(.headline)

                        if tier == .balanced {
                            Text(LocationVocabulary.balancedDefaultBadge)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.solOrangeAccessible)
                        }
                    }

                    Text(tier.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.solOrangeAccessible : Color(.separator), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

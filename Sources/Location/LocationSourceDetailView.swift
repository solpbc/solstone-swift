// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import UIKit

struct LocationSourceDetailView: View {
    @Environment(AppConfig.self) private var appConfig
    @Environment(LocationManager.self) private var locationManager
    @Environment(MobileSegmentUploader.self) private var mobileSegmentUploader
    @Environment(MobileSegmentTransferHolder.self) private var mobileSegmentTransferHolder
    @Environment(TunnelManager.self) private var tunnelManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var recentResult: LocationRecentResult?
    @State private var showingDeleteConfirm = false
    @State private var showingJournal = false
    @State private var isDeleting = false
    @State private var deleteResult: DeleteShareSourceResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if self.locationManager.sourceState == .off {
                    LocationEnrollmentContent(
                        manager: self.locationManager,
                        isJournalPaired: self.appConfig.isPaired
                    )
                } else {
                    self.stateContent
                }

                SourceHomeTileControl(sourceID: "location")
                self.deleteResultBlock
            }
            .frame(maxWidth: self.horizontalSizeClass == .regular ? 560 : .infinity, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(LocationVocabulary.sourceDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: self.tunnelManager.activeConnection?.port) {
            await self.loadRecent()
        }
        .alert(LocationVocabulary.deleteConfirmButton, isPresented: self.$showingDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button(LocationVocabulary.deleteConfirmButton, role: .destructive) {
                Task {
                    await self.runDelete()
                }
            }
        } message: {
            Text(LocationVocabulary.deleteConfirmBody)
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
        let sharingStatus = LocationVocabulary.sharingStatus(for: self.locationManager.sharingGrant)
        let fault = locationSourceFault(
            effective: self.locationManager.sharingGrant,
            tier: self.locationManager.tier,
            paused: sourceState == .paused
        )
        let action = fault.map(sourceFaultAction) ?? .none

        return VStack(alignment: .leading, spacing: 12) {
            SourceDetailVerdictLine(state: sourceState)
            SourceDetailReasonLine(message: self.locationManager.sourceAttention?.message)
            SourceFaultActionControl(
                action: action,
                title: action == .matchToAllowed
                    ? LocationVocabulary.matchToAllowedAction
                    : LocationVocabulary.openSettingsAction,
                hint: action == .openSettings
                    ? "Opens iOS Settings for location access."
                    : "Changes the detail level to what iOS allows.",
                perform: {
                    if action == .matchToAllowed {
                        self.handleRecovery(.matchToAllowed(suggestedTier: self.locationManager.tier))
                    } else {
                        self.handleRecovery(.openSettings)
                    }
                }
            )

            Text(sourceState.subtext(
                activeSubtext: LocationVocabulary.activeSubtext(isJournalPaired: self.appConfig.isPaired),
                isJournalPaired: self.appConfig.isPaired
            ))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(sharingStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(sharingStatus.replacingOccurrences(of: " · ", with: ", "))

            Button(self.pauseResumeLabel) {
                Task {
                    await self.handlePauseResumeTap()
                }
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .accessibilityHint(self.locationManager.sourceState == .paused ? "Resumes location updates to your journal." : "Pauses location updates to your journal.")
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
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(item.timeLabel). \(SourceVocabulary.shareDeliveredProgress)")
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
        let bundleSummary = self.mobileSegmentTransferHolder.summary(for: .location)
        let summary = LocationDetailPresentation.deliverySummary(
            pending: bundleSummary.pendingCount,
            failed: bundleSummary.failedCount
        )

        return VStack(alignment: .leading, spacing: 10) {
            Text(summary.line)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if summary.showsRetry {
                Button(SourceVocabulary.retry) {
                    Task {
                        await self.mobileSegmentUploader.resolveFinalizeFailurePile()
                        try? await self.mobileSegmentTransferHolder.transferEngine.retryAttention(
                            source: ObserverAudioTransferSource.mobileSegment
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityHint("Tries sending location updates again.")
            }
        }
    }

    var deleteBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(LocationVocabulary.deleteConfirmButton, role: .destructive) {
                self.showingDeleteConfirm = true
            }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .disabled(self.isDeleting)
                .accessibilityHint("Removes location's contributions from your journal.")
        }
    }

    @ViewBuilder
    var deleteResultBlock: some View {
        if let deleteResult {
            switch deleteResult {
            case .confirmed(let receipt, _):
                VStack(alignment: .leading, spacing: 8) {
                    Text(LocationVocabulary.deleteReceiptHeadline(days: receipt.removed.days ?? 0))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(deleteResult.notRemovedIssues, id: \.self) { issue in
                        Text(issue.plainReason)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(deleteResult.notConfirmedIssues, id: \.self) { issue in
                        Text(issue.plainReason)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            case .notConfirmed, .unreachable:
                Text(SourceVocabulary.deleteJournalUnreachableLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
            }
        }
    }

    var openJournalBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(SourceVocabulary.openJournalLink) {
                self.showingJournal = true
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .disabled(self.journalURL == nil)
            .accessibilityLabel(SourceVocabulary.openJournalLink)
            .accessibilityHint("opens your journal inside the solstone app.")
            .sheet(isPresented: self.$showingJournal) {
                InAppJournalView()
            }

            if self.journalURL == nil {
                Text(SourceVocabulary.notConnectedRowAffordance(isJournalPaired: self.appConfig.isPaired))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var journalURL: URL? {
        ConveyURL.rootURL(activeLocalPort: self.tunnelManager.activeConnection?.port)
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
                    .foregroundStyle(isSelected ? Color.solOrange : .secondary)
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
        .accessibilityHint(tier == .light ? "Uses places only from now on." : tier == .balanced ? "Uses places plus comings and goings from now on. This is the recommended default." : "Uses the complete picture from now on.")
    }

    func handlePauseResumeTap() async {
        if self.locationManager.sourceState == .paused {
            await self.locationManager.resume()
        } else {
            await self.locationManager.pause()
        }
    }

    func runDelete() async {
        self.isDeleting = true
        let result = await self.deleteLocationSource()
        if result.shouldFlipOff {
            await self.mobileSegmentUploader.deleteLocationLocalState()
            await self.locationManager.stopForDelete()
        }
        self.deleteResult = result
        self.isDeleting = false
    }

    func deleteLocationSource() async -> DeleteShareSourceResult {
        guard let localPort = self.tunnelManager.activeConnection?.port else {
            return .unreachable(reason: "location source delete unavailable: missing local port")
        }
        switch await LinkedDeviceIngestClient().deleteSource(localPort: localPort, source: "location") {
        case .success(let receipt?):
            return .confirmed(receipt: receipt, localNotRemoved: [])
        case .success(nil):
            return .notConfirmed
        case .failure(let error):
            return .unreachable(reason: String(describing: error))
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
        let tunnelManager = self.tunnelManager
        let reconciler = LinkedDeviceIngestReconciler(activeLocalPort: { tunnelManager.activeConnection?.port })
        self.recentResult = await reconciler.reconcileLocationRecent(
            day: LinkedDeviceIngestViewMapper.dayString(for: Date())
        )
    }
}

private struct LocationEnrollmentContent: View {
    @State private var coordinator: LocationEnrollmentCoordinator

    private let presentation: LocationEnrollmentPresentation

    init(manager: LocationManager, isJournalPaired: Bool) {
        self._coordinator = State(initialValue: LocationEnrollmentCoordinator(manager: manager))
        self.presentation = LocationEnrollmentPresentation.current(isJournalPaired: isJournalPaired)
    }

    var body: some View {
        @Bindable var coordinator = self.coordinator

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
                    .accessibilityHint("Starts adding location updates to your journal.")
                }
            }
        }
        .alert(self.presentation.alwaysPrimerHeader, isPresented: $coordinator.showingPrimer) {
            Button(self.presentation.alwaysPrimerContinue) {
                Task {
                    await coordinator.acknowledgePrimer()
                }
            }
            .accessibilityHint("Continues to the iOS location permission step.")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(self.presentation.alwaysBackgroundPrimer)
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
            .background(Color(.secondarySystemBackground), in: ConcentricRectangle())
    }

    func tierOption(_ tier: LocationTier) -> some View {
        let isSelected = self.coordinator.selectedTier == tier
        return Button {
            self.coordinator.selectTier(tier)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.solOrange : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(tier.label)
                            .font(.headline)

                        if tier == .balanced {
                            Text(LocationVocabulary.balancedDefaultBadge)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.orangeInk)
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
            .background(Color(.tertiarySystemBackground), in: ConcentricRectangle())
            .overlay {
                ConcentricRectangle()
                    .stroke(isSelected ? Color.solOrange : Color(.separator), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(tier == .light ? "Chooses places only for location." : tier == .balanced ? "Chooses places plus comings and goings for location. This is the recommended default." : "Chooses the complete picture for location.")
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let homeLog = Logger(subsystem: "org.solpbc.solstone-swift", category: "home")

struct DayZeroOverlayView: View {
    @Environment(AppConfig.self) private var appConfig
    @AppStorage("briefing.firstSeen") private var hasSeenFirstBriefing = false

    let pairingClient: any PairingClient
    let onBrowseJournal: () -> Void

    @State private var snapshot: ProgressSnapshot?
    @State private var isLoading = false

    private var shouldShowDayOne: Bool {
        !self.hasSeenFirstBriefing && self.snapshot?.briefingReady == true
    }

    private var shouldShowDayZero: Bool {
        !self.hasSeenFirstBriefing && self.snapshot != nil && self.snapshot?.briefingReady != true
    }

    var body: some View {
        ZStack {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            if self.shouldShowDayOne {
                self.dayOneCard
            } else if self.shouldShowDayZero, let snapshot {
                self.dayZeroCard(snapshot: snapshot)
            } else if self.isLoading {
                ProgressView()
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .padding(20)
        .task {
            await self.startPolling()
        }
        .onChange(of: self.snapshot) { _, newSnapshot in
            guard let newSnapshot else { return }
            homeLog.info(
                "progress snapshot segments=\(newSnapshot.segmentsObserved) meetings=\(newSnapshot.meetingsDetected) entities=\(newSnapshot.entitiesIdentified) percent=\(newSnapshot.percent) briefingReady=\(String(describing: newSnapshot.briefingReady), privacy: .public)"
            )
        }
    }
}

private extension DayZeroOverlayView {
    @ViewBuilder
    func dayZeroCard(snapshot: ProgressSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sol is observing your day.")
                .font(.title3.weight(.semibold))
            ProgressView(value: Double(snapshot.percent), total: 100)
                .tint(Color.solOrangeAccessible)
            Text("\(snapshot.percent)% complete")
                .font(.headline)
            Text("\(snapshot.segmentsObserved) segments observed")
                .font(.body)
            Text("\(snapshot.meetingsDetected) meetings detected")
                .font(.body)
            Text("\(snapshot.entitiesIdentified) entities identified")
                .font(.body)
            Text("Your first briefing arrives tomorrow at 7:00 AM")
                .font(.body)
                .foregroundStyle(.secondary)
            Button("Browse your journal", action: self.onBrowseJournal)
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityHint("Opens Today in your journal")
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .onAppear {
            homeLog.info(
                "day-zero overlay rendered segments=\(snapshot.segmentsObserved) meetings=\(snapshot.meetingsDetected) entities=\(snapshot.entitiesIdentified) percent=\(snapshot.percent)"
            )
        }
    }

    var dayOneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your first briefing")
                .font(.title3.weight(.semibold))
            Text("This is how sol will reach you each morning. You can change the time in Settings.")
                .font(.body)
                .foregroundStyle(.secondary)
            Button("Continue") {
                self.hasSeenFirstBriefing = true
                self.snapshot = nil
                homeLog.info("day-one acknowledgment dismissed")
            }
            .buttonStyle(.borderedProminent)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityHint("Dismisses this first-briefing message")
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .onAppear {
            homeLog.info("day-one acknowledgment rendered")
        }
    }

    func startPolling() async {
        homeLog.info("day-zero startPolling invoked")
        guard let sessionKey = self.appConfig.currentSessionKey() else {
            homeLog.error("day-zero polling skipped: missing pair session")
            return
        }
        homeLog.info("day-zero polling started")
        self.isLoading = true
        defer { self.isLoading = false }

        while !Task.isCancelled && !self.hasSeenFirstBriefing {
            do {
                self.snapshot = try await self.pairingClient.progressToday(sessionKey: sessionKey)
            } catch {
                self.snapshot = nil
                homeLog.error("day-zero progress poll failed: \(String(describing: error), privacy: .public)")
            }

            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import os

private let homeLog = Logger(subsystem: "app.solstone.swift", category: "home")

typealias DayZeroProgressFetch = @MainActor () async throws -> ProgressTodaySnapshot

nonisolated enum DayZeroPollDecision: Equatable, Sendable {
    case terminal
    case retry
}

nonisolated enum DayZeroPollResult: Sendable {
    case loaded(ProgressTodaySnapshot)
    case inert

    var isInert: Bool {
        if case .inert = self {
            return true
        }
        return false
    }
}

struct DayZeroOverlayView: View {
    @Environment(AppConfig.self) private var appConfig
    @AppStorage("briefing.firstSeen") private var hasSeenFirstBriefing = false

    let localPort: Int
    let onBrowseJournal: () -> Void
    let fetchProgress: DayZeroProgressFetch?

    @State private var snapshot: ProgressSnapshot?
    @State private var isLoading = false

    init(
        localPort: Int,
        onBrowseJournal: @escaping () -> Void,
        fetchProgress: DayZeroProgressFetch? = nil
    ) {
        self.localPort = localPort
        self.onBrowseJournal = onBrowseJournal
        self.fetchProgress = fetchProgress
    }

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

extension DayZeroOverlayView {
    nonisolated static func pollDecision(for error: any Error) -> DayZeroPollDecision {
        if let homeError = error as? HomeAPIError,
           case .server(status: 404, body: _) = homeError
        {
            return .terminal
        }
        return .retry
    }

    @MainActor
    static func runPolling(
        fetch: DayZeroProgressFetch,
        sleep: @MainActor (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        maxTransientRetries: Int = 3,
        shouldContinue: @MainActor () -> Bool,
        onLoaded: @MainActor (ProgressTodaySnapshot) -> Void = { _ in }
    ) async -> DayZeroPollResult {
        var transientFailures = 0
        var latestSnapshot: ProgressTodaySnapshot?

        while !Task.isCancelled && shouldContinue() {
            do {
                let snapshot = try await fetch()
                latestSnapshot = snapshot
                transientFailures = 0
                onLoaded(snapshot)
            } catch {
                switch self.pollDecision(for: error) {
                case .terminal:
                    return .inert
                case .retry:
                    transientFailures += 1
                    if transientFailures >= maxTransientRetries {
                        return .inert
                    }
                }
            }

            guard !Task.isCancelled && shouldContinue() else {
                break
            }

            do {
                try await sleep(.seconds(30))
            } catch {
                break
            }
        }

        if let latestSnapshot {
            return .loaded(latestSnapshot)
        }
        return .inert
    }
}

private extension DayZeroOverlayView {
    @ViewBuilder
    func dayZeroCard(snapshot: ProgressSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("sol is observing your day.")
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
            Text("your first briefing arrives tomorrow at 7:00 AM")
                .font(.body)
                .foregroundStyle(.secondary)
            Button("browse your journal", action: self.onBrowseJournal)
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
            Text("your first briefing")
                .font(.title3.weight(.semibold))
            Text("this is how sol will reach you each morning.")
                .font(.body)
                .foregroundStyle(.secondary)
            Button("continue") {
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

    @MainActor
    func startPolling() async {
        homeLog.info("day-zero polling started")
        self.isLoading = true
        let fetch = self.fetchProgress ?? {
            try await HomeAPIClient(loopbackPort: self.localPort).progressToday()
        }
        let result = await Self.runPolling(
            fetch: fetch,
            shouldContinue: {
                !Task.isCancelled && !self.hasSeenFirstBriefing
            },
            onLoaded: { snapshot in
                self.snapshot = snapshot
            }
        )

        if self.hasSeenFirstBriefing {
            self.snapshot = nil
        } else {
            switch result {
            case .loaded(let snapshot):
                self.snapshot = snapshot
            case .inert:
                self.snapshot = nil
            }
        }
        self.isLoading = false
    }
}

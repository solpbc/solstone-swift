// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

/// What a source detail screen's recent list is loaded for: the journal connection, and how many
/// items have been delivered since launch, so a delivery shows up without leaving the screen.
nonisolated struct LinkedDeviceIngestRecentKey: Hashable, Sendable {
    let port: Int?
    let deliveredCount: Int
}

nonisolated struct LinkedDeviceIngestReconciler: Sendable {
    private let client: LinkedDeviceIngestClient
    private let activeLocalPort: @MainActor @Sendable () -> Int?

    init(
        client: LinkedDeviceIngestClient = .init(),
        activeLocalPort: @escaping @MainActor @Sendable () -> Int?
    ) {
        self.client = client
        self.activeLocalPort = activeLocalPort
    }

    func reconcileObserverManifest(day: String, fileName: String) async -> ObserverManifestResult {
        switch await self.currentSegments(day: day) {
        case .noConnection:
            return .unavailable
        case .connectionChanged:
            return .failed
        case .fetched(let result):
            return LinkedDeviceIngestViewMapper.observerManifestResult(result, day: day, fileName: fileName)
        }
    }

    func reconcileLocationRecent(day: String) async -> LocationRecentResult {
        switch await self.currentSegments(day: day) {
        case .noConnection:
            return .unavailable
        case .connectionChanged:
            return .failed
        case .fetched(let result):
            return LinkedDeviceIngestViewMapper.locationRecentResult(result, day: day)
        }
    }

    private enum SegmentsRead {
        /// No journal connection was up, so no request went out.
        case noConnection
        /// The connection changed while the request was out; its answer can't be trusted.
        case connectionChanged
        case fetched(Result<LinkedDeviceIngestSegmentsResponse, LinkedDeviceIngestClientError>)
    }

    private func currentSegments(day: String) async -> SegmentsRead {
        guard let issuedPort = await self.activeLocalPort() else { return .noConnection }

        let result = await self.client.fetchSegments(
            localPort: issuedPort,
            source: ObserverAudioTransferSource.mobileSegment,
            day: day
        )

        guard let currentPort = await self.activeLocalPort(), currentPort == issuedPort else {
            return .connectionChanged
        }
        return .fetched(result)
    }
}

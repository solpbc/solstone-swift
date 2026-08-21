// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

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

    func reconcileObserverManifest(day: String) async -> ObserverManifestResult {
        guard let result = await self.currentSegments(day: day) else { return .failed }
        return LinkedDeviceIngestViewMapper.observerManifestResult(result)
    }

    func reconcileLocationRecent(day: String) async -> LocationRecentResult {
        guard let result = await self.currentSegments(day: day) else { return .failed }
        return LinkedDeviceIngestViewMapper.locationRecentResult(result)
    }

    private func currentSegments(
        day: String
    ) async -> Result<LinkedDeviceIngestSegmentsResponse, LinkedDeviceIngestClientError>? {
        guard let issuedPort = await self.activeLocalPort() else { return nil }

        let result = await self.client.fetchSegments(
            localPort: issuedPort,
            source: ObserverAudioTransferSource.mobileSegment,
            day: day
        )

        guard let currentPort = await self.activeLocalPort(), currentPort == issuedPort else {
            return nil
        }
        return result
    }
}

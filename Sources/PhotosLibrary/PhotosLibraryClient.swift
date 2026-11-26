// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum PhotosDashboardFetchResult: Equatable, Sendable {
    case ok(PhotosJournalDashboardSummary)
    case notFound
    case failed
}

/// Client-initiated channel to the paired journal's `/app/devices/photos-library/*` routes.
nonisolated protocol PhotosLibraryTransport: Sendable {
    func checkCapability() async -> Bool?
    func postScanStart(_ payload: PhotosScanStartPayload) async throws
    func postScanBatch(_ payload: PhotosScanBatchPayload) async throws
    func postScanFinish(_ payload: PhotosScanFinishPayload) async throws
    func postScanChanges(_ payload: PhotosScanChangesPayload) async throws
    func postStatus(_ payload: PhotosDeviceStatusPayload) async throws
    func fetchWanted(limit: Int) async throws -> PhotosWantedResponse
    func postCopy(_ payload: PhotosCopyUploadPayload) async throws
    func fetchDashboardState() async -> PhotosJournalDashboardSummary?
    func fetchDashboardStateResult() async -> PhotosDashboardFetchResult
    func postPause() async throws
    func postResume() async throws
}

nonisolated extension PhotosLibraryTransport {
    func fetchDashboardState() async -> PhotosJournalDashboardSummary? { nil }
    func fetchDashboardStateResult() async -> PhotosDashboardFetchResult {
        if let summary = await self.fetchDashboardState() {
            return .ok(summary)
        }
        return .failed
    }
    func postPause() async throws {}
    func postResume() async throws {}
}

nonisolated enum PhotosLibraryTransportError: Error, Equatable {
    case unpaired
    case sendNotAdmitted
    case invalidURL
    case httpStatus(Int)
    case decodeFailed
}

/// Concrete transport over the app's existing authenticated loopback door
/// (`AuthenticatedHomeClient`), honoring Privacy Principle 8 (`admitSend`).
nonisolated final class AuthenticatedPhotosLibraryClient: PhotosLibraryTransport, @unchecked Sendable {
    private let homeClient: AuthenticatedHomeClient
    private let localPortProvider: @Sendable () async -> Int?
    private let admitSend: @Sendable () async -> Bool
    private let sessionFactory: @Sendable (Duration) -> URLSession

    init(
        homeClient: AuthenticatedHomeClient = AuthenticatedHomeClient(),
        localPortProvider: @escaping @Sendable () async -> Int?,
        admitSend: @escaping @Sendable () async -> Bool,
        sessionFactory: @escaping @Sendable (Duration) -> URLSession = { timeout in
            let config = URLSessionConfiguration.ephemeral
            let secs = AuthenticatedPhotosLibraryClient.timeoutSeconds(timeout)
            config.timeoutIntervalForRequest = secs
            config.timeoutIntervalForResource = secs
            return URLSession(configuration: config)
        }
    ) {
        self.homeClient = homeClient
        self.localPortProvider = localPortProvider
        self.admitSend = admitSend
        self.sessionFactory = sessionFactory
    }

    private static func timeoutSeconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    func checkCapability() async -> Bool? {
        guard let port = await self.localPortProvider() else { return nil }
        let report = await self.homeClient.fetchStatusReport(localPort: port)
        switch report {
        case .failed:
            return nil
        case .read:
            return report.lists(PhotosLibraryWire.capability)
        }
    }

    func postScanStart(_ payload: PhotosScanStartPayload) async throws {
        try await self.postJSON(path: "/app/devices/photos-library/scan/start", payload: payload, timeout: .seconds(15))
    }

    func postScanBatch(_ payload: PhotosScanBatchPayload) async throws {
        try await self.postJSON(path: "/app/devices/photos-library/scan/batch", payload: payload, timeout: .seconds(30))
    }

    func postScanFinish(_ payload: PhotosScanFinishPayload) async throws {
        try await self.postJSON(path: "/app/devices/photos-library/scan/finish", payload: payload, timeout: .seconds(60))
    }

    func postScanChanges(_ payload: PhotosScanChangesPayload) async throws {
        try await self.postJSON(path: "/app/devices/photos-library/scan/changes", payload: payload, timeout: .seconds(60))
    }

    func postStatus(_ payload: PhotosDeviceStatusPayload) async throws {
        try await self.postJSON(path: "/app/devices/photos-library/status", payload: payload, timeout: .seconds(10))
    }

    func fetchWanted(limit: Int) async throws -> PhotosWantedResponse {
        guard await self.admitSend() else {
            throw PhotosLibraryTransportError.sendNotAdmitted
        }
        guard let port = await self.localPortProvider() else {
            throw PhotosLibraryTransportError.unpaired
        }
        let capped = max(1, min(limit, 100))
        let (data, code) = try await self.homeClient.sourceRequest(
            localPort: port,
            path: "/app/devices/photos-library/wanted?limit=\(capped)",
            timeout: .seconds(15)
        )
        guard (200..<300).contains(code) else {
            throw PhotosLibraryTransportError.httpStatus(code)
        }
        guard let decoded = try? JSONDecoder().decode(PhotosWantedResponse.self, from: data) else {
            throw PhotosLibraryTransportError.decodeFailed
        }
        return decoded
    }

    func postCopy(_ payload: PhotosCopyUploadPayload) async throws {
        try await self.postJSON(path: "/app/devices/photos-library/copy", payload: payload, timeout: .seconds(60))
    }

    func fetchDashboardState() async -> PhotosJournalDashboardSummary? {
        guard case .ok(let summary) = await self.fetchDashboardStateResult() else { return nil }
        return summary
    }

    func fetchDashboardStateResult() async -> PhotosDashboardFetchResult {
        guard await self.admitSend(),
              let port = await self.localPortProvider()
        else { return .failed }
        guard let (data, code) = try? await self.homeClient.sourceRequest(
            localPort: port,
            path: "/app/sources/photos/api/state",
            timeout: .seconds(10)
        ) else { return .failed }
        if code == 404 {
            return .notFound
        }
        guard (200..<300).contains(code),
              let decoded = try? JSONDecoder().decode(PhotosJournalDashboardSummary.self, from: data)
        else { return .failed }
        return .ok(decoded)
    }

    func postPause() async throws {
        try await self.postJSON(path: "/app/sources/photos/api/pause", payload: [String: String](), timeout: .seconds(10))
    }

    func postResume() async throws {
        try await self.postJSON(path: "/app/sources/photos/api/resume", payload: [String: String](), timeout: .seconds(10))
    }

    private func postJSON<T: Encodable>(path: String, payload: T, timeout: Duration) async throws {
        guard await self.admitSend() else {
            throw PhotosLibraryTransportError.sendNotAdmitted
        }
        guard let port = await self.localPortProvider() else {
            throw PhotosLibraryTransportError.unpaired
        }
        guard (1...65535).contains(port),
              let url = URL(string: "http://127.0.0.1:\(port)\(path)")
        else {
            throw PhotosLibraryTransportError.invalidURL
        }
        let body = try JSONEncoder().encode(payload)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeoutSeconds(timeout))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.attachLoopbackCapability()

        let session = self.sessionFactory(timeout)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PhotosLibraryTransportError.httpStatus(http.statusCode)
        }
    }
}

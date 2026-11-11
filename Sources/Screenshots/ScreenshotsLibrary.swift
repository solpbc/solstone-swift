// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct ScreenshotsAsset: Equatable, Sendable, Identifiable {
    var localIdentifier: String
    var created: Date
    var uniformTypeIdentifier: String
    var pixelWidth: Int
    var pixelHeight: Int

    var id: String { self.localIdentifier }
}

nonisolated enum ScreenshotsExportResult: Equatable, Sendable {
    case bytes(Data, uniformTypeIdentifier: String)
    case missing
    case failed
}

nonisolated enum ScreenshotsChanges: Equatable, Sendable {
    case expired
    case delta(inserted: [String], updated: [String], deleted: [String], token: Data)
}

/// The photo library as this source uses it. Tests stand in for PhotoKit.
protocol ScreenshotsLibrary: AnyObject, Sendable {
    func access() -> ScreenshotsAccess
    func requestAccess() async -> ScreenshotsAccess
    func screenshots(onOrAfter start: Date) async throws -> [ScreenshotsAsset]
    func asset(localIdentifier: String) async -> ScreenshotsAsset?
    func changes(since token: Data?) async -> ScreenshotsChanges
    func currentToken() -> Data?
    func export(localIdentifier: String) async -> ScreenshotsExportResult
    func setObserving(_ on: Bool)
}

extension ScreenshotsLibrary {
    func setObserving(_ on: Bool) {}
}

struct ScreenshotsUpload: Equatable, Sendable {
    var localIdentifier: String
    var itemID: UUID
    var bytes: Data
    var filename: String
    var contentType: String
    var hash: String
    var capturedAt: String
    var day: String
    var segment: String
    var offsetSeconds: Int
    var timeZoneIdentifier: String
    var created: Date
}

protocol ScreenshotsSending: AnyObject, Sendable {
    func send(_ upload: ScreenshotsUpload) async throws
}

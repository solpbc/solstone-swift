// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

/// Test-only pairing of the production path value with an injected writer.
/// Path computation remains exclusively on `WatchCaptureStoragePaths`.
struct WatchCaptureTestStorage {
    let paths: WatchCaptureStoragePaths
    let fileWriter: any WatchFileWriting

    init(
        rootURL: URL,
        fileWriter: any WatchFileWriting = FoundationWatchFileWriter()
    ) throws {
        self.paths = WatchCaptureStoragePaths(rootURL: rootURL)
        self.fileWriter = fileWriter
    }

    var rootURL: URL { self.paths.rootURL }

    func dayString(for date: Date) -> String { self.paths.dayString(for: date) }
    func segmentString(for date: Date, durationSeconds: Double) -> String {
        self.paths.segmentString(for: date, durationSeconds: durationSeconds)
    }
    func provisionalSegmentString(for date: Date) -> String { self.paths.provisionalSegmentString(for: date) }
    func segmentDirectoryURL(day: String, segment: String) -> URL {
        self.paths.segmentDirectoryURL(day: day, segment: segment)
    }
    func manifestURL(directory: URL) -> URL { self.paths.manifestURL(directory: directory) }
    func audioURL(directory: URL) -> URL { self.paths.audioURL(directory: directory) }
    func locationURL(directory: URL) -> URL { self.paths.locationURL(directory: directory) }
}

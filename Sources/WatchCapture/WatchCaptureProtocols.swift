// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation

@MainActor
protocol WatchAudioRecording: AnyObject {
    var url: URL? { get }
    var currentTime: TimeInterval { get }
    var isRecording: Bool { get }
    var microphonePermission: WatchMicrophonePermission { get }
    var eventSink: (any WatchAudioRecorderEventSink)? { get set }

    func requestPermission() async -> WatchMicrophonePermission
    func start(url: URL) throws
    func stop() throws -> TimeInterval
}

@MainActor
protocol WatchAudioRecorderEventSink: AnyObject {
    func audioRecorderDidFinish(successfully: Bool)
    func audioRecorderEncodeError(_ error: (any Error)?)
}

@MainActor
protocol WatchAudioSessionControlling: AnyObject {
    var hasSuitableInput: Bool { get }

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

@MainActor
protocol WatchLocationProviding: AnyObject {
    var onFix: (@MainActor @Sendable (WatchLocationFix) -> Void)? { get set }
    var onAuthorizationChanged: (@MainActor @Sendable (WatchLocationAuthorization) -> Void)? { get set }
    var onFailure: (@MainActor @Sendable (any Error) -> Void)? { get set }
    var authorizationStatus: WatchLocationAuthorization { get }

    func requestWhenInUseAuthorization()
    func start() throws
    func stop()
}

@MainActor
protocol WatchFileWriting: AnyObject {
    func createDirectory(at url: URL) throws
    func createFileIfNeeded(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func readData(from url: URL) throws -> Data
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) throws
    func appendLine(_ line: Data, to url: URL) throws
    func atomicReplaceFile(at url: URL, with data: Data) throws
    func removeItem(at url: URL) throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
}

@MainActor
protocol WatchAudioProbing: AnyObject {
    func decodableDuration(at url: URL) -> TimeInterval?
}

@MainActor
final class FoundationWatchFileWriter: WatchFileWriting {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func createDirectory(at url: URL) throws {
        try self.fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func createFileIfNeeded(at url: URL) throws {
        try self.createDirectory(at: url.deletingLastPathComponent())
        if !self.fileManager.fileExists(atPath: url.path) {
            _ = self.fileManager.createFile(atPath: url.path, contents: nil)
        }
    }

    func fileExists(at url: URL) -> Bool {
        self.fileManager.fileExists(atPath: url.path)
    }

    func readData(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions = []) throws {
        try self.createDirectory(at: url.deletingLastPathComponent())
        try data.write(to: url, options: options)
    }

    func appendLine(_ line: Data, to url: URL) throws {
        try self.createFileIfNeeded(at: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.write(contentsOf: Data([0x0A]))
        try handle.synchronize()
    }

    func atomicReplaceFile(at url: URL, with data: Data) throws {
        try self.createDirectory(at: url.deletingLastPathComponent())
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        try data.write(to: tempURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: tempURL)
        try handle.synchronize()
        try? handle.close()
        if self.fileManager.fileExists(atPath: url.path) {
            _ = try self.fileManager.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try self.fileManager.moveItem(at: tempURL, to: url)
        }
    }

    func removeItem(at url: URL) throws {
        guard self.fileManager.fileExists(atPath: url.path) else { return }
        try self.fileManager.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try self.createDirectory(at: destinationURL.deletingLastPathComponent())
        if self.fileManager.fileExists(atPath: destinationURL.path) {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileWriteFileExistsError,
                userInfo: [NSFilePathErrorKey: destinationURL.path]
            )
        }
        try self.fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        guard self.fileManager.fileExists(atPath: url.path) else { return [] }
        return try self.fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    }
}

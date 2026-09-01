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
    func start(url: URL, source: WatchCaptureSourceToken) throws
    func stop() throws -> TimeInterval
}

@MainActor
protocol WatchAudioRecorderEventSink: AnyObject {
    func audioRecorderDidFinish(successfully: Bool, source: WatchCaptureSourceToken)
    func audioRecorderEncodeError(_ error: (any Error)?, source: WatchCaptureSourceToken)
}

@MainActor
protocol WatchAudioSessionControlling: AnyObject {
    var hasSuitableInput: Bool { get }

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

@MainActor
protocol WatchNotificationScheduling: AnyObject {
    func authorizationStatus() async -> WatchNotificationAuthorizationStatus
    func alertSetting() async -> WatchNotificationAlertSetting
    func requestAuthorization() async throws -> WatchNotificationAuthorizationStatus
    func add(identifier: String, title: String, body: String, triggerDate: Date?) async throws
    func removePending(identifier: String)
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

nonisolated protocol WatchFileWriting: Sendable {
    func createDirectory(at url: URL) async throws
    func createFileIfNeeded(at url: URL) async throws
    func fileExists(at url: URL) async -> Bool
    func itemKind(at url: URL) async throws -> WatchCaptureStorageItemKind
    func fileSize(at url: URL) async throws -> Int64
    func fileFingerprint(at url: URL) async throws -> WatchCaptureStorageFileFingerprint?
    func readData(from url: URL) async throws -> Data
    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) async throws
    func appendLine(_ line: Data, to url: URL) async throws
    func atomicReplaceFile(at url: URL, with data: Data) async throws
    func removeItem(at url: URL) async throws
    func moveItem(at sourceURL: URL, to destinationURL: URL) async throws
    func contentsOfDirectory(at url: URL) async throws -> [URL]
}

nonisolated enum WatchCaptureStorageItemKind: Sendable {
    case missing
    case file
    case directory
    case symlink
}

nonisolated struct WatchCaptureStorageFileFingerprint: Codable, Equatable, Sendable {
    let byteCount: Int64
    let modificationDate: Date?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.byteCount == rhs.byteCount
            && lhs.modificationDate?.timeIntervalSince1970.bitPattern
                == rhs.modificationDate?.timeIntervalSince1970.bitPattern
    }
}

nonisolated struct FoundationWatchFileWriter: WatchFileWriting {
    init() {}

    func createDirectory(at url: URL) async throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func createFileIfNeeded(at url: URL) async throws {
        try await self.createDirectory(at: url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    func fileExists(at url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func itemKind(at url: URL) async throws -> WatchCaptureStorageItemKind {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if values?.isSymbolicLink == true {
            return .symlink
        }
        if let isDirectory = values?.isDirectory {
            return isDirectory ? .directory : .file
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .missing }
        return isDirectory.boolValue ? .directory : .file
    }

    func fileSize(at url: URL) async throws -> Int64 {
        guard await self.fileExists(at: url) else { return 0 }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSFilePathErrorKey: url.path])
        }
        return size.int64Value
    }

    func fileFingerprint(at url: URL) async throws -> WatchCaptureStorageFileFingerprint? {
        guard await self.fileExists(at: url) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSFilePathErrorKey: url.path])
        }
        return WatchCaptureStorageFileFingerprint(
            byteCount: size.int64Value,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }

    func readData(from url: URL) async throws -> Data { try Data(contentsOf: url) }

    func writeData(_ data: Data, to url: URL, options: Data.WritingOptions) async throws {
        try await self.createDirectory(at: url.deletingLastPathComponent())
        try data.write(to: url, options: options)
    }

    func appendLine(_ line: Data, to url: URL) async throws {
        try await self.createFileIfNeeded(at: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.write(contentsOf: Data([0x0A]))
        try handle.synchronize()
    }

    func atomicReplaceFile(at url: URL, with data: Data) async throws {
        try await self.createDirectory(at: url.deletingLastPathComponent())
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp", isDirectory: false)
        try data.write(to: tempURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: tempURL)
        try handle.synchronize()
        try? handle.close()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }

    func removeItem(at url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) async throws {
        try await self.createDirectory(at: destinationURL.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: [NSFilePathErrorKey: destinationURL.path])
        }
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
    }

    func contentsOfDirectory(at url: URL) async throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }
}

nonisolated enum WatchAudioProbeResult: Equatable, Sendable {
    case decodable(duration: TimeInterval)
    case confirmedUndecodable
    case ioUnknown
}

nonisolated protocol WatchAudioProbing: Sendable {
    func probe(at url: URL) async -> WatchAudioProbeResult
}

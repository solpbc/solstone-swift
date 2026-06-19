// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
protocol ShareItemProvider: AnyObject {
    func registeredContentType() -> String?
    func suggestedFilename() -> String?
    func loadFileRepresentation() async throws -> URL
    func loadText() async throws -> String
}

@MainActor
protocol ShareImportQueueing: AnyObject {
    func enqueue(
        fileURL: URL,
        source: String,
        targetJournal: String,
        contentType: String,
        originalFilename: String?,
        originApp: String?
    ) async throws -> UUID
}

extension ImportQueue: ShareImportQueueing {}

nonisolated enum ShareImportCopy {
    static let dismiss = "dismiss"
    static let savedAccessibilityLabel = "saved"

    static func failureMessage(plainReason: String) -> String {
        "couldn't save this — \(plainReason). nothing was added."
    }
}

nonisolated enum ShareImportFailure: Equatable, Sendable {
    case oversized
    case unreadable
    case unsupported
    case protected
    case undecodable

    var plainReason: String {
        switch self {
        case .oversized:
            "too large"
        case .unreadable:
            "couldn't read it"
        case .unsupported:
            "unsupported file type"
        case .protected:
            "protected file"
        case .undecodable:
            "couldn't read the image"
        }
    }

    var message: String {
        ShareImportCopy.failureMessage(plainReason: self.plainReason)
    }
}

nonisolated enum ShareImportEvent: Equatable, Sendable {
    case resolved
    case precheckPassed
    case enqueueStarted
    case enqueueSucceeded(UUID)
    case saveCommitted
    case failed(ShareImportFailure)
}

nonisolated enum ShareImportResult: Equatable, Sendable {
    case success(UUID)
    case failure(ShareImportFailure)
    case dropped

    var failureMessage: String? {
        switch self {
        case .success, .dropped:
            nil
        case .failure(let failure):
            failure.message
        }
    }
}

@MainActor
final class ShareImportCoordinator {
    nonisolated static let oversizedByteLimit: Int64 = 100 * 1024 * 1024

    private let queue: any ShareImportQueueing
    private let fileManager: FileManager
    private let recordEvent: @MainActor @Sendable (ShareImportEvent) -> Void

    init(
        queue: any ShareImportQueueing,
        fileManager: FileManager = .default,
        recordEvent: @escaping @MainActor @Sendable (ShareImportEvent) -> Void = { _ in }
    ) {
        self.queue = queue
        self.fileManager = fileManager
        self.recordEvent = recordEvent
    }

    func accept(provider: any ShareItemProvider) async -> ShareImportResult {
        guard let contentType = provider.registeredContentType(),
              Self.isSupportedContentType(contentType),
              let importerSource = Self.importerSource(for: contentType)
        else {
            return self.fail(.unsupported)
        }
        let originalFilename = provider.suggestedFilename()
        self.emit(.resolved)

        if Self.isPlainTextContentType(contentType) {
            return await self.acceptText(
                provider: provider,
                originalFilename: originalFilename
            )
        }

        let fileURL: URL
        do {
            fileURL = try await provider.loadFileRepresentation()
        } catch {
            return self.fail(.unreadable)
        }
        defer {
            try? self.fileManager.removeItem(at: fileURL)
        }

        var enqueueFileURL = fileURL
        var enqueueContentType = contentType
        var enqueueFilename = originalFilename
        var extraCleanupURL: URL?
        if Self.isHEICContentType(contentType) {
            do {
                let jpegURL = try self.transcodeHEICToJPEG(
                    fileURL: fileURL,
                    originalFilename: originalFilename
                )
                enqueueFileURL = jpegURL
                enqueueContentType = UTType.jpeg.identifier
                enqueueFilename = jpegURL.lastPathComponent
                extraCleanupURL = jpegURL
            } catch {
                return self.fail(.undecodable)
            }
        }
        defer {
            if let extraCleanupURL {
                try? self.fileManager.removeItem(at: extraCleanupURL)
            }
        }

        guard self.fileManager.fileExists(atPath: enqueueFileURL.path) else {
            return self.fail(.unreadable)
        }

        do {
            let size = try self.byteCount(fileURL: enqueueFileURL)
            guard size <= Self.oversizedByteLimit else {
                return self.fail(.oversized)
            }
        } catch {
            return self.fail(.unreadable)
        }

        do {
            try self.checkReadable(fileURL: enqueueFileURL)
        } catch {
            return self.fail(.protected)
        }

        self.emit(.precheckPassed)
        self.emit(.enqueueStarted)

        do {
            let itemID = try await self.queue.enqueue(
                fileURL: enqueueFileURL,
                source: importerSource,
                targetJournal: "",
                contentType: enqueueContentType,
                originalFilename: enqueueFilename,
                originApp: nil
            )
            self.emit(.enqueueSucceeded(itemID))
            return .success(itemID)
        } catch {
            return self.fail(.unreadable)
        }
    }

    func saveCommitted() {
        self.emit(.saveCommitted)
    }
}

extension ShareImportCoordinator {
    nonisolated static func supportedContentType(from identifiers: [String]) -> String? {
        identifiers.first { self.isSupportedContentType($0) }
    }

    nonisolated static func isSupportedContentType(_ identifier: String) -> Bool {
        self.importerSource(for: identifier) != nil
    }

    nonisolated static func importerSource(for identifier: String) -> String? {
        if self.isPlainTextContentType(identifier) {
            return "quick"
        }
        if identifier == "public.m4a-audio" || identifier == "audio/m4a" || identifier == "audio/mp4" {
            return "recording"
        }
        if self.isSupportedImageContentType(identifier) {
            return "image"
        }
        guard let type = UTType(identifier) else { return nil }
        if type.conforms(to: .pdf) {
            return "document"
        }
        if type.conforms(to: .audio) {
            return "recording"
        }
        return nil
    }

    nonisolated static func isPlainTextContentType(_ identifier: String) -> Bool {
        if identifier == "public.plain-text" || identifier == "public.utf8-plain-text" || identifier == "text/plain" {
            return true
        }
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .plainText)
    }

    nonisolated static func isSupportedImageContentType(_ identifier: String) -> Bool {
        switch identifier {
        case "public.jpeg", "public.jpg", "image/jpeg",
            "public.png", "image/png",
            "org.webmproject.webp", "public.webp", "image/webp",
            "com.compuserve.gif", "image/gif",
            "public.tiff", "image/tiff",
            "public.heic", "public.heif", "image/heic", "image/heif":
            return true
        default:
            break
        }

        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .jpeg)
            || type.conforms(to: .png)
            || type.conforms(to: .gif)
            || type.conforms(to: .tiff)
            || type.conforms(to: .heic)
            || type.conforms(to: .heif)
    }

    nonisolated static func isHEICContentType(_ identifier: String) -> Bool {
        if identifier == "public.heic" || identifier == "public.heif" || identifier == "image/heic" || identifier == "image/heif" {
            return true
        }
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .heic) || type.conforms(to: .heif)
    }
}

private extension ShareImportCoordinator {
    func emit(_ event: ShareImportEvent) {
        self.recordEvent(event)
    }

    func fail(_ failure: ShareImportFailure) -> ShareImportResult {
        self.emit(.failed(failure))
        return .failure(failure)
    }

    func acceptText(
        provider: any ShareItemProvider,
        originalFilename: String?
    ) async -> ShareImportResult {
        let text: String
        do {
            text = try await provider.loadText()
        } catch {
            return self.fail(.unreadable)
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .dropped
        }

        let fileURL: URL
        do {
            fileURL = try self.writeTextToScratch(text, originalFilename: originalFilename)
        } catch {
            return self.fail(.unreadable)
        }
        defer {
            try? self.fileManager.removeItem(at: fileURL)
        }

        do {
            let size = try self.byteCount(fileURL: fileURL)
            guard size <= Self.oversizedByteLimit else {
                return self.fail(.oversized)
            }
            try self.checkReadable(fileURL: fileURL)
        } catch {
            return self.fail(.unreadable)
        }

        self.emit(.precheckPassed)
        self.emit(.enqueueStarted)

        do {
            let itemID = try await self.queue.enqueue(
                fileURL: fileURL,
                source: "quick",
                targetJournal: "",
                contentType: "public.plain-text",
                originalFilename: originalFilename ?? "shared-text.txt",
                originApp: nil
            )
            self.emit(.enqueueSucceeded(itemID))
            return .success(itemID)
        } catch {
            return self.fail(.unreadable)
        }
    }

    func byteCount(fileURL: URL) throws -> Int64 {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize {
            return Int64(fileSize)
        }

        let attributes = try self.fileManager.attributesOfItem(atPath: fileURL.path)
        if let size = attributes[.size] as? NSNumber {
            return size.int64Value
        }

        return Int64((try Data(contentsOf: fileURL)).count)
    }

    func checkReadable(fileURL: URL) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }
        _ = try handle.read(upToCount: 1)
    }

    func writeTextToScratch(_ text: String, originalFilename: String?) throws -> URL {
        let filename = originalFilename?.isEmpty == false ? originalFilename! : "shared-text.txt"
        let targetURL = try self.scratchFileURL(filename: filename)
        try Data(text.utf8).write(to: targetURL, options: .atomic)
        return targetURL
    }

    func transcodeHEICToJPEG(fileURL: URL, originalFilename: String?) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else {
            throw ShareImportCoordinatorError.imageDecodeFailed
        }

        let targetURL = try self.scratchFileURL(filename: Self.jpegFilename(for: originalFilename ?? fileURL.lastPathComponent))
        guard let destination = CGImageDestinationCreateWithURL(
            targetURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ShareImportCoordinatorError.imageDecodeFailed
        }

        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ShareImportCoordinatorError.imageDecodeFailed
        }
        return targetURL
    }

    func scratchFileURL(filename: String) throws -> URL {
        let directory = self.fileManager.temporaryDirectory
            .appendingPathComponent("SolstoneShareImport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(filename, isDirectory: false)
    }

    nonisolated static func jpegFilename(for filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        return (base.isEmpty ? "image" : base) + ".jpg"
    }
}

private enum ShareImportCoordinatorError: Error {
    case imageDecodeFailed
}

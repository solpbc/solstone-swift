// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UniformTypeIdentifiers

@MainActor
protocol ShareItemProvider: AnyObject {
    func registeredContentType() -> String?
    func suggestedFilename() -> String?
    func loadFileRepresentation() async throws -> URL
}

@MainActor
protocol ShareImportQueueing: AnyObject {
    func enqueue(
        fileURL: URL,
        source: String,
        stream: String,
        targetJournal: String,
        contentType: String,
        originalFilename: String?,
        originApp: String?
    ) async throws -> UUID
}

extension ImportQueue: ShareImportQueueing {}

nonisolated enum ShareImportCopy {
    static let dismiss = "dismiss"
    static let connectFirstBody = "connect your journal first — then you can send things to it."
    static let connectJournalButton = "connect your journal"
    static let pausedBody = "share sheet is paused. resume it to send this, or cancel."
    static let cancel = "cancel"
    static let resumeAndSend = "resume & send"
    static let sendToYourJournal = "send to your journal"
    static let solCanReadBody = "sol can read it so you can find and ask about it later."

    static func failureMessage(plainReason: String) -> String {
        "couldn't save this — \(plainReason). nothing was added."
    }
}

nonisolated enum ShareImportFailure: Equatable, Sendable {
    case oversized
    case unreadable
    case unsupported
    case protected

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

    var failureMessage: String? {
        switch self {
        case .success:
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

    func accept(provider: any ShareItemProvider, journalName: String) async -> ShareImportResult {
        guard let contentType = provider.registeredContentType(),
              Self.isSupportedContentType(contentType)
        else {
            return self.fail(.unsupported)
        }
        let originalFilename = provider.suggestedFilename()
        self.emit(.resolved)

        let fileURL: URL
        do {
            fileURL = try await provider.loadFileRepresentation()
        } catch {
            return self.fail(.unreadable)
        }
        defer {
            try? self.fileManager.removeItem(at: fileURL)
        }

        guard self.fileManager.fileExists(atPath: fileURL.path) else {
            return self.fail(.unreadable)
        }

        do {
            let size = try self.byteCount(fileURL: fileURL)
            guard size <= Self.oversizedByteLimit else {
                return self.fail(.oversized)
            }
        } catch {
            return self.fail(.unreadable)
        }

        do {
            try self.checkReadable(fileURL: fileURL)
        } catch {
            return self.fail(.protected)
        }

        self.emit(.precheckPassed)
        self.emit(.enqueueStarted)

        do {
            let itemID = try await self.queue.enqueue(
                fileURL: fileURL,
                source: "share",
                stream: "import.share",
                targetJournal: journalName,
                contentType: contentType,
                originalFilename: originalFilename,
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
        if identifier == "public.m4a-audio"
            || identifier == "public.jpg"
            || identifier == "public.webp"
        {
            return true
        }

        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .pdf)
            || type.conforms(to: .audio)
            || type.conforms(to: .image)
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
}

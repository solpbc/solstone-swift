// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UniformTypeIdentifiers

@MainActor
protocol ShareItemProvider: AnyObject {
    func registeredContentType() -> String?
    func suggestedFilename() -> String?
    func deliverFile(to sink: any ShareFileSink) async throws -> ShareFileDelivery
    func loadText() async throws -> String
}

@MainActor
protocol ShareImportQueueing: AnyObject {
    func beginEnqueue() throws -> ShareImportEnqueueHandle
    func makeFileSink(
        handle: ShareImportEnqueueHandle,
        operation: ShareImportLandingOperation,
        inboundContentType: String,
        suggestedFilename: String?
    ) -> any ShareFileSink
    func commitEnqueue(
        handle: ShareImportEnqueueHandle,
        delivery: ShareFileDelivery,
        source: String,
        targetJournal: String,
        originApp: String?
    ) throws -> UUID
    func abortEnqueue(_ handle: ShareImportEnqueueHandle)
}

extension ShareImportStore: ShareImportQueueing {}

nonisolated enum ShareImportCopy {
    static let dismiss = "dismiss"
    static let savedAccessibilityLabel = "saved"

    static func failureMessage(plainReason: String) -> String {
        "couldn't save this — \(plainReason). nothing was added."
    }

    static func batchCounts(for results: [ShareImportResult]) -> (saved: Int, failed: Int) {
        var saved = 0
        var failed = 0
        for result in results {
            switch result {
            case .success:
                saved += 1
            case .failure:
                failed += 1
            case .dropped:
                break
            }
        }
        return (saved, failed)
    }

    static func batchStatus(saved: Int, failed: Int) -> String {
        switch (saved, failed) {
        case (0, 0):
            ""
        case (1, 0):
            Self.savedAccessibilityLabel
        case (let saved, 0) where saved > 1:
            "saved \(saved) of \(saved)"
        case (let saved, let failed) where saved > 0 && failed > 0:
            "\(saved) saved · \(failed) couldn't"
        case (0, 1):
            // The caller renders the single failed item's reason-rich copy directly.
            ""
        case (0, let failed) where failed > 1:
            "couldn't save \(failed) items — nothing was added."
        default:
            ""
        }
    }
}

nonisolated enum ShareImportFailure: Equatable, Sendable {
    case noRoom
    case unreadable
    case unsupported
    case protected
    case undecodable

    var plainReason: String {
        switch self {
        case .noRoom:
            "not enough space"
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
    private let queue: any ShareImportQueueing
    private let recordEvent: @MainActor @Sendable (ShareImportEvent) -> Void

    init(
        queue: any ShareImportQueueing,
        recordEvent: @escaping @MainActor @Sendable (ShareImportEvent) -> Void = { _ in }
    ) {
        self.queue = queue
        self.recordEvent = recordEvent
    }

    func accept(provider: any ShareItemProvider) async -> ShareImportResult {
        // TODO(import-classifier): future classifiers may route screenshots/current-segment captures to the iPhone segment stream.
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

        do {
            let handle = try self.queue.beginEnqueue()
            var committed = false
            defer {
                if !committed {
                    self.queue.abortEnqueue(handle)
                }
            }
            let operation: ShareImportLandingOperation = Self.isHEICContentType(contentType)
                ? .transcodeHEICToJPEG
                : .copy
            let sink = self.queue.makeFileSink(
                handle: handle,
                operation: operation,
                inboundContentType: contentType,
                suggestedFilename: originalFilename
            )
            let delivery = try await provider.deliverFile(to: sink)
            self.emit(.precheckPassed)
            self.emit(.enqueueStarted)
            let itemID = try self.queue.commitEnqueue(
                handle: handle,
                delivery: delivery,
                source: importerSource,
                targetJournal: "",
                originApp: nil
            )
            committed = true
            self.emit(.enqueueSucceeded(itemID))
            return .success(itemID)
        } catch {
            return self.fail(self.failure(from: error))
        }
    }

    func saveCommitted() {
        self.emit(.saveCommitted)
    }
}

extension ShareImportCoordinator {
    func accept(providers: [any ShareItemProvider]) async -> [ShareImportResult] {
        var results: [ShareImportResult] = []
        results.reserveCapacity(providers.count)
        for provider in providers {
            results.append(await self.accept(provider: provider))
        }
        return results
    }

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
            return "audio"
        }
        if self.isSupportedImageContentType(identifier) {
            return "image"
        }
        guard let type = UTType(identifier) else { return nil }
        if type.conforms(to: .pdf) {
            return "document"
        }
        if type.conforms(to: .audio) {
            return "audio"
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

        do {
            let handle = try self.queue.beginEnqueue()
            var committed = false
            defer {
                if !committed {
                    self.queue.abortEnqueue(handle)
                }
            }
            let textData = Data(text.utf8)
            try textData.write(to: handle.stagingRawURL, options: .atomic)
            let delivery = ShareFileDelivery(
                byteCount: Int64(textData.count),
                itemTime: Date(),
                basis: "file",
                contentType: "public.plain-text",
                filename: originalFilename ?? "shared-text.txt"
            )
            self.emit(.precheckPassed)
            self.emit(.enqueueStarted)
            let itemID = try self.queue.commitEnqueue(
                handle: handle,
                delivery: delivery,
                source: "quick",
                targetJournal: "",
                originApp: nil
            )
            committed = true
            self.emit(.enqueueSucceeded(itemID))
            return .success(itemID)
        } catch {
            return self.fail(self.failure(from: error))
        }
    }

    func failure(from error: Error) -> ShareImportFailure {
        guard let storeError = error as? ShareImportStoreError else {
            return .unreadable
        }
        switch storeError {
        case .noRoom:
            return .noRoom
        case .protected:
            return .protected
        case .undecodable:
            return .undecodable
        case .writeFailed, .missingRequiredArtifact, .noteDecodeFailed, .textDecodeFailed:
            return .unreadable
        }
    }
}

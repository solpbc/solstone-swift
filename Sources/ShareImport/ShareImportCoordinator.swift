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
        originApp: String?,
        handoff: ShareImportHandoff?
    ) throws -> UUID
    func abortEnqueue(_ handle: ShareImportEnqueueHandle)
}

extension ShareImportQueueing {
    func commitEnqueue(
        handle: ShareImportEnqueueHandle,
        delivery: ShareFileDelivery,
        source: String,
        targetJournal: String,
        originApp: String?
    ) throws -> UUID {
        try self.commitEnqueue(
            handle: handle,
            delivery: delivery,
            source: source,
            targetJournal: targetJournal,
            originApp: originApp,
            handoff: nil
        )
    }
}

extension ShareImportStore: ShareImportQueueing {}

/// What the journal's import page asked for when it handed a pick to the app: the import
/// area and the page's context object, kept as the JSON text the page sent. Both ride to
/// the journal with the file, unchanged.
nonisolated struct ShareImportHandoff: Equatable, Sendable {
    let area: String
    let context: String
}

nonisolated enum ShareImportCopy {
    static let dismiss = AppStrings.ios_app_dismiss()
    static let savedAccessibilityLabel = AppStrings.ios_shareimportcoordinator_saved()

    static func failureMessage(plainReason: String) -> String {
        AppStrings.ios_share_failuremessage("\(plainReason)")
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
            AppStrings.ios_share_batchstatus2_native("\(saved)", "\(saved)")
        case (let saved, let failed) where saved > 0 && failed > 0:
            AppStrings.ios_share_batchstatus3_native("\(saved)", "\(failed)")
        case (0, 1):
            // The caller renders the single failed item's reason-rich copy directly.
            ""
        case (0, let failed) where failed > 1:
            AppStrings.ios_share_batchstatus_native("\(failed)")
        default:
            ""
        }
    }
}

nonisolated enum ShareImportFailure: Equatable, Sendable {
    case noRoom
    case tooLarge
    case unreadable
    case unsupported
    case protected
    case undecodable

    var plainReason: String {
        switch self {
        case .noRoom:
            AppStrings.ios_share_plainreason3()
        case .tooLarge:
            AppStrings.ios_share_plainreasontoolarge()
        case .unreadable:
            AppStrings.ios_share_plainreason()
        case .unsupported:
            AppStrings.ios_share_plainreason5()
        case .protected:
            AppStrings.ios_share_plainreason4()
        case .undecodable:
            AppStrings.ios_share_plainreason2()
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
    private let originApp: String?
    private let handoff: ShareImportHandoff?
    private let recordEvent: @MainActor @Sendable (ShareImportEvent) -> Void

    /// `originApp` names where every item in this batch came from, when the app knows it (see `ShareImportOrigin`).
    /// `handoff` is set when the journal's import page asked for these items.
    init(
        queue: any ShareImportQueueing,
        originApp: String? = nil,
        handoff: ShareImportHandoff? = nil,
        recordEvent: @escaping @MainActor @Sendable (ShareImportEvent) -> Void = { _ in }
    ) {
        self.queue = queue
        self.originApp = originApp
        self.handoff = handoff
        self.recordEvent = recordEvent
    }

    func accept(provider: any ShareItemProvider) async -> ShareImportResult {
        // The journal decides what a file is, so any file is taken; only a bare link is not a file.
        guard let contentType = provider.registeredContentType(),
              let importerSource = Self.importerSource(for: contentType)
        else {
            return self.fail(.unsupported)
        }
        let originalFilename = provider.suggestedFilename()
        self.emit(.resolved)

        if Self.isPlainTextContentType(contentType), self.handoff == nil {
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
                // A handed-off text file goes as a file, so the journal keeps its name.
                source: importerSource == "quick" ? "file" : importerSource,
                targetJournal: "",
                originApp: self.originApp,
                handoff: self.handoff
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

    /// The type an item is read as: a kind the app knows first, otherwise any file type it carries.
    nonisolated static func supportedContentType(from identifiers: [String]) -> String? {
        identifiers.first { self.isKnownContentType($0) } ?? identifiers.first { self.isSupportedContentType($0) }
    }

    nonisolated static func isSupportedContentType(_ identifier: String) -> Bool {
        self.importerSource(for: identifier) != nil
    }

    private nonisolated static func isKnownContentType(_ identifier: String) -> Bool {
        guard let source = self.importerSource(for: identifier) else { return false }
        return source != "file"
    }

    /// The local label an item is filed under. `quick` items go to the journal as text; every
    /// other kind goes as a file. Only a link, which is not a file, has none.
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
        if type.conforms(to: .url) || !type.conforms(to: .data) {
            return nil
        }
        return "file"
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
            guard Int64(textData.count) <= ShareImportFileSink.maxFileBytes else {
                throw ShareImportStoreError.tooLarge
            }
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
                originApp: self.originApp,
                handoff: nil
            )
            committed = true
            self.emit(.enqueueSucceeded(itemID))
            return .success(itemID)
        } catch {
            return self.fail(self.failure(from: error))
        }
    }

    func failure(from error: Error) -> ShareImportFailure {
        if let storeError = error as? ShareImportStoreError {
            switch storeError {
            case .noRoom:
                return .noRoom
            case .tooLarge:
                return .tooLarge
            case .protected:
                return .protected
            case .undecodable:
                return .undecodable
            case .unreadable, .writeFailed, .missingRequiredArtifact, .noteDecodeFailed, .textDecodeFailed:
                return .unreadable
            }
        }
        if case .unsupported = error as? ShareExtensionItemProviderError {
            return .unsupported
        }
        if ShareImportNoRoom.matches(error) {
            return .noRoom
        }
        return .unreadable
    }
}

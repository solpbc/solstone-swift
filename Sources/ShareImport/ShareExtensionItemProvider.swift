// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

@MainActor
final class ShareExtensionItemProvider: ShareItemProvider {
    private let provider: NSItemProvider

    init(provider: NSItemProvider) {
        self.provider = provider
    }

    func registeredContentType() -> String? {
        ShareImportCoordinator.supportedContentType(from: self.provider.registeredTypeIdentifiers)
    }

    func suggestedFilename() -> String? {
        self.provider.suggestedName
    }

    func deliverFile(to sink: any ShareFileSink) async throws -> ShareFileDelivery {
        guard let typeIdentifier = self.registeredContentType() else {
            throw ShareExtensionItemProviderError.unsupported
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeIdentifier) { sourceURL, isInPlace, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let sourceURL else {
                    continuation.resume(throwing: ShareExtensionItemProviderError.missingFile)
                    return
                }

                var didStartAccess = false
                if isInPlace {
                    didStartAccess = sourceURL.startAccessingSecurityScopedResource()
                }

                do {
                    let delivery = try sink.consume(sourceURL: sourceURL, isInPlace: isInPlace)
                    if didStartAccess {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                    continuation.resume(returning: delivery)
                } catch {
                    if didStartAccess {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func loadText() async throws -> String {
        guard let typeIdentifier = self.registeredContentType(),
              ShareImportCoordinator.isPlainTextContentType(typeIdentifier)
        else {
            throw ShareExtensionItemProviderError.unsupported
        }

        if let text = try? await self.loadTextData(typeIdentifier: typeIdentifier) {
            return text
        }
        return try await self.loadTextItem(typeIdentifier: typeIdentifier)
    }

    private func loadTextData(typeIdentifier: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let text = String(data: data, encoding: .utf8) else {
                    continuation.resume(throwing: ShareExtensionItemProviderError.textDecodeFailed)
                    return
                }
                continuation.resume(returning: text)
            }
        }
    }

    private func loadTextItem(typeIdentifier: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                do {
                    continuation.resume(returning: try Self.text(from: item))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func text(from item: NSSecureCoding?) throws -> String {
        if let string = item as? String {
            return string
        }
        if let string = item as? NSString {
            return string as String
        }
        if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let url = item as? URL {
            return try String(contentsOf: url, encoding: .utf8)
        }
        if let url = item as? NSURL, let swiftURL = url as URL? {
            return try String(contentsOf: swiftURL, encoding: .utf8)
        }
        throw ShareExtensionItemProviderError.textDecodeFailed
    }
}

enum ShareExtensionItemProviderError: Error {
    case unsupported
    case missingFile
    case textDecodeFailed
}

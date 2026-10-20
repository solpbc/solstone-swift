// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UniformTypeIdentifiers

/// The in-app ways into import: the photo picker, the file picker and a drop onto the import pane.
/// Each hands its items to the same coordinator, item provider and store the share extension uses,
/// so a picked or dropped item lands exactly as a shared one does.
@MainActor
enum InAppImport {
    /// What the file picker and the drop target offer: the kinds the share extension accepts.
    static let acceptedContentTypes: [UTType] = [.pdf, .audio, .image, .plainText]

    static func accept(
        itemProviders: [NSItemProvider],
        queue: any ShareImportQueueing,
        originApp: String? = nil
    ) async -> [ShareImportResult] {
        let coordinator = ShareImportCoordinator(queue: queue, originApp: originApp)
        return await coordinator.accept(providers: itemProviders.map { ShareExtensionItemProvider(provider: $0) })
    }

    /// Picked files are security scoped, so access is held until every file has landed.
    static func accept(
        fileURLs: [URL],
        queue: any ShareImportQueueing
    ) async -> [ShareImportResult] {
        let accessed = fileURLs.filter { $0.startAccessingSecurityScopedResource() }
        defer {
            for url in accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let providers = fileURLs.map { url in
            let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
            provider.suggestedName = url.lastPathComponent
            return provider
        }
        return await self.accept(itemProviders: providers, queue: queue)
    }

    /// The share extension's own wording for a finished batch; `nil` when nothing was taken in.
    nonisolated static func outcomeText(for results: [ShareImportResult]) -> String? {
        let counts = ShareImportCopy.batchCounts(for: results)
        if counts.saved > 0 {
            return ShareImportCopy.batchStatus(saved: counts.saved, failed: counts.failed)
        }
        if counts.failed == 1 {
            return results.lazy.compactMap(\.failureMessage).first
        }
        if counts.failed > 1 {
            return ShareImportCopy.batchStatus(saved: 0, failed: counts.failed)
        }
        return nil
    }
}

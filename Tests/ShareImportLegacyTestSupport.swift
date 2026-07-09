// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation

enum ShareImportLegacyTestSupport {
    static func writeLegacyItem(
        root: URL,
        status: String = "pending",
        itemID: UUID,
        source: String = "file",
        raw: Data = Data("share".utf8),
        contentType: String? = nil,
        requestFilename: String? = nil,
        originalFilename: String? = nil,
        originApp: String? = "com.example.share",
        targetJournal: String = "",
        itemTime: String = "2026-07-09T00:00:00Z",
        savePath: String? = nil,
        saveTimestamp: String = "2026-07-09T00:00:00Z",
        saveAction: String = TransferRecommendedAction.start.rawValue,
        failure: ImportFailureRecord? = nil
    ) throws -> URL {
        let itemIDString = itemID.uuidString.lowercased()
        let directory = self.itemDirectory(root: root, status: status, itemID: itemID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try raw.write(to: directory.appendingPathComponent("raw.bin", isDirectory: false), options: .atomic)

        let resolvedContentType = contentType ?? (source == "quick" ? "text/plain" : "application/pdf")
        let resolvedRequestFilename = requestFilename ?? (source == "quick" ? "text.txt" : "document.pdf")
        let note = ShareImportStore.FrozenNote(
            source: source,
            originApp: originApp,
            contentType: resolvedContentType,
            filename: originalFilename ?? (source == "quick" ? "note.txt" : "document.pdf"),
            bytes: Int64(raw.count),
            basis: "file",
            itemTime: itemTime,
            targetJournal: targetJournal,
            itemID: itemIDString
        )
        try ShareImportStore.orderedNoteData(note)
            .write(to: directory.appendingPathComponent("item.json", isDirectory: false), options: .atomic)

        let requestJSON: [String: Any] = [
            "content_type": resolvedContentType,
            "filename": resolvedRequestFilename,
            "source": source,
        ]
        try JSONSerialization.data(withJSONObject: requestJSON, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("request.json", isDirectory: false), options: .atomic)

        if let savePath {
            let saveJSON: [String: Any] = [
                "path": savePath,
                "recommended_action": saveAction,
                "timestamp": saveTimestamp,
            ]
            try JSONSerialization.data(withJSONObject: saveJSON, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("save.json", isDirectory: false), options: .atomic)
        }
        if let failure {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(failure)
                .write(to: directory.appendingPathComponent("failure.json", isDirectory: false), options: .atomic)
        }
        return directory
    }

    static func itemDirectory(root: URL, status: String, itemID: UUID) -> URL {
        root.appendingPathComponent(status, isDirectory: true)
            .appendingPathComponent(itemID.uuidString.lowercased(), isDirectory: true)
    }
}

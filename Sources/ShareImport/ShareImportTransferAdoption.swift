// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let shareImportTransferLog = Logger(subsystem: "app.solstone.swift", category: "share-import-transfer")

nonisolated enum ShareImportTransferMetadata {
    static let key = "share_import"

    struct Fields: Equatable, Sendable {
        let basis: String
        let contentType: String
        let targetJournal: String
        let filename: String?
        let originApp: String?
        let itemTime: String?
        let bytes: Int64?
        let requestSource: String
    }

    static func meta(fields: Fields) -> JSONValue {
        .object([
            self.key: .object([
                "basis": .string(fields.basis),
                "content_type": .string(fields.contentType),
                "target_journal": .string(fields.targetJournal),
                "filename": fields.filename.map(JSONValue.string) ?? .null,
                "origin_app": fields.originApp.map(JSONValue.string) ?? .null,
                "item_time": fields.itemTime.map(JSONValue.string) ?? .null,
                "bytes": fields.bytes.map { .int(Int($0)) } ?? .null,
                "request_source": .string(fields.requestSource),
            ]),
        ])
    }

    static func fields(from manifest: TransferManifest) throws -> Fields {
        guard case .object(let root) = manifest.meta,
              case .object(let object)? = root[self.key],
              case .string(let basis)? = object["basis"],
              case .string(let contentType)? = object["content_type"],
              case .string(let targetJournal)? = object["target_journal"],
              case .string(let requestSource)? = object["request_source"]
        else {
            throw ShareImportStoreError.noteDecodeFailed(itemID: manifest.itemID.uuidString.lowercased())
        }
        return Fields(
            basis: basis,
            contentType: contentType,
            targetJournal: targetJournal,
            filename: self.optionalString(object["filename"]),
            originApp: self.optionalString(object["origin_app"]),
            itemTime: self.optionalString(object["item_time"]),
            bytes: self.optionalInt(object["bytes"]).map(Int64.init),
            requestSource: requestSource
        )
    }

    private static func optionalString(_ value: JSONValue?) -> String? {
        if case .string(let string)? = value { return string }
        return nil
    }

    private static func optionalInt(_ value: JSONValue?) -> Int? {
        if case .int(let int)? = value { return int }
        return nil
    }
}

@MainActor
extension ShareImportStore {
    func adoptToTransfer(
        engine: TransferEngine,
        diagnosticLog: DiagnosticLog?,
        quarantineRootURL: URL
    ) async -> Int {
        do {
            try self.ensureRootDirectories()
        } catch {
            Self.emit(diagnosticLog, detail: "source=\(self.cacheRootURL.path) reason=ensure-root failed")
            return 1
        }

        let ledger: [String: LedgerEntry]
        do {
            ledger = try self.loadLedger()
        } catch {
            let detail = "source=\(self.ledgerURL().path) reason=ledger unreadable error=\(String(describing: error))"
            Self.emit(diagnosticLog, detail: detail)
            shareImportTransferLog.error("share import adoption aborted ledger unreadable source=\(self.ledgerURL().path, privacy: .public): \(String(describing: error), privacy: .public)")
            return 1
        }

        var unresolved = 0
        unresolved += await self.adopt(status: .pending, ledger: ledger, engine: engine, diagnosticLog: diagnosticLog, quarantineRootURL: quarantineRootURL)
        unresolved += await self.adopt(status: .failed, ledger: ledger, engine: engine, diagnosticLog: diagnosticLog, quarantineRootURL: quarantineRootURL)
        self.refreshCounts()
        return unresolved
    }

    func recordDelivered(manifest: TransferManifest, successKind: TransferSuccessKind) throws {
        let fields = try ShareImportTransferMetadata.fields(from: manifest)
        let receipt = Self.receipt(successKind)
        try self.recordDelivered(
            itemID: manifest.itemID.uuidString.lowercased(),
            basis: fields.basis,
            contentType: fields.contentType,
            targetJournal: fields.targetJournal,
            serverPath: receipt.serverPath,
            serverTimestamp: receipt.serverTimestamp,
            filename: fields.filename,
            originApp: fields.originApp,
            itemTime: fields.itemTime
        )
    }

    private func adopt(
        status: ItemStatus,
        ledger: [String: LedgerEntry],
        engine: TransferEngine,
        diagnosticLog: DiagnosticLog?,
        quarantineRootURL: URL
    ) async -> Int {
        let directories: [URL]
        do {
            directories = try self.itemDirectories(status: status)
        } catch {
            Self.emit(diagnosticLog, detail: "source=\(self.directoryURL(status: status).path) reason=list failed")
            return 1
        }

        var unresolved = 0
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if Task.isCancelled { return unresolved + 1 }
            let itemID = directory.lastPathComponent

            if ledger[itemID] != nil {
                try? self.fileManager.removeItem(at: directory)
                continue
            }

            guard let uuid = UUID(uuidString: itemID) else {
                let quarantined = Self.quarantine(
                    directory,
                    quarantineRootURL: quarantineRootURL,
                    diagnosticLog: diagnosticLog,
                    reason: "invalid item id",
                    fileManager: self.fileManager
                )
                if quarantined == 0 {
                    unresolved += 1
                }
                continue
            }

            let prepared: PreparedShareTransferItem
            let tempURL: URL
            do {
                prepared = try self.prepareTransferItem(itemID: itemID, uuid: uuid, status: status)
                tempURL = try self.copyPayloadToTemp(itemID: itemID, status: status, partID: prepared.partID)
            } catch {
                let quarantined = Self.quarantine(
                    directory,
                    quarantineRootURL: quarantineRootURL,
                    diagnosticLog: diagnosticLog,
                    reason: "unreadable",
                    fileManager: self.fileManager
                )
                if quarantined == 0 {
                    unresolved += 1
                }
                shareImportTransferLog.error("share import adoption quarantined source=\(directory.path, privacy: .public): \(String(describing: error), privacy: .public)")
                continue
            }

            do {
                defer { try? self.fileManager.removeItem(at: tempURL.deletingLastPathComponent()) }
                switch prepared.adoption {
                case .queued:
                    _ = try await engine.enqueue(manifest: prepared.manifest, payloadFileURLs: [prepared.partID: tempURL])
                case .attention(let reason):
                    _ = try await engine.enqueueAttention(
                        manifest: prepared.manifest,
                        payloadFileURLs: [prepared.partID: tempURL],
                        reason: "legacy_terminal_share_import",
                        detail: reason
                    )
                }
                try self.fileManager.removeItem(at: directory)
            } catch {
                unresolved += 1
                Self.emit(diagnosticLog, detail: "source=\(directory.path) reason=adoption failed")
                shareImportTransferLog.error("share import adoption failed source=\(directory.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return unresolved
    }

    private func prepareTransferItem(itemID: String, uuid: UUID, status: ItemStatus) throws -> PreparedShareTransferItem {
        guard self.requiredFilesExist(itemID: itemID, status: status) else {
            throw ShareImportStoreError.missingRequiredArtifact(itemID: itemID)
        }
        let descriptor = try self.loadDescriptor(itemID: itemID, status: status)
        let fields = try self.metadataFields(itemID: itemID, status: status, requestSource: descriptor.source)
        let saveResult = try self.loadSaveResultIfPresent(itemID: itemID, status: status)
        let phase = saveResult.map { result in
            TransferSaveThenStartState(
                phase: .startPending,
                savedPath: result.path,
                savedTimestamp: result.timestamp,
                recommendedAction: result.recommendedAction,
                serverSource: result.source
            )
        } ?? TransferSaveThenStartState(phase: .savePending)
        let payloadKind: TransferPayloadKind = descriptor.source == "quick" ? .text : .file
        let partID = payloadKind == .text ? "text" : "file"
        let parsedItemTime: Date?
        if let value = fields.itemTime {
            parsedItemTime = Self.parseItemTime(value)
        } else {
            parsedItemTime = nil
        }
        let createdAt = parsedItemTime ?? self.now()
        let manifest = TransferManifest(
            itemID: uuid,
            source: ObserverAudioTransferSource.share,
            createdAt: createdAt,
            priority: TransferPriorityInputs(basePriority: .normal, sourceKey: ObserverAudioTransferSource.share),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: partID,
                    kind: payloadKind,
                    relativePath: "raw.bin",
                    filename: descriptor.filename,
                    contentType: descriptor.contentType,
                    byteCount: fields.bytes.map(Int.init)
                ),
            ],
            endpoint: TransferEndpointDescriptor(
                destinationKind: .saveThenStart,
                path: ImporterServerURL.savePath,
                startPath: ImporterServerURL.startPath,
                requiresAuth: false
            ),
            meta: ShareImportTransferMetadata.meta(fields: fields),
            saveThenStart: phase,
            appVersion: AppVersion.shortVersion
        )

        let adoption: PreparedShareTransferItem.Adoption
        if status == .failed {
            guard let failure = self.loadFailureRecordIfPresent(itemID: itemID, status: status) else {
                throw ShareImportStoreError.noteDecodeFailed(itemID: itemID)
            }
            switch failure.classification {
            case .transient:
                adoption = .queued
            case .terminal:
                adoption = .attention(reason: failure.reason)
            }
        } else {
            adoption = .queued
        }
        return PreparedShareTransferItem(manifest: manifest, partID: partID, adoption: adoption)
    }

    private func metadataFields(itemID: String, status: ItemStatus, requestSource: String) throws -> ShareImportTransferMetadata.Fields {
        let data = try Data(contentsOf: self.noteURL(itemID: itemID, status: status))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let basis = object["basis"] as? String,
              let contentType = object["content_type"] as? String,
              let targetJournal = object["target_journal"] as? String
        else {
            throw ShareImportStoreError.noteDecodeFailed(itemID: itemID)
        }
        return ShareImportTransferMetadata.Fields(
            basis: basis,
            contentType: contentType,
            targetJournal: targetJournal,
            filename: object["filename"] as? String,
            originApp: object["origin_app"] as? String,
            itemTime: object["item_time"] as? String,
            bytes: (object["bytes"] as? NSNumber)?.int64Value,
            requestSource: requestSource
        )
    }

    private func copyPayloadToTemp(itemID: String, status: ItemStatus, partID: String) throws -> URL {
        let tempDirectory = self.fileManager.temporaryDirectory
            .appendingPathComponent("share-import-transfer-adoption", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try self.fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        var shouldCleanUpTempDirectory = true
        defer {
            if shouldCleanUpTempDirectory {
                try? self.fileManager.removeItem(at: tempDirectory)
            }
        }
        let tempURL = tempDirectory.appendingPathComponent("raw.bin", isDirectory: false)
        try self.fileManager.copyItem(at: self.rawURL(itemID: itemID, status: status), to: tempURL)
        _ = partID
        shouldCleanUpTempDirectory = false
        return tempURL
    }

    private static func receipt(_ successKind: TransferSuccessKind) -> (serverPath: String?, serverTimestamp: String?) {
        switch successKind {
        case .delivered(let serverPath, let serverTimestamp),
             .alreadyStartedOrComplete(let serverPath, let serverTimestamp):
            return (serverPath, serverTimestamp)
        case .alreadyDelivered:
            return (nil, nil)
        }
    }

    static func quarantine(
        _ sourceURL: URL,
        quarantineRootURL: URL,
        diagnosticLog: DiagnosticLog?,
        reason: String,
        fileManager: FileManager
    ) -> Int {
        do {
            try fileManager.createDirectory(at: quarantineRootURL, withIntermediateDirectories: true)
            let destination = quarantineRootURL
                .appendingPathComponent("\(UUID().uuidString)-\(sourceURL.lastPathComponent)", isDirectory: true)
            try fileManager.moveItem(at: sourceURL, to: destination)
            self.emit(diagnosticLog, detail: "source=\(sourceURL.path) quarantine=\(destination.path) reason=\(reason)")
            return 1
        } catch {
            self.emit(diagnosticLog, detail: "source=\(sourceURL.path) reason=quarantine failed")
            shareImportTransferLog.error("share import quarantine failed source=\(sourceURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    static func emit(_ diagnosticLog: DiagnosticLog?, detail: String) {
        diagnosticLog?.append(category: .upload, severity: .warning, message: "needs attention", detail: detail)
    }
}

private struct PreparedShareTransferItem {
    enum Adoption {
        case queued
        case attention(reason: String)
    }

    let manifest: TransferManifest
    let partID: String
    let adoption: Adoption
}

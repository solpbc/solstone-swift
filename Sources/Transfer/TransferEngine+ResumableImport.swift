// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

extension TransferEngine {
    func resumableProgress(for item: TransferStoredItem) -> TransferResumableProgress? {
        guard item.manifest.endpoint.destinationKind == .saveThenStart,
              item.manifest.saveThenStart?.phase != .startPending,
              let resumable = item.manifest.saveThenStart?.resumable
        else {
            return nil
        }
        let itemID = item.manifest.itemID
        let effectivePhase: TransferResumablePhase = self.inFlight.contains(itemID)
            ? resumable.phase
            : .paused
        return TransferResumableProgress(
            bytesSent: resumable.remoteOffset,
            bytesTotal: resumable.totalBytes,
            phase: effectivePhase,
            isResuming: self.resumableResumingItemIDs.contains(itemID),
            chunkBytes: resumable.chunkBytes ?? ResumableImportDefaults.chunkBytes
        )
    }

    func notifyResumableProgressObserver(itemID: UUID, progress: TransferResumableProgress?) {
        guard let observer = self.resumableProgressObserver else { return }
        Task {
            await observer(itemID, progress)
        }
    }

    func wakeResumableItemsForNewConnection() async {
        // Cancel any in-flight resumable task still bound to a superseded endpoint so the new
        // connection takes over immediately via `GET /uploads/{id}` resync.
        for (itemID, endpoint) in self.resumableTaskEndpointByItemID {
            let current = await self.endpointResolver.isCurrent(endpoint)
            if !current {
                self.resumableUploadTasks[itemID]?.task.cancel()
            }
        }
        var wokeAny = false
        for item in self.queuedItems.values {
            let itemID = item.manifest.itemID
            guard !self.inFlight.contains(itemID),
                  item.manifest.saveThenStart?.resumable != nil,
                  item.manifest.nextAttemptAt != nil
            else {
                continue
            }
            let cleared = item.manifest.replacingNextAttemptAt(nil)
            if let updated = try? self.spool.updateQueuedManifest(cleared, directoryURL: item.directoryURL) {
                self.queuedItems[itemID] = updated
            } else {
                self.queuedItems[itemID] = TransferStoredItem(manifest: cleared, directoryURL: item.directoryURL)
            }
            wokeAny = true
        }
        if wokeAny {
            self.scheduleWork()
        }
    }

    func launchBestEffortResumableDelete(
        uploadID: String,
        expectedInstanceID: String?,
        endpointDescriptor: TransferEndpointDescriptor
    ) {
        let endpointResolver = self.endpointResolver
        let transport = self.transport
        Task.detached(priority: .utility) {
            let resolution = await endpointResolver.resolve(endpointDescriptor)
            guard case .available(let endpoint) = resolution else { return }
            if Self.instanceIDChanged(
                persisted: expectedInstanceID,
                current: endpoint.dispatchOwner?.journalInstanceID
            ) {
                return
            }
            _ = await transport.sendRawRequest(
                method: "DELETE",
                path: "\(ResumableImportDefaults.uploadsPath)/\(uploadID)",
                endpoint: endpoint
            )
        }
    }

    static func instanceIDChanged(persisted: String?, current: String?) -> Bool {
        let lhs = persisted.flatMap { $0.isEmpty ? nil : $0 }
        let rhs = current.flatMap { $0.isEmpty ? nil : $0 }
        guard lhs != nil || rhs != nil else { return false }
        return lhs != rhs
    }

    /// Evaluates whether a `.save` `.file` item should use the resumable upload protocol.
    /// Returns `true` if handled (dispatched, paused, auth-held, or moved to attention), or
    /// `false` if the item should fall through to single-POST `POST /app/import/api/save`.
    func tryDispatchResumableSave(
        item: TransferStoredItem,
        attempt: Int
    ) async -> Bool {
        guard let probe = self.resumableImportProbe,
              let part = item.manifest.payloadParts.first,
              part.kind == .file
        else {
            return false
        }
        let itemID = item.manifest.itemID
        let sourceKey = item.manifest.sourceKey

        let payloadURL: URL
        let totalBytes: Int64
        do {
            guard let existingURL = try self.spool.existingPayloadURL(for: part, in: item) else {
                self.failResumableItemToAttention(
                    itemID: itemID,
                    reason: .resumableFault(
                        journalReasonCode: TransferReasonCodes.localFileUnreadable,
                        detail: part.filename,
                        retryable: false
                    ),
                    clearUploadSession: false,
                    clearWholeFileHash: false,
                    endpoint: nil
                )
                return true
            }
            payloadURL = existingURL
            totalBytes = Int64(try self.spool.payloadByteCount(for: part, in: item))
        } catch {
            self.failResumableItemToAttention(
                itemID: itemID,
                reason: .resumableFault(
                    journalReasonCode: TransferReasonCodes.localFileUnreadable,
                    detail: part.filename,
                    retryable: false
                ),
                clearUploadSession: false,
                clearWholeFileHash: false,
                endpoint: nil
            )
            return true
        }

        let resolution = await self.endpointResolver.resolve(item.manifest.endpoint)
        guard case .available(let endpoint) = resolution else {
            if case .unavailable(let detail) = resolution {
                self.markEndpointHeld(detail: detail)
            }
            self.pauseResumableWithoutBackoff(itemID: itemID, sourceKey: sourceKey, summary: "held")
            self.scheduleRetryTimer()
            return true
        }

        guard await self.endpointResolver.isCurrent(endpoint) else {
            self.pauseResumableWithoutBackoff(itemID: itemID, sourceKey: sourceKey, summary: "held")
            self.scheduleWork()
            return true
        }

        if let sourceGate = self.sourceGate,
           !(await sourceGate.admits(manifest: item.manifest, endpoint: endpoint))
        {
            if attempt > 1 {
                self.attemptCountByItemID[itemID] = attempt - 1
            } else {
                self.attemptCountByItemID.removeValue(forKey: itemID)
                self.firstAttemptAtByItemID.removeValue(forKey: itemID)
            }
            self.clearInFlight(itemID: itemID, sourceKey: sourceKey)
            self.scheduleStatusUpdate(summary: "held")
            return true
        }

        // Enforce pairing-switch rule before reusing any persisted remote upload session.
        self.applyPairingSwitchRuleIfNeeded(
            itemID: itemID,
            currentInstanceID: endpoint.dispatchOwner?.journalInstanceID
        )

        let capability = await probe.capability(
            for: endpoint,
            journalVersion: self.journalVersion
        )

        guard self.queuedItems[itemID] != nil,
              self.inFlight.contains(itemID),
              !self.droppedItemIDs.contains(itemID)
        else {
            self.clearInFlight(itemID: itemID, sourceKey: sourceKey)
            self.scheduleWork()
            return true
        }

        guard !self.paused, await self.endpointResolver.isCurrent(endpoint) else {
            self.pauseResumableWithoutBackoff(itemID: itemID, sourceKey: sourceKey, summary: "held")
            self.scheduleWork()
            return true
        }

        let currentItem = self.queuedItems[itemID] ?? item
        switch capability {
        case .authRefused(let statusCode):
            await self.handleResumableAuthHold(itemID: itemID, statusCode: statusCode)
            return true

        case .unavailable(let transient):
            if currentItem.manifest.saveThenStart?.resumable != nil {
                self.pauseResumableItemForRetry(itemID: itemID, reason: transient)
            } else {
                self.pauseUnstartedItemForTransientRetry(itemID: itemID, reason: transient)
            }
            return true

        case .unsupported:
            // Older journal: clear any stale resumable state and keep single-POST `/save` unchanged.
            if currentItem.manifest.saveThenStart?.resumable != nil {
                var manifest = currentItem.manifest
                manifest.saveThenStart = TransferSaveThenStartState(phase: .savePending)
                self.persistQueuedManifest(manifest, for: currentItem)
                self.notifyResumableProgressObserver(itemID: itemID, progress: nil)
            }
            return false

        case .supported(let config):
            self.advertisedResumableThresholdBytes = config.thresholdBytes
            let hasOpenSession = currentItem.manifest.saveThenStart?.resumable?.uploadID != nil
            guard hasOpenSession || (totalBytes >= config.thresholdBytes && totalBytes > 0) else {
                return false
            }
            let runToken = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                await self.runResumableUpload(
                    itemID: itemID,
                    runToken: runToken,
                    payloadURL: payloadURL,
                    totalBytes: totalBytes,
                    config: config,
                    endpoint: endpoint
                )
            }
            self.resumableUploadTasks[itemID] = (token: runToken, task: task)
            self.resumableTaskEndpointByItemID[itemID] = endpoint
            return true
        }
    }

    private func applyPairingSwitchRuleIfNeeded(itemID: UUID, currentInstanceID: String?) {
        guard let item = self.queuedItems[itemID],
              var saveState = item.manifest.saveThenStart,
              var resumable = saveState.resumable,
              Self.instanceIDChanged(persisted: resumable.uploadInstanceID, current: currentInstanceID)
        else {
            return
        }
        ResumableUploadLog.notice("pairing switched; clearing remote upload session for \(itemID.uuidString)")
        resumable.uploadID = nil
        resumable.remoteOffset = 0
        resumable.uploadInstanceID = currentInstanceID
        resumable.expiresAt = nil
        resumable.phase = .paused
        saveState.resumable = resumable
        var manifest = item.manifest
        manifest.saveThenStart = saveState
        self.persistQueuedManifest(manifest, for: item)
    }

    private func runResumableUpload(
        itemID: UUID,
        runToken: UUID,
        payloadURL: URL,
        totalBytes: Int64,
        config: ResumableImportConfig,
        endpoint: TransferResolvedEndpoint
    ) async {
        defer {
            if self.resumableUploadTasks[itemID]?.token == runToken {
                self.resumableUploadTasks.removeValue(forKey: itemID)
                self.resumableTaskEndpointByItemID.removeValue(forKey: itemID)
            }
            self.resumableResumingItemIDs.remove(itemID)
        }

        let currentInstanceID = endpoint.dispatchOwner?.journalInstanceID
        guard let initialItem = self.queuedItems[itemID],
              let part = initialItem.manifest.payloadParts.first
        else {
            self.finishDroppedOrMissing(itemID: itemID)
            return
        }
        let sourceKey = initialItem.manifest.sourceKey

        // Initialize or normalize persisted resumable state.
        var resumable = initialItem.manifest.saveThenStart?.resumable ?? TransferResumableUploadState(
            uploadID: nil,
            remoteOffset: 0,
            totalBytes: totalBytes,
            chunkBytes: config.chunkBytes,
            uploadInstanceID: currentInstanceID,
            wholeFileSHA256: nil,
            phase: .sending,
            expiresAt: nil
        )
        resumable.totalBytes = totalBytes
        resumable.chunkBytes = ResumableImportDefaults.clampedChunkBytes(resumable.chunkBytes ?? config.chunkBytes)
        if resumable.uploadID == nil {
            resumable.uploadInstanceID = currentInstanceID
        }
        resumable.phase = resumable.remoteOffset >= totalBytes && resumable.uploadID != nil ? .checking : .sending
        self.persistResumableState(resumable, for: itemID, flushImmediately: true)

        // Step A: Whole-file SHA-256 once from stored custody copy (off-MainActor, O(1) RAM).
        let wholeFileSHA256: String
        if let existingHash = resumable.wholeFileSHA256,
           ResumableUploadIDValidator.isValidSHA256Hex(existingHash)
        {
            wholeFileSHA256 = existingHash.lowercased()
        } else {
            do {
                let computed = try await ResumableFileReader.sha256Hex(at: payloadURL)
                guard await self.shouldContinueResumable(itemID: itemID, endpoint: endpoint) else {
                    self.handleResumableInterrupted(itemID: itemID, sourceKey: sourceKey)
                    return
                }
                wholeFileSHA256 = computed
                resumable.wholeFileSHA256 = computed
                self.persistResumableState(resumable, for: itemID, flushImmediately: false)
            } catch ResumableFileReaderError.cancelled {
                self.handleResumableInterrupted(itemID: itemID, sourceKey: sourceKey)
                return
            } catch {
                self.failResumableItemToAttention(
                    itemID: itemID,
                    reason: .resumableFault(
                        journalReasonCode: TransferReasonCodes.localFileUnreadable,
                        detail: part.filename,
                        retryable: false
                    ),
                    clearUploadSession: false,
                    clearWholeFileHash: false,
                    endpoint: endpoint
                )
                return
            }
        }

        // Step B: Create session or resync existing session.
        var uploadID: String
        if let existingID = resumable.uploadID, ResumableUploadIDValidator.isValid(existingID) {
            uploadID = existingID
            if resumable.remoteOffset < totalBytes {
                self.resumableResumingItemIDs.insert(itemID)
                self.persistResumableState(resumable, for: itemID, flushImmediately: true)
                let syncResult = await self.transport.sendRawRequest(
                    method: "GET",
                    path: "\(ResumableImportDefaults.uploadsPath)/\(existingID)",
                    headers: ["Cache-Control": "no-cache"],
                    endpoint: endpoint
                )
                self.resumableResumingItemIDs.remove(itemID)

                guard await self.shouldContinueResumable(itemID: itemID, endpoint: endpoint) else {
                    self.handleResumableInterrupted(itemID: itemID, sourceKey: sourceKey)
                    return
                }

                switch await self.handleStatusResyncResponse(
                    syncResult,
                    uploadID: existingID,
                    itemID: itemID,
                    totalBytes: totalBytes,
                    defaultChunkBytes: config.chunkBytes,
                    endpoint: endpoint
                ) {
                case .synced(let nextOffset, let chunkBytes, let expiresAt):
                    var workingSize = min(resumable.chunkBytes ?? chunkBytes, chunkBytes)
                    if nextOffset == resumable.remoteOffset, let attempted = resumable.interruptedChunkBytes {
                        let smaller = max(ResumableImportDefaults.minChunkBytes, min(512 * 1024, attempted / 2))
                        workingSize = min(workingSize, smaller)
                    }
                    resumable.interruptedChunkBytes = nil
                    resumable.remoteOffset = nextOffset
                    resumable.chunkBytes = workingSize
                    resumable.expiresAt = expiresAt ?? resumable.expiresAt
                    resumable.phase = nextOffset >= totalBytes ? .checking : .sending
                    self.persistResumableState(resumable, for: itemID, flushImmediately: true)
                case .handledAndStop:
                    return
                }
            }
            // When remoteOffset == totalBytes, skip GET and go straight to commit so a lost commit
            // response hits the journal's recent-commit replay instead of getting 404 from GET.
        } else {
            guard let item = self.queuedItems[itemID] else {
                self.finishDroppedOrMissing(itemID: itemID)
                return
            }
            let metadata = try? ShareImportTransferMetadata.fields(from: item.manifest)
            let createPayload = ResumableUploadCreatePayload(
                clientItemID: itemID.uuidString.lowercased(),
                filename: part.filename,
                totalBytes: totalBytes,
                sha256: wholeFileSHA256,
                mimeType: part.contentType,
                importedVia: ShareImportOrigin.importedVia,
                deviceNoun: self.deviceNoun,
                capturedAt: metadata?.capturedAt,
                area: metadata?.importArea,
                context: metadata?.importContext
            )
            let createBody: Data
            do {
                createBody = try createPayload.jsonData()
            } catch {
                self.failResumableItemToAttention(
                    itemID: itemID,
                    reason: .malformedManifest("invalid upload request"),
                    clearUploadSession: true,
                    clearWholeFileHash: false,
                    endpoint: endpoint
                )
                return
            }

            let createResult = await self.transport.sendRawRequest(
                method: "POST",
                path: ResumableImportDefaults.uploadsPath,
                headers: ["Content-Type": "application/json"],
                body: createBody,
                endpoint: endpoint
            )

            guard await self.shouldContinueResumable(itemID: itemID, endpoint: endpoint) else {
                self.handleResumableInterrupted(itemID: itemID, sourceKey: sourceKey)
                return
            }

            if let issue = createResult.issue {
                self.pauseResumableItemForRetry(itemID: itemID, reason: Self.transientReason(for: issue))
                return
            }
            guard let statusCode = createResult.statusCode else {
                self.pauseResumableItemForRetry(itemID: itemID, reason: .transport("missing status"))
                return
            }
            if statusCode == 403, createResult.loopbackRefused {
                self.pauseResumableItemForRetry(itemID: itemID, reason: .transport("loopback refused"))
                return
            }
            if statusCode == 401 || statusCode == 403 {
                await self.handleResumableAuthHold(itemID: itemID, statusCode: statusCode)
                return
            }
            let errBody = 400..<600 ~= statusCode ? ResumableUploadErrorBody.parse(from: createResult.data) : nil
            if (statusCode == 404 || statusCode == 405),
               errBody?.reasonCode != TransferReasonCodes.uploadNotFound
            {
                // Older journal without `/app/import/api/uploads`: mark unsupported and fall back
                // silently to streamed single-POST `/save`.
                await self.resumableImportProbe?.markUnsupported(
                    for: endpoint,
                    journalVersion: self.journalVersion
                )
                self.clearResumableStateAndFallbackToSave(itemID: itemID, sourceKey: sourceKey)
                return
            }
            if statusCode == 507 || errBody?.reasonCode == TransferReasonCodes.insufficientJournalSpace {
                self.failResumableItemToAttention(
                    itemID: itemID,
                    reason: .resumableFault(
                        journalReasonCode: TransferReasonCodes.insufficientJournalSpace,
                        detail: errBody?.error,
                        retryable: true
                    ),
                    clearUploadSession: true,
                    clearWholeFileHash: false,
                    endpoint: endpoint
                )
                return
            }
            if statusCode == 409, errBody?.reasonCode == TransferReasonCodes.journalBusy {
                self.pauseResumableItemForRetry(itemID: itemID, reason: .httpServerError(statusCode: 409))
                return
            }
            if 500..<600 ~= statusCode {
                self.pauseResumableItemForRetry(itemID: itemID, reason: .httpServerError(statusCode: statusCode))
                return
            }
            if !(200..<300 ~= statusCode) {
                self.failResumableWithClientError(
                    itemID: itemID,
                    statusCode: statusCode,
                    data: createResult.data,
                    errBody: errBody,
                    clearUploadSession: true,
                    endpoint: endpoint
                )
                return
            }

            guard let decoded = ResumableUploadWireDecoder.decodeCreateResponse(from: createResult.data) else {
                self.failResumableItemToAttention(
                    itemID: itemID,
                    reason: .decodeFailed(AppStrings.ios_transfer_classifysavesuccess()),
                    clearUploadSession: true,
                    clearWholeFileHash: false,
                    endpoint: endpoint
                )
                return
            }

            switch decoded {
            case .open(let open):
                guard open.totalBytes == totalBytes else {
                    self.failResumableItemToAttention(
                        itemID: itemID,
                        reason: .decodeFailed("upload size mismatch"),
                        clearUploadSession: true,
                        clearWholeFileHash: false,
                        endpoint: endpoint
                    )
                    return
                }
                uploadID = open.uploadID
                resumable.interruptedChunkBytes = nil
                resumable.uploadID = open.uploadID
                resumable.remoteOffset = open.nextOffset
                resumable.chunkBytes = ResumableImportDefaults.clampedChunkBytes(open.chunkBytes ?? config.chunkBytes)
                resumable.uploadInstanceID = currentInstanceID
                resumable.expiresAt = open.expiresAt
                resumable.phase = open.nextOffset >= totalBytes ? .checking : .sending
                self.resumableRetryAttemptByItemID[itemID] = 0
                self.persistResumableState(resumable, for: itemID, flushImmediately: true)

            case .alreadyStaged(let saveData):
                self.handleResumableSaveResponse(itemID: itemID, saveData: saveData, endpoint: endpoint)
                return

            case .alreadyImported(let importID):
                self.completeResumableDelivery(
                    itemID: itemID,
                    successKind: .alreadyStartedOrComplete(serverPath: nil, serverTimestamp: importID),
                    endpoint: endpoint
                )
                return
            }
        }

        // Steps C & D: sequential chunk uploads followed by commit (re-entering the chunk loop if
        // commit ever returns `409 incomplete_upload`).
        var incompleteRewinds = 0
        while true {
            var consecutiveChecksumRetries = 0
            var consecutiveNonAdvancingOffsets = 0

            // Step C: Chunk loop.
            while resumable.remoteOffset < totalBytes {
                guard await self.shouldContinueResumable(itemID: itemID, endpoint: endpoint) else {
                    self.handleResumableInterrupted(itemID: itemID, sourceKey: sourceKey)
                    return
                }

                let chunkSize = ResumableImportDefaults.clampedChunkBytes(resumable.chunkBytes ?? config.chunkBytes)
                let want = Int(min(Int64(chunkSize), totalBytes - resumable.remoteOffset))
                let chunkData: Data
                do {
                    chunkData = try await ResumableFileReader.readChunk(
                        at: payloadURL,
                        offset: resumable.remoteOffset,
                        length: want
                    )
                } catch ResumableFileReaderError.cancelled {
                    self.handleResumableInterrupted(itemID: itemID, sourceKey: sourceKey)
                    return
                } catch {
                    self.failResumableItemToAttention(
                        itemID: itemID,
                        reason: .resumableFault(
                            journalReasonCode: TransferReasonCodes.localFileUnreadable,
                            detail: part.filename,
                            retryable: false
                        ),
                        clearUploadSession: false,
                        clearWholeFileHash: false,
                        endpoint: endpoint
                    )
                    return
                }

                guard await self.shouldContinueResumable(itemID: itemID, endpoint: endpoint) else {
                    self.handleResumableInterrupted(itemID: itemID, sourceKey: sourceKey)
                    return
                }

                let chunkSHA256 = ResumableFileReader.sha256Hex(of: chunkData)
                let putResult = await self.transport.sendRawRequest(
                    method: "PUT",
                    path: "\(ResumableImportDefaults.uploadsPath)/\(uploadID)",
                    queryItems: [URLQueryItem(name: "offset", value: "\(resumable.remoteOffset)")],
                    headers: [
                        "Content-Type": "application/octet-stream",
                        "X-Chunk-Sha256": chunkSHA256,
                    ],
                    body: chunkData,
                    endpoint: endpoint
                )

                if putResult.issue?.mayHaveInterruptedUpload == true,
                   self.resumableUploadTasks[itemID]?.token == runToken,
                   var current = self.queuedItems[itemID]?.manifest.saveThenStart?.resumable,
                   current.uploadID == uploadID, current.uploadInstanceID == resumable.uploadInstanceID,
                   current.remoteOffset == resumable.remoteOffset {
                    current.interruptedChunkBytes = chunkData.count
                    self.persistResumableState(current, for: itemID, flushImmediately: true)
                }
                guard await self.shouldContinueResumable(itemID: itemID, endpoint: endpoint) else {
                    self.handleResumableInterrupted(itemID: itemID, sourceKey: sourceKey)
                    return
                }

                if let issue = putResult.issue {
                    self.pauseResumableItemForRetry(itemID: itemID, reason: Self.transientReason(for: issue))
                    return
                }
                guard let statusCode = putResult.statusCode else {
                    self.pauseResumableItemForRetry(itemID: itemID, reason: .transport("missing status"))
                    return
                }
                if statusCode == 403, putResult.loopbackRefused {
                    self.pauseResumableItemForRetry(itemID: itemID, reason: .transport("loopback refused"))
                    return
                }
                if statusCode == 401 || statusCode == 403 {
                    await self.handleResumableAuthHold(itemID: itemID, statusCode: statusCode)
                    return
                }

                if 200..<300 ~= statusCode {
                    guard let ack = ResumableUploadWireDecoder.decodeChunkResponse(from: putResult.data),
                          ack.uploadID == uploadID, ack.totalBytes == totalBytes,
                          ack.nextOffset > resumable.remoteOffset
                    else {
                        self.pauseResumableItemForRetry(itemID: itemID, reason: .transport("invalid chunk ack"))
                        return
                    }
                    let confirmedDelta = Int(max(0, ack.nextOffset - resumable.remoteOffset))
                    resumable.remoteOffset = ack.nextOffset
                    resumable.expiresAt = ack.expiresAt ?? resumable.expiresAt
                    resumable.phase = ack.nextOffset >= totalBytes ? .checking : .sending
                    self.resumableRetryAttemptByItemID[itemID] = 0
                    consecutiveChecksumRetries = 0
                    consecutiveNonAdvancingOffsets = 0
                    if confirmedDelta > 0 {
                        self.noteResumableChunkBytes(bytes: confirmedDelta, sourceKey: sourceKey)
                    }
                    self.persistResumableState(resumable, for: itemID, flushImmediately: false)
                    continue
                }

                let errBody = ResumableUploadErrorBody.parse(from: putResult.data)
                if statusCode == 409 {
                    if errBody?.reasonCode == TransferReasonCodes.journalBusy {
                        self.pauseResumableItemForRetry(itemID: itemID, reason: .httpServerError(statusCode: 409))
                        return
                    }
                    if errBody?.reasonCode == TransferReasonCodes.offsetMismatch,
                       let serverOffset = errBody?.nextOffset,
                       serverOffset >= 0,
                       serverOffset <= totalBytes
                    {
                        if serverOffset == resumable.remoteOffset {
                            consecutiveNonAdvancingOffsets += 1
                            if consecutiveNonAdvancingOffsets >= 5 {
                                self.pauseResumableItemForRetry(itemID: itemID, reason: .httpServerError(statusCode: 409))
                                return
                            }
                        } else {
                            consecutiveNonAdvancingOffsets = 0
                            resumable.remoteOffset = serverOffset
                            resumable.phase = serverOffset >= totalBytes ? .checking : .sending
                            self.persistResumableState(resumable, for: itemID, flushImmediately: false)
                        }
                        continue
                    }
                    if errBody?.reasonCode == nil {
                        // Proxy or bridge stripped the 409 JSON body: resync via GET.
                        let syncResult = await self.transport.sendRawRequest(
                            method: "GET",
                            path: "\(ResumableImportDefaults.uploadsPath)/\(uploadID)",
                            headers: ["Cache-Control": "no-cache"],
                            endpoint: endpoint
                        )
                        guard await self.shouldContinueResumable(itemID: itemID, endpoint: endpoint) else {
                            self.handleResumableInterrupted(itemID: itemID, sourceKey: sourceKey)
                            return
                        }
                        switch await self.handleStatusResyncResponse(
                            syncResult,
                            uploadID: uploadID,
                            itemID: itemID,
                            totalBytes: totalBytes,
                            defaultChunkBytes: chunkSize,
                            endpoint: endpoint
                        ) {
                        case .synced(let nextOffset, let syncedChunkBytes, let expiresAt):
                            resumable.chunkBytes = min(chunkSize, syncedChunkBytes)
                            if nextOffset == resumable.remoteOffset {
                                consecutiveNonAdvancingOffsets += 1
                                if consecutiveNonAdvancingOffsets >= 5 {
                                    self.pauseResumableItemForRetry(itemID: itemID, reason: .httpServerError(statusCode: 409))
                                    return
                                }
                            } else {
                                consecutiveNonAdvancingOffsets = 0
                                resumable.remoteOffset = nextOffset
                                resumable.expiresAt = expiresAt ?? resumable.expiresAt
                                resumable.phase = nextOffset >= totalBytes ? .checking : .sending
                            }
                            self.persistResumableState(resumable, for: itemID, flushImmediately: false)
                            continue
                        case .handledAndStop:
                            return
                        }
                    }
                    self.failResumableWithClientError(
                        itemID: itemID,
                        statusCode: statusCode,
                        data: putResult.data,
                        errBody: errBody,
                        clearUploadSession: false,
                        endpoint: endpoint
                    )
                    return
                }

                if statusCode == 422, errBody?.reasonCode == TransferReasonCodes.chunkChecksumMismatch {
                    consecutiveChecksumRetries += 1
                    if consecutiveChecksumRetries <= 3 {
                        continue
                    }
                    self.failResumableItemToAttention(
                        itemID: itemID,
                        reason: .resumableFault(
                            journalReasonCode: TransferReasonCodes.chunkChecksumMismatch,
                            detail: errBody?.error,
                            retryable: true
                        ),
                        clearUploadSession: false,
                        clearWholeFileHash: false,
                        endpoint: endpoint
                    )
                    return
                }

                if statusCode == 404 {
                    self.failResumableItemToAttention(
                        itemID: itemID,
                        reason: .resumableFault(
                            journalReasonCode: TransferReasonCodes.uploadNotFound,
                            detail: errBody?.error,
                            retryable: true
                        ),
                        clearUploadSession: true,
                        clearWholeFileHash: false,
                        endpoint: endpoint
                    )
                    return
                }

                if statusCode == 507 || errBody?.reasonCode == TransferReasonCodes.insufficientJournalSpace {
                    // Keep remote upload_id and offset so retrying after freeing space resumes cleanly.
                    self.failResumableItemToAttention(
                        itemID: itemID,
                        reason: .resumableFault(
                            journalReasonCode: TransferReasonCodes.insufficientJournalSpace,
                            detail: errBody?.error,
                            retryable: true
                        ),
                        clearUploadSession: false,
                        clearWholeFileHash: false,
                        endpoint: endpoint
                    )
                    return
                }

                if 500..<600 ~= statusCode {
                    self.pauseResumableItemForRetry(itemID: itemID, reason: .httpServerError(statusCode: statusCode))
                    return
                }

                self.failResumableWithClientError(
                    itemID: itemID,
                    statusCode: statusCode,
                    data: putResult.data,
                    errBody: errBody,
                    clearUploadSession: false,
                    endpoint: endpoint
                )
                return
            }

            // Step D: Commit.
            guard await self.shouldContinueResumable(itemID: itemID, endpoint: endpoint) else {
                self.handleResumableInterrupted(itemID: itemID, sourceKey: sourceKey)
                return
            }
            resumable.phase = .checking
            self.persistResumableState(resumable, for: itemID, flushImmediately: true)

            let commitBody: Data
            do {
                commitBody = try ResumableUploadWireDecoder.commitBodyData(sha256: wholeFileSHA256)
            } catch {
                self.failResumableItemToAttention(
                    itemID: itemID,
                    reason: .malformedManifest("invalid commit request"),
                    clearUploadSession: false,
                    clearWholeFileHash: false,
                    endpoint: endpoint
                )
                return
            }

            let commitResult = await self.transport.sendRawRequest(
                method: "POST",
                path: "\(ResumableImportDefaults.uploadsPath)/\(uploadID)/commit",
                headers: ["Content-Type": "application/json"],
                body: commitBody,
                endpoint: endpoint
            )

            guard await self.shouldContinueResumable(itemID: itemID, endpoint: endpoint) else {
                self.handleResumableInterrupted(itemID: itemID, sourceKey: sourceKey)
                return
            }

            if let issue = commitResult.issue {
                self.pauseResumableItemForRetry(itemID: itemID, reason: Self.transientReason(for: issue))
                return
            }
            guard let statusCode = commitResult.statusCode else {
                self.pauseResumableItemForRetry(itemID: itemID, reason: .transport("missing status"))
                return
            }
            if statusCode == 403, commitResult.loopbackRefused {
                self.pauseResumableItemForRetry(itemID: itemID, reason: .transport("loopback refused"))
                return
            }
            if statusCode == 401 || statusCode == 403 {
                await self.handleResumableAuthHold(itemID: itemID, statusCode: statusCode)
                return
            }

            if 200..<300 ~= statusCode {
                self.handleResumableSaveResponse(itemID: itemID, saveData: commitResult.data, endpoint: endpoint)
                return
            }

            let errBody = ResumableUploadErrorBody.parse(from: commitResult.data)
            if statusCode == 409, errBody?.reasonCode == TransferReasonCodes.incompleteUpload,
               let serverOffset = errBody?.nextOffset,
               serverOffset >= 0,
               serverOffset < totalBytes
            {
                incompleteRewinds += 1
                if incompleteRewinds > 3 {
                    self.pauseResumableItemForRetry(itemID: itemID, reason: .httpServerError(statusCode: 409))
                    return
                }
                resumable.remoteOffset = serverOffset
                resumable.phase = .sending
                self.persistResumableState(resumable, for: itemID, flushImmediately: true)
                continue
            }

            if statusCode == 409, errBody?.reasonCode == TransferReasonCodes.journalBusy {
                self.pauseResumableItemForRetry(itemID: itemID, reason: .httpServerError(statusCode: 409))
                return
            }

            if statusCode == 422, errBody?.reasonCode == TransferReasonCodes.wholeFileChecksumMismatch {
                // Journal deleted the partial upload. Clear remote session and cached hash so
                // owner-initiated retry hashes cleanly and starts a fresh resumable upload.
                self.failResumableItemToAttention(
                    itemID: itemID,
                    reason: .resumableFault(
                        journalReasonCode: TransferReasonCodes.wholeFileChecksumMismatch,
                        detail: errBody?.error,
                        retryable: true
                    ),
                    clearUploadSession: true,
                    clearWholeFileHash: true,
                    endpoint: endpoint
                )
                return
            }

            if statusCode == 404 {
                self.failResumableItemToAttention(
                    itemID: itemID,
                    reason: .resumableFault(
                        journalReasonCode: TransferReasonCodes.uploadNotFound,
                        detail: errBody?.error,
                        retryable: true
                    ),
                    clearUploadSession: true,
                    clearWholeFileHash: false,
                    endpoint: endpoint
                )
                return
            }

            if statusCode == 507 || errBody?.reasonCode == TransferReasonCodes.insufficientJournalSpace {
                self.failResumableItemToAttention(
                    itemID: itemID,
                    reason: .resumableFault(
                        journalReasonCode: TransferReasonCodes.insufficientJournalSpace,
                        detail: errBody?.error,
                        retryable: true
                    ),
                    clearUploadSession: false,
                    clearWholeFileHash: false,
                    endpoint: endpoint
                )
                return
            }

            if 500..<600 ~= statusCode {
                self.pauseResumableItemForRetry(itemID: itemID, reason: .httpServerError(statusCode: statusCode))
                return
            }

            self.failResumableWithClientError(
                itemID: itemID,
                statusCode: statusCode,
                data: commitResult.data,
                errBody: errBody,
                clearUploadSession: false,
                endpoint: endpoint
            )
            return
        }
    }

    // MARK: - Resumable Outcome Helpers

    private enum StatusResyncOutcome {
        case synced(nextOffset: Int64, chunkBytes: Int, expiresAt: String?)
        case handledAndStop
    }

    private func handleStatusResyncResponse(
        _ result: TransferHTTPResult,
        uploadID: String,
        itemID: UUID,
        totalBytes: Int64,
        defaultChunkBytes: Int,
        endpoint: TransferResolvedEndpoint
    ) async -> StatusResyncOutcome {
        if let issue = result.issue {
            self.pauseResumableItemForRetry(itemID: itemID, reason: Self.transientReason(for: issue))
            return .handledAndStop
        }
        guard let statusCode = result.statusCode else {
            self.pauseResumableItemForRetry(itemID: itemID, reason: .transport("missing status"))
            return .handledAndStop
        }
        if statusCode == 403, result.loopbackRefused {
            self.pauseResumableItemForRetry(itemID: itemID, reason: .transport("loopback refused"))
            return .handledAndStop
        }
        if statusCode == 401 || statusCode == 403 {
            await self.handleResumableAuthHold(itemID: itemID, statusCode: statusCode)
            return .handledAndStop
        }
        if statusCode == 200 {
            guard let status = ResumableUploadWireDecoder.decodeStatusResponse(from: result.data),
                  status.uploadID == uploadID, status.totalBytes == totalBytes
            else {
                self.pauseResumableItemForRetry(itemID: itemID, reason: .transport("invalid status response"))
                return .handledAndStop
            }
            return .synced(
                nextOffset: status.nextOffset,
                chunkBytes: ResumableImportDefaults.clampedChunkBytes(status.chunkBytes ?? defaultChunkBytes),
                expiresAt: status.expiresAt
            )
        }
        let errBody = ResumableUploadErrorBody.parse(from: result.data)
        if statusCode == 404 {
            self.failResumableItemToAttention(
                itemID: itemID,
                reason: .resumableFault(
                    journalReasonCode: TransferReasonCodes.uploadNotFound,
                    detail: errBody?.error,
                    retryable: true
                ),
                clearUploadSession: true,
                clearWholeFileHash: false,
                endpoint: endpoint
            )
            return .handledAndStop
        }
        if statusCode == 409, errBody?.reasonCode == TransferReasonCodes.journalBusy {
            self.pauseResumableItemForRetry(itemID: itemID, reason: .httpServerError(statusCode: 409))
            return .handledAndStop
        }
        if 500..<600 ~= statusCode {
            self.pauseResumableItemForRetry(itemID: itemID, reason: .httpServerError(statusCode: statusCode))
            return .handledAndStop
        }
        self.failResumableWithClientError(
            itemID: itemID,
            statusCode: statusCode,
            data: result.data,
            errBody: errBody,
            clearUploadSession: false,
            endpoint: endpoint
        )
        return .handledAndStop
    }

    private func shouldContinueResumable(
        itemID: UUID,
        endpoint: TransferResolvedEndpoint
    ) async -> Bool {
        guard !Task.isCancelled,
              !self.paused,
              !self.policyPaused,
              !self.droppedItemIDs.contains(itemID),
              let item = self.queuedItems[itemID],
              !self.authHeldSources.contains(item.manifest.sourceKey),
              self.inFlight.contains(itemID)
        else {
            return false
        }
        return await self.endpointResolver.isCurrent(endpoint)
    }

    private func handleResumableInterrupted(itemID: UUID, sourceKey: String) {
        if self.droppedItemIDs.remove(itemID) != nil || self.queuedItems[itemID] == nil {
            self.clearInFlight(itemID: itemID, sourceKey: sourceKey)
            self.notifyResumableProgressObserver(itemID: itemID, progress: nil)
            self.scheduleStatusUpdate(summary: "dropped")
            self.scheduleWork()
            return
        }
        self.pauseResumableWithoutBackoff(itemID: itemID, sourceKey: sourceKey, summary: "paused")
        self.scheduleWork()
    }

    private func finishDroppedOrMissing(itemID: UUID) {
        self.droppedItemIDs.remove(itemID)
        self.notifyResumableProgressObserver(itemID: itemID, progress: nil)
        if let item = self.queuedItems[itemID] {
            self.clearInFlight(itemID: itemID, sourceKey: item.manifest.sourceKey)
        } else {
            self.inFlight.remove(itemID)
            self.counters.inFlightCount = self.inFlight.count
        }
        self.scheduleWork()
    }

    private func persistResumableState(
        _ resumable: TransferResumableUploadState,
        for itemID: UUID,
        flushImmediately: Bool
    ) {
        guard let item = self.queuedItems[itemID] else { return }
        var manifest = item.manifest
        var saveState = manifest.saveThenStart ?? TransferSaveThenStartState(phase: .savePending)
        saveState.phase = .savePending
        saveState.resumable = resumable
        manifest.saveThenStart = saveState
        self.persistQueuedManifest(manifest, for: item)
        let progress = self.queuedItems[itemID].flatMap { self.resumableProgress(for: $0) }
        self.notifyResumableProgressObserver(itemID: itemID, progress: progress)
        if flushImmediately {
            self.lastEventSummary = resumable.phase.rawValue
            self.pendingStatusSnapshot = self.snapshot()
            Task { await self.flushStatusUpdate() }
        } else {
            self.scheduleStatusUpdate(summary: resumable.phase.rawValue)
        }
    }

    private func persistQueuedManifest(_ manifest: TransferManifest, for item: TransferStoredItem) {
        let itemID = item.manifest.itemID
        if let updated = try? self.spool.updateQueuedManifest(manifest, directoryURL: item.directoryURL) {
            self.queuedItems[itemID] = updated
        } else {
            self.queuedItems[itemID] = TransferStoredItem(manifest: manifest, directoryURL: item.directoryURL)
        }
    }

    private func noteResumableChunkBytes(bytes: Int, sourceKey: String) {
        guard bytes > 0 else { return }
        let now = self.clock.wallNow()
        self.updateSourceState(sourceKey) { state in
            state.byteWindow.noteDelivered(bytes: bytes, at: now)
        }
    }

    private func clearResumableStateAndFallbackToSave(itemID: UUID, sourceKey: String) {
        if let item = self.queuedItems[itemID] {
            var manifest = item.manifest.replacingNextAttemptAt(nil)
            manifest.saveThenStart = TransferSaveThenStartState(phase: .savePending)
            self.persistQueuedManifest(manifest, for: item)
        }
        self.resumableRetryAttemptByItemID.removeValue(forKey: itemID)
        self.notifyResumableProgressObserver(itemID: itemID, progress: nil)
        self.clearInFlight(itemID: itemID, sourceKey: sourceKey)
        self.scheduleStatusUpdate(summary: "queued")
        self.scheduleWork()
    }

    private func pauseResumableWithoutBackoff(itemID: UUID, sourceKey: String, summary: String) {
        self.clearInFlight(itemID: itemID, sourceKey: sourceKey)
        if let item = self.queuedItems[itemID],
           var saveState = item.manifest.saveThenStart,
           var resumable = saveState.resumable
        {
            resumable.phase = .paused
            saveState.resumable = resumable
            var manifest = item.manifest
            manifest.saveThenStart = saveState
            self.persistQueuedManifest(manifest, for: item)
            let progress = self.queuedItems[itemID].flatMap { self.resumableProgress(for: $0) }
            self.notifyResumableProgressObserver(itemID: itemID, progress: progress)
        }
        self.lastEventSummary = summary
        self.pendingStatusSnapshot = self.snapshot()
        Task { await self.flushStatusUpdate() }
    }

    private func pauseResumableItemForRetry(itemID: UUID, reason: TransferTransientReason) {
        guard let item = self.queuedItems[itemID] else {
            self.finishDroppedOrMissing(itemID: itemID)
            return
        }
        self.clearInFlight(itemID: itemID, sourceKey: item.manifest.sourceKey)
        let nextRetryAttempt = self.resumableRetryAttemptByItemID[itemID, default: 0] + 1
        self.resumableRetryAttemptByItemID[itemID] = nextRetryAttempt
        let delay = self.resumableRetryLadder.delay(itemID: itemID, attempt: nextRetryAttempt)
        let nextAttemptAt = self.clock.wallNow().addingTimeInterval(delay)
        var manifest = item.manifest.replacingNextAttemptAt(nextAttemptAt)
        if var saveState = manifest.saveThenStart, var resumable = saveState.resumable {
            resumable.phase = .paused
            saveState.resumable = resumable
            manifest.saveThenStart = saveState
        }
        self.persistQueuedManifest(manifest, for: item)
        let progress = self.queuedItems[itemID].flatMap { self.resumableProgress(for: $0) }
        self.notifyResumableProgressObserver(itemID: itemID, progress: progress)
        let retryDetail = reason.retryDetail
        self.noteError(sourceKey: item.manifest.sourceKey, detail: retryDetail)
        self.emit(
            item: self.queuedItems[itemID] ?? item,
            previousState: .dispatching,
            nextState: .queued,
            outcome: .retrying,
            attempt: nextRetryAttempt,
            detail: retryDetail
        )
        self.lastEventSummary = "paused"
        self.pendingStatusSnapshot = self.snapshot()
        Task { await self.flushStatusUpdate() }
        self.scheduleRetryTimer()
    }

    private func pauseUnstartedItemForTransientRetry(itemID: UUID, reason: TransferTransientReason) {
        guard let item = self.queuedItems[itemID] else {
            self.finishDroppedOrMissing(itemID: itemID)
            return
        }
        self.clearInFlight(itemID: itemID, sourceKey: item.manifest.sourceKey)
        let attempt = self.attemptCountByItemID[itemID, default: 1]
        let decision = self.pacer.delay(for: TransferPacerInput(
            itemID: itemID,
            source: item.manifest.sourceKey,
            attemptCount: attempt,
            lastOutcome: reason
        ))
        let nextAttemptAt = self.clock.wallNow().addingTimeInterval(decision.delay)
        let updatedManifest = item.manifest.replacingNextAttemptAt(nextAttemptAt)
        self.persistQueuedManifest(updatedManifest, for: item)
        let retryDetail = reason.retryDetail
        self.noteError(sourceKey: item.manifest.sourceKey, detail: retryDetail)
        self.emit(
            item: self.queuedItems[itemID] ?? item,
            previousState: .dispatching,
            nextState: .queued,
            outcome: .retrying,
            attempt: attempt,
            detail: retryDetail
        )
        self.scheduleStatusUpdate(summary: self.lastEventSummary)
        self.scheduleRetryTimer()
    }

    private func handleResumableAuthHold(itemID: UUID, statusCode: Int) async {
        guard let item = self.queuedItems[itemID] else {
            self.finishDroppedOrMissing(itemID: itemID)
            return
        }
        self.clearInFlight(itemID: itemID, sourceKey: item.manifest.sourceKey)
        if var saveState = item.manifest.saveThenStart, var resumable = saveState.resumable {
            resumable.phase = .paused
            saveState.resumable = resumable
            var manifest = item.manifest
            manifest.saveThenStart = saveState
            self.persistQueuedManifest(manifest, for: item)
            let progress = self.queuedItems[itemID].flatMap { self.resumableProgress(for: $0) }
            self.notifyResumableProgressObserver(itemID: itemID, progress: progress)
        }
        let currentAttempts = self.attemptCountByItemID[itemID, default: 0]
        if currentAttempts > 1 {
            self.attemptCountByItemID[itemID] = currentAttempts - 1
        } else {
            self.attemptCountByItemID.removeValue(forKey: itemID)
            self.firstAttemptAtByItemID.removeValue(forKey: itemID)
        }
        self.authHeldSources.insert(item.manifest.sourceKey)
        if self.sourceStates[item.manifest.sourceKey] == nil {
            self.sourceStates[item.manifest.sourceKey] = TransferSourceRuntimeState()
        }
        self.emit(
            item: self.queuedItems[itemID] ?? item,
            previousState: .dispatching,
            nextState: .held,
            outcome: .held,
            attempt: self.attemptCountByItemID[itemID, default: 0],
            detail: "http \(statusCode)"
        )
        self.lastEventSummary = "held"
        self.pendingStatusSnapshot = self.snapshot()
        await self.flushStatusUpdate()
        self.scheduleWork()
    }

    private func failResumableWithClientError(
        itemID: UUID,
        statusCode: Int,
        data: Data,
        errBody: ResumableUploadErrorBody?,
        clearUploadSession: Bool,
        endpoint: TransferResolvedEndpoint
    ) {
        let code = TransferHTTPClassifier.storedJournalReasonCode(errBody?.reasonCode)
        let reasonCodeDetail = code.map { "reason_code=\($0)" }
        let sentence = errBody?.error.flatMap { $0.isEmpty ? nil : $0 }
        let plainText = errBody == nil ? String(data: data, encoding: .utf8) : nil
        let detail = sentence ?? reasonCodeDetail ?? plainText
        self.failResumableItemToAttention(
            itemID: itemID,
            reason: .httpClientError(statusCode: statusCode, detail: detail, journalReasonCode: code),
            clearUploadSession: clearUploadSession,
            clearWholeFileHash: false,
            endpoint: endpoint
        )
    }

    private func failResumableItemToAttention(
        itemID: UUID,
        reason: TransferAttentionReason,
        clearUploadSession: Bool,
        clearWholeFileHash: Bool,
        endpoint: TransferResolvedEndpoint?
    ) {
        guard var item = self.queuedItems[itemID] else {
            self.finishDroppedOrMissing(itemID: itemID)
            return
        }
        self.clearInFlight(itemID: itemID, sourceKey: item.manifest.sourceKey)
        self.resumableRetryAttemptByItemID.removeValue(forKey: itemID)
        self.notifyResumableProgressObserver(itemID: itemID, progress: nil)
        if var saveState = item.manifest.saveThenStart, var resumable = saveState.resumable {
            if clearUploadSession {
                resumable.uploadID = nil
                resumable.remoteOffset = 0
                resumable.expiresAt = nil
            }
            if clearWholeFileHash {
                resumable.wholeFileSHA256 = nil
            }
            resumable.phase = .paused
            saveState.resumable = resumable
            var manifest = item.manifest
            manifest.saveThenStart = saveState
            self.persistQueuedManifest(manifest, for: item)
            item = self.queuedItems[itemID] ?? item
        }
        let detail = self.shortDetail(for: reason)
        self.noteError(sourceKey: item.manifest.sourceKey, detail: detail)
        let savedInstanceID = endpoint?.dispatchOwner?.journalInstanceID
            ?? item.manifest.saveThenStart?.savedInstanceID
        self.moveToAttention(
            item: item,
            reason: reason,
            detail: detail,
            refusedUnder: nil,
            savedInstanceID: savedInstanceID
        )
        self.lastEventSummary = AppStrings.ios_transfer_needsattention()
        self.pendingStatusSnapshot = self.snapshot()
        Task { await self.flushStatusUpdate() }
        self.scheduleWork()
    }

    private func handleResumableSaveResponse(
        itemID: UUID,
        saveData: Data,
        endpoint: TransferResolvedEndpoint
    ) {
        switch TransferHTTPClassifier.classifySaveSuccessData(saveData) {
        case .continueWithStart(var saveState):
            guard let item = self.queuedItems[itemID] else {
                self.finishDroppedOrMissing(itemID: itemID)
                return
            }
            self.clearInFlight(itemID: itemID, sourceKey: item.manifest.sourceKey)
            self.resumableRetryAttemptByItemID.removeValue(forKey: itemID)
            self.notifyResumableProgressObserver(itemID: itemID, progress: nil)
            saveState.savedInstanceID = endpoint.dispatchOwner?.journalInstanceID ?? saveState.savedInstanceID
            saveState.resumable = nil
            var manifest = item.manifest.replacingNextAttemptAt(nil)
            manifest.saveThenStart = saveState
            self.spool.removeBodyCache(for: item)
            self.persistQueuedManifest(manifest, for: item)
            self.emit(
                item: self.queuedItems[itemID] ?? item,
                previousState: .dispatching,
                nextState: .queued,
                outcome: .queued,
                attempt: self.attemptCountByItemID[itemID, default: 0],
                detail: "queued"
            )
            self.scheduleStatusUpdate(summary: "queued")
            self.scheduleWork()

        case .terminalSuccess(let successKind):
            self.completeResumableDelivery(itemID: itemID, successKind: successKind, endpoint: endpoint)

        case .terminalAttention(let reason):
            self.failResumableItemToAttention(
                itemID: itemID,
                reason: reason,
                clearUploadSession: true,
                clearWholeFileHash: false,
                endpoint: endpoint
            )

        case .transientRetry(let reason):
            self.pauseResumableItemForRetry(itemID: itemID, reason: reason)

        case .authHold(let statusCode):
            Task { await self.handleResumableAuthHold(itemID: itemID, statusCode: statusCode) }
        }
    }

    private func completeResumableDelivery(
        itemID: UUID,
        successKind: TransferSuccessKind,
        endpoint: TransferResolvedEndpoint
    ) {
        guard let item = self.queuedItems[itemID] else {
            self.finishDroppedOrMissing(itemID: itemID)
            return
        }
        self.clearInFlight(itemID: itemID, sourceKey: item.manifest.sourceKey)
        self.resumableRetryAttemptByItemID.removeValue(forKey: itemID)
        self.notifyResumableProgressObserver(itemID: itemID, progress: nil)
        self.queuedItems.removeValue(forKey: itemID)
        self.counters.queuedCount -= 1
        self.counters.deliveredCount += 1
        let deliveredAt = self.clock.wallNow()
        // Wire bytes were already counted on each confirmed chunk ACK.
        self.noteDelivered(bytes: 0, sourceKey: item.manifest.sourceKey, at: deliveredAt)
        self.updateSourceState(item.manifest.sourceKey) { state in
            state.counters.queuedCount -= 1
            state.counters.deliveredCount += 1
        }
        try? self.spool.removeCommittedItem(item)
        self.emit(
            item: item,
            previousState: .dispatching,
            nextState: .delivered,
            outcome: .delivered,
            attempt: self.attemptCountByItemID[itemID, default: 0],
            detail: "delivered"
        )
        self.firstAttemptAtByItemID.removeValue(forKey: itemID)
        var deliveredManifest = item.manifest
        if let instanceID = endpoint.dispatchOwner?.journalInstanceID, !instanceID.isEmpty {
            var saveState = deliveredManifest.saveThenStart ?? TransferSaveThenStartState(phase: .savePending)
            if saveState.savedInstanceID == nil {
                saveState.savedInstanceID = instanceID
                deliveredManifest.saveThenStart = saveState
            }
        }
        self.launchDeliveredHook(
            for: deliveredManifest,
            successKind: successKind,
            attempt: self.attemptCountByItemID[itemID, default: 0]
        )
        self.scheduleStatusUpdate(summary: "delivered")
        self.scheduleWork()
    }

    private static func transientReason(for issue: TransferTransportIssue) -> TransferTransientReason {
        switch issue {
        case .timeout:
            return .timeout
        case .cancelled:
            return .cancelled
        case .connectionLost(let detail), .transport(let detail):
            return .transport(detail)
        }
    }
}

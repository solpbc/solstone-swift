// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum ObserverAudioTransferSource {
    static let omi = "omi-audio"
    static let watch = "watch-audio"
}

actor ObserverIngestTransferEndpointResolver: TransferEndpointResolver {
    private var activeLocalPort: Int?

    func update(activeLocalPort: Int?) {
        self.activeLocalPort = activeLocalPort
    }

    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        guard descriptor.destinationKind == .observerIngest else {
            return .unavailable("unsupported endpoint")
        }
        guard let port = self.activeLocalPort else {
            return .unavailable("waiting")
        }
        guard let baseURL = ObserverServerURL.url(localPort: port, path: "/") else {
            return .unavailable("invalid endpoint")
        }
        return .available(TransferResolvedEndpoint(baseURL: baseURL, port: port))
    }
}

nonisolated enum ObserverAudioTransferAuthProvider {
    static func make(
        omiRegistration: ObserverRegistration,
        watchRegistration: ObserverRegistration
    ) -> TransferAuthProvider {
        { manifest in
            switch manifest.sourceKey {
            case ObserverAudioTransferSource.omi:
                return try await omiRegistration.ensureRegistered()
            case ObserverAudioTransferSource.watch:
                return try await watchRegistration.ensureRegistered()
            default:
                throw ObserverAudioTransferError.unsupportedSource(manifest.sourceKey)
            }
        }
    }
}

nonisolated enum ObserverAudioTransferError: Error, Equatable, Sendable {
    case unsupportedSource(String)
    case missingObserverIngestMetadata
    case missingSessionID
}

nonisolated enum ObserverAudioTransferDiagnostics {
    static func makeSink(diagnosticLog: DiagnosticLog) -> TransferDiagnosticSink {
        { event in
            Task { @MainActor in
                diagnosticLog.append(
                    category: .upload,
                    severity: Self.severity(for: event.outcome),
                    message: Self.message(for: event.outcome),
                    detail: Self.detail(for: event)
                )
            }
        }
    }

    private static func severity(for outcome: TransferDiagnosticOutcomeSummary) -> DiagnosticSeverity {
        switch outcome {
        case .needsAttention, .hookFailed, .salvaged:
            return .warning
        case .queued, .delivered, .retrying, .held, .dropped, .paused, .resumed:
            return .info
        }
    }

    private static func message(for outcome: TransferDiagnosticOutcomeSummary) -> String {
        switch outcome {
        case .delivered:
            return "synced to your journal"
        case .needsAttention, .hookFailed, .salvaged:
            return "needs attention"
        case .queued, .retrying, .held, .dropped, .paused, .resumed:
            return "waiting"
        }
    }

    private static func detail(for event: TransferDiagnosticEvent) -> String {
        [
            "source=\(event.source)",
            "item=\(event.itemID.uuidString)",
            "from=\(event.previousState.rawValue)",
            "to=\(event.nextState.rawValue)",
            "attempt=\(event.attempt)",
            "detail=\(event.shortDetail)",
        ].joined(separator: " ")
    }
}

@MainActor
final class ObserverAudioTransferEnqueuer {
    private let engine: TransferEngine

    init(engine: TransferEngine) {
        self.engine = engine
    }

    @discardableResult
    func enqueueOmiChunkMovingFile(chunkURL: URL, sidecar: ChunkSidecar) async throws -> UUID {
        let manifest = Self.makeOmiManifest(sidecar: sidecar)
        return try await self.engine.enqueue(manifest: manifest, payloadFileURLs: ["audio": chunkURL])
    }

    @discardableResult
    func enqueueWatchSegment(
        manifest watchManifest: WatchSegmentManifest,
        audioData: Data?,
        locationData: Data?
    ) async throws -> UUID {
        let manifest = Self.makeWatchManifest(
            watchManifest: watchManifest,
            hasAudio: audioData != nil,
            hasLocation: locationData != nil
        )
        var payloads: [String: Data] = [:]
        if let audioData {
            payloads["audio"] = audioData
        }
        if let locationData {
            payloads["location"] = locationData
        }
        return try await self.engine.enqueue(manifest: manifest, payloads: payloads)
    }

    @discardableResult
    func enqueueWatchChunkMovingFiles(
        audioURL: URL,
        locationURL: URL?,
        sidecar: ChunkSidecar
    ) async throws -> UUID {
        let manifest = Self.makeWatchManifest(
            sidecar: sidecar,
            hasLocation: locationURL != nil
        )
        var payloadFileURLs: [String: URL] = ["audio": audioURL]
        if let locationURL {
            payloadFileURLs["location"] = locationURL
        }
        return try await self.engine.enqueue(manifest: manifest, payloadFileURLs: payloadFileURLs)
    }

    nonisolated static func makeOmiManifest(
        itemID: UUID = UUID(),
        sidecar: ChunkSidecar
    ) -> TransferManifest {
        self.makeManifest(
            itemID: itemID,
            source: ObserverAudioTransferSource.omi,
            platform: "ios",
            createdAt: sidecar.startedAt,
            segment: sidecar.segment,
            day: sidecar.day,
            startedAt: sidecar.startedAt,
            durationS: sidecar.durationS,
            sources: ["audio"],
            chunkIndex: sidecar.chunkIndex,
            sessionID: sidecar.sessionID,
            modeRawValue: sidecar.mode.rawValue,
            segmentID: nil,
            payloadParts: [Self.audioPart()]
        )
    }

    nonisolated static func makeWatchManifest(
        itemID: UUID = UUID(),
        watchManifest: WatchSegmentManifest,
        hasAudio: Bool,
        hasLocation: Bool
    ) -> TransferManifest {
        var sources: [String] = []
        var parts: [TransferPayloadPartDescriptor] = []
        if hasAudio {
            sources.append("audio")
            parts.append(Self.audioPart())
        }
        if hasLocation {
            sources.append("location")
            parts.append(Self.locationPart())
        }
        return self.makeManifest(
            itemID: itemID,
            source: ObserverAudioTransferSource.watch,
            platform: "watchos",
            createdAt: watchManifest.startedAt,
            segment: watchManifest.segment,
            day: watchManifest.day,
            startedAt: watchManifest.startedAt,
            durationS: watchManifest.duration,
            sources: sources,
            chunkIndex: 0,
            sessionID: watchManifest.id,
            modeRawValue: ObserverMode.meeting.rawValue,
            segmentID: watchManifest.id,
            payloadParts: parts
        )
    }

    nonisolated static func makeWatchManifest(
        itemID: UUID = UUID(),
        sidecar: ChunkSidecar,
        hasLocation: Bool
    ) -> TransferManifest {
        var sources = ["audio"]
        var parts = [Self.audioPart()]
        if hasLocation {
            sources.append("location")
            parts.append(Self.locationPart())
        }
        return self.makeManifest(
            itemID: itemID,
            source: ObserverAudioTransferSource.watch,
            platform: "watchos",
            createdAt: sidecar.startedAt,
            segment: sidecar.segment,
            day: sidecar.day,
            startedAt: sidecar.startedAt,
            durationS: sidecar.durationS,
            sources: sources,
            chunkIndex: sidecar.chunkIndex,
            sessionID: sidecar.sessionID,
            modeRawValue: sidecar.mode.rawValue,
            segmentID: sidecar.sessionID,
            payloadParts: parts
        )
    }

    nonisolated static func makeManifest(
        itemID: UUID,
        source: String,
        platform: String,
        createdAt: Date,
        segment: String,
        day: String,
        startedAt: Date,
        durationS: TimeInterval,
        sources: [String],
        chunkIndex: Int?,
        sessionID: UUID?,
        modeRawValue: String?,
        segmentID: UUID?,
        payloadParts: [TransferPayloadPartDescriptor]
    ) -> TransferManifest {
        TransferManifest(
            itemID: itemID,
            source: source,
            createdAt: createdAt,
            priority: TransferPriorityInputs(basePriority: .normal, sourceKey: source),
            payloadParts: payloadParts,
            endpoint: TransferEndpointDescriptor(
                destinationKind: .observerIngest,
                path: "/app/observer/ingest",
                requiresAuth: true
            ),
            observerIngest: TransferObserverIngestMetadata(
                platform: platform,
                segment: segment,
                day: day,
                startedAt: startedAt,
                durationS: durationS,
                sources: sources,
                chunkIndex: chunkIndex,
                sessionID: sessionID,
                modeRawValue: modeRawValue,
                segmentID: segmentID
            ),
            meta: .object(["source": .string(source)]),
            appVersion: AppVersion.shortVersion
        )
    }

    nonisolated static func audioPart() -> TransferPayloadPartDescriptor {
        TransferPayloadPartDescriptor(
            partID: "audio",
            kind: .audio,
            relativePath: "audio.m4a",
            filename: "audio.m4a",
            contentType: "audio/mp4"
        )
    }

    nonisolated static func locationPart() -> TransferPayloadPartDescriptor {
        TransferPayloadPartDescriptor(
            partID: "location",
            kind: .location,
            relativePath: "location.jsonl",
            filename: "location.jsonl",
            contentType: "application/x-ndjson"
        )
    }
}

nonisolated enum ObserverAudioTransferSnapshotMapper {
    static func sourceResult(
        snapshots: [TransferItemSnapshot],
        source: OnThisPhoneAudioSource,
        engine: TransferEngine
    ) async -> OnThisPhoneSourceResult {
        let items = await self.items(snapshots: snapshots, source: source, engine: engine)
        return .loaded(items: OnThisPhoneItemSort.newestFirst(items))
    }

    static func items(
        snapshots: [TransferItemSnapshot],
        source: OnThisPhoneAudioSource,
        engine: TransferEngine
    ) async -> [OnThisPhoneItem] {
        var items: [OnThisPhoneItem] = []
        for snapshot in snapshots {
            let manifest = snapshot.manifest
            let ingest = manifest.observerIngest
            let audioPart = manifest.payloadParts.first { $0.kind == .audio }
            let primaryPart = audioPart ?? manifest.payloadParts.first
            let rawURL: URL?
            if let audioPart {
                rawURL = await engine.payloadFileURL(itemID: snapshot.itemID, partID: audioPart.partID)
            } else {
                rawURL = nil
            }
            let attention = manifest.attention
            let failureReason = attention.map { info in
                info.reason == info.shortDetail ? info.reason : "\(info.reason): \(info.shortDetail)"
            }
            items.append(OnThisPhoneItem(
                id: OnThisPhoneItemID.transferIDString(itemID: snapshot.itemID, source: source),
                sourceKind: .audio,
                sendState: self.sendState(for: snapshot.state),
                contentType: primaryPart?.contentType,
                filename: primaryPart?.filename,
                bytes: self.byteCount(manifest.payloadParts),
                originApp: nil,
                basis: nil,
                itemTime: ingest?.startedAt ?? manifest.createdAt,
                targetJournal: nil,
                stream: nil,
                day: ingest?.day,
                segment: ingest?.segment,
                deliveredAt: nil,
                rawFileURL: rawURL,
                audioDurationS: ingest?.durationS,
                failureReason: failureReason,
                failureAttemptCount: snapshot.attempts > 0 ? snapshot.attempts : nil,
                sourceLabel: source.sourceLabel,
                retryAvailable: snapshot.state == .attention,
                lastAttemptAt: attention?.movedAt
            ))
        }
        return items
    }

    private static func sendState(for state: TransferRuntimeState) -> OnThisPhoneSendState {
        switch state {
        case .queued, .held, .paused, .salvaged:
            return .savedOnThisPhone
        case .dispatching:
            return .sending
        case .attention:
            return .needsAttention
        case .delivered:
            return .inYourJournal
        case .dropped, .staged:
            return .savedOnThisPhone
        }
    }

    private static func byteCount(_ parts: [TransferPayloadPartDescriptor]) -> Int64? {
        let values = parts.reduce(into: [Int]()) { result, part in
            if let byteCount = part.byteCount {
                result.append(byteCount)
            }
        }
        guard !values.isEmpty else { return nil }
        return Int64(values.reduce(0, +))
    }
}

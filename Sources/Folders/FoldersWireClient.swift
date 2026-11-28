// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

/// Journal operations required by the folder source engine (protocol v3).
nonisolated protocol FoldersTransport: Sendable {
    func checkCapability() async -> Bool?
    func fetchFacets() async -> (FolderFacetsAvailability, [FolderFacet])
    func fetchSupported() async -> FolderSupportedList?
    func fetchEstimate(folderID: String, items: [FolderEstimateItem]) async -> FolderBackfillEstimate?
    func uploadSegment(
        _ delivery: FolderSegmentDelivery,
        supported: FolderSupportedList,
        canSend: @escaping @Sendable () async -> Bool,
        readContent: @escaping @Sendable (FolderStagedContentFile) -> Data?
    ) async -> FolderDeliveryOutcome
}

/// Pure protocol-v3 wire parsing & multipart payload builder for the folder source.
nonisolated enum FoldersWire {
    enum BuildError: Error {
        case refusedContent([String])
    }

    /// Parse `GET /app/devices/ingest/folder/facets`.
    static func parseFacets(_ data: Data) -> [FolderFacet]? {
        struct WireFacet: Decodable {
            var name: String
            var title: String?
            var color: String?
            var muted: Bool?
        }
        struct WireResponse: Decodable {
            var facets: [WireFacet]
        }
        guard let decoded = try? JSONDecoder().decode(WireResponse.self, from: data) else {
            return nil
        }
        let filtered = decoded.facets.compactMap { item -> FolderFacet? in
            guard item.muted != true else { return nil }
            let trimmedName = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return nil }
            let rawTitle = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return FolderFacet(
                name: trimmedName,
                title: rawTitle.isEmpty ? trimmedName : rawTitle,
                color: item.color
            )
        }
        return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Parse `GET /app/devices/ingest/folder/supported`.
    static func parseSupportedList(_ data: Data) -> FolderSupportedList? {
        struct WireThresholds: Decodable {
            var structuredProseMinWords: Int?
            var structuredProseMinHeadingLevels: Int?
            var longProseMinWords: Int?

            enum CodingKeys: String, CodingKey {
                case structuredProseMinWords = "structured_prose_min_words"
                case structuredProseMinHeadingLevels = "structured_prose_min_heading_levels"
                case longProseMinWords = "long_prose_min_words"
            }
        }
        struct WireKind: Decodable {
            var extensions: [String]?
            var convertToPNGOnDevice: [String]?
            var thresholds: WireThresholds?

            enum CodingKeys: String, CodingKey {
                case extensions
                case convertToPNGOnDevice = "convert_to_png_on_device"
                case thresholds
            }
        }
        struct WireKinds: Decodable {
            var notes: WireKind?
            var documents: WireKind?
            var transcripts: WireKind?
            var screenshots: WireKind?
            var photos: WireKind?
        }
        struct WireSupported: Decodable {
            var rulesetVersion: Int?
            var maxFileBytes: UInt64?
            var maxNoteBytes: UInt64?
            var maxImagePixels: UInt64?
            var documentRevisionCooldownSeconds: Int64?
            var kinds: WireKinds?

            enum CodingKeys: String, CodingKey {
                case rulesetVersion = "ruleset_version"
                case maxFileBytes = "max_file_bytes"
                case maxNoteBytes = "max_note_bytes"
                case maxImagePixels = "max_image_pixels"
                case documentRevisionCooldownSeconds = "document_revision_cooldown_seconds"
                case kinds
            }
        }

        guard let wire = try? JSONDecoder().decode(WireSupported.self, from: data) else {
            return nil
        }

        func norm(_ raw: [String]?) -> Set<String> {
            Set((raw ?? []).compactMap { entry -> String? in
                var s = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                while s.hasPrefix(".") { s.removeFirst() }
                return s.isEmpty ? nil : s
            })
        }

        var list = FolderSupportedList.default
        let notes = norm(wire.kinds?.notes?.extensions)
        if !notes.isEmpty {
            list.noteExtensions = notes
        }
        let docs = norm(wire.kinds?.documents?.extensions).subtracting(list.noteExtensions)
        if !docs.isEmpty {
            list.documentExtensions = docs
        }
        if let th = wire.kinds?.documents?.thresholds {
            if let w = th.structuredProseMinWords { list.noteStructuredWords = w }
            if let h = th.structuredProseMinHeadingLevels { list.noteHeadingLevels = h }
            if let w = th.longProseMinWords { list.noteLongWords = w }
        }
        if let extensions = wire.kinds?.transcripts?.extensions {
            list.transcriptExtensions = norm(extensions)
        }

        let acceptedImages = norm(wire.kinds?.screenshots?.extensions)
            .union(norm(wire.kinds?.photos?.extensions))
        if !acceptedImages.isEmpty {
            list.acceptedImageExtensions = acceptedImages
        }
        let convertible = norm(wire.kinds?.screenshots?.convertToPNGOnDevice)
            .union(norm(wire.kinds?.photos?.convertToPNGOnDevice))
        if !convertible.isEmpty {
            list.convertibleImageExtensions = convertible
        }
        if let v = wire.rulesetVersion { list.rulesetVersion = v }
        if let max = wire.maxFileBytes { list.maxContentBytes = max }
        if let max = wire.maxNoteBytes { list.maxNoteBytes = max }
        if let px = wire.maxImagePixels { list.maxImagePixels = px }
        if let secs = wire.documentRevisionCooldownSeconds, secs > 0 {
            list.documentRevisionCooldownMs = secs * 1_000
        }
        list.fromJournal = true
        return list
    }

    /// Parse `POST /app/devices/ingest/folder/estimate`.
    static func parseEstimate(_ data: Data) -> FolderBackfillEstimate? {
        struct WireEstimate: Decodable {
            var segments: Int
            var days: Int
            var thoughts: Int
            var alreadyInJournal: Int?

            enum CodingKeys: String, CodingKey {
                case segments
                case days
                case thoughts
                case alreadyInJournal = "already_in_journal"
            }
        }
        guard let wire = try? JSONDecoder().decode(WireEstimate.self, from: data) else {
            return nil
        }
        return FolderBackfillEstimate(
            segments: wire.segments,
            days: wire.days,
            thoughts: wire.thoughts,
            alreadyInJournal: wire.alreadyInJournal ?? 0,
            fromJournal: true
        )
    }

    /// Map an HTTP reply from `POST /app/devices/ingest` (`source = "folder"`) onto a `FolderDeliveryOutcome`.
    static func classifyUploadReply(statusCode: Int, body: Data) -> FolderDeliveryOutcome {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let refusedPaths = Self.extractRefusedPaths(from: json)

        if statusCode == 200 {
            guard let json, let status = json["status"] as? String else {
                return .hold
            }
            if status == "ok" || status == "duplicate" {
                if !refusedPaths.isEmpty {
                    return .deliveredWithRefusedContent(refusedPaths)
                }
                return .delivered
            }
            return .hold
        }

        let reasonCode = json?["reason_code"] as? String
        switch reasonCode {
        case "segment_removed", "duplicate", "collision":
            return .delivered
        case "folder_file_invalid":
            return .allFilesRefused(refusedPaths)
        case "folder_invalid":
            return .invalidPermanent
        case "folder_ahead", "journal_read_failed":
            return .hold
        default:
            return .hold
        }
    }

    static func extractRefusedPaths(from json: [String: Any]?) -> [String] {
        guard let refused = json?["refused_files"] as? [[String: Any]] else {
            return []
        }
        var seen = Set<String>()
        var out: [String] = []
        for entry in refused {
            if let path = entry["path"] as? String, !path.isEmpty, seen.insert(path).inserted {
                out.append(path)
            }
        }
        return out
    }

    /// Build a complete protocol-v3 multipart body (`envelope`, `folder_<sha256>.jsonl`,
    /// and companion parts `c_01.<ext>`…`c_63.<ext>`).
    static func buildMultipartBody(
        delivery: FolderSegmentDelivery,
        supported: FolderSupportedList,
        boundary: String,
        readContent: (FolderStagedContentFile) -> Data?
    ) throws -> (body: Data, activityFileName: String, partNames: [String]) {
        let stagedByEventID = Dictionary(uniqueKeysWithValues: delivery.contentFiles.map { ($0.eventID, $0) })

        var localRefusals: [String] = []
        var companionParts: [ObserverIngestMultipartPart] = []
        var partBindingByEventID: [String: (partName: String, hash: String)] = [:]

        for event in delivery.events {
            guard event.delivery == .content,
                  event.verb != .removed,
                  let staged = stagedByEventID[event.id],
                  companionParts.count < FolderConstants.maxUploadContentParts
            else {
                continue
            }

            guard let liveBytes = readContent(staged) else { throw CocoaError(.fileReadUnknown) }
            let rawBytes: Data?
            if staged.kind == .note, let noteText = staged.notePayload {
                rawBytes = Data(noteText.utf8)
            } else {
                if let expected = staged.contentHash, folderSHA256Hex(liveBytes) != expected {
                    throw CocoaError(.fileReadUnknown)
                }
                rawBytes = liveBytes
            }
            guard var payloadBytes = rawBytes,
                  UInt64(payloadBytes.count) <= supported.maxContentBytes
            else {
                localRefusals.append(event.relPath)
                continue
            }

            var ext = (staged.extensionLower ?? "bin").lowercased()
            if staged.kind == .screenshot || staged.kind == .photo {
                if staged.needsImageConvert || supported.convertibleImageExtensions.contains(ext) {
                    guard let png = FoldersImageSupport.convertToPNG(
                        payloadBytes,
                        maxPixels: supported.maxImagePixels,
                        maxBytes: supported.maxContentBytes
                    ) else {
                        localRefusals.append(event.relPath)
                        continue
                    }
                    payloadBytes = png
                    ext = "png"
                } else {
                    if let px = FoldersImageSupport.pixelCount(in: payloadBytes),
                       px > supported.maxImagePixels
                    {
                        localRefusals.append(event.relPath)
                        continue
                    }
                }
            }

            let safeExt = Self.sanitizedPartExtension(ext)
            let partIndex = companionParts.count + 1
            let partName = String(format: "c_%02d.%@", partIndex, safeExt)
            let partHash = folderSHA256Hex(payloadBytes)
            companionParts.append(ObserverIngestMultipartPart(
                filename: partName,
                contentType: Self.contentType(forExtension: safeExt),
                data: payloadBytes
            ))
            partBindingByEventID[event.id] = (partName, partHash)
        }

        if !localRefusals.isEmpty { throw BuildError.refusedContent(localRefusals) }

        // Build UTF-8 LF-terminated activity JSONL lines.
        var jsonlData = Data()
        for event in delivery.events {
            var line: [String: Any] = [
                "v": 1,
                "event": event.verb.wireEvent,
                "path": event.relPath,
                "at": FolderStamp.formatRFC3339(ms: event.eventMs, offsetSeconds: event.offsetSeconds),
                "observed_at": FolderStamp.formatRFC3339(ms: event.observedMs, offsetSeconds: event.offsetSeconds),
                "size": event.metadata.sizeBytes,
                "modified_at": FolderStamp.formatRFC3339(ms: event.metadata.modifiedMs, offsetSeconds: event.offsetSeconds),
            ]
            if event.verb == .renamed, let prev = event.previousPath {
                line["previous_path"] = prev
            }
            if let fileType = event.metadata.extensionLower, !fileType.isEmpty, fileType.count <= 64 {
                line["file_type"] = fileType
            }
            if let createdMs = event.metadata.createdMs {
                line["created_at"] = FolderStamp.formatRFC3339(ms: createdMs, offsetSeconds: event.offsetSeconds)
            }
            if let binding = partBindingByEventID[event.id] {
                line["part"] = binding.partName
                line["content_hash"] = binding.hash
                if let hint = event.kind.kindHint {
                    line["kind_hint"] = hint
                }
            }
            if let platform = Self.platformObject(event.metadata) {
                line["platform"] = platform
            }
            let encodedLine = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
            jsonlData.append(encodedLine)
            jsonlData.append(0x0A)
        }

        let activityHash = folderSHA256Hex(jsonlData)
        let activityFileName = "folder_\(activityHash).jsonl"
        let activityPart = ObserverIngestMultipartPart(
            filename: activityFileName,
            contentType: "application/x-ndjson",
            data: jsonlData
        )
        let allParts = [activityPart] + companionParts

        var folderMeta: [String: Any] = [
            "v": 1,
            "id": delivery.folderID,
            "name": delivery.folderName,
            "kinds": delivery.kinds.enabledNames,
        ]
        if let facet = delivery.facet {
            folderMeta["facet"] = facet
        } else {
            folderMeta["facet"] = NSNull()
        }

        let envelope: [String: Any] = [
            "day": delivery.window.day,
            "segment": delivery.window.segment,
            "source": FolderConstants.wireSource,
            "files": allParts.map { ["submitted": $0.filename] },
            "meta": ["folder": folderMeta],
        ]
        let envelopeData = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])

        var body = Data()
        body.append(ObserverIngestMultipartBody.multipartField(
            named: "envelope",
            value: String(decoding: envelopeData, as: UTF8.self),
            boundary: boundary
        ))
        for part in allParts {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(ObserverServerURL.filesFieldName)\"; filename=\"\(part.filename)\"\r\n".utf8))
            body.append(Data("Content-Type: \(part.contentType)\r\n\r\n".utf8))
            body.append(part.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return (body, activityFileName, allParts.map(\.filename))
    }

    private static func platformObject(_ meta: FolderPlatformMetadata) -> [String: Any]? {
        var obj: [String: Any] = [:]
        if let v = meta.originURL, !v.isEmpty { obj["origin_url"] = v }
        if let v = meta.referrerURL, !v.isEmpty { obj["referrer_url"] = v }
        if let v = meta.downloadedBy, !v.isEmpty { obj["downloaded_by"] = v }
        if let v = meta.sourceApp, !v.isEmpty { obj["source_app"] = v }
        if let v = meta.whereFroms, !v.isEmpty { obj["where_froms"] = Array(v.prefix(16)) }
        if let v = meta.quarantine, !v.isEmpty { obj["quarantine"] = v }
        if let v = meta.xattrs, !v.isEmpty { obj["xattrs"] = v }
        return obj.isEmpty ? nil : obj
    }

    private static func sanitizedPartExtension(_ ext: String) -> String {
        let filtered = ext.unicodeScalars.filter {
            ($0.value >= 0x30 && $0.value <= 0x39)
                || ($0.value >= 0x61 && $0.value <= 0x7A)
        }
        let cleaned = String(filtered.map(Character.init)).prefix(12)
        return cleaned.isEmpty ? "bin" : String(cleaned)
    }

    private static func contentType(forExtension ext: String) -> String {
        switch ext {
        case "md", "markdown": "text/markdown"
        case "txt", "log": "text/plain"
        case "pdf": "application/pdf"
        case "vtt": "text/vtt"
        case "srt": "application/x-subrip"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "json": "application/json"
        case "csv": "text/csv"
        case "tsv": "text/tab-separated-values"
        case "html": "text/html"
        default: "application/octet-stream"
        }
    }
}

/// Concrete authenticated loopback client over `AuthenticatedHomeClient`,
/// carrying `X-Solstone-Protocol-Version: 3` and enforcing pairing admission.
nonisolated final class AuthenticatedFoldersClient: FoldersTransport, @unchecked Sendable {
    private let homeClient: AuthenticatedHomeClient
    private let localPortProvider: @Sendable () async -> Int?
    private let isPairedProvider: @Sendable () async -> Bool
    private let admitSend: @Sendable () async -> Bool
    private let pairingGeneration: @Sendable () async -> UInt64
    private let sessionFactory: @Sendable (Duration) -> URLSession

    init(
        homeClient: AuthenticatedHomeClient = AuthenticatedHomeClient(),
        localPortProvider: @escaping @Sendable () async -> Int?,
        isPairedProvider: @escaping @Sendable () async -> Bool,
        admitSend: @escaping @Sendable () async -> Bool,
        pairingGeneration: @escaping @Sendable () async -> UInt64,
        sessionFactory: @escaping @Sendable (Duration) -> URLSession = AuthenticatedHomeClient.defaultSessionFactory
    ) {
        self.homeClient = homeClient
        self.localPortProvider = localPortProvider
        self.isPairedProvider = isPairedProvider
        self.admitSend = admitSend
        self.pairingGeneration = pairingGeneration
        self.sessionFactory = sessionFactory
    }

    func checkCapability() async -> Bool? {
        guard await self.admitSend(),
              let port = await self.localPortProvider()
        else { return nil }
        let report = await self.homeClient.fetchStatusReport(localPort: port)
        switch report {
        case .failed:
            return nil
        case .read:
            return report.lists(FolderConstants.capability)
        }
    }

    func fetchFacets() async -> (FolderFacetsAvailability, [FolderFacet]) {
        guard await self.isPairedProvider() else {
            return (.unpaired, [])
        }
        guard await self.admitSend(),
              let port = await self.localPortProvider(),
              let (data, code) = await self.getV3(localPort: port, path: "/app/devices/ingest/folder/facets", timeout: .seconds(10)),
              code == 200,
              let facets = FoldersWire.parseFacets(data)
        else {
            return (.offline, [])
        }
        return (.ready, facets)
    }

    func fetchSupported() async -> FolderSupportedList? {
        guard await self.admitSend(),
              let port = await self.localPortProvider(),
              let (data, code) = await self.getV3(localPort: port, path: "/app/devices/ingest/folder/supported", timeout: .seconds(10)),
              code == 200
        else { return nil }
        return FoldersWire.parseSupportedList(data)
    }

    func fetchEstimate(folderID: String, items: [FolderEstimateItem]) async -> FolderBackfillEstimate? {
        guard await self.admitSend(),
              let port = await self.localPortProvider()
        else { return nil }
        struct EstimateRequest: Encodable {
            var folder_id: String
            var items: [FolderEstimateItem]
        }
        guard let body = try? JSONEncoder().encode(EstimateRequest(folder_id: folderID, items: items)),
              let (data, code) = await self.postV3(
                localPort: port,
                path: "/app/devices/ingest/folder/estimate",
                contentType: "application/json",
                body: body,
                timeout: .seconds(30)
              ),
              code == 200
        else { return nil }
        return FoldersWire.parseEstimate(data)
    }

    func uploadSegment(
        _ delivery: FolderSegmentDelivery,
        supported: FolderSupportedList,
        canSend: @escaping @Sendable () async -> Bool,
        readContent: @escaping @Sendable (FolderStagedContentFile) -> Data?
    ) async -> FolderDeliveryOutcome {
        guard await self.admitSend(),
              let port = await self.localPortProvider()
        else { return .hold }

        let capturedGen = await self.pairingGeneration()
        let boundary = "SolstoneFolder-\(UUID().uuidString)"
        let builtBody: Data
        do {
            let built = try await Task.detached(priority: .utility) {
                try FoldersWire.buildMultipartBody(
                    delivery: delivery,
                    supported: supported,
                    boundary: boundary,
                    readContent: readContent
                )
            }.value
            builtBody = built.body
        } catch FoldersWire.BuildError.refusedContent(let paths) {
            return .allFilesRefused(paths)
        } catch {
            return .hold
        }

        guard await canSend(), await self.admitSend(),
              await self.pairingGeneration() == capturedGen
        else { return .hold }

        guard let (data, code) = await self.postV3(
            localPort: port,
            path: "/app/devices/ingest",
            contentType: "multipart/form-data; boundary=\(boundary)",
            body: builtBody,
            timeout: .seconds(120)
        ) else {
            return .hold
        }

        guard await self.pairingGeneration() == capturedGen else {
            return .hold
        }
        return FoldersWire.classifyUploadReply(statusCode: code, body: data)
    }

    // MARK: - HTTP helpers

    private func getV3(localPort: Int, path: String, timeout: Duration) async -> (Data, Int)? {
        guard (1...65535).contains(localPort),
              let url = URL(string: "http://127.0.0.1:\(localPort)\(path)")
        else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue(ObserverServerURL.ingestProtocolVersion, forHTTPHeaderField: ObserverServerURL.protocolVersionHeaderName)
        request.attachLoopbackCapability()

        let session = self.sessionFactory(timeout)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            return (data, http.statusCode)
        } catch {
            return nil
        }
    }

    private func postV3(
        localPort: Int,
        path: String,
        contentType: String,
        body: Data,
        timeout: Duration
    ) async -> (Data, Int)? {
        guard (1...65535).contains(localPort),
              let url = URL(string: "http://127.0.0.1:\(localPort)\(path)")
        else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue(ObserverServerURL.ingestProtocolVersion, forHTTPHeaderField: ObserverServerURL.protocolVersionHeaderName)
        request.httpBody = body
        request.attachLoopbackCapability()

        let session = self.sessionFactory(timeout)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            return (data, http.statusCode)
        } catch {
            return nil
        }
    }
}

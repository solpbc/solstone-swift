// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let watchSegmentDrainLog = Logger(subsystem: "app.solstone.swift", category: "watch-drain")

@MainActor
final class WatchSegmentDrain {
    nonisolated static let backgroundSessionIdentifier = "app.solstone.swift.watch-upload"
    nonisolated static let cacheDirectoryName = "WatchObserver"

    private let stagingRootURL: URL
    private let tempDirectoryURL: URL
    private let watchUploader: ObserverUploader
    private let watchRegistration: ObserverRegistration
    private let localPortProvider: @Sendable @MainActor () -> Int?
    private let session: URLSession
    private let urlBuilder: @Sendable (Int) -> URL?
    private let fileManager: FileManager
    private let decoder: JSONDecoder
    private var inFlight: Set<UUID> = []

    init(
        stagingRootURL: URL? = nil,
        watchUploader: ObserverUploader,
        watchRegistration: ObserverRegistration,
        localPortProvider: @escaping @Sendable @MainActor () -> Int?,
        session: URLSession = .shared,
        urlBuilder: @escaping @Sendable (Int) -> URL? = { ObserverServerURL.ingestURL(localPort: $0) },
        fileManager: FileManager = .default,
        tempDirectoryURL: URL? = nil
    ) throws {
        self.stagingRootURL = try stagingRootURL
            ?? AppGroupContainer.rootURL(fileManager: fileManager)
                .appendingPathComponent(WatchRelayReceiver.rootDirectoryName, isDirectory: true)
                .appendingPathComponent(WatchRelayReceiver.stagingDirectoryName, isDirectory: true)
        self.tempDirectoryURL = tempDirectoryURL
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("watch-segment-drain", isDirectory: true)
        self.watchUploader = watchUploader
        self.watchRegistration = watchRegistration
        self.localPortProvider = localPortProvider
        self.session = session
        self.urlBuilder = urlBuilder
        self.fileManager = fileManager
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        try self.fileManager.createDirectory(at: self.stagingRootURL, withIntermediateDirectories: true)
        try self.fileManager.createDirectory(at: self.tempDirectoryURL, withIntermediateDirectories: true)

        self.watchUploader.onSegmentDelivered = { [weak self] id in
            self?.removeStaged(id)
        }
    }

    func drain() async {
        let directories: [URL]
        do {
            directories = try self.fileManager.contentsOfDirectory(
                at: self.stagingRootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            watchSegmentDrainLog.error("watch drain enumeration failed: \(String(describing: error), privacy: .public)")
            return
        }

        for directory in directories where self.isDirectory(directory) {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            guard !self.inFlight.contains(id) else { continue }

            self.inFlight.insert(id)
            await self.drain(directory: directory, id: id)
        }
    }

    func removeStaged(_ id: UUID) {
        let directory = self.stagingRootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try? self.fileManager.removeItem(at: directory)
        self.inFlight.remove(id)
        watchSegmentDrainLog.info("watch staged segment removed id=\(id.uuidString, privacy: .public)")
    }
}

private extension WatchSegmentDrain {
    func drain(directory: URL, id: UUID) async {
        do {
            let manifest = try self.loadManifest(in: directory)
            guard manifest.id == id else {
                watchSegmentDrainLog.error("watch drain manifest id mismatch id=\(id.uuidString, privacy: .public)")
                self.inFlight.remove(id)
                return
            }

            let audioURL = directory.appendingPathComponent(WatchSegmentBundleCodec.audioFilename, isDirectory: false)
            let locationURL = directory.appendingPathComponent(WatchSegmentBundleCodec.locationFilename, isDirectory: false)
            let audioData = self.fileManager.fileExists(atPath: audioURL.path)
                ? try Data(contentsOf: audioURL)
                : nil
            let locationData = self.fileManager.fileExists(atPath: locationURL.path)
                ? try Data(contentsOf: locationURL)
                : nil

            if let audioData {
                try await self.enqueueAudioSegment(
                    manifest: manifest,
                    audioData: audioData,
                    locationData: locationData
                )
                return
            }

            if let locationData {
                await self.uploadLocationOnlySegment(manifest: manifest, locationData: locationData)
                return
            }

            watchSegmentDrainLog.debug("watch drain staged segment has no files id=\(id.uuidString, privacy: .public)")
            self.inFlight.remove(id)
        } catch {
            watchSegmentDrainLog.error("watch drain failed id=\(id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            self.inFlight.remove(id)
        }
    }

    func enqueueAudioSegment(
        manifest: WatchSegmentManifest,
        audioData: Data,
        locationData: Data?
    ) async throws {
        let tempURL = self.tempDirectoryURL
            .appendingPathComponent(manifest.id.uuidString, isDirectory: false)
            .appendingPathExtension("m4a")
        if self.fileManager.fileExists(atPath: tempURL.path) {
            try self.fileManager.removeItem(at: tempURL)
        }
        try audioData.write(to: tempURL, options: .atomic)

        let sidecar = ChunkSidecar(
            segment: manifest.segment,
            day: manifest.day,
            chunkIndex: 0,
            startedAt: manifest.startedAt,
            durationS: manifest.duration,
            sessionID: manifest.id,
            mode: .meeting,
            locationJSONL: locationData
        )
        await self.watchUploader.enqueue(chunkURL: tempURL, sidecar: sidecar)

        if self.fileManager.fileExists(atPath: tempURL.path) {
            try? self.fileManager.removeItem(at: tempURL)
            self.inFlight.remove(manifest.id)
        }
    }

    func uploadLocationOnlySegment(manifest: WatchSegmentManifest, locationData: Data) async {
        guard let localPort = self.localPortProvider() else {
            watchSegmentDrainLog.debug("watch location-only upload held: local port unavailable")
            self.inFlight.remove(manifest.id)
            return
        }

        let handle: String
        do {
            handle = try await self.watchRegistration.ensureRegistered()
        } catch {
            watchSegmentDrainLog.debug("watch location-only upload held: registration unavailable")
            self.inFlight.remove(manifest.id)
            return
        }

        guard let url = self.urlBuilder(localPort) else {
            watchSegmentDrainLog.error("watch location-only upload unavailable: invalid url")
            self.inFlight.remove(manifest.id)
            return
        }

        do {
            let boundary = self.boundary(for: manifest.id)
            var request = ObserverAuthorizedRequest.make(url: url, handle: handle, method: "POST")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = try self.locationOnlyMultipartBody(
                manifest: manifest,
                locationData: locationData,
                boundary: boundary
            )

            let (_, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                watchSegmentDrainLog.error("watch location-only upload failed id=\(manifest.id.uuidString, privacy: .public): HTTP \(status, privacy: .public)")
                self.inFlight.remove(manifest.id)
                return
            }

            self.removeStaged(manifest.id)
        } catch {
            watchSegmentDrainLog.error("watch location-only upload failed id=\(manifest.id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            self.inFlight.remove(manifest.id)
        }
    }

    func loadManifest(in directory: URL) throws -> WatchSegmentManifest {
        let url = directory.appendingPathComponent(WatchSegmentBundleCodec.manifestFilename, isDirectory: false)
        return try self.decoder.decode(WatchSegmentManifest.self, from: Data(contentsOf: url))
    }

    func locationOnlyMultipartBody(
        manifest: WatchSegmentManifest,
        locationData: Data,
        boundary: String
    ) throws -> Data {
        var body = Data()
        body.append(self.multipartField(named: "segment", value: manifest.segment, boundary: boundary))
        body.append(self.multipartField(named: "day", value: manifest.day, boundary: boundary))
        body.append(self.multipartField(named: "platform", value: "watchos", boundary: boundary))

        let meta = try JSONSerialization.data(withJSONObject: [
            "segment": manifest.segment,
            "day": manifest.day,
            "chunk_index": 0,
            "started_at": ISO8601DateFormatter().string(from: manifest.startedAt),
            "duration_s": manifest.duration,
            "session_id": manifest.id.uuidString,
            "mode": ObserverMode.meeting.rawValue,
        ], options: [.sortedKeys])
        body.append(self.multipartField(
            named: "meta",
            value: String(decoding: meta, as: UTF8.self),
            boundary: boundary
        ))

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(ObserverServerURL.filesFieldName)\"; filename=\"location.jsonl\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/x-ndjson\r\n\r\n".data(using: .utf8)!)
        body.append(locationData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    func multipartField(named name: String, value: String, boundary: String) -> Data {
        Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
    }

    func boundary(for id: UUID) -> String {
        "Boundary-\(id.uuidString)"
    }

    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

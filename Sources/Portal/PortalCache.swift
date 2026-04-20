// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

final class PortalCache {
    struct Entry: Codable, Equatable, Sendable {
        let path: String
        let fetchedAt: Date
        let etag: String?
    }

    struct CachedPage: Equatable, Sendable {
        let html: String
        let entry: Entry
    }

    private let fileManager: FileManager
    private let cacheDirectory: URL
    private let ttl: TimeInterval

    init(
        fileManager: FileManager = .default,
        cacheDirectory: URL? = nil,
        ttl: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.fileManager = fileManager
        self.cacheDirectory = cacheDirectory ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("solstone-portal", isDirectory: true)
        self.ttl = ttl
    }

    func storeHTML(_ html: String, path: String, etag: String? = nil) throws {
        try self.ensureDirectory()
        let entry = Entry(path: path, fetchedAt: .now, etag: etag)
        try html.data(using: .utf8)?.write(to: self.payloadURL(for: path), options: .atomic)
        let metadata = try JSONEncoder().encode(entry)
        try metadata.write(to: self.metadataURL(for: path), options: .atomic)
    }

    func cachedHTML(path: String) -> CachedPage? {
        guard let entry = self.entry(for: path) else { return nil }
        guard Date().timeIntervalSince(entry.fetchedAt) <= self.ttl else { return nil }
        guard let data = try? Data(contentsOf: self.payloadURL(for: path)),
              let html = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return CachedPage(html: html, entry: entry)
    }

    func cacheAgeHours(path: String) -> Int? {
        guard let entry = self.entry(for: path) else { return nil }
        return max(Int(Date().timeIntervalSince(entry.fetchedAt) / 3600), 0)
    }

    private func entry(for path: String) -> Entry? {
        guard let data = try? Data(contentsOf: self.metadataURL(for: path)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func ensureDirectory() throws {
        if !self.fileManager.fileExists(atPath: self.cacheDirectory.path) {
            try self.fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        }
    }

    private func payloadURL(for path: String) -> URL {
        self.cacheDirectory.appendingPathComponent("\(self.filename(for: path)).html")
    }

    private func metadataURL(for path: String) -> URL {
        self.cacheDirectory.appendingPathComponent("\(self.filename(for: path)).json")
    }

    private func filename(for path: String) -> String {
        Data(path.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }
}

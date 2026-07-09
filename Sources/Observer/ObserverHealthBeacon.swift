// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

@MainActor
protocol ObserverQueueHealthProviding: AnyObject {
    var pendingCount: Int { get }
    var recentErrorCount: Int { get }
    var lastError: String? { get }
    var lastUploadAt: Date? { get }
}

@MainActor
final class ObserverHealthBeacon {
    private struct Payload: Encodable {
        let name: String
        let streamType: String
        let version: String
        let uptime: Int
        let lastSuccessfulSync: String?
        let pendingQueueDepth: Int
        let recentErrorCount: Int
        let lastErrorReason: String?

        enum CodingKeys: String, CodingKey {
            case name
            case streamType = "stream_type"
            case version
            case uptime
            case lastSuccessfulSync = "last_successful_sync"
            case pendingQueueDepth = "pending_queue_depth"
            case recentErrorCount = "recent_error_count"
            case lastErrorReason = "last_error_reason"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.name, forKey: .name)
            try container.encode(self.streamType, forKey: .streamType)
            try container.encode(self.version, forKey: .version)
            try container.encode(self.uptime, forKey: .uptime)
            if let lastSuccessfulSync {
                try container.encode(lastSuccessfulSync, forKey: .lastSuccessfulSync)
            } else {
                try container.encodeNil(forKey: .lastSuccessfulSync)
            }
            try container.encode(self.pendingQueueDepth, forKey: .pendingQueueDepth)
            try container.encode(self.recentErrorCount, forKey: .recentErrorCount)
            if let lastErrorReason {
                try container.encode(lastErrorReason, forKey: .lastErrorReason)
            } else {
                try container.encodeNil(forKey: .lastErrorReason)
            }
        }
    }

    private let registration: ObserverRegistration
    private let queueHealth: any ObserverQueueHealthProviding
    private let isJournalConfigured: @MainActor @Sendable () -> Bool
    private let urlBuilder: @MainActor @Sendable (Int) -> URL?
    private let session: URLSession
    private let clock: any ObserverClock
    private let interval: Duration
    private let encoder: JSONEncoder
    private let iso8601Formatter = ISO8601DateFormatter()
    private let log = Logger(subsystem: "app.solstone.swift", category: "observer-health")

    private var startTime: Date?
    private var lastSuccessfulContact: Date?
    private var task: Task<Void, Never>?

    init(
        registration: ObserverRegistration,
        uploader: any ObserverQueueHealthProviding,
        isJournalConfigured: @escaping @MainActor @Sendable () -> Bool,
        urlBuilder: @escaping @MainActor @Sendable (Int) -> URL? = { ObserverServerURL.healthURL(localPort: $0) },
        session: URLSession,
        clock: any ObserverClock,
        interval: Duration = .seconds(300)
    ) {
        self.registration = registration
        self.queueHealth = uploader
        self.isJournalConfigured = isJournalConfigured
        self.urlBuilder = urlBuilder
        self.session = session
        self.clock = clock
        self.interval = interval

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func start() {
        guard self.task == nil else { return }
        self.startTime = self.clock.now()
        self.task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.emit()
            while !Task.isCancelled {
                do {
                    try await self.clock.sleep(for: self.interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.emit()
            }
        }
    }

    func stop() {
        self.task?.cancel()
        self.task = nil
    }

    private func emit() async {
        guard self.isJournalConfigured() else {
            self.log.debug("observer health beacon skipped: journal unavailable")
            return
        }
        guard let port = self.registration.activeLocalPort else {
            self.log.debug("observer health beacon skipped: local port unavailable")
            return
        }
        guard let name = self.registration.registrationPrefix, !name.isEmpty else {
            self.log.debug("observer health beacon skipped: registration identity unavailable")
            return
        }
        guard let handle = self.registration.registeredHandle() else {
            self.log.debug("observer health beacon skipped: registration handle unavailable")
            return
        }
        guard let url = self.urlBuilder(port) else {
            self.log.error("observer health beacon unavailable: invalid url")
            return
        }

        do {
            let now = self.clock.now()
            var request = ObserverAuthorizedRequest.make(url: url, handle: handle, method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try self.encoder.encode(self.payload(name: name, now: now))

            let (_, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                self.log.error("observer health beacon failed: invalid response")
                return
            }
            guard 200..<300 ~= http.statusCode else {
                self.log.debug("observer health beacon failed: HTTP \(http.statusCode, privacy: .public)")
                return
            }
            self.lastSuccessfulContact = self.clock.now()
        } catch {
            self.log.error("observer health beacon failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func payload(name: String, now: Date) -> Payload {
        Payload(
            name: name,
            streamType: self.registration.streamType,
            version: self.registration.version,
            uptime: self.uptime(now: now),
            lastSuccessfulSync: self.lastSuccessfulSync(),
            pendingQueueDepth: self.queueHealth.pendingCount,
            recentErrorCount: self.queueHealth.recentErrorCount,
            lastErrorReason: self.sanitized(self.queueHealth.lastError)
        )
    }

    private func uptime(now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(self.startTime ?? now)))
    }

    private func lastSuccessfulSync() -> String? {
        let upload = self.queueHealth.lastUploadAt
        let contact = self.lastSuccessfulContact
        let latest: Date?
        switch (upload, contact) {
        case (.none, .none):
            latest = nil
        case (.some(let value), .none), (.none, .some(let value)):
            latest = value
        case (.some(let upload), .some(let contact)):
            latest = max(upload, contact)
        }
        return latest.map { self.iso8601Formatter.string(from: $0) }
    }

    private func sanitized(_ detail: String?) -> String? {
        guard var redacted = detail, !redacted.isEmpty else { return nil }
        redacted = redacted
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if let authorizationRange = redacted.range(of: "Authorization:", options: [.caseInsensitive]) {
            redacted = String(redacted[..<authorizationRange.lowerBound]) + "Authorization: [redacted]"
        }
        while let bearerRange = redacted.range(of: "Bearer ") {
            var end = bearerRange.upperBound
            while end < redacted.endIndex, !redacted[end].isWhitespace {
                end = redacted.index(after: end)
            }
            redacted.replaceSubrange(bearerRange.lowerBound..<end, with: "[redacted bearer]")
        }
        let capped = String(redacted.prefix(200))
        return capped.isEmpty ? nil : capped
    }
}

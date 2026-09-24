// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import UserNotifications
import os

nonisolated private let log = Logger(subsystem: "app.solstone.swift", category: "notification-service")

nonisolated final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private struct State {
        var contentHandler: ((UNNotificationContent) -> Void)?
        var originalContent: UNNotificationContent?
    }

    private let lock = NSLock()
    private var state = State()

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.lock.withLock {
            self.state.contentHandler = contentHandler
            self.state.originalContent = request.content
        }

        let store = PushKeyStore.production()
        do {
            let mutated = try PushEnvelope.mutateContent(request: request, keyStore: store)
            self.finish(with: mutated)
        } catch let error as PushEnvelopeError {
            log.error("notification unseal failed: \(error.reasonCode, privacy: .public)")
            self.finish(with: request.content)
        } catch {
            log.error("notification unseal failed: unexpected")
            self.finish(with: request.content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        self.lock.withLock {
            if let original = self.state.originalContent, let handler = self.state.contentHandler {
                self.state.contentHandler = nil
                self.state.originalContent = nil
                handler(original)
            }
        }
    }

    private func finish(with content: UNNotificationContent) {
        self.lock.withLock {
            if let handler = self.state.contentHandler {
                self.state.contentHandler = nil
                self.state.originalContent = nil
                handler(content)
            }
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import UIKit

@Observable
final class BannerPresenter {
    var currentBanner: BannerItem?
    var showDiagnostics: Bool = false

    @ObservationIgnored private let diagnosticLog: DiagnosticLog
    @ObservationIgnored private let voiceManager: VoiceManager
    @ObservationIgnored private let tunnelManager: TunnelManager
    @ObservationIgnored private var queue: [BannerItem] = []
    @ObservationIgnored private var lastProcessedIndex: Int = 0
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    struct BannerItem: Identifiable {
        let id: UUID
        let event: DiagnosticEvent
        let autoDismissSeconds: Double?

        init(event: DiagnosticEvent) {
            self.id = UUID()
            self.event = event
            switch event.severity {
            case .info:
                self.autoDismissSeconds = 3
            case .warning:
                self.autoDismissSeconds = 5
            case .error:
                self.autoDismissSeconds = nil
            }
        }
    }

    init(diagnosticLog: DiagnosticLog, voiceManager: VoiceManager, tunnelManager: TunnelManager) {
        self.diagnosticLog = diagnosticLog
        self.voiceManager = voiceManager
        self.tunnelManager = tunnelManager
        self.lastProcessedIndex = diagnosticLog.events.count
    }

    func processNewEvents() {
        let events = self.diagnosticLog.events

        if self.lastProcessedIndex > events.count {
            self.lastProcessedIndex = 0
        }

        guard self.lastProcessedIndex < events.count else { return }

        let newEvents = events[self.lastProcessedIndex...]
        self.lastProcessedIndex = events.count

        guard self.tunnelManager.state.isConnected else { return }

        let isVoiceActive = self.voiceManager.state == .listening || self.voiceManager.state == .speaking

        for event in newEvents {
            if event.severity == .info {
                self.resolveCategory(event.category)
            }

            guard Self.isBannerWorthy(event) else { continue }

            if isVoiceActive && event.severity == .info {
                continue
            }

            self.enqueue(BannerItem(event: event))
        }
    }

    func dismiss() {
        self.dismissTask?.cancel()
        self.dismissTask = nil
        self.currentBanner = nil
        self.showNext()
    }

    func tap() {
        self.showDiagnostics = true
        self.dismiss()
    }

    func clearAll() {
        self.dismissTask?.cancel()
        self.dismissTask = nil
        self.currentBanner = nil
        self.queue.removeAll()
    }

    func dismissInfoIfVoiceActive() {
        guard self.voiceManager.state == .listening || self.voiceManager.state == .speaking else { return }

        if let banner = self.currentBanner, banner.event.severity == .info {
            self.dismissTask?.cancel()
            self.dismissTask = nil
            self.currentBanner = nil
        }

        self.queue.removeAll { $0.event.severity == .info }

        if self.currentBanner == nil && !self.queue.isEmpty {
            self.showNext()
        }
    }

    static func isBannerWorthy(_ event: DiagnosticEvent) -> Bool {
        switch event.severity {
        case .warning, .error:
            return true
        case .info:
            return self.isInfoAllowed(event)
        }
    }

    private static func isInfoAllowed(_ event: DiagnosticEvent) -> Bool {
        guard !self.messageContainsLocalPort(event.message) else {
            return false
        }
        switch event.category {
        case .network:
            return true
        case .brain:
            return true
        case .tunnel:
            return event.message == "journal connected"
                || event.message == "connecting"
                || event.message == "disconnected"
        case .voice:
            return event.message.hasPrefix("session")
        case .upload:
            return event.message.contains("files sent")
        }
    }

    private static func messageContainsLocalPort(_ message: String) -> Bool {
        message.range(
            of: #"(?i)(localhost|127\.0\.0\.1|(?:on\s+)?port\s+\d{2,5}|:\d{2,5}\b)"#,
            options: .regularExpression
        ) != nil
    }

    private func resolveCategory(_ category: DiagnosticCategory) {
        if let banner = self.currentBanner,
           banner.event.category == category,
           banner.event.severity != .info
        {
            self.dismissTask?.cancel()
            self.dismissTask = nil
            self.currentBanner = nil
        }

        self.queue.removeAll { $0.event.category == category && $0.event.severity != .info }

        if self.currentBanner == nil && !self.queue.isEmpty {
            self.showNext()
        }
    }

    private func enqueue(_ item: BannerItem) {
        let now = item.event.timestamp

        if let banner = self.currentBanner,
           banner.event.category == item.event.category,
           now.timeIntervalSince(banner.event.timestamp) < 1
        {
            self.dismissTask?.cancel()
            self.dismissTask = nil
            self.currentBanner = item
            if let seconds = item.autoDismissSeconds {
                self.scheduleAutoDismiss(seconds: seconds)
            }
            self.announceForAccessibility(item)
            return
        }

        if let index = self.queue.lastIndex(where: {
            $0.event.category == item.event.category
                && now.timeIntervalSince($0.event.timestamp) < 1
        }) {
            self.queue[index] = item
        } else {
            self.queue.append(item)
        }

        while self.queue.count > 3 {
            self.queue.removeFirst()
        }

        if self.currentBanner == nil {
            self.showNext()
        }
    }

    private func showNext() {
        guard !self.queue.isEmpty else { return }
        let item = self.queue.removeFirst()
        self.currentBanner = item

        if item.event.severity == .error {
            if UserSettings.haptics {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }

        self.announceForAccessibility(item)

        if let seconds = item.autoDismissSeconds {
            self.scheduleAutoDismiss(seconds: seconds)
        }
    }

    private func scheduleAutoDismiss(seconds: Double) {
        self.dismissTask?.cancel()
        self.dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func announceForAccessibility(_ item: BannerItem) {
        let message = item.event.message
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct OmiDiagnosticsPayload: Codable, Sendable, Equatable {
    struct UptimeSnapshot: Codable, Sendable, Equatable {
        var connectedSince: Date?
        var accumulatedConnectedSeconds: TimeInterval

        init(
            connectedSince: Date? = nil,
            accumulatedConnectedSeconds: TimeInterval = 0
        ) {
            self.connectedSince = connectedSince
            self.accumulatedConnectedSeconds = accumulatedConnectedSeconds
        }

        init(_ uptime: OmiUptimeAccumulator) {
            self.connectedSince = uptime.connectedSince
            self.accumulatedConnectedSeconds = uptime.accumulatedConnectedSeconds
        }

        var accumulator: OmiUptimeAccumulator {
            OmiUptimeAccumulator(
                connectedSince: self.connectedSince,
                accumulatedConnectedSeconds: self.accumulatedConnectedSeconds
            )
        }

        func connectedSeconds(asOf date: Date) -> TimeInterval {
            self.accumulator.connectedSeconds(asOf: date)
        }

        func connectedFraction(since start: Date, asOf date: Date) -> Double? {
            self.accumulator.connectedFraction(since: start, asOf: date)
        }
    }

    struct ReconnectEvent: Codable, Sendable, Equatable {
        var timestamp: Date
        var reason: String
        var appStateAtDrop: String
        var timeToReconnect: TimeInterval?

        init(
            timestamp: Date,
            reason: String,
            appStateAtDrop: String,
            timeToReconnect: TimeInterval?
        ) {
            self.timestamp = timestamp
            self.reason = reason
            self.appStateAtDrop = appStateAtDrop
            self.timeToReconnect = timeToReconnect
        }

        init(_ event: OmiSourceEvent) {
            self.init(
                timestamp: event.timestamp,
                reason: event.reason,
                appStateAtDrop: event.appStateAtDrop,
                timeToReconnect: event.timeToReconnect
            )
        }
    }

    struct DecodeCounters: Codable, Sendable, Equatable {
        var ok: Int
        var errors: Int
        var gaps: Int
        var outOfOrder: Int

        init(
            ok: Int = 0,
            errors: Int = 0,
            gaps: Int = 0,
            outOfOrder: Int = 0
        ) {
            self.ok = ok
            self.errors = errors
            self.gaps = gaps
            self.outOfOrder = outOfOrder
        }
    }

    struct PendantBatterySample: Codable, Sendable, Equatable {
        var timestamp: Date
        var level: Int
    }

    struct PendantSignalSample: Codable, Sendable, Equatable {
        var timestamp: Date
        var level: Int
    }

    struct PhoneSample: Codable, Sendable, Equatable {
        var timestamp: Date
        var batteryLevel: Double?
        var thermalState: String
        var batteryState: String? = nil
    }

    struct GapTallies: Codable, Sendable, Equatable {
        var disconnectGapCount: Int
        var disconnectGapSeconds: TimeInterval
        var connectedSilentGapCount: Int
        var connectedSilentGapSeconds: TimeInterval

        init(
            disconnectGapCount: Int = 0,
            disconnectGapSeconds: TimeInterval = 0,
            connectedSilentGapCount: Int = 0,
            connectedSilentGapSeconds: TimeInterval = 0
        ) {
            self.disconnectGapCount = disconnectGapCount
            self.disconnectGapSeconds = disconnectGapSeconds
            self.connectedSilentGapCount = connectedSilentGapCount
            self.connectedSilentGapSeconds = connectedSilentGapSeconds
        }
    }

    static let currentVersion = 1

    var version: Int
    var firstObservedAt: Date?
    var uptime: UptimeSnapshot
    var reconnectEvents: [ReconnectEvent]
    var decodeCounters: DecodeCounters
    var pendantBatteryTrend: [PendantBatterySample]
    var pendantSignalTrend: [PendantSignalSample]? = nil
    var phoneSamples: [PhoneSample]
    var gapTallies: GapTallies
    var lastDecodedSampleAt: Date?
    var openDisconnectStartedAt: Date?
    var openConnectedSilentStartedAt: Date?

    init(
        version: Int = Self.currentVersion,
        firstObservedAt: Date? = nil,
        uptime: UptimeSnapshot = UptimeSnapshot(),
        reconnectEvents: [ReconnectEvent] = [],
        decodeCounters: DecodeCounters = DecodeCounters(),
        pendantBatteryTrend: [PendantBatterySample] = [],
        pendantSignalTrend: [PendantSignalSample]? = nil,
        phoneSamples: [PhoneSample] = [],
        gapTallies: GapTallies = GapTallies(),
        lastDecodedSampleAt: Date? = nil,
        openDisconnectStartedAt: Date? = nil,
        openConnectedSilentStartedAt: Date? = nil
    ) {
        self.version = version
        self.firstObservedAt = firstObservedAt
        self.uptime = uptime
        self.reconnectEvents = reconnectEvents
        self.decodeCounters = decodeCounters
        self.pendantBatteryTrend = pendantBatteryTrend
        self.pendantSignalTrend = pendantSignalTrend
        self.phoneSamples = phoneSamples
        self.gapTallies = gapTallies
        self.lastDecodedSampleAt = lastDecodedSampleAt
        self.openDisconnectStartedAt = openDisconnectStartedAt
        self.openConnectedSilentStartedAt = openConnectedSilentStartedAt
    }
}

nonisolated struct OmiDiagnosticsGapProbe: Equatable, Sendable {
    let timestamp: Date
    let connected: Bool
    let connectedSince: Date?
    let lastAudioAt: Date?

    init(
        timestamp: Date,
        connected: Bool,
        connectedSince: Date? = nil,
        lastAudioAt: Date? = nil
    ) {
        self.timestamp = timestamp
        self.connected = connected
        self.connectedSince = connectedSince
        self.lastAudioAt = lastAudioAt
    }
}

nonisolated struct OmiDiagnosticsGapSummary: Equatable, Sendable {
    var disconnectGapCount: Int
    var disconnectGapSeconds: TimeInterval
    var connectedSilentGapCount: Int
    var connectedSilentGapSeconds: TimeInterval

    init(
        disconnectGapCount: Int = 0,
        disconnectGapSeconds: TimeInterval = 0,
        connectedSilentGapCount: Int = 0,
        connectedSilentGapSeconds: TimeInterval = 0
    ) {
        self.disconnectGapCount = disconnectGapCount
        self.disconnectGapSeconds = disconnectGapSeconds
        self.connectedSilentGapCount = connectedSilentGapCount
        self.connectedSilentGapSeconds = connectedSilentGapSeconds
    }
}

nonisolated enum OmiDiagnosticsLogic {
    static let connectedSilenceThreshold: TimeInterval = 30

    static func decodeErrorRate(ok: Int, errors: Int) -> Double {
        let total = ok + errors
        guard total > 0 else {
            return 0
        }
        return Double(errors) / Double(total)
    }

    static func accumulatedCounter(
        lifetime: Int,
        lastSeen: Int,
        incoming: Int
    ) -> (lifetime: Int, lastSeen: Int) {
        if incoming >= lastSeen {
            return (lifetime + (incoming - lastSeen), incoming)
        }
        return (lifetime + incoming, incoming)
    }

    static func diagnosticRows(payload: OmiDiagnosticsPayload, asOf date: Date) -> [(label: String, value: String)] {
        let uptimePercent = payload.firstObservedAt
            .flatMap { payload.uptime.connectedFraction(since: $0, asOf: date) }
            .map { "\(String(format: "%.1f", $0 * 100))%" } ?? "unknown"
        let reconnects = payload.reconnectEvents.filter { $0.timeToReconnect != nil }
        let decodeRate = Self.decodeErrorRate(
            ok: payload.decodeCounters.ok,
            errors: payload.decodeCounters.errors
        )

        return [
            ("uptime", uptimePercent),
            ("reconnects", "\(reconnects.count)"),
            ("disconnect gaps", "\(payload.gapTallies.disconnectGapCount)"),
            ("connected-without-audio gaps", "\(payload.gapTallies.connectedSilentGapCount)"),
            ("decode error rate", "\(String(format: "%.1f", decodeRate * 100))%")
        ]
    }

    static func gapSummary(
        from probes: [OmiDiagnosticsGapProbe],
        silenceThreshold: TimeInterval = Self.connectedSilenceThreshold
    ) -> OmiDiagnosticsGapSummary {
        let sorted = probes.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count > 1 else {
            return OmiDiagnosticsGapSummary()
        }

        var summary = OmiDiagnosticsGapSummary()
        var isInsideDisconnectGap = false
        var isInsideConnectedSilentGap = false

        for index in 0..<(sorted.count - 1) {
            let current = sorted[index]
            let next = sorted[index + 1]
            let duration = max(next.timestamp.timeIntervalSince(current.timestamp), 0)
            guard duration > 0 else {
                continue
            }

            if !current.connected {
                if !isInsideDisconnectGap {
                    summary.disconnectGapCount += 1
                }
                summary.disconnectGapSeconds += duration
                isInsideDisconnectGap = true
                isInsideConnectedSilentGap = false
                continue
            }

            isInsideDisconnectGap = false

            guard let connectedSince = current.connectedSince else {
                isInsideConnectedSilentGap = false
                continue
            }

            let lastAudioAt = current.lastAudioAt.map { max($0, connectedSince) } ?? connectedSince
            let thresholdDate = lastAudioAt.addingTimeInterval(silenceThreshold)
            let silentStart = max(current.timestamp, thresholdDate)
            let silentSeconds = max(next.timestamp.timeIntervalSince(silentStart), 0)

            if silentSeconds > 0 {
                if !isInsideConnectedSilentGap {
                    summary.connectedSilentGapCount += 1
                }
                summary.connectedSilentGapSeconds += silentSeconds
                isInsideConnectedSilentGap = true
            } else {
                isInsideConnectedSilentGap = false
            }
        }

        return summary
    }

    static func exportSummary(
        payload: OmiDiagnosticsPayload,
        asOf date: Date
    ) -> String {
        let connectedSeconds = payload.uptime.connectedSeconds(asOf: date)
        let uptimePercent = payload.firstObservedAt
            .flatMap { payload.uptime.connectedFraction(since: $0, asOf: date) }
            .map(Self.percentText) ?? "unknown"
        let reconnects = payload.reconnectEvents.filter { $0.timeToReconnect != nil }
        let disconnectGapSeconds = payload.gapTallies.disconnectGapSeconds
            + Self.openDuration(from: payload.openDisconnectStartedAt, asOf: date)
        let connectedSilentGapSeconds = payload.gapTallies.connectedSilentGapSeconds
            + Self.openDuration(from: payload.openConnectedSilentStartedAt, asOf: date)
        let decodeRate = Self.decodeErrorRate(
            ok: payload.decodeCounters.ok,
            errors: payload.decodeCounters.errors
        )

        var lines: [String] = []
        lines.append("omi diagnostics")
        lines.append("generated: \(Self.dateText(date))")
        lines.append("uptime: \(uptimePercent)")
        lines.append("connected time: \(Self.durationText(connectedSeconds))")
        lines.append("reconnects: \(reconnects.count)")
        lines.append("last reconnect: \(Self.lastReconnectText(reconnects))")
        lines.append("disconnect profile: \(Self.disconnectProfileText(payload.reconnectEvents))")
        lines.append("disconnect gaps: \(payload.gapTallies.disconnectGapCount), \(Self.durationText(disconnectGapSeconds))")
        lines.append("connected-without-audio gaps: \(payload.gapTallies.connectedSilentGapCount), \(Self.durationText(connectedSilentGapSeconds))")
        lines.append("decode error rate: \(Self.percentText(decodeRate))")
        lines.append("decode frames: \(payload.decodeCounters.ok) ok, \(payload.decodeCounters.errors) errors")
        lines.append("audio gaps: \(payload.decodeCounters.gaps)")
        lines.append("out of order frames: \(payload.decodeCounters.outOfOrder)")
        lines.append("pendant battery: \(Self.pendantBatteryText(payload.pendantBatteryTrend))")
        lines.append("pendant signal: \(Self.pendantSignalText(payload.pendantSignalTrend))")
        lines.append("phone battery: \(Self.phoneBatteryText(payload.phoneSamples))")
        lines.append("phone thermal state: \(payload.phoneSamples.last?.thermalState ?? "unknown")")

        return lines.joined(separator: "\n") + "\n"
    }

    static func disconnectProfileText(_ events: [OmiDiagnosticsPayload.ReconnectEvent]) -> String {
        guard !events.isEmpty else {
            return "none"
        }

        let reconnectedCount = events.filter { $0.timeToReconnect != nil }.count
        let buckets = Dictionary(grouping: events) { event in
            "\(event.reason)/\(event.appStateAtDrop)"
        }
        let bucketText = buckets
            .map { (key: $0.key, count: $0.value.count) }
            .sorted {
                if $0.count != $1.count {
                    return $0.count > $1.count
                }
                return $0.key < $1.key
            }
            .map { "\($0.key) ×\($0.count)" }
            .joined(separator: ", ")

        return "\(events.count) disconnects (\(reconnectedCount) reconnected, \(events.count - reconnectedCount) unpaired); \(bucketText)"
    }

    private static func lastReconnectText(_ events: [OmiDiagnosticsPayload.ReconnectEvent]) -> String {
        guard let event = events.last, let latency = event.timeToReconnect else {
            return "none"
        }
        return "\(Self.durationText(latency)) after \(event.reason)"
    }

    private static func pendantBatteryText(_ samples: [OmiDiagnosticsPayload.PendantBatterySample]) -> String {
        guard let first = samples.first, let last = samples.last else {
            return "rate unavailable (0 samples)"
        }

        guard samples.count > 1 else {
            return "\(first.level)%→\(last.level)%, rate unavailable (\(samples.count) samples)"
        }

        var totalDrop = 0.0
        var totalHours = 0.0
        for index in 0..<(samples.count - 1) {
            let start = samples[index]
            let end = samples[index + 1]
            let seconds = end.timestamp.timeIntervalSince(start.timestamp)
            guard seconds > 0 else {
                continue
            }
            totalHours += seconds / 3_600
            totalDrop += max(Double(start.level - end.level), 0)
        }

        guard totalHours > 0 else {
            return "\(first.level)%→\(last.level)%, rate unavailable (\(samples.count) samples)"
        }

        return "\(first.level)%→\(last.level)%, drain \(String(format: "%.1f", totalDrop / totalHours))%/hr (\(samples.count) samples)"
    }

    private static func pendantSignalText(_ samples: [OmiDiagnosticsPayload.PendantSignalSample]?) -> String {
        guard let samples, let sample = samples.last else {
            return "unknown"
        }
        return "\(sample.level) (\(samples.count) samples)"
    }

    private static func phoneBatteryText(_ samples: [OmiDiagnosticsPayload.PhoneSample]) -> String {
        let knownLevels = samples.compactMap { sample -> (sample: OmiDiagnosticsPayload.PhoneSample, percent: Double)? in
            guard let level = sample.batteryLevel else {
                return nil
            }
            return (sample, level * 100)
        }
        guard let first = knownLevels.first, let last = knownLevels.last else {
            return "unknown (\(samples.count) samples)"
        }

        let startPercent = Int(first.percent.rounded())
        let endPercent = Int(last.percent.rounded())
        guard knownLevels.count >= 2 else {
            return "\(startPercent)%→\(endPercent)%, rate unavailable (\(samples.count) samples)"
        }

        var totalDrop = 0.0
        var totalHours = 0.0
        for index in 0..<(samples.count - 1) {
            let start = samples[index]
            let end = samples[index + 1]
            guard start.batteryState == "unplugged",
                  end.batteryState == "unplugged",
                  let startLevel = start.batteryLevel,
                  let endLevel = end.batteryLevel
            else {
                continue
            }

            let seconds = end.timestamp.timeIntervalSince(start.timestamp)
            guard seconds > 0 else {
                continue
            }

            totalHours += seconds / 3_600
            totalDrop += max((startLevel * 100) - (endLevel * 100), 0)
        }

        guard totalHours > 0 else {
            return "\(startPercent)%→\(endPercent)%, no on-battery interval (\(samples.count) samples)"
        }

        return "\(startPercent)%→\(endPercent)%, drain \(String(format: "%.1f", totalDrop / totalHours))%/hr (\(samples.count) samples)"
    }

    private static func openDuration(from start: Date?, asOf date: Date) -> TimeInterval {
        guard let start else {
            return 0
        }
        return max(date.timeIntervalSince(start), 0)
    }

    private static func percentText(_ value: Double) -> String {
        "\(String(format: "%.1f", value * 100))%"
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let wholeSeconds = max(Int(seconds.rounded()), 0)
        let minutes = wholeSeconds / 60
        let secondsRemainder = wholeSeconds % 60
        if minutes == 0 {
            return "\(secondsRemainder)s"
        }
        return "\(minutes)m \(secondsRemainder)s"
    }

    private static func dateText(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

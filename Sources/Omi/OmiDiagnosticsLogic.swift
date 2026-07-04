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
        var droppedSamples: Int
        var failedOpens: Int
        var malformed: Int

        init(
            ok: Int = 0,
            errors: Int = 0,
            gaps: Int = 0,
            outOfOrder: Int = 0,
            droppedSamples: Int = 0,
            failedOpens: Int = 0,
            malformed: Int = 0
        ) {
            self.ok = ok
            self.errors = errors
            self.gaps = gaps
            self.outOfOrder = outOfOrder
            self.droppedSamples = droppedSamples
            self.failedOpens = failedOpens
            self.malformed = malformed
        }

        enum CodingKeys: String, CodingKey {
            case ok
            case errors
            case gaps
            case outOfOrder
            case droppedSamples
            case failedOpens
            case malformed
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.ok = try container.decodeIfPresent(Int.self, forKey: .ok) ?? 0
            self.errors = try container.decodeIfPresent(Int.self, forKey: .errors) ?? 0
            self.gaps = try container.decodeIfPresent(Int.self, forKey: .gaps) ?? 0
            self.outOfOrder = try container.decodeIfPresent(Int.self, forKey: .outOfOrder) ?? 0
            self.droppedSamples = try container.decodeIfPresent(Int.self, forKey: .droppedSamples) ?? 0
            self.failedOpens = try container.decodeIfPresent(Int.self, forKey: .failedOpens) ?? 0
            self.malformed = try container.decodeIfPresent(Int.self, forKey: .malformed) ?? 0
        }
    }

    struct PendantBatterySample: Codable, Sendable, Equatable {
        var timestamp: Date
        var level: Int
        var rawByte: UInt8? = nil
    }

    struct SubscribeLatencySample: Codable, Sendable, Equatable {
        var timestamp: Date
        var latencySeconds: TimeInterval
        var appState: String
    }

    struct StorageBacklogSample: Codable, Sendable, Equatable {
        var timestamp: Date
        var usedBytes: UInt32
        var rawHex: String
        var fileCountUnconfirmed: UInt32
    }

    struct PendantRebootEvent: Codable, Sendable, Equatable {
        var observedAt: Date
        var epochBefore: UInt32
        var epochAfter: UInt32
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
        var connectedSilentForegroundSeconds: TimeInterval? = nil
        var connectedSilentBackgroundSeconds: TimeInterval? = nil
        var connectedSilentLockedSeconds: TimeInterval? = nil

        init(
            disconnectGapCount: Int = 0,
            disconnectGapSeconds: TimeInterval = 0,
            connectedSilentGapCount: Int = 0,
            connectedSilentGapSeconds: TimeInterval = 0,
            connectedSilentForegroundSeconds: TimeInterval? = nil,
            connectedSilentBackgroundSeconds: TimeInterval? = nil,
            connectedSilentLockedSeconds: TimeInterval? = nil
        ) {
            self.disconnectGapCount = disconnectGapCount
            self.disconnectGapSeconds = disconnectGapSeconds
            self.connectedSilentGapCount = connectedSilentGapCount
            self.connectedSilentGapSeconds = connectedSilentGapSeconds
            self.connectedSilentForegroundSeconds = connectedSilentForegroundSeconds
            self.connectedSilentBackgroundSeconds = connectedSilentBackgroundSeconds
            self.connectedSilentLockedSeconds = connectedSilentLockedSeconds
        }
    }

    static let currentVersion = 3

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
    var subscribeLatencySamples: [SubscribeLatencySample]? = nil
    var storageBacklogSamples: [StorageBacklogSample]? = nil
    var pendantRebootEvents: [PendantRebootEvent]? = nil
    var mtuAtConnect: Int? = nil
    var mtuAtSubscribeConfirm: Int? = nil
    var connectToFirstAudioSeconds: TimeInterval? = nil

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
        openConnectedSilentStartedAt: Date? = nil,
        subscribeLatencySamples: [SubscribeLatencySample]? = nil,
        storageBacklogSamples: [StorageBacklogSample]? = nil,
        pendantRebootEvents: [PendantRebootEvent]? = nil,
        mtuAtConnect: Int? = nil,
        mtuAtSubscribeConfirm: Int? = nil,
        connectToFirstAudioSeconds: TimeInterval? = nil
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
        self.subscribeLatencySamples = subscribeLatencySamples
        self.storageBacklogSamples = storageBacklogSamples
        self.pendantRebootEvents = pendantRebootEvents
        self.mtuAtConnect = mtuAtConnect
        self.mtuAtSubscribeConfirm = mtuAtSubscribeConfirm
        self.connectToFirstAudioSeconds = connectToFirstAudioSeconds
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

nonisolated struct SubscribeLatencyBreakdown: Equatable, Sendable {
    var sampleCount: Int
    var totalSeconds: TimeInterval
    var foregroundSeconds: TimeInterval
    var backgroundSeconds: TimeInterval
    var lockedSeconds: TimeInterval

    init(
        sampleCount: Int = 0,
        totalSeconds: TimeInterval = 0,
        foregroundSeconds: TimeInterval = 0,
        backgroundSeconds: TimeInterval = 0,
        lockedSeconds: TimeInterval = 0
    ) {
        self.sampleCount = sampleCount
        self.totalSeconds = totalSeconds
        self.foregroundSeconds = foregroundSeconds
        self.backgroundSeconds = backgroundSeconds
        self.lockedSeconds = lockedSeconds
    }
}

nonisolated struct StorageBacklogProjection: Equatable, Sendable {
    var startUsedBytes: UInt32
    var endUsedBytes: UInt32
    var growthBytes: Int64
    var timeToFullSeconds: TimeInterval?
    var fileCountUnconfirmed: UInt32
}

nonisolated enum OmiDiagnosticsLogic {
    static let connectedSilenceThreshold: TimeInterval = 30
    static let retainedMinuteSeriesSampleCount = 24 * 60
    static let retainedEventSeriesCount = OmiEventRing.capacity

    static func appStateBucket(
        applicationStateIsActive: Bool,
        isProtectedDataAvailable: Bool
    ) -> String {
        if applicationStateIsActive {
            return "foreground"
        }
        if !isProtectedDataAvailable {
            return "locked"
        }
        return "background"
    }

    static func decodeErrorRate(ok: Int, errors: Int) -> Double {
        let total = ok + errors
        guard total > 0 else {
            return 0
        }
        return Double(errors) / Double(total)
    }

    static func subscribeLatencyBreakdown(
        _ samples: [OmiDiagnosticsPayload.SubscribeLatencySample]
    ) -> SubscribeLatencyBreakdown {
        var breakdown = SubscribeLatencyBreakdown(sampleCount: samples.count)
        for sample in samples {
            let latency = max(sample.latencySeconds, 0)
            breakdown.totalSeconds += latency
            switch Self.normalizedAppState(sample.appState) {
            case "foreground":
                breakdown.foregroundSeconds += latency
            case "locked":
                breakdown.lockedSeconds += latency
            default:
                breakdown.backgroundSeconds += latency
            }
        }
        return breakdown
    }

    static func addingSilentAttribution(
        to tallies: OmiDiagnosticsPayload.GapTallies,
        elapsed: TimeInterval,
        appState: String
    ) -> OmiDiagnosticsPayload.GapTallies {
        let elapsed = max(elapsed, 0)
        guard elapsed > 0 else {
            return tallies
        }

        var updated = tallies
        switch Self.normalizedAppState(appState) {
        case "foreground":
            updated.connectedSilentForegroundSeconds = (updated.connectedSilentForegroundSeconds ?? 0) + elapsed
        case "locked":
            updated.connectedSilentLockedSeconds = (updated.connectedSilentLockedSeconds ?? 0) + elapsed
        default:
            updated.connectedSilentBackgroundSeconds = (updated.connectedSilentBackgroundSeconds ?? 0) + elapsed
        }
        return updated
    }

    static func disconnectWindowLines(
        events: [OmiDiagnosticsPayload.ReconnectEvent],
        capacity: Int,
        asOf date: Date
    ) -> [String] {
        guard !events.isEmpty else {
            return ["disconnect windows: none"]
        }

        var lines: [String] = []
        if capacity > 0, events.count == capacity {
            lines.append("disconnect windows: showing most recent \(capacity) retained disconnects")
        }

        for event in events {
            let endText: String
            if let latency = event.timeToReconnect {
                endText = Self.dateText(event.timestamp.addingTimeInterval(max(latency, 0)))
            } else {
                endText = "open"
            }
            lines.append(
                "disconnect window: [\(Self.dateText(event.timestamp)),\(endText)] reason: \(event.reason), app state: \(event.appStateAtDrop)"
            )
        }
        return lines
    }

    static func voicedSeconds(decodeOK: Int) -> TimeInterval {
        Double(max(decodeOK, 0)) * 0.02
    }

    static func storageBacklogProjection(
        samples: [OmiDiagnosticsPayload.StorageBacklogSample],
        capacityBytes: UInt32 = 480_000_000
    ) -> StorageBacklogProjection? {
        guard let first = samples.first, let last = samples.last else {
            return nil
        }

        let growth = Int64(last.usedBytes) - Int64(first.usedBytes)
        let elapsed = last.timestamp.timeIntervalSince(first.timestamp)
        let timeToFull: TimeInterval?
        if samples.count >= 2,
           growth > 0,
           elapsed > 0,
           last.usedBytes < capacityBytes
        {
            let bytesPerSecond = Double(growth) / elapsed
            let remaining = Double(capacityBytes - last.usedBytes)
            timeToFull = remaining / bytesPerSecond
        } else {
            timeToFull = nil
        }

        return StorageBacklogProjection(
            startUsedBytes: first.usedBytes,
            endUsedBytes: last.usedBytes,
            growthBytes: growth,
            timeToFullSeconds: timeToFull,
            fileCountUnconfirmed: last.fileCountUnconfirmed
        )
    }

    static func isPendantReboot(
        epochBefore: UInt32,
        epochAfter: UInt32,
        sentinel: UInt32 = 1_609_459_200,
        decreaseThreshold: UInt32 = 300
    ) -> Bool {
        if epochBefore >= sentinel, epochAfter < sentinel {
            return true
        }
        guard epochBefore > epochAfter else {
            return false
        }
        return epochBefore - epochAfter > decreaseThreshold
    }

    static func pendantRebootEvents(
        from observations: [(observedAt: Date, epoch: UInt32)]
    ) -> [OmiDiagnosticsPayload.PendantRebootEvent] {
        guard let first = observations.first else {
            return []
        }

        var baseline = first.epoch
        var events: [OmiDiagnosticsPayload.PendantRebootEvent] = []
        for observation in observations.dropFirst() {
            if Self.isPendantReboot(epochBefore: baseline, epochAfter: observation.epoch) {
                events.append(OmiDiagnosticsPayload.PendantRebootEvent(
                    observedAt: observation.observedAt,
                    epochBefore: baseline,
                    epochAfter: observation.epoch
                ))
                baseline = observation.epoch
            } else if observation.epoch > baseline {
                baseline = observation.epoch
            }
        }
        return events
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

    static func retainingMostRecent<Element>(_ values: [Element], limit: Int) -> [Element] {
        guard limit > 0, values.count > limit else {
            return values
        }
        return Array(values.suffix(limit))
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
            ("decode error rate", "\(String(format: "%.1f", decodeRate * 100))%"),
            ("audio gaps", "\(payload.decodeCounters.gaps)"),
            ("out of order frames", "\(payload.decodeCounters.outOfOrder)"),
            ("malformed audio packets", "\(payload.decodeCounters.malformed)"),
            ("dropped audio samples", "\(payload.decodeCounters.droppedSamples)"),
            ("audio file open failures", "\(payload.decodeCounters.failedOpens)")
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
        if payload.reconnectEvents.count == OmiEventRing.capacity {
            lines.append("reconnects: \(reconnects.count) (showing most recent \(OmiEventRing.capacity) retained — see disconnect gaps for full count)")
        } else {
            lines.append("reconnects: \(reconnects.count)")
        }
        lines.append("last reconnect: \(Self.lastReconnectText(reconnects))")
        lines.append("disconnect profile: \(Self.disconnectProfileText(payload.reconnectEvents))")
        lines.append("disconnect gaps: \(payload.gapTallies.disconnectGapCount), \(Self.durationText(disconnectGapSeconds))")
        lines.append("connected-without-audio gaps: \(payload.gapTallies.connectedSilentGapCount), \(Self.durationText(connectedSilentGapSeconds))")
        lines.append("decode error rate: \(Self.percentText(decodeRate))")
        lines.append("decode frames: \(payload.decodeCounters.ok) ok, \(payload.decodeCounters.errors) errors")
        lines.append("audio gaps: \(payload.decodeCounters.gaps)")
        lines.append("out of order frames: \(payload.decodeCounters.outOfOrder)")
        lines.append("malformed audio packets: \(payload.decodeCounters.malformed)")
        lines.append("dropped audio samples: \(payload.decodeCounters.droppedSamples)")
        lines.append("audio file open failures: \(payload.decodeCounters.failedOpens)")
        lines.append("pendant battery: \(Self.pendantBatteryText(payload.pendantBatteryTrend))")
        lines.append("pendant signal: \(Self.pendantSignalText(payload.pendantSignalTrend))")
        lines.append("phone battery: \(Self.phoneBatteryText(payload.phoneSamples))")
        lines.append("phone thermal state: \(payload.phoneSamples.last?.thermalState ?? "unknown")")
        lines.append(Self.subscribeLatencyText(
            payload.subscribeLatencySamples ?? [],
            reconnectCount: reconnects.count
        ))
        lines.append(Self.connectedSilentBucketsText(payload.gapTallies))
        lines.append(contentsOf: Self.disconnectWindowLines(
            events: payload.reconnectEvents,
            capacity: OmiEventRing.capacity,
            asOf: date
        ))
        lines.append("voiced-seconds received live: \(Self.secondsText(Self.voicedSeconds(decodeOK: payload.decodeCounters.ok))) voiced")
        lines.append("recovery note: SD fills disconnect windows with voiced-only audio, so recovered audio is <= wall-clock.")
        lines.append("silence note: connected-without-audio may be VAD silence, not loss; silence is never quantified as loss.")
        lines.append(Self.storageBacklogText(payload.storageBacklogSamples ?? []))
        lines.append("supporting readings: raw millivolts are not exposed over BLE on 3.0.19")
        lines.append(Self.rebootText(payload.pendantRebootEvents ?? []))
        lines.append(Self.supportingReadingsText(payload))

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

    private static func subscribeLatencyText(
        _ samples: [OmiDiagnosticsPayload.SubscribeLatencySample],
        reconnectCount: Int
    ) -> String {
        guard !samples.isEmpty else {
            return "unrecoverable connect-to-subscribe: unavailable (no subscribe-confirm samples)"
        }

        let breakdown = Self.subscribeLatencyBreakdown(samples)
        return "unrecoverable connect-to-subscribe: \(Self.secondsText(breakdown.totalSeconds)) total not on SD / unrecoverable (foreground \(Self.secondsText(breakdown.foregroundSeconds)), background \(Self.secondsText(breakdown.backgroundSeconds)), locked \(Self.secondsText(breakdown.lockedSeconds)), \(breakdown.sampleCount) samples across \(reconnectCount) reconnects — unconfirmed reconnects not measured (foreground floor))"
    }

    private static func connectedSilentBucketsText(_ tallies: OmiDiagnosticsPayload.GapTallies) -> String {
        "connected-without-audio buckets: foreground \(Self.durationText(tallies.connectedSilentForegroundSeconds ?? 0)), background \(Self.durationText(tallies.connectedSilentBackgroundSeconds ?? 0)), locked \(Self.durationText(tallies.connectedSilentLockedSeconds ?? 0)) (foreground-sampled; background under-counted)"
    }

    private static func storageBacklogText(_ samples: [OmiDiagnosticsPayload.StorageBacklogSample]) -> String {
        guard let projection = Self.storageBacklogProjection(samples: samples) else {
            return "storage backlog: unavailable (characteristic never read)"
        }

        let timeToFull = projection.timeToFullSeconds.map(Self.durationText) ?? "unavailable"
        return "storage backlog: \(projection.startUsedBytes)->\(projection.endUsedBytes) bytes, growth \(projection.growthBytes), time-to-full projection \(timeToFull), files \(projection.fileCountUnconfirmed) (layout-unconfirmed)"
    }

    private static func rebootText(_ events: [OmiDiagnosticsPayload.PendantRebootEvent]) -> String {
        let times = events.isEmpty
            ? "none"
            : events.map { Self.dateText($0.observedAt) }.joined(separator: ", ")
        return "supporting readings: reboot count \(events.count), times \(times)"
    }

    private static func supportingReadingsText(_ payload: OmiDiagnosticsPayload) -> String {
        let mtuConnect = payload.mtuAtConnect.map(String.init) ?? "unknown"
        let mtuSubscribe = payload.mtuAtSubscribeConfirm.map(String.init) ?? "unknown"
        let firstAudio = payload.connectToFirstAudioSeconds.map(Self.secondsText) ?? "unknown"
        return "supporting readings: mtu connect \(mtuConnect), mtu subscribe-confirm \(mtuSubscribe), connect-to-first-audio \(firstAudio)"
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

    private static func secondsText(_ seconds: TimeInterval) -> String {
        "\(String(format: "%.2f", max(seconds, 0)))s"
    }

    private static func dateText(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func normalizedAppState(_ appState: String) -> String {
        switch appState {
        case "foreground", "locked":
            return appState
        default:
            return "background"
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import UIKit
import os

nonisolated protocol OmiDiagnosticsPersistenceSink: Sendable {
    func write(_ data: Data) throws
}

nonisolated struct FileOmiDiagnosticsPersistenceSink: OmiDiagnosticsPersistenceSink {
    let fileURL: URL

    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: self.fileURL, options: [.atomic])
    }
}

@MainActor
@Observable
final class OmiDiagnostics {
    nonisolated static var defaultFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("solstone", isDirectory: true)
            .appendingPathComponent("omi-diagnostics.json")
    }

    private static let exportFileName = "omi-diagnostics.txt"

    private(set) var payload: OmiDiagnosticsPayload

    @ObservationIgnored private let clock: any ObserverClock
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let persistenceSink: any OmiDiagnosticsPersistenceSink
    @ObservationIgnored private let log = Logger(subsystem: "app.solstone.swift", category: "omi-diagnostics")
    @ObservationIgnored private var decodeLastSeen = OmiDiagnosticsPayload.DecodeCounters()
    @ObservationIgnored private var coalescingDepth = 0
    @ObservationIgnored private var hasCoalescedChanges = false
    @ObservationIgnored private var didLogReconnectDeltaCap = false
    @ObservationIgnored private var didLogSubscribeDeltaCap = false

    init(
        clock: any ObserverClock = SystemObserverClock(),
        fileURL: URL = OmiDiagnostics.defaultFileURL,
        persistenceSink: (any OmiDiagnosticsPersistenceSink)? = nil,
        processID: UUID = UUID(),
        processStartedAt: Date? = nil
    ) {
        self.clock = clock
        self.fileURL = fileURL
        self.persistenceSink = persistenceSink ?? FileOmiDiagnosticsPersistenceSink(fileURL: fileURL)
        let startedAt = processStartedAt ?? clock.now()
        var payload = (try? Self.loadPayload(from: fileURL)) ?? OmiDiagnosticsPayload()
        let preservesSequence = payload.processID == processID && payload.processStartedAt == startedAt
        payload.processID = processID
        payload.processStartedAt = startedAt
        if !preservesSequence {
            payload.nextSequence = 0
        }
        self.payload = payload
        if !preservesSequence {
            self.persist()
        }
    }

    func beginCoalescing() {
        self.coalescingDepth += 1
    }

    func endCoalescing() {
        guard self.coalescingDepth > 0 else {
            return
        }
        self.coalescingDepth -= 1
        guard self.coalescingDepth == 0, self.hasCoalescedChanges else {
            return
        }
        self.hasCoalescedChanges = false
        self.persist()
    }

    func recordConnected() {
        let now = self.clock.now()
        self.ensureFirstObserved(at: now)
        self.closeOpenDisconnectGap(at: now)
        self.closeOpenConnectedSilentGap(at: now)
        var uptime = self.payload.uptime.accumulator
        uptime.noteConnected(at: now)
        self.payload.uptime = OmiDiagnosticsPayload.UptimeSnapshot(uptime)
        self.persist()
    }

    func allocateEventIdentity() -> OmiEventIdentity {
        guard let processID = self.payload.processID else {
            preconditionFailure("omi diagnostics process anchor unavailable")
        }
        let sequence = self.payload.nextSequence ?? 0
        self.payload.nextSequence = sequence + 1
        self.persist()
        return OmiEventIdentity(processID: processID, sequence: sequence)
    }

    @discardableResult
    func recordDisconnected(event: OmiSourceEvent) -> OmiEventIdentity {
        let identity = event.identity ?? self.allocateEventIdentity()
        let persistedEvent = OmiDiagnosticsPayload.ReconnectEvent(
            timestamp: event.timestamp,
            reason: event.reason,
            appStateAtDrop: event.appStateAtDrop,
            timeToReconnect: event.timeToReconnect,
            processID: identity.processID,
            sequence: identity.sequence,
            revision: event.revision
        )
        self.ensureFirstObserved(at: event.timestamp)
        self.closeOpenConnectedSilentGap(at: event.timestamp)
        var uptime = self.payload.uptime.accumulator
        uptime.noteDisconnected(at: event.timestamp)
        self.payload.uptime = OmiDiagnosticsPayload.UptimeSnapshot(uptime)
        self.payload.reconnectEvents.append(persistedEvent)
        if self.payload.reconnectEvents.count > OmiEventRing.capacity {
            self.payload.reconnectEvents.removeFirst(self.payload.reconnectEvents.count - OmiEventRing.capacity)
        }
        if self.payload.openDisconnectStartedAt == nil {
            self.payload.gapTallies.disconnectGapCount += 1
            self.payload.openDisconnectStartedAt = event.timestamp
        }
        self.appendUnhandedReconnect(persistedEvent)
        self.persist()
        return identity
    }

    func recordReconnect(identity: OmiEventIdentity, latency: TimeInterval) {
        Self.completeReconnect(
            in: &self.payload.reconnectEvents,
            identity: identity,
            latency: latency
        )
        var unhanded = self.payload.unhandedReconnectEvents ?? []
        Self.completeReconnect(in: &unhanded, identity: identity, latency: latency)
        self.payload.unhandedReconnectEvents = unhanded.isEmpty ? nil : unhanded
        self.persist()
    }

    func recordBattery(level: Int, at date: Date, rawByte: UInt8? = nil) {
        self.ensureFirstObserved(at: date)
        self.payload.pendantBatteryTrend.append(OmiDiagnosticsPayload.PendantBatterySample(
            timestamp: date,
            level: level,
            rawByte: rawByte
        ))
        self.payload.pendantBatteryTrend = OmiDiagnosticsLogic.retainingMostRecent(
            self.payload.pendantBatteryTrend,
            limit: OmiDiagnosticsLogic.retainedMinuteSeriesSampleCount
        )
        self.persist()
    }

    func recordSignal(level: Int, at date: Date) {
        self.ensureFirstObserved(at: date)
        var samples = self.payload.pendantSignalTrend ?? []
        samples.append(OmiDiagnosticsPayload.PendantSignalSample(
            timestamp: date,
            level: level
        ))
        self.payload.pendantSignalTrend = OmiDiagnosticsLogic.retainingMostRecent(
            samples,
            limit: OmiDiagnosticsLogic.retainedMinuteSeriesSampleCount
        )
        self.persist()
    }

    func beginSubscribe(identity: OmiEventIdentity, connectedAt: Date, appState: String) {
        self.ensureFirstObserved(at: connectedAt)
        self.appendUnhandedSubscribe(OmiDiagnosticsPayload.SubscribeLatencySample(
            timestamp: connectedAt,
            latencySeconds: 0,
            appState: appState,
            connectedAt: connectedAt,
            processID: identity.processID,
            sequence: identity.sequence,
            revision: 1
        ))
        self.persist()
    }

    func completeSubscribe(
        identity: OmiEventIdentity,
        connectedAt: Date,
        subscribedAt: Date,
        latencySeconds: TimeInterval,
        appState: String
    ) {
        self.ensureFirstObserved(at: subscribedAt)
        let completed = OmiDiagnosticsPayload.SubscribeLatencySample(
            timestamp: subscribedAt,
            latencySeconds: latencySeconds,
            appState: appState,
            connectedAt: connectedAt,
            processID: identity.processID,
            sequence: identity.sequence,
            revision: 2
        )
        var samples = self.payload.subscribeLatencySamples ?? []
        samples.append(completed)
        self.payload.subscribeLatencySamples = OmiDiagnosticsLogic.retainingMostRecent(
            samples,
            limit: OmiDiagnosticsLogic.retainedEventSeriesCount
        )
        var unhanded = self.payload.unhandedSubscribeLatencySamples ?? []
        if let index = unhanded.indices.first(where: { Self.matches(unhanded[$0], identity: identity) }) {
            unhanded[index] = completed
        } else {
            self.appendUnhandedSubscribe(completed, to: &unhanded)
        }
        self.payload.unhandedSubscribeLatencySamples = unhanded.isEmpty ? nil : unhanded
        self.persist()
    }

    func frozenSegmentDeltas() -> (
        reconnectEvents: [OmiDiagnosticsPayload.ReconnectEvent],
        subscribeSamples: [OmiDiagnosticsPayload.SubscribeLatencySample],
        tokens: [OmiSegmentMetadataToken]
    ) {
        let reconnectEvents = self.payload.unhandedReconnectEvents ?? []
        let subscribeSamples = self.payload.unhandedSubscribeLatencySamples ?? []
        let reconnectTokens: [OmiSegmentMetadataToken] = reconnectEvents.compactMap { event -> OmiSegmentMetadataToken? in
            guard let processID = event.processID,
                  let sequence = event.sequence,
                  let revision = event.revision
            else { return nil }
            return OmiSegmentMetadataToken(
                kind: .reconnect,
                processID: processID,
                sequence: sequence,
                revision: revision
            )
        }
        let subscribeTokens: [OmiSegmentMetadataToken] = subscribeSamples.compactMap { sample -> OmiSegmentMetadataToken? in
            guard let processID = sample.processID,
                  let sequence = sample.sequence,
                  let revision = sample.revision
            else { return nil }
            return OmiSegmentMetadataToken(
                kind: .subscribe,
                processID: processID,
                sequence: sequence,
                revision: revision
            )
        }
        return (reconnectEvents, subscribeSamples, reconnectTokens + subscribeTokens)
    }

    func acknowledgeSegmentMetadata(tokens: [OmiSegmentMetadataToken]) {
        guard !tokens.isEmpty else { return }
        let reconnectTokens = tokens.filter { $0.kind == .reconnect }
        let subscribeTokens = tokens.filter { $0.kind == .subscribe }
        self.payload.unhandedReconnectEvents = self.removingAcknowledged(
            self.payload.unhandedReconnectEvents ?? [],
            tokens: reconnectTokens
        )
        self.payload.unhandedSubscribeLatencySamples = self.removingAcknowledged(
            self.payload.unhandedSubscribeLatencySamples ?? [],
            tokens: subscribeTokens
        )
        self.persist()
    }

    func attributeConnectedSilentSeconds(elapsed: TimeInterval, appState: String) {
        self.payload.gapTallies = OmiDiagnosticsLogic.addingSilentAttribution(
            to: self.payload.gapTallies,
            elapsed: elapsed,
            appState: appState
        )
        self.persist()
    }

    func appendStorageBacklogSample(
        timestamp: Date,
        usedBytes: UInt32,
        rawHex: String,
        fileCountUnconfirmed: UInt32
    ) {
        self.ensureFirstObserved(at: timestamp)
        var samples = self.payload.storageBacklogSamples ?? []
        samples.append(OmiDiagnosticsPayload.StorageBacklogSample(
            timestamp: timestamp,
            usedBytes: usedBytes,
            rawHex: rawHex,
            fileCountUnconfirmed: fileCountUnconfirmed
        ))
        self.payload.storageBacklogSamples = OmiDiagnosticsLogic.retainingMostRecent(
            samples,
            limit: OmiDiagnosticsLogic.retainedMinuteSeriesSampleCount
        )
        self.persist()
    }

    func appendPendantRebootEvent(
        observedAt: Date,
        epochBefore: UInt32,
        epochAfter: UInt32
    ) {
        self.ensureFirstObserved(at: observedAt)
        var events = self.payload.pendantRebootEvents ?? []
        events.append(OmiDiagnosticsPayload.PendantRebootEvent(
            observedAt: observedAt,
            epochBefore: epochBefore,
            epochAfter: epochAfter
        ))
        self.payload.pendantRebootEvents = OmiDiagnosticsLogic.retainingMostRecent(
            events,
            limit: OmiDiagnosticsLogic.retainedEventSeriesCount
        )
        self.persist()
    }

    func clearPerConnectionPointReadingsForNewConnection() {
        self.payload.mtuAtSubscribeConfirm = nil
        self.payload.connectToFirstAudioSeconds = nil
    }

    func setMTUAtConnect(_ value: Int?) {
        self.payload.mtuAtConnect = value
        self.persist()
    }

    func setMTUAtSubscribeConfirm(_ value: Int?) {
        self.payload.mtuAtSubscribeConfirm = value
        self.persist()
    }

    func setConnectToFirstAudioSeconds(_ value: TimeInterval?) {
        self.payload.connectToFirstAudioSeconds = value
        self.persist()
    }

    func noteDecodedSamples(at date: Date) {
        self.ensureFirstObserved(at: date)
        self.payload.lastDecodedSampleAt = date
        self.closeOpenConnectedSilentGap(at: date)
    }

    func updateDecodeCounters(
        ok: Int,
        errors: Int,
        gaps: Int,
        outOfOrder: Int,
        malformed: Int,
        droppedSamples: Int,
        failedOpens: Int
    ) {
        let current = self.payload.decodeCounters
        let lastSeen = self.decodeLastSeen
        let okAcc = OmiDiagnosticsLogic.accumulatedCounter(
            lifetime: current.ok,
            lastSeen: lastSeen.ok,
            incoming: ok
        )
        let errorsAcc = OmiDiagnosticsLogic.accumulatedCounter(
            lifetime: current.errors,
            lastSeen: lastSeen.errors,
            incoming: errors
        )
        let gapsAcc = OmiDiagnosticsLogic.accumulatedCounter(
            lifetime: current.gaps,
            lastSeen: lastSeen.gaps,
            incoming: gaps
        )
        let outOfOrderAcc = OmiDiagnosticsLogic.accumulatedCounter(
            lifetime: current.outOfOrder,
            lastSeen: lastSeen.outOfOrder,
            incoming: outOfOrder
        )
        let malformedAcc = OmiDiagnosticsLogic.accumulatedCounter(
            lifetime: current.malformed,
            lastSeen: lastSeen.malformed,
            incoming: malformed
        )
        let droppedSamplesAcc = OmiDiagnosticsLogic.accumulatedCounter(
            lifetime: current.droppedSamples,
            lastSeen: lastSeen.droppedSamples,
            incoming: droppedSamples
        )
        let failedOpensAcc = OmiDiagnosticsLogic.accumulatedCounter(
            lifetime: current.failedOpens,
            lastSeen: lastSeen.failedOpens,
            incoming: failedOpens
        )

        self.payload.decodeCounters = OmiDiagnosticsPayload.DecodeCounters(
            ok: okAcc.lifetime,
            errors: errorsAcc.lifetime,
            gaps: gapsAcc.lifetime,
            outOfOrder: outOfOrderAcc.lifetime,
            droppedSamples: droppedSamplesAcc.lifetime,
            failedOpens: failedOpensAcc.lifetime,
            malformed: malformedAcc.lifetime
        )
        self.decodeLastSeen = OmiDiagnosticsPayload.DecodeCounters(
            ok: okAcc.lastSeen,
            errors: errorsAcc.lastSeen,
            gaps: gapsAcc.lastSeen,
            outOfOrder: outOfOrderAcc.lastSeen,
            droppedSamples: droppedSamplesAcc.lastSeen,
            failedOpens: failedOpensAcc.lastSeen,
            malformed: malformedAcc.lastSeen
        )
    }

    func recordDecodeCounters(
        ok: Int,
        errors: Int,
        gaps: Int,
        outOfOrder: Int,
        malformed: Int,
        droppedSamples: Int,
        failedOpens: Int
    ) {
        self.updateDecodeCounters(
            ok: ok,
            errors: errors,
            gaps: gaps,
            outOfOrder: outOfOrder,
            malformed: malformed,
            droppedSamples: droppedSamples,
            failedOpens: failedOpens
        )
        self.persist()
    }

    func recordPhoneSample() {
        let now = self.clock.now()
        self.ensureFirstObserved(at: now)
        self.updateOpenConnectedSilentGap(asOf: now)
        let rawBatteryLevel = UIDevice.current.batteryLevel
        self.payload.phoneSamples.append(OmiDiagnosticsPayload.PhoneSample(
            timestamp: now,
            batteryLevel: rawBatteryLevel >= 0 ? Double(rawBatteryLevel) : nil,
            thermalState: thermalStateString(ProcessInfo.processInfo.thermalState),
            batteryState: Self.batteryStateString(UIDevice.current.batteryState)
        ))
        self.payload.phoneSamples = OmiDiagnosticsLogic.retainingMostRecent(
            self.payload.phoneSamples,
            limit: OmiDiagnosticsLogic.retainedMinuteSeriesSampleCount
        )
        self.persist()
    }

    func persist() {
        do {
            guard self.coalescingDepth == 0 else {
                self.hasCoalescedChanges = true
                return
            }
            self.payload.version = OmiDiagnosticsPayload.currentVersion
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(self.payload)
            try self.persistenceSink.write(data)
        } catch {
            self.log.error("omi diagnostics write failed: \(String(describing: error), privacy: .public)")
        }
    }

    func exportFileURL() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.exportFileName, isDirectory: false)
        do {
            let report = OmiDiagnosticsLogic.exportSummary(
                payload: self.payload,
                asOf: self.clock.now()
            )
            try Data(report.utf8).write(to: url, options: [.atomic])
            return url
        } catch {
            self.log.error("omi diagnostics export failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

private extension OmiDiagnostics {
    static func matches(
        _ event: OmiDiagnosticsPayload.ReconnectEvent,
        identity: OmiEventIdentity
    ) -> Bool {
        event.processID == identity.processID && event.sequence == identity.sequence
    }

    static func matches(
        _ sample: OmiDiagnosticsPayload.SubscribeLatencySample,
        identity: OmiEventIdentity
    ) -> Bool {
        sample.processID == identity.processID && sample.sequence == identity.sequence
    }

    static func completeReconnect(
        in events: inout [OmiDiagnosticsPayload.ReconnectEvent],
        identity: OmiEventIdentity,
        latency: TimeInterval
    ) {
        guard let index = events.indices.first(where: { Self.matches(events[$0], identity: identity) }) else {
            return
        }
        events[index].timeToReconnect = latency
        events[index].revision = (events[index].revision ?? 1) + 1
    }

    func appendUnhandedReconnect(_ event: OmiDiagnosticsPayload.ReconnectEvent) {
        var events = self.payload.unhandedReconnectEvents ?? []
        events.append(event)
        if events.count > OmiEventRing.capacity {
            let dropped = events.count - OmiEventRing.capacity
            events.removeFirst(dropped)
            if !self.didLogReconnectDeltaCap {
                self.didLogReconnectDeltaCap = true
                self.log.error("omi segment reconnect delta cap reached dropped=\(dropped, privacy: .public)")
            }
        }
        self.payload.unhandedReconnectEvents = events
    }

    func appendUnhandedSubscribe(_ sample: OmiDiagnosticsPayload.SubscribeLatencySample) {
        var samples = self.payload.unhandedSubscribeLatencySamples ?? []
        self.appendUnhandedSubscribe(sample, to: &samples)
        self.payload.unhandedSubscribeLatencySamples = samples
    }

    func appendUnhandedSubscribe(
        _ sample: OmiDiagnosticsPayload.SubscribeLatencySample,
        to samples: inout [OmiDiagnosticsPayload.SubscribeLatencySample]
    ) {
        samples.append(sample)
        if samples.count > OmiEventRing.capacity {
            let dropped = samples.count - OmiEventRing.capacity
            samples.removeFirst(dropped)
            if !self.didLogSubscribeDeltaCap {
                self.didLogSubscribeDeltaCap = true
                self.log.error("omi segment subscribe delta cap reached dropped=\(dropped, privacy: .public)")
            }
        }
    }

    func removingAcknowledged(
        _ events: [OmiDiagnosticsPayload.ReconnectEvent],
        tokens: [OmiSegmentMetadataToken]
    ) -> [OmiDiagnosticsPayload.ReconnectEvent]? {
        let retained = events.filter { event in
            !tokens.contains {
                $0.processID == event.processID
                    && $0.sequence == event.sequence
                    && $0.revision == event.revision
            }
        }
        return retained.isEmpty ? nil : retained
    }

    func removingAcknowledged(
        _ samples: [OmiDiagnosticsPayload.SubscribeLatencySample],
        tokens: [OmiSegmentMetadataToken]
    ) -> [OmiDiagnosticsPayload.SubscribeLatencySample]? {
        let retained = samples.filter { sample in
            !tokens.contains {
                $0.processID == sample.processID
                    && $0.sequence == sample.sequence
                    && $0.revision == sample.revision
            }
        }
        return retained.isEmpty ? nil : retained
    }

    static func loadPayload(from fileURL: URL) throws -> OmiDiagnosticsPayload {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OmiDiagnosticsPayload.self, from: data)
    }

    static func batteryStateString(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown:
            "unknown"
        case .unplugged:
            "unplugged"
        case .charging:
            "charging"
        case .full:
            "full"
        @unknown default:
            "unknown"
        }
    }

    func ensureFirstObserved(at date: Date) {
        if self.payload.firstObservedAt == nil {
            self.payload.firstObservedAt = date
        }
    }

    func closeOpenDisconnectGap(at date: Date) {
        guard let start = self.payload.openDisconnectStartedAt else {
            return
        }
        self.payload.gapTallies.disconnectGapSeconds += max(date.timeIntervalSince(start), 0)
        self.payload.openDisconnectStartedAt = nil
    }

    func closeOpenConnectedSilentGap(at date: Date) {
        guard let start = self.payload.openConnectedSilentStartedAt else {
            return
        }
        self.payload.gapTallies.connectedSilentGapSeconds += max(date.timeIntervalSince(start), 0)
        self.payload.openConnectedSilentStartedAt = nil
    }

    func updateOpenConnectedSilentGap(asOf date: Date) {
        guard let connectedSince = self.payload.uptime.connectedSince else {
            self.closeOpenConnectedSilentGap(at: date)
            return
        }

        let lastAudioAt = self.payload.lastDecodedSampleAt.map { max($0, connectedSince) } ?? connectedSince
        let thresholdDate = lastAudioAt.addingTimeInterval(OmiDiagnosticsLogic.connectedSilenceThreshold)
        guard date > thresholdDate else {
            return
        }

        if self.payload.openConnectedSilentStartedAt == nil {
            self.payload.gapTallies.connectedSilentGapCount += 1
            self.payload.openConnectedSilentStartedAt = thresholdDate
        }
    }
}

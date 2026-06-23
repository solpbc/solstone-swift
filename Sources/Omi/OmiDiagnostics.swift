// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import UIKit
import os

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
    @ObservationIgnored private let log = Logger(subsystem: "app.solstone.swift", category: "omi-diagnostics")
    @ObservationIgnored private var decodeLastSeen = OmiDiagnosticsPayload.DecodeCounters()

    init(
        clock: any ObserverClock = SystemObserverClock(),
        fileURL: URL = OmiDiagnostics.defaultFileURL
    ) {
        self.clock = clock
        self.fileURL = fileURL
        self.payload = (try? Self.loadPayload(from: fileURL)) ?? OmiDiagnosticsPayload()
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

    func recordDisconnected(event: OmiSourceEvent) {
        self.ensureFirstObserved(at: event.timestamp)
        self.closeOpenConnectedSilentGap(at: event.timestamp)
        var uptime = self.payload.uptime.accumulator
        uptime.noteDisconnected(at: event.timestamp)
        self.payload.uptime = OmiDiagnosticsPayload.UptimeSnapshot(uptime)
        self.payload.reconnectEvents.append(OmiDiagnosticsPayload.ReconnectEvent(event))
        if self.payload.reconnectEvents.count > OmiEventRing.capacity {
            self.payload.reconnectEvents.removeFirst(self.payload.reconnectEvents.count - OmiEventRing.capacity)
        }
        if self.payload.openDisconnectStartedAt == nil {
            self.payload.gapTallies.disconnectGapCount += 1
            self.payload.openDisconnectStartedAt = event.timestamp
        }
        self.persist()
    }

    func recordReconnect(latency: TimeInterval) {
        guard let index = self.payload.reconnectEvents.indices.reversed().first(where: {
            self.payload.reconnectEvents[$0].timeToReconnect == nil
        }) else {
            self.persist()
            return
        }
        self.payload.reconnectEvents[index].timeToReconnect = latency
        self.persist()
    }

    func recordBattery(level: Int, at date: Date) {
        self.ensureFirstObserved(at: date)
        self.payload.pendantBatteryTrend.append(OmiDiagnosticsPayload.PendantBatterySample(
            timestamp: date,
            level: level
        ))
        self.persist()
    }

    func recordSignal(level: Int, at date: Date) {
        self.ensureFirstObserved(at: date)
        var samples = self.payload.pendantSignalTrend ?? []
        samples.append(OmiDiagnosticsPayload.PendantSignalSample(
            timestamp: date,
            level: level
        ))
        self.payload.pendantSignalTrend = samples
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
        outOfOrder: Int
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

        self.payload.decodeCounters = OmiDiagnosticsPayload.DecodeCounters(
            ok: okAcc.lifetime,
            errors: errorsAcc.lifetime,
            gaps: gapsAcc.lifetime,
            outOfOrder: outOfOrderAcc.lifetime
        )
        self.decodeLastSeen = OmiDiagnosticsPayload.DecodeCounters(
            ok: okAcc.lastSeen,
            errors: errorsAcc.lastSeen,
            gaps: gapsAcc.lastSeen,
            outOfOrder: outOfOrderAcc.lastSeen
        )
    }

    func recordPhoneSample() {
        let now = self.clock.now()
        self.ensureFirstObserved(at: now)
        self.updateOpenConnectedSilentGap(asOf: now)
        let rawBatteryLevel = UIDevice.current.batteryLevel
        self.payload.phoneSamples.append(OmiDiagnosticsPayload.PhoneSample(
            timestamp: now,
            batteryLevel: rawBatteryLevel >= 0 ? Double(rawBatteryLevel) : nil,
            thermalState: Self.thermalStateString(ProcessInfo.processInfo.thermalState),
            batteryState: Self.batteryStateString(UIDevice.current.batteryState)
        ))
        self.persist()
    }

    func persist() {
        do {
            try FileManager.default.createDirectory(
                at: self.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(self.payload)
            try data.write(to: self.fileURL, options: [.atomic])
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
    static func loadPayload(from fileURL: URL) throws -> OmiDiagnosticsPayload {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OmiDiagnosticsPayload.self, from: data)
    }

    static func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            "nominal"
        case .fair:
            "fair"
        case .serious:
            "serious"
        case .critical:
            "critical"
        @unknown default:
            "unknown"
        }
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

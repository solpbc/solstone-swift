// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@preconcurrency import CoreBluetooth
import Foundation

nonisolated enum OmiSourceState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case needsAttention(OmiAttention)

    var displayString: String {
        switch self {
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .connected:
            "connected"
        case .reconnecting:
            "reconnecting"
        case .needsAttention(let attention):
            "needs attention: \(attention.displayString)"
        }
    }
}

nonisolated enum OmiAttention: Equatable, Sendable {
    case bluetoothOff
    case unauthorized
    case unsupported
    case pendantNotFound
    case connectFailed(String)
    case codecNotOpus
    case audioUnavailable

    var displayString: String {
        switch self {
        case .bluetoothOff:
            "bluetooth off"
        case .unauthorized:
            "bluetooth permission needed"
        case .unsupported:
            "bluetooth unsupported"
        case .pendantNotFound:
            "omi pendant not found"
        case .connectFailed(let reason):
            "connection failed: \(reason)"
        case .codecNotOpus:
            "audio codec unsupported"
        case .audioUnavailable:
            "audio unavailable"
        }
    }
}

nonisolated enum OmiReconnectDecision: Equatable, Sendable {
    case stayDisconnected
    case systemReconnecting
    case rearmConnect
}

nonisolated enum OmiRestoreAction: Equatable, Sendable {
    case rearmConnect
    case discoverServices
    case readCodec
    case needsAttention(OmiAttention)
    case subscribeAudio
    case alreadyLive
}

nonisolated struct OmiUptimeAccumulator: Equatable, Sendable {
    private(set) var connectedSince: Date?
    private(set) var accumulatedConnectedSeconds: TimeInterval

    init(
        connectedSince: Date? = nil,
        accumulatedConnectedSeconds: TimeInterval = 0
    ) {
        self.connectedSince = connectedSince
        self.accumulatedConnectedSeconds = accumulatedConnectedSeconds
    }

    mutating func noteConnected(at date: Date) {
        guard self.connectedSince == nil else {
            return
        }
        self.connectedSince = date
    }

    mutating func noteDisconnected(at date: Date) {
        guard let connectedSince else {
            return
        }
        self.accumulatedConnectedSeconds += max(date.timeIntervalSince(connectedSince), 0)
        self.connectedSince = nil
    }

    func connectedSeconds(asOf now: Date) -> TimeInterval {
        guard let connectedSince else {
            return self.accumulatedConnectedSeconds
        }
        return self.accumulatedConnectedSeconds + max(now.timeIntervalSince(connectedSince), 0)
    }

    func connectedFraction(since start: Date, asOf now: Date) -> Double? {
        let wallClockSeconds = max(now.timeIntervalSince(start), 0)
        guard wallClockSeconds > 0 else {
            return nil
        }
        return self.connectedSeconds(asOf: now) / wallClockSeconds
    }
}

nonisolated struct OmiSourceEvent: Equatable, Sendable {
    let timestamp: Date
    let reason: String
    let appStateAtDrop: String
    let timeToReconnect: TimeInterval?
    let identity: OmiEventIdentity?
    let revision: Int

    init(
        timestamp: Date,
        reason: String,
        appStateAtDrop: String,
        timeToReconnect: TimeInterval?,
        identity: OmiEventIdentity? = nil,
        revision: Int = 1
    ) {
        self.timestamp = timestamp
        self.reason = reason
        self.appStateAtDrop = appStateAtDrop
        self.timeToReconnect = timeToReconnect
        self.identity = identity
        self.revision = revision
    }
}

nonisolated struct OmiEventRing: Equatable, Sendable {
    static let capacity = 50

    private(set) var events: [OmiSourceEvent]

    init(events: [OmiSourceEvent] = []) {
        self.events = []
        for event in events {
            self.append(event)
        }
    }

    mutating func append(_ event: OmiSourceEvent) {
        self.events.append(event)
        if self.events.count > Self.capacity {
            self.events.removeFirst(self.events.count - Self.capacity)
        }
    }

    mutating func completeReconnect(identity: OmiEventIdentity, timeToReconnect: TimeInterval) {
        guard let index = self.events.indices.first(where: { self.events[$0].identity == identity }) else {
            return
        }
        let event = self.events[index]
        self.events[index] = OmiSourceEvent(
            timestamp: event.timestamp,
            reason: event.reason,
            appStateAtDrop: event.appStateAtDrop,
            timeToReconnect: timeToReconnect,
            identity: event.identity,
            revision: event.revision + 1
        )
    }
}

nonisolated struct OmiAudioCounterSnapshot: Equatable, Sendable {
    let packets: Int
    let frames: Int
    let gaps: Int
    let outOfOrder: Int
    let malformed: Int
    let markers: Int
    let decodeOK: Int
    let decodeErrors: Int
}

nonisolated struct TimedReading<Value: Sendable & Equatable>: Equatable, Sendable {
    var value: Value
    var at: Date
}

nonisolated enum OmiReadingFallback: Equatable, Sendable {
    case notRead
    case unknown
}

nonisolated enum OmiSurfacedReading<Value: Sendable & Equatable>: Equatable, Sendable {
    case live(Value)
    case lastKnown(value: Value, at: Date)
    case missing(OmiReadingFallback)
}

nonisolated enum OmiAudioHealth: Equatable, Sendable {
    case receiving
    case silentWhileConnected(since: Date)
    case idle
}

nonisolated enum OmiSourceLogic {
    static func segmentConnectionState(_ state: OmiSourceState) -> String {
        switch state {
        case .connected:
            "connected"
        case .connecting, .reconnecting:
            "reconnecting"
        case .disconnected, .needsAttention:
            "disconnected"
        }
    }

    static let audioSilenceAttentionWindow: TimeInterval = 5 * 60
    // Reconnect misses are harder failures than quiet subscribed audio, so surface them sooner.
    static let reconnectAttentionDeadline: TimeInterval = 2 * 60

    static func reconnectDecision(
        isManualDisconnect: Bool,
        isReconnecting: Bool
    ) -> OmiReconnectDecision {
        if isManualDisconnect {
            return .stayDisconnected
        }
        if isReconnecting {
            return .systemReconnecting
        }
        return .rearmConnect
    }

    static func attention(for managerState: CBManagerState) -> OmiAttention? {
        switch managerState {
        case .poweredOn:
            nil
        case .poweredOff:
            .bluetoothOff
        case .unauthorized:
            .unauthorized
        case .unsupported:
            .unsupported
        case .unknown, .resetting:
            nil
        @unknown default:
            nil
        }
    }

    static func restoreAction(
        peripheralState: CBPeripheralState,
        hasAudioService: Bool,
        isAudioNotifying: Bool,
        codec: BLEReadState<BLEAudioCodecInfo>
    ) -> OmiRestoreAction {
        guard peripheralState == .connected else {
            return .rearmConnect
        }
        guard hasAudioService else {
            return .discoverServices
        }
        switch codec {
        case .notRead:
            return .readCodec
        case .unavailable:
            return .needsAttention(.codecNotOpus)
        case .value(let info):
            guard info.isOpus else {
                return .needsAttention(.codecNotOpus)
            }
            return isAudioNotifying ? .alreadyLive : .subscribeAudio
        }
    }

    /// Single decision point + sole producer of the `.audioUnavailable → .connected`
    /// recovery transition. Returns `.connected` ONLY when currently latched at
    /// `.needsAttention(.audioUnavailable)` and audio is demonstrably live on the
    /// existing connection; otherwise `nil` (no transition). The codec guard is
    /// implicit: we only override `.audioUnavailable`, never `.codecNotOpus`.
    nonisolated static func recoveredConnectionState(
        current: OmiSourceState,
        audioIsLive: Bool
    ) -> OmiSourceState? {
        guard case .needsAttention(.audioUnavailable) = current, audioIsLive else {
            return nil
        }
        return .connected
    }

    static func persistedPeripheralID(from storedValue: String?) -> UUID? {
        guard let storedValue else {
            return nil
        }
        return UUID(uuidString: storedValue)
    }

    static func storedPeripheralIDValue(for id: UUID) -> String {
        id.uuidString
    }

    static func surfacedBattery(
        live: BLEReadState<Int>,
        lastKnown: TimedReading<Int>?
    ) -> OmiSurfacedReading<Int> {
        switch live {
        case .value(let value):
            return .live(value)
        case .notRead:
            if let lastKnown {
                return .lastKnown(value: lastKnown.value, at: lastKnown.at)
            }
            return .missing(.notRead)
        case .unavailable:
            if let lastKnown {
                return .lastKnown(value: lastKnown.value, at: lastKnown.at)
            }
            return .missing(.unknown)
        }
    }

    static func surfacedSignal(
        live: Int?,
        lastKnown: TimedReading<Int>?
    ) -> OmiSurfacedReading<Int> {
        if let live {
            return .live(live)
        }
        if let lastKnown {
            return .lastKnown(value: lastKnown.value, at: lastKnown.at)
        }
        return .missing(.unknown)
    }

    static func shouldReReadBattery(
        connected: Bool,
        hasCachedReadableCharacteristic: Bool
    ) -> Bool {
        connected && hasCachedReadableCharacteristic
    }

    static func audioHealth(
        connectionState: OmiSourceState,
        lastAudioAt: Date?,
        connectedSince: Date?,
        now: Date,
        threshold: TimeInterval = OmiDiagnosticsLogic.connectedSilenceThreshold
    ) -> OmiAudioHealth {
        guard case .connected = connectionState else {
            return .idle
        }

        let baseline: Date?
        if let connectedSince {
            baseline = lastAudioAt.map { max($0, connectedSince) } ?? connectedSince
        } else {
            baseline = lastAudioAt
        }

        guard let baseline else {
            return .idle
        }

        if now.timeIntervalSince(baseline) <= threshold {
            return .receiving
        }
        return .silentWhileConnected(since: baseline)
    }

    static func shouldAttemptResubscribe(
        health: OmiAudioHealth,
        isAudioSubscribed: Bool,
        alreadyFired: Bool
    ) -> Bool {
        guard case .silentWhileConnected = health else {
            return false
        }
        return isAudioSubscribed && !alreadyFired
    }

    static func audioUnsubscribedWhileConnectedFault(
        connectionState: OmiSourceState,
        isAudioNotifying: Bool
    ) -> Bool {
        guard case .connected = connectionState else {
            return false
        }
        return !isAudioNotifying
    }

    static func effectiveConnectionState(
        connectionState: OmiSourceState,
        writerFaulted: Bool,
        audioUnsubscribedWhileConnected: Bool,
        reconnectStartedAt: Date?,
        isAudioSubscribed: Bool,
        lastAudioAt: Date?,
        connectedSince: Date?,
        now: Date,
        audioSilenceAttentionWindow: TimeInterval = Self.audioSilenceAttentionWindow,
        reconnectAttentionDeadline: TimeInterval = Self.reconnectAttentionDeadline
    ) -> OmiSourceState {
        if writerFaulted {
            return .needsAttention(.audioUnavailable)
        }
        if audioUnsubscribedWhileConnected {
            return .needsAttention(.audioUnavailable)
        }
        if case .reconnecting = connectionState,
           let reconnectStartedAt,
           now.timeIntervalSince(reconnectStartedAt) > reconnectAttentionDeadline
        {
            return .needsAttention(.connectFailed("connection timed out"))
        }
        if case .connected = connectionState,
           isAudioSubscribed,
           let baseline = Self.audioSilenceBaseline(
               lastAudioAt: lastAudioAt,
               connectedSince: connectedSince
           ),
           now.timeIntervalSince(baseline) > audioSilenceAttentionWindow
        {
            return .needsAttention(.audioUnavailable)
        }
        return connectionState
    }

    static func pendantBatteryText(
        reading: OmiSurfacedReading<Int>,
        now: Date
    ) -> String {
        switch reading {
        case .live(let value):
            return "\(value)%"
        case .lastKnown(let value, let at):
            return "\(value)% (\(Self.asOfText(at: at, now: now)))"
        case .missing(let fallback):
            return Self.missingText(fallback)
        }
    }

    static func pendantSignalText(
        reading: OmiSurfacedReading<Int>,
        now: Date
    ) -> String {
        switch reading {
        case .live(let value):
            return "\(value)"
        case .lastKnown(let value, let at):
            return "\(value) (\(Self.asOfText(at: at, now: now)))"
        case .missing(let fallback):
            return Self.missingText(fallback)
        }
    }

    static func audioHealthText(_ health: OmiAudioHealth, now: Date) -> String {
        switch health {
        case .receiving:
            return "flowing"
        case .silentWhileConnected(let since):
            return "connected, none for \(Self.elapsedMinuteText(since: since, now: now))"
        case .idle:
            return "unknown"
        }
    }

    static func sourceReadingSubtext(
        battery: OmiSurfacedReading<Int>,
        signal: OmiSurfacedReading<Int>,
        now: Date
    ) -> String {
        "battery \(Self.sourceBatteryText(battery, now: now)), signal \(Self.sourceSignalText(signal, now: now))"
    }

    static func audioCounterSnapshot(
        reassembler: BLEAudioReassembler,
        decodeOK: Int,
        decodeErrors: Int
    ) -> OmiAudioCounterSnapshot {
        OmiAudioCounterSnapshot(
            packets: reassembler.packets,
            frames: reassembler.frames,
            gaps: reassembler.gaps,
            outOfOrder: reassembler.outOfOrder,
            malformed: reassembler.malformed,
            markers: reassembler.markers,
            decodeOK: decodeOK,
            decodeErrors: decodeErrors
        )
    }

    static func emitDecodedFrames(
        _ frames: [Data],
        decode: (Data) -> [Int16]?,
        sink: (([Int16]) -> Void)?
    ) -> (decodeOK: Int, decodeErrors: Int) {
        var decodeOK = 0
        var decodeErrors = 0

        for frame in frames {
            guard let samples = decode(frame) else {
                decodeErrors += 1
                continue
            }
            decodeOK += 1
            sink?(samples)
        }

        return (decodeOK, decodeErrors)
    }

    private static func sourceBatteryText(_ reading: OmiSurfacedReading<Int>, now: Date) -> String {
        switch reading {
        case .live(let value):
            return "\(value)%"
        case .lastKnown(let value, let at):
            return "\(value)% \(Self.asOfText(at: at, now: now))"
        case .missing(let fallback):
            return Self.missingText(fallback)
        }
    }

    private static func sourceSignalText(_ reading: OmiSurfacedReading<Int>, now: Date) -> String {
        switch reading {
        case .live(let value):
            return "\(value)"
        case .lastKnown(let value, let at):
            return "\(value) \(Self.asOfText(at: at, now: now))"
        case .missing(let fallback):
            return Self.missingText(fallback)
        }
    }

    private static func audioSilenceBaseline(lastAudioAt: Date?, connectedSince: Date?) -> Date? {
        if let connectedSince {
            return lastAudioAt.map { max($0, connectedSince) } ?? connectedSince
        }
        return lastAudioAt
    }

    private static func missingText(_ fallback: OmiReadingFallback) -> String {
        switch fallback {
        case .notRead:
            return "not read yet"
        case .unknown:
            return "unknown"
        }
    }

    private static func asOfText(at date: Date, now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(date).rounded()), 0)
        guard seconds >= 60 else {
            return "as of now"
        }

        let minutes = seconds / 60
        guard minutes >= 60 else {
            return "as of \(minutes)m ago"
        }

        let hours = minutes / 60
        guard hours >= 24 else {
            return "as of \(hours)h ago"
        }

        return "as of \(hours / 24)d ago"
    }

    private static func elapsedMinuteText(since date: Date, now: Date) -> String {
        let minutes = max(Int(now.timeIntervalSince(date) / 60), 1)
        return "\(minutes)m"
    }
}

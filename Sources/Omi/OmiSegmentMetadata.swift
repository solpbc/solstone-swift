// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated private let omiSegmentMetadataLog = Logger(
    subsystem: "app.solstone.swift",
    category: "omi-segment-metadata"
)

nonisolated struct OmiSegmentMetadata: Codable, Equatable, Sendable {
    static let key = "omi"

    struct ReconnectEvent: Codable, Equatable, Sendable {
        var processID: UUID
        var sequence: Int
        var revision: Int
        var disconnectedAt: Date
        var appState: String
        var latencySeconds: TimeInterval?

        var reconnectedAt: Date? {
            guard let latencySeconds, latencySeconds.isFinite else { return nil }
            return self.disconnectedAt.addingTimeInterval(latencySeconds)
        }

        enum CodingKeys: String, CodingKey {
            case processID = "process_id"
            case sequence
            case revision
            case disconnectedAt = "disconnected_at"
            case appState = "app_state"
            case latencySeconds = "latency_s"
            case reconnectedAt = "reconnected_at"
        }

        init(
            processID: UUID,
            sequence: Int,
            revision: Int,
            disconnectedAt: Date,
            appState: String,
            latencySeconds: TimeInterval?
        ) {
            self.processID = processID
            self.sequence = sequence
            self.revision = revision
            self.disconnectedAt = disconnectedAt
            self.appState = appState
            self.latencySeconds = latencySeconds
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.processID = try container.decode(UUID.self, forKey: .processID)
            self.sequence = try container.decode(Int.self, forKey: .sequence)
            self.revision = try container.decode(Int.self, forKey: .revision)
            self.disconnectedAt = try container.decode(Date.self, forKey: .disconnectedAt)
            self.appState = try container.decode(String.self, forKey: .appState)
            self.latencySeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .latencySeconds)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.processID, forKey: .processID)
            try container.encode(self.sequence, forKey: .sequence)
            try container.encode(self.revision, forKey: .revision)
            try container.encode(self.disconnectedAt, forKey: .disconnectedAt)
            try container.encode(self.appState, forKey: .appState)
            if let latencySeconds = self.latencySeconds, latencySeconds.isFinite {
                try container.encode(latencySeconds, forKey: .latencySeconds)
            }
            if let reconnectedAt = self.reconnectedAt {
                try container.encode(reconnectedAt, forKey: .reconnectedAt)
            }
        }
    }

    struct SubscribeEvent: Codable, Equatable, Sendable {
        var processID: UUID
        var sequence: Int
        var revision: Int
        var connectedAt: Date
        var subscribedAt: Date?
        var latencySeconds: TimeInterval?
        var appState: String

        enum CodingKeys: String, CodingKey {
            case processID = "process_id"
            case sequence
            case revision
            case connectedAt = "connected_at"
            case subscribedAt = "subscribed_at"
            case latencySeconds = "latency_s"
            case appState = "app_state"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.processID, forKey: .processID)
            try container.encode(self.sequence, forKey: .sequence)
            try container.encode(self.revision, forKey: .revision)
            try container.encode(self.connectedAt, forKey: .connectedAt)
            try container.encodeIfPresent(self.subscribedAt, forKey: .subscribedAt)
            if let latencySeconds = self.latencySeconds, latencySeconds.isFinite {
                try container.encode(latencySeconds, forKey: .latencySeconds)
            }
            try container.encode(self.appState, forKey: .appState)
        }
    }

    var connectionState: String
    var processID: UUID?
    var processStartedAt: Date?
    var pendantBatteryLevel: Int?
    var pendantBatteryAt: Date?
    var phoneBatteryLevel: Double?
    var phoneBatteryAt: Date?
    var phoneBatteryState: String?
    var phoneThermalState: String?
    var firmware: String?
    var connectToFirstAudioSeconds: TimeInterval?
    var reconnectCount: Int?
    var reconnectEvents: [ReconnectEvent]
    var subscribeEvents: [SubscribeEvent]

    enum CodingKeys: String, CodingKey {
        case connectionState = "connection_state"
        case processID = "process_id"
        case processStartedAt = "process_started_at"
        case pendantBatteryLevel = "pendant_battery_level"
        case pendantBatteryAt = "pendant_battery_at"
        case phoneBatteryLevel = "phone_battery_level"
        case phoneBatteryAt = "phone_battery_at"
        case phoneBatteryState = "phone_battery_state"
        case phoneThermalState = "phone_thermal_state"
        case firmware
        case connectToFirstAudioSeconds = "connect_to_first_audio_s"
        case reconnectCount = "reconnect_count"
        case reconnectEvents = "reconnect_events"
        case subscribeEvents = "subscribe_events"
    }

    init(
        connectionState: String,
        processID: UUID? = nil,
        processStartedAt: Date? = nil,
        pendantBatteryLevel: Int? = nil,
        pendantBatteryAt: Date? = nil,
        phoneBatteryLevel: Double? = nil,
        phoneBatteryAt: Date? = nil,
        phoneBatteryState: String? = nil,
        phoneThermalState: String? = nil,
        firmware: String? = nil,
        connectToFirstAudioSeconds: TimeInterval? = nil,
        reconnectCount: Int? = nil,
        reconnectEvents: [ReconnectEvent] = [],
        subscribeEvents: [SubscribeEvent] = []
    ) {
        self.connectionState = connectionState
        self.processID = processID
        self.processStartedAt = processStartedAt
        self.pendantBatteryLevel = pendantBatteryLevel
        self.pendantBatteryAt = pendantBatteryAt
        self.phoneBatteryLevel = phoneBatteryLevel
        self.phoneBatteryAt = phoneBatteryAt
        self.phoneBatteryState = phoneBatteryState
        self.phoneThermalState = phoneThermalState
        self.firmware = firmware
        self.connectToFirstAudioSeconds = connectToFirstAudioSeconds
        self.reconnectCount = reconnectCount
        self.reconnectEvents = reconnectEvents
        self.subscribeEvents = subscribeEvents
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.connectionState = try container.decode(String.self, forKey: .connectionState)
        self.processID = try container.decodeIfPresent(UUID.self, forKey: .processID)
        self.processStartedAt = try container.decodeIfPresent(Date.self, forKey: .processStartedAt)
        self.pendantBatteryLevel = try container.decodeIfPresent(Int.self, forKey: .pendantBatteryLevel)
        self.pendantBatteryAt = try container.decodeIfPresent(Date.self, forKey: .pendantBatteryAt)
        self.phoneBatteryLevel = try container.decodeIfPresent(Double.self, forKey: .phoneBatteryLevel)
        self.phoneBatteryAt = try container.decodeIfPresent(Date.self, forKey: .phoneBatteryAt)
        self.phoneBatteryState = try container.decodeIfPresent(String.self, forKey: .phoneBatteryState)
        self.phoneThermalState = try container.decodeIfPresent(String.self, forKey: .phoneThermalState)
        self.firmware = try container.decodeIfPresent(String.self, forKey: .firmware)
        self.connectToFirstAudioSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .connectToFirstAudioSeconds)
        self.reconnectCount = try container.decodeIfPresent(Int.self, forKey: .reconnectCount)
        self.reconnectEvents = try container.decodeIfPresent([ReconnectEvent].self, forKey: .reconnectEvents) ?? []
        self.subscribeEvents = try container.decodeIfPresent([SubscribeEvent].self, forKey: .subscribeEvents) ?? []
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.connectionState, forKey: .connectionState)
        try container.encodeIfPresent(self.processID, forKey: .processID)
        try container.encodeIfPresent(self.processStartedAt, forKey: .processStartedAt)
        try container.encodeIfPresent(self.pendantBatteryLevel, forKey: .pendantBatteryLevel)
        try container.encodeIfPresent(self.pendantBatteryAt, forKey: .pendantBatteryAt)
        if let phoneBatteryLevel = self.phoneBatteryLevel, phoneBatteryLevel.isFinite {
            try container.encode(phoneBatteryLevel, forKey: .phoneBatteryLevel)
        }
        try container.encodeIfPresent(self.phoneBatteryAt, forKey: .phoneBatteryAt)
        if let phoneBatteryState = self.phoneBatteryState, !phoneBatteryState.isEmpty {
            try container.encode(phoneBatteryState, forKey: .phoneBatteryState)
        }
        if let phoneThermalState = self.phoneThermalState, !phoneThermalState.isEmpty {
            try container.encode(phoneThermalState, forKey: .phoneThermalState)
        }
        if let firmware = self.firmware, !firmware.isEmpty {
            try container.encode(firmware, forKey: .firmware)
        }
        if let connectToFirstAudioSeconds = self.connectToFirstAudioSeconds,
           connectToFirstAudioSeconds.isFinite
        {
            try container.encode(connectToFirstAudioSeconds, forKey: .connectToFirstAudioSeconds)
        }
        try container.encodeIfPresent(self.reconnectCount, forKey: .reconnectCount)
        if !self.reconnectEvents.isEmpty {
            try container.encode(self.reconnectEvents, forKey: .reconnectEvents)
        }
        if !self.subscribeEvents.isEmpty {
            try container.encode(self.subscribeEvents, forKey: .subscribeEvents)
        }
    }

    static func attaching(_ metadata: OmiSegmentMetadata, to meta: JSONValue) -> JSONValue {
        var root: [String: JSONValue]
        if case .object(let object) = meta {
            root = object
        } else {
            root = [:]
        }
        do {
            root[self.key] = try metadata.jsonValue()
        } catch {
            omiSegmentMetadataLog.error("omi segment metadata encoding failed: \(String(describing: error), privacy: .public)")
            return meta
        }
        return .object(root)
    }

    static func namespaceValue(from meta: JSONValue) -> JSONValue? {
        guard case .object(let root) = meta else { return nil }
        return root[self.key]
    }

    static func from(meta: JSONValue) -> OmiSegmentMetadata? {
        guard let value = self.namespaceValue(from: meta),
              let data = try? JSONEncoder().encode(value)
        else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OmiSegmentMetadata.self, from: data)
    }

    private func jsonValue() throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

nonisolated struct OmiSegmentMetadataToken: Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case reconnect
        case subscribe
    }

    var kind: Kind
    var processID: UUID
    var sequence: Int
    var revision: Int
}

nonisolated struct OmiSegmentMetadataSnapshot: Equatable, Sendable {
    var metadata: OmiSegmentMetadata
    var frozenTokens: [OmiSegmentMetadataToken]
}

nonisolated struct OmiEventIdentity: Codable, Equatable, Sendable {
    var processID: UUID
    var sequence: Int
}

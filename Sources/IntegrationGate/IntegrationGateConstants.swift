// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

#if DEBUG && targetEnvironment(simulator)
private let log = Logger(subsystem: "app.solstone.swift", category: "integration-gate-constants")

enum IntegrationGateConstants {
    static let schemaVersion = 1
    static let launchArgument = "--solstone-spl-gate"
    static let directoryName = "integration-gate"
    static let manifestFileName = "manifest.json"
    static let resultFileName = "result.json"
    static let relayEndpoint = "https://link.solstone.app"
    static let maxManifestBytes = 128 * 1024
    static let canarySkewMilliseconds: UInt64 = 2_000
    static let connectCeilingMilliseconds: UInt64 = 30_000
    static let canaryCeilingMilliseconds: UInt64 = 10_000
    static let cleanupCeilingMilliseconds: UInt64 = 5_000
    static let streamCeilingMilliseconds: UInt64 = 20_000
    static let progressCeilingMilliseconds: UInt64 = 30_000
    static let reconnectCeilingMilliseconds: UInt64 = 60_000
    static let observationWindowMilliseconds: UInt64 = 20_000
    static let networkStatusPath = "/app/network/api/status"
    static let homePulsePath = "/app/home/api/pulse"
    // Extro-tools coordinator home fixture contract only. This is not an
    // existing journal route; live G2 cannot run until that fixture serves it.
    static let coordinatorRangeFixturePath = "/app/integration-gate/range"
    // Extro-tools coordinator home fixture contract only. This is not an
    // existing journal route; live G3 cannot run until that fixture serves it.
    static let coordinatorRetryFixturePath = "/app/integration-gate/retry"

    // Mirrors spl-swift Sources/SPLTunnel/Mux/MuxStream.swift:6 MuxConstants.initialCredit.
    // MuxConstants is internal, so the app cannot read that value directly.
    static let gateMuxInitialCreditBytes = 1 << 20

    static func gateDirectoryURL(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("solstone", isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }
}

enum IntegrationGateRouteLabel: String, Codable, CaseIterable, Sendable, Equatable {
    case networkStatus
    case homePulse
    case gateRange
    case gateRetry

    var path: String {
        switch self {
        case .networkStatus:
            return IntegrationGateConstants.networkStatusPath
        case .homePulse:
            return IntegrationGateConstants.homePulsePath
        case .gateRange:
            return IntegrationGateConstants.coordinatorRangeFixturePath
        case .gateRetry:
            return IntegrationGateConstants.coordinatorRetryFixturePath
        }
    }
}

enum IntegrationGateAction: String, Codable, CaseIterable, Sendable, Equatable {
    case canary
    case rangeHash
    case generationRetry
    case syncReconnectWindow
    case syncTransferWindow

    var routeLabel: IntegrationGateRouteLabel {
        switch self {
        case .canary:
            return .homePulse
        case .rangeHash:
            return .gateRange
        case .generationRetry:
            return .gateRetry
        case .syncReconnectWindow, .syncTransferWindow:
            return .networkStatus
        }
    }
}
#endif

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
    case gateCanary
    case gateRange
    case gateRetry

    var path: String {
        switch self {
        case .networkStatus:
            return "/app/network/api/status"
        case .gateCanary:
            return "/app/integration-gate/canary"
        case .gateRange:
            return "/app/integration-gate/range"
        case .gateRetry:
            return "/app/integration-gate/retry"
        }
    }

    static func validateRouteInput(_ value: String) throws -> IntegrationGateRouteLabel {
        if value.contains("://") || value.contains("/") || value.contains("..") {
            throw IntegrationGateValidationError(.malformedRouteInput)
        }
        guard let label = IntegrationGateRouteLabel(rawValue: value) else {
            throw IntegrationGateValidationError(.unknownAction)
        }
        return label
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
            return .gateCanary
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

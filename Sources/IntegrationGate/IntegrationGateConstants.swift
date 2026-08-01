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
    static let g1ObservationWindowMilliseconds: UInt64 = 10_000
    static let cleanupCeilingMilliseconds: UInt64 = 5_000
    // Stays at 20s for the first chunked-reader fix. The local reader cost is
    // now known to be roughly 1000x lower; re-derive from the first live gate run.
    static let streamCeilingMilliseconds: UInt64 = 20_000
    static let progressCeilingMilliseconds: UInt64 = 30_000
    static let reconnectCeilingMilliseconds: UInt64 = 60_000
    static let observationWindowMilliseconds: UInt64 = 20_000
    // Bounded extension past `observationWindowMilliseconds`, entered only while the raw
    // status has recovered and the published one has not caught up yet. Publishing lags
    // raw by up to `pollCadence + debounceInterval` (2.5s), so a window that ends the
    // instant raw recovers hands the verifier a pessimistic sample and G4/G5 fail on the
    // benign direction. 10s is 4x the worst-case publish latency.
    static let syncRecoveryTailMilliseconds: UInt64 = 10_000
    // Samples held after the label converges, so the coordinator's out-of-process owner-UI
    // observer has a window in which the correct label is actually on screen. Still
    // bounded by `syncRecoveryTailMilliseconds`.
    static let syncRecoverySettleSamples: Int = 2
    // G3's mid-stream interrupt window, made explicit. It used to exist only as an
    // artifact of the per-byte drain defect (~10-12s for 2 MiB); repairing the drain
    // cut that to 498 ms and the window vanished, leaving G3 UNREACHABLE rather than
    // merely unpassable -- run 20260731T1929Z never observed a running record at all.
    // After publishing the running record the app holds the stream open so the
    // coordinator's fault has somewhere to land. The fault arriving is what normally
    // ends the hold; the ceiling is only the backstop, and a run with no fault
    // injected still drains and reports `completedFirstAttempt`.
    static let g3InterruptHoldMilliseconds: UInt64 = 45_000
    // Must exceed the hold plus the drain, or the hold trips the stream ceiling and
    // G3 reports `requestTimedOut` instead of being interrupted.
    static let g3StreamCeilingMilliseconds: UInt64 = 75_000
    static let networkStatusPath = "/app/network/api/status"
    static let homePulsePath = "/app/home/api/pulse"
    // The fixed real journal transcripts serve_file route for both media
    // actions. G2 (`rangeHash`) and G3 (`generationRetry`) resolve to this
    // exact relative path and to nothing else because the manifest carries no
    // path, URL, host, or port field. A coordinator can choose which action
    // runs, not where it points.
    //
    // The extro-tools coordinator provisions the bytes at
    // chronicle/20260729/integration-gate/122500_300/ios-spl-gate-260729.m4a
    // on the home under test. The body is deterministic and over 1 MiB so a
    // ranged read crosses `gateMuxInitialCreditBytes`, with a stable content
    // length and SHA-256 across runs. Live G2/G3 stay dormant until it exists.
    static let transcriptsServeFilePath = "/app/transcripts/api/serve_file/20260729/integration-gate/122500_300/ios-spl-gate-260729.m4a"

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
        case .gateRange, .gateRetry:
            return IntegrationGateConstants.transcriptsServeFilePath
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

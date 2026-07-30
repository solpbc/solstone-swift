// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest

// criterion 2: production composition.
@MainActor
final class IntegrationGateCompositionTests: XCTestCase {
    func testDependencySurfaceUsesConcreteProductionTypes() {
        func assertConcreteTypes(_ dependencies: IntegrationGateDependencies) {
            let _: SPLKeychainStore = dependencies.keychainStore
            let _: TunnelManager = dependencies.tunnelManager
            let _: CFTunnelTransport = dependencies.transport
            let _: ConnectionSyncModel = dependencies.connectionSyncModel
        }

        _ = assertConcreteTypes
    }

    func testAppCompositionPassesProductionInstances() throws {
        let appText = try Self.sourceText("Sources/SolstoneSwiftApp.swift")
        XCTAssertTrue(appText.contains("IntegrationGateDependencies("))
        XCTAssertTrue(appText.contains("keychainStore: SPLRuntime.keychainStore"))
        XCTAssertTrue(appText.contains("tunnelManager: tunnel"))
        XCTAssertTrue(appText.contains("transport: transport"))
        XCTAssertTrue(appText.contains("connectionSyncModel: connectionSyncModel"))

        let httpText = try Self.sourceText("Sources/IntegrationGate/IntegrationGateHTTPClient.swift")
        XCTAssertTrue(httpText.contains("tunnelManager.activeConnection"))
        XCTAssertTrue(httpText.contains("components.path = routeLabel.path"))

        let actionsText = try Self.sourceText("Sources/IntegrationGate/IntegrationGateActions.swift")
        XCTAssertTrue(actionsText.contains("httpClient.canary(routeLabel: .homePulse)"))

        let samplerText = try Self.sourceText("Sources/IntegrationGate/IntegrationGateSampler.swift")
        XCTAssertTrue(samplerText.contains("httpClient.canary(routeLabel: .networkStatus)"))
    }

    private static func sourceText(_ relativePath: String) throws -> String {
        let url = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}

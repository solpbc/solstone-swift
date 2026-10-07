// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import CryptoKit
import Foundation
import SPLTunnel
import Security
import os

private let unpairLog = Logger(subsystem: "app.solstone.swift", category: "owner-unpair")

enum OwnerUnpairTransport {
    static let live: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }
}

private nonisolated func executeUnpairRequest(
    request: URLRequest,
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
    timeout: Duration
) async throws -> HTTPURLResponse? {
    try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
        group.addTask {
            try await transport(request)
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw URLError(.timedOut)
        }
        let (_, response) = try await group.next()!
        group.cancelAll()
        return response as? HTTPURLResponse
    }
}

@MainActor
@discardableResult
func ownerUnpair(
    appConfig: AppConfig,
    tunnelManager: TunnelManager,
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = OwnerUnpairTransport.live,
    timeout: Duration = .seconds(10),
    expectedOwnerID: UUID? = nil,
    expectedPairingGeneration: UInt64? = nil
) async -> Bool {
    guard (expectedOwnerID == nil) == (expectedPairingGeneration == nil) else { return false }
    let state = tunnelManager.state
    let lease: DeviceMigrationInvalidationLease
    do {
        lease = try appConfig.beginPairingInvalidation(
            expectedOwnerID: expectedOwnerID,
            expectedPairingGeneration: expectedPairingGeneration
        )
    } catch {
        unpairLog.error("pairing invalidation could not be persisted")
        return false
    }
    let invalidationGeneration = appConfig.store.snapshot().pairingGeneration
    tunnelManager.closeOrdinaryAdmission()

    if case .error(.revoked) = state {
        let cleared = appConfig.clearPairing(invalidation: lease)
        await tunnelManager.disconnectIfPairingInvalidated(generation: invalidationGeneration)
        return cleared && appConfig.store.snapshot().pairing == nil
    }

    guard case .connected(let localPort, _) = state else {
        guard appConfig.clearPairing(invalidation: lease) else {
            await tunnelManager.disconnectIfPairingInvalidated(generation: invalidationGeneration)
            return false
        }
        unpairLog.error("journal unpair skipped: tunnel not connected")
        await tunnelManager.disconnectIfPairingInvalidated(generation: invalidationGeneration)
        return appConfig.store.snapshot().pairing == nil
    }

    guard let stored = try? appConfig.store.load(),
          let certificate = try? CertChain.certificates(fromPEM: stored.clientCertPEM).first,
          let derData = SecCertificateCopyData(certificate) as Data? else {
        guard appConfig.clearPairing(invalidation: lease) else {
            await tunnelManager.disconnectIfPairingInvalidated(generation: invalidationGeneration)
            return false
        }
        unpairLog.error("journal unpair skipped: client certificate unreadable")
        await tunnelManager.disconnectIfPairingInvalidated(generation: invalidationGeneration)
        return appConfig.store.snapshot().pairing == nil
    }

    let digest = SHA256.hash(data: derData)
    let cidHex = digest.map { String(format: "%02x", $0) }.joined()

    guard let url = URL(string: "http://127.0.0.1:\(localPort)/app/network/api/clients/sha256%3A\(cidHex)") else {
        guard appConfig.clearPairing(invalidation: lease) else {
            await tunnelManager.disconnectIfPairingInvalidated(generation: invalidationGeneration)
            return false
        }
        unpairLog.error("journal unpair skipped: unpair url not buildable")
        await tunnelManager.disconnectIfPairingInvalidated(generation: invalidationGeneration)
        return appConfig.store.snapshot().pairing == nil
    }

    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.attachLoopbackCapability()
    let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
    request.timeoutInterval = timeoutSeconds

    do {
        if let http = try await executeUnpairRequest(request: request, transport: transport, timeout: timeout) {
            if http.statusCode != 200 && http.statusCode != 204 && http.statusCode != 404 {
                unpairLog.error("journal unpair request returned HTTP \(http.statusCode)")
            }
        }
    } catch is CancellationError {
        unpairLog.error("journal unpair request timed out")
    } catch let urlError as URLError where urlError.code == .timedOut {
        unpairLog.error("journal unpair request timed out")
    } catch {
        unpairLog.error("journal unpair transport failed")
    }

    guard appConfig.clearPairing(invalidation: lease) else {
        await tunnelManager.disconnectIfPairingInvalidated(generation: invalidationGeneration)
        return false
    }
    await tunnelManager.disconnectIfPairingInvalidated(generation: invalidationGeneration)
    return appConfig.store.snapshot().pairing == nil
}

@MainActor
func unpairAndReturnToOnboarding(
    appConfig: AppConfig,
    onboardingFlow: OnboardingFlow,
    tunnelManager: TunnelManager,
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = OwnerUnpairTransport.live,
    timeout: Duration = .seconds(10)
) async {
    guard await ownerUnpair(
        appConfig: appConfig,
        tunnelManager: tunnelManager,
        transport: transport,
        timeout: timeout
    ), appConfig.store.snapshot().pairing == nil else { return }
    onboardingFlow.reset()
}

@MainActor
@discardableResult
func unpairForNewPair(
    appConfig: AppConfig,
    tunnelManager: TunnelManager,
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = OwnerUnpairTransport.live,
    timeout: Duration = .seconds(10)
) async -> Bool {
    guard await ownerUnpair(
        appConfig: appConfig,
        tunnelManager: tunnelManager,
        transport: transport,
        timeout: timeout
    ), appConfig.store.snapshot().pairing == nil else { return false }
    return true
}

@MainActor
func unpairThisDevice(
    appConfig: AppConfig,
    onboardingFlow: OnboardingFlow,
    tunnelManager: TunnelManager,
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = OwnerUnpairTransport.live,
    timeout: Duration = .seconds(10)
) async {
    guard await ownerUnpair(
        appConfig: appConfig,
        tunnelManager: tunnelManager,
        transport: transport,
        timeout: timeout
    ), appConfig.store.snapshot().pairing == nil else { return }
    onboardingFlow.reset()
}

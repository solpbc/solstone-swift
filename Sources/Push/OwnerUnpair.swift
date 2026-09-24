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
func ownerUnpair(
    appConfig: AppConfig,
    tunnelManager: TunnelManager,
    notice: JournalUnpairNoticeStore,
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = OwnerUnpairTransport.live,
    timeout: Duration = .seconds(10)
) async {
    let state = tunnelManager.state
    if case .error(.revoked) = state {
        appConfig.clearPairing()
        return
    }

    guard case .connected(let localPort, _) = state else {
        appConfig.clearPairing()
        notice.markNotTold()
        return
    }

    guard let stored = try? appConfig.store.load(),
          let certificate = try? CertChain.certificates(fromPEM: stored.clientCertPEM).first,
          let derData = SecCertificateCopyData(certificate) as Data?
    else {
        appConfig.clearPairing()
        notice.markNotTold()
        return
    }

    let digest = SHA256.hash(data: derData)
    let cidHex = digest.map { String(format: "%02x", $0) }.joined()

    guard let url = URL(string: "http://127.0.0.1:\(localPort)/app/network/api/clients/sha256%3A\(cidHex)") else {
        appConfig.clearPairing()
        notice.markNotTold()
        return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.attachLoopbackCapability()
    let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
    request.timeoutInterval = timeoutSeconds

    var unpairConfirmed = false
    do {
        if let http = try await executeUnpairRequest(request: request, transport: transport, timeout: timeout) {
            if http.statusCode == 200 || http.statusCode == 204 || http.statusCode == 404 {
                unpairConfirmed = true
            } else {
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

    appConfig.clearPairing()
    if !unpairConfirmed {
        notice.markNotTold()
    }
}

@MainActor
func unpairAndReturnToOnboarding(
    appConfig: AppConfig,
    onboardingFlow: OnboardingFlow,
    tunnelManager: TunnelManager,
    noticeStore: JournalUnpairNoticeStore,
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = OwnerUnpairTransport.live,
    timeout: Duration = .seconds(10)
) async {
    await ownerUnpair(
        appConfig: appConfig,
        tunnelManager: tunnelManager,
        notice: noticeStore,
        transport: transport,
        timeout: timeout
    )
    onboardingFlow.reset()
    await tunnelManager.disconnect()
}

@MainActor
func unpairForNewPair(
    appConfig: AppConfig,
    tunnelManager: TunnelManager,
    noticeStore: JournalUnpairNoticeStore,
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = OwnerUnpairTransport.live,
    timeout: Duration = .seconds(10)
) async {
    await ownerUnpair(
        appConfig: appConfig,
        tunnelManager: tunnelManager,
        notice: noticeStore,
        transport: transport,
        timeout: timeout
    )
    await tunnelManager.disconnect()
}

@MainActor
func unpairThisDevice(
    appConfig: AppConfig,
    onboardingFlow: OnboardingFlow,
    tunnelManager: TunnelManager,
    noticeStore: JournalUnpairNoticeStore,
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = OwnerUnpairTransport.live,
    timeout: Duration = .seconds(10)
) async {
    await ownerUnpair(
        appConfig: appConfig,
        tunnelManager: tunnelManager,
        notice: noticeStore,
        transport: transport,
        timeout: timeout
    )
    onboardingFlow.reset()
    await tunnelManager.disconnect()
}

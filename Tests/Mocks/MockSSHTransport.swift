// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift

nonisolated final class MockSSHTransport: SSHTransporting, @unchecked Sendable {
    var probeLANResult: Bool = true
    var connectDelay: Duration? = nil
    var connectLocalPort: Int = 8080
    var connectError: TunnelError? = nil
    var triggerHostKeyMismatch: Bool = false
    var acceptPendingHostKeyError: Error? = nil
    var disconnectCalled: Bool = false
    var shutdownCalled: Bool = false
    var probeConnectionResult: Bool = true
    var probeConnectionCallCount: Int = 0
    var connectCallCount: Int = 0
    var lastConnectEndpoint: ConnectionEndpoint?
    var lastOnDisconnect: (@Sendable () -> Void)?
    var lastOnKeepaliveResult: (@Sendable (Bool, Int) -> Void)?
    var lastOnStageChange: (@Sendable (SSHStageEvent) -> Void)?
    var stageEventsToEmit: [SSHStageEvent] = []

    func probeLAN() async -> Bool {
        self.probeLANResult
    }

    func connect(
        endpoint: ConnectionEndpoint,
        onDisconnect: @Sendable @escaping () -> Void,
        onHostKeyMismatch: @Sendable @escaping () -> Void,
        onKeepaliveResult: @Sendable @escaping (Bool, Int) -> Void,
        onStageChange: @Sendable @escaping (SSHStageEvent) -> Void
    ) async throws -> Int {
        self.connectCallCount += 1
        self.lastConnectEndpoint = endpoint
        self.lastOnDisconnect = onDisconnect
        self.lastOnKeepaliveResult = onKeepaliveResult
        self.lastOnStageChange = onStageChange
        for event in self.stageEventsToEmit {
            onStageChange(event)
        }
        if let connectDelay = self.connectDelay {
            try await Task.sleep(for: connectDelay)
        }
        if self.triggerHostKeyMismatch {
            onHostKeyMismatch()
            throw TunnelError.hostKeyMismatch
        }
        if let error = self.connectError {
            throw error
        }
        return self.connectLocalPort
    }

    func disconnect() async {
        self.disconnectCalled = true
    }

    func acceptPendingHostKey() throws {
        if let error = self.acceptPendingHostKeyError {
            throw error
        }
    }

    func shutdown() async {
        self.shutdownCalled = true
    }

    func probeConnection() async -> Bool {
        self.probeConnectionCallCount += 1
        return self.probeConnectionResult
    }
}

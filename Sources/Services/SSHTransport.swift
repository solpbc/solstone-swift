// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Crypto
import Network
import NIOConcurrencyHelpers
import NIOCore
import NIOSSH
import NIOTransportServices
import os

private let log = Logger(subsystem: "org.solpbc.solstone-swift", category: "ssh-transport")

nonisolated protocol SSHTransporting: Sendable {
    func probeLAN() async -> Bool
    func connect(
        endpoint: ConnectionEndpoint,
        onDisconnect: @Sendable @escaping () -> Void,
        onHostKeyMismatch: @Sendable @escaping () -> Void,
        onKeepaliveResult: @Sendable @escaping (Bool, Int) -> Void,
        onStageChange: @Sendable @escaping (SSHStageEvent) -> Void
    ) async throws -> Int
    func disconnect() async
    func acceptPendingHostKey() throws
    func shutdown() async
    func probeConnection() async -> Bool
}

actor SSHTransport: SSHTransporting {
    private let config: AppConfig
    private let keyManager: any KeyManaging
    private let group = NIOTSEventLoopGroup(loopCount: 1)
    private var sshChannel: (any Channel)?
    private var execChannel: (any Channel)?
    private var portForwardServer: PortForwardingServer?
    private var monitorTask: Task<Void, Never>?
    private var execMonitorTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var lastProbeAlive: Bool?
    private var consecutiveKeepaliveFailures = 0
    private let pendingHostKeyBox = NIOLockedValueBox<NIOSSHPublicKey?>(nil)
    private let execOutputBuffer = NIOLockedValueBox(ExecOutputBuffer())
    private let readyPortBox = NIOLockedValueBox(ReadyPortWaiter())

    init(config: AppConfig = .default, keyManager: any KeyManaging = KeyManager()) {
        self.config = config
        self.keyManager = keyManager
    }

    func probeLAN() async -> Bool {
        do {
            let ch = try await NIOTSConnectionBootstrap(group: self.group)
                .connectTimeout(self.config.connectTimeoutLan)
                .channelInitializer { channel in channel.eventLoop.makeSucceededVoidFuture() }
                .connect(host: self.config.lanHost, port: self.config.lanPort)
                .get()
            try? await ch.close().get()
            return true
        } catch {
            return false
        }
    }

    func connect(
        endpoint: ConnectionEndpoint,
        onDisconnect: @Sendable @escaping () -> Void,
        onHostKeyMismatch: @Sendable @escaping () -> Void,
        onKeepaliveResult: @Sendable @escaping (Bool, Int) -> Void,
        onStageChange: @Sendable @escaping (SSHStageEvent) -> Void
    ) async throws -> Int {
        self.pendingHostKeyBox.withLockedValue { $0 = nil }
        self.execOutputBuffer.withLockedValue { $0 = ExecOutputBuffer() }
        self.readyPortBox.withLockedValue { $0 = ReadyPortWaiter() }

        let identityKey = try self.keyManager.loadOrCreateIdentityKey()
        let authDelegate = PrivateKeyAuthDelegate(
            username: self.config.sshUsername,
            privateKey: NIOSSHPrivateKey(ed25519Key: identityKey)
        )
        let validator = HostKeyValidator(keyManager: self.keyManager) { [pendingHostKeyBox] candidate in
            pendingHostKeyBox.withLockedValue { $0 = candidate }
            onHostKeyMismatch()
        }

        let host = endpoint == .lan ? self.config.lanHost : self.config.remoteHost
        let port = endpoint == .lan ? self.config.lanPort : self.config.remotePort

        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            onStageChange(.sshConnecting)
            let sshChannel = try await NIOTSConnectionBootstrap(group: self.group)
                .connectTimeout(endpoint == .lan ? self.config.connectTimeoutLan : self.config.connectTimeoutRemote)
                .tcpOptions(tcp)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sshHandler = NIOSSHHandler(
                            role: .client(
                                .init(
                                    userAuthDelegate: authDelegate,
                                    serverAuthDelegate: validator
                                )
                            ),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                        try channel.pipeline.syncOperations.addHandlers([sshHandler, ErrorHandler()])
                    }
                }
                .connect(host: host, port: port)
                .get()

            log.info("[solstone-swift] SSH TCP connected to \(host):\(port)")
            onStageChange(.sshConnected)

            if Task.isCancelled {
                try? await sshChannel.close().get()
                throw CancellationError()
            }

            // Start hub-phone on remote server and wait for it to be ready
            onStageChange(.startingHubPhone)
            let execCh = try await self.startRemoteHubPhone(on: sshChannel, onStageChange: onStageChange)
            let discoveredPort = try await self.waitForReadyPort(execChannel: execCh, onStageChange: onStageChange)

            if Task.isCancelled {
                try? await sshChannel.close().get()
                throw CancellationError()
            }

            onStageChange(.portForwarding)
            let forwardHost = self.config.forwardHost
            let portForwardServer = PortForwardingServer(group: self.group) { inboundChannel in
                Self.makeForwardingFuture(
                    inboundChannel: inboundChannel,
                    sshChannel: sshChannel,
                    forwardHost: forwardHost,
                    forwardPort: discoveredPort
                )
            }
            let localPort = try await portForwardServer.start()
            log.info("[solstone-swift] port-forward server listening on localhost:\(localPort)")

            if Task.isCancelled {
                await portForwardServer.close()
                try? await sshChannel.close().get()
                throw CancellationError()
            }

            self.sshChannel = sshChannel
            self.portForwardServer = portForwardServer
            self.execChannel = execCh
            let execOutputBuffer = self.execOutputBuffer

            self.monitorTask = Task { [weak self] in
                try? await sshChannel.closeFuture.get()
                guard self != nil, !Task.isCancelled else { return }
                onDisconnect()
            }

            self.execMonitorTask = Task { [weak self, execOutputBuffer, onStageChange] in
                try? await execCh.closeFuture.get()
                guard self != nil, !Task.isCancelled else { return }
                let stderrOutput = execOutputBuffer.withLockedValue { $0.stderr }
                if !stderrOutput.isEmpty {
                    log.warning("[solstone-swift] hub-phone exec channel closed with stderr output")
                    onStageChange(.execFailed(stderr: stderrOutput))
                }
                log.info("[solstone-swift] hub-phone exec channel closed")
                onDisconnect()
            }

            self.keepaliveTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    let alive = await self.probeConnection()
                    if !alive && !Task.isCancelled {
                        let shouldClose = await self.recordKeepaliveFailure()
                        let failures = await self.consecutiveKeepaliveFailures
                        onKeepaliveResult(false, failures)
                        if shouldClose {
                            if let ch = await self.sshChannel {
                                try? await ch.close().get()
                            }
                            return
                        }
                    } else {
                        await self.resetKeepaliveFailures()
                        if !Task.isCancelled {
                            onKeepaliveResult(true, 0)
                        }
                    }
                }
            }

            log.info("[solstone-swift] SSH tunnel fully established on localhost:\(localPort) via \(endpoint == .lan ? "lan" : "remote")")
            return localPort
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log.error("[solstone-swift] SSH connect failed: \(error)")
            throw TunnelError.classify(error)
        }
    }

    func disconnect() async {
        self.monitorTask?.cancel()
        self.monitorTask = nil
        self.keepaliveTask?.cancel()
        self.keepaliveTask = nil
        self.execMonitorTask?.cancel()
        self.execMonitorTask = nil

        if let portForwardServer = self.portForwardServer {
            self.portForwardServer = nil
            await portForwardServer.close()
        }

        if let execChannel = self.execChannel {
            self.execChannel = nil
            try? await execChannel.close().get()
        }

        if let sshChannel = self.sshChannel {
            self.sshChannel = nil
            try? await sshChannel.close().get()
        }

        self.lastProbeAlive = nil
        self.consecutiveKeepaliveFailures = 0
    }

    // "record" is metrics terminology here, not audio.
    private func recordKeepaliveFailure() -> Bool {
        consecutiveKeepaliveFailures += 1
        if consecutiveKeepaliveFailures == 1 {
            log.warning("[solstone-swift] keepalive probe failed (strike 1 of 2)")
        }
        return consecutiveKeepaliveFailures >= 2
    }

    private func resetKeepaliveFailures() {
        consecutiveKeepaliveFailures = 0
    }

    func shutdown() async {
        await self.disconnect()
        try? await self.group.shutdownGracefully()
    }

    nonisolated func acceptPendingHostKey() throws {
        guard let key = self.pendingHostKeyBox.withLockedValue({ val -> NIOSSHPublicKey? in
            defer { val = nil }
            return val
        }) else { return }
        try self.keyManager.saveHostKey(key)
    }
}

extension TunnelError {
    static func classify(_ error: Error) -> TunnelError {
        if error is HostKeyError {
            return .hostKeyMismatch
        }
        if let ce = error as? ChannelError, case .connectTimeout = ce {
            return .connectionTimeout
        }
        if let nw = error as? NWError {
            switch nw {
            case .posix(.ECONNREFUSED):
                return .connectionRefused
            case .posix(.ENETUNREACH), .posix(.EHOSTUNREACH):
                return .networkUnreachable
            case .dns:
                return .networkUnreachable
            default:
                return .unknown(String(describing: error))
            }
        }
        // NIOSSH has no explicit "auth rejected" error. When the server rejects
        // authentication, NIOSSH closes the connection; subsequent channel creation
        // attempts hit `creatingChannelAfterClosure`. This heuristic also fires for
        // non-auth closures, making it imprecise. `invalidUserAuthSignature` only
        // covers client-side signature validation failure, not server-side rejection.
        // Revisit when NIOSSH adds a dedicated auth failure error type.
        if let ssh = error as? NIOSSHError, ssh.type == .creatingChannelAfterClosure {
            return .authenticationFailed
        }
        return .unknown(String(describing: error))
    }
}

extension SSHTransport {
    nonisolated private static func parseReadyPort(from line: String) -> Int? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ready"] as? Bool == true,
              let port = json["port"] as? Int,
              port > 0, port <= 65535
        else { return nil }
        return port
    }

    enum ForwardingError: Error {
        case invalidForwardingChannelType
    }

    nonisolated static func makeForwardingFuture(
        inboundChannel: Channel,
        sshChannel: any Channel,
        forwardHost: String,
        forwardPort: Int
    ) -> EventLoopFuture<Void> {
        sshChannel.eventLoop.flatSubmit {
            log.debug("[solstone-swift] forwarding: inbound connection, target \(forwardHost):\(forwardPort)")
            let promise = sshChannel.eventLoop.makePromise(of: Channel.self)
            do {
                let sshHandler = try sshChannel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                // NIOTSListenerBootstrap channels may have nil addresses during
                // childChannelInitializer. Use a synthetic originator address —
                // the SSH server only needs a valid address format, not the real one.
                let originatorAddress: SocketAddress
                if let addr = inboundChannel.remoteAddress ?? inboundChannel.localAddress {
                    originatorAddress = addr
                } else {
                    originatorAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                }
                let directTCPIP = SSHChannelType.DirectTCPIP(
                    targetHost: forwardHost,
                    targetPort: forwardPort,
                    originatorAddress: originatorAddress
                )

                sshHandler.createChannel(
                    promise,
                    channelType: .directTCPIP(directTCPIP)
                ) { childChannel, channelType in
                    guard case .directTCPIP = channelType else {
                        return childChannel.eventLoop.makeFailedFuture(ForwardingError.invalidForwardingChannelType)
                    }

                    return childChannel.eventLoop.makeCompletedFuture {
                        precondition(childChannel.eventLoop === inboundChannel.eventLoop)
                        let (ours, theirs) = GlueHandler.matchedPair()

                        try childChannel.pipeline.syncOperations.addHandlers([
                            SSHWrapperHandler(),
                            ours,
                            ErrorHandler(),
                        ])
                        try inboundChannel.pipeline.syncOperations.addHandlers([
                            theirs,
                            ErrorHandler(),
                        ])
                    }
                }
            } catch {
                inboundChannel.close(promise: nil)
                promise.fail(error)
            }
            return promise.futureResult.map { _ in
                log.debug("[solstone-swift] forwarding: channel established to \(forwardHost):\(forwardPort)")
            }.flatMapError { error in
                log.error("[solstone-swift] forwarding: channel failed to \(forwardHost):\(forwardPort) — \(error)")
                return sshChannel.eventLoop.makeFailedFuture(error)
            }
        }
    }

    func probeConnection() async -> Bool {
        guard let sshChannel = self.sshChannel, sshChannel.isActive else { return false }

        let alive: EventLoopFuture<Bool> = sshChannel.eventLoop.flatSubmit {
            do {
                let sshHandler = try sshChannel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                let promise = sshChannel.eventLoop.makePromise(of: GlobalRequest.TCPForwardingResponse?.self)
                sshHandler.sendTCPForwardingRequest(.cancel(host: "keepalive", port: 0), promise: promise)

                let timeout = sshChannel.eventLoop.scheduleTask(in: .seconds(5)) {
                    promise.fail(ChannelError.connectTimeout(.seconds(5)))
                }

                return promise.futureResult.map { _ in
                    timeout.cancel()
                    return true
                }.flatMapError { error in
                    timeout.cancel()
                    // globalRequestRefused = server responded with SSH_MSG_REQUEST_FAILURE — alive
                    let isAlive = (error as? NIOSSHError)?.type == .globalRequestRefused
                    return sshChannel.eventLoop.makeSucceededFuture(isAlive)
                }
            } catch {
                return sshChannel.eventLoop.makeSucceededFuture(false)
            }
        }

        let result = (try? await alive.get()) ?? false
        if let last = lastProbeAlive {
            if last != result {
                if result {
                    log.info("[solstone-swift] keepalive: connection recovered (dead → alive)")
                } else {
                    log.error("[solstone-swift] keepalive: connection lost (alive → dead)")
                }
            }
        } else {
            if result {
                log.info("[solstone-swift] keepalive: first probe alive")
            } else {
                log.error("[solstone-swift] keepalive: first probe dead")
            }
        }
        lastProbeAlive = result
        return result
    }

    private func startRemoteHubPhone(
        on sshChannel: any Channel,
        onStageChange: @Sendable @escaping (SSHStageEvent) -> Void
    ) async throws -> any Channel {
        log.info("[solstone-swift] starting hub-phone on remote server")
        let outputBuffer = self.execOutputBuffer
        let readyBox = self.readyPortBox
        let execChannel = try await sshChannel.eventLoop.flatSubmit {
            do {
                let sshHandler = try sshChannel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                let promise = sshChannel.eventLoop.makePromise(of: Channel.self)
                let command = "cd /home/jer/projects/extro-hub && exec .venv/bin/hub-phone --port 0 --extro-root /home/jer/projects/extro"

                sshHandler.createChannel(promise, channelType: .session) { childChannel, _ in
                    childChannel.eventLoop.makeCompletedFuture {
                        try childChannel.pipeline.syncOperations.addHandlers([
                            ExecOnActiveHandler(
                                command: command,
                                outputBuffer: outputBuffer,
                                onOutput: { text, isStdErr in
                                    onStageChange(.execOutput(text, isStdErr: isStdErr))
                                    if !isStdErr {
                                        readyBox.withLockedValue { state in
                                            guard !state.resolved else { return }
                                            state.lineBuffer.append(text)
                                            while let newlineIndex = state.lineBuffer.firstIndex(of: "\n") {
                                                let line = String(state.lineBuffer[state.lineBuffer.startIndex..<newlineIndex])
                                                state.lineBuffer = String(state.lineBuffer[state.lineBuffer.index(after: newlineIndex)...])
                                                if let port = SSHTransport.parseReadyPort(from: line) {
                                                    state.discoveredPort = port
                                                    state.resolved = true
                                                    state.continuation?.resume(returning: port)
                                                    state.continuation = nil
                                                    return
                                                }
                                            }
                                        }
                                    }
                                }
                            ),
                            ErrorHandler(),
                        ])
                    }
                }

                let timeout = sshChannel.eventLoop.scheduleTask(in: .seconds(5)) {
                    promise.fail(ChannelError.connectTimeout(.seconds(5)))
                }

                return promise.futureResult.always { _ in timeout.cancel() }
            } catch {
                return sshChannel.eventLoop.makeFailedFuture(error)
            }
        }.get()
        log.info("[solstone-swift] hub-phone exec channel established")
        return execChannel
    }

    private func waitForReadyPort(
        execChannel: any Channel,
        onStageChange: @Sendable @escaping (SSHStageEvent) -> Void
    ) async throws -> Int {
        let readyBox = self.readyPortBox
        let outputBuffer = self.execOutputBuffer

        let timeoutTask = Task { [readyBox, outputBuffer] in
            try await Task.sleep(for: .seconds(30))
            readyBox.withLockedValue { state in
                guard !state.resolved else { return }
                state.resolved = true
                let stderr = outputBuffer.withLockedValue { $0.stderr }
                let message = stderr.isEmpty
                    ? "hub-phone did not announce ready within 30s"
                    : stderr
                let error = TunnelError.hubPhoneStartFailed(message)
                state.failureError = error
                state.continuation?.resume(throwing: error)
                state.continuation = nil
            }
        }

        let execCloseTask = Task { [readyBox, outputBuffer] in
            try? await execChannel.closeFuture.get()
            readyBox.withLockedValue { state in
                guard !state.resolved else { return }
                // Flush remaining line buffer — ready line may lack trailing newline
                let remaining = state.lineBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !remaining.isEmpty, let port = SSHTransport.parseReadyPort(from: remaining) {
                    state.discoveredPort = port
                    state.resolved = true
                    state.continuation?.resume(returning: port)
                    state.continuation = nil
                    return
                }
                state.resolved = true
                let stderr = outputBuffer.withLockedValue { $0.stderr }
                let message = stderr.isEmpty
                    ? "hub-phone exec channel closed before ready announcement"
                    : stderr
                let error = TunnelError.hubPhoneStartFailed(message)
                state.failureError = error
                state.continuation?.resume(throwing: error)
                state.continuation = nil
            }
        }

        defer {
            timeoutTask.cancel()
            execCloseTask.cancel()
        }

        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, any Error>) in
            readyBox.withLockedValue { state in
                if let port = state.discoveredPort {
                    continuation.resume(returning: port)
                } else if state.resolved {
                    let error = state.failureError ?? TunnelError.hubPhoneStartFailed("hub-phone failed before ready")
                    continuation.resume(throwing: error)
                } else {
                    state.continuation = continuation
                }
            }
        }

        onStageChange(.hubPhoneReady(port: port))
        return port
    }
}

nonisolated private final class PrivateKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let privateKey: NIOSSHPrivateKey
    private let offered = NIOLockedValueBox<Bool>(false)

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let wasOffered = self.offered.withLockedValue { v -> Bool in defer { v = true }; return v }
        if wasOffered {
            nextChallengePromise.succeed(nil)
        } else {
            nextChallengePromise.succeed(
                .init(
                    username: self.username,
                    serviceName: "ssh-connection",
                    offer: .privateKey(.init(privateKey: self.privateKey))
                )
            )
        }
    }
}

nonisolated private final class ErrorHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

nonisolated private struct ExecOutputBuffer: Sendable {
    var lines: [(isStdErr: Bool, text: String)] = []
    static let maxLines = 50

    mutating func append(_ text: String, isStdErr: Bool) {
        let newLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in newLines {
            let s = String(line)
            if !s.isEmpty {
                self.lines.append((isStdErr: isStdErr, text: s))
            }
        }
        if self.lines.count > Self.maxLines {
            self.lines.removeFirst(self.lines.count - Self.maxLines)
        }
    }

    var stderr: String {
        self.lines.filter(\.isStdErr).map(\.text).joined(separator: "\n")
    }
}

nonisolated private struct ReadyPortWaiter: Sendable {
    var lineBuffer: String = ""
    var continuation: CheckedContinuation<Int, any Error>?
    var discoveredPort: Int?
    var failureError: TunnelError?
    var resolved: Bool = false
}

nonisolated private final class ExecOnActiveHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = SSHChannelData

    let command: String
    let outputBuffer: NIOLockedValueBox<ExecOutputBuffer>
    let onOutput: @Sendable (String, Bool) -> Void

    init(
        command: String,
        outputBuffer: NIOLockedValueBox<ExecOutputBuffer>,
        onOutput: @Sendable @escaping (String, Bool) -> Void
    ) {
        self.command = command
        self.outputBuffer = outputBuffer
        self.onOutput = onOutput
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelActive(context: ChannelHandlerContext) {
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: self.command, wantReply: true)
        context.triggerUserOutboundEvent(execRequest, promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = self.unwrapInboundIn(data)
        let isStdErr = channelData.type == .stdErr
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        guard let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) else { return }
        self.outputBuffer.withLockedValue { $0.append(text, isStdErr: isStdErr) }
        self.onOutput(text, isStdErr)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            log.info("[solstone-swift] exec request accepted by server")
        case is ChannelFailureEvent:
            log.error("[solstone-swift] exec request rejected by server")
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
}

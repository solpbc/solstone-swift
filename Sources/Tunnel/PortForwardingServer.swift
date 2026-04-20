// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOSSH
import NIOTransportServices
import Network

actor PortForwardingServer {
    private let group: NIOTSEventLoopGroup
    private let bindHost: String
    private let bindPort: Int
    private let forwardingChannelConstructor: @Sendable (Channel) -> EventLoopFuture<Void>
    private var channel: Channel?

    init(
        group: NIOTSEventLoopGroup,
        bindHost: String = "127.0.0.1",
        bindPort: Int = 0,
        forwardingChannelConstructor: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) {
        self.group = group
        self.bindHost = bindHost
        self.bindPort = bindPort
        self.forwardingChannelConstructor = forwardingChannelConstructor
    }

    func start() async throws -> Int {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let channel = try await NIOTSListenerBootstrap(group: self.group)
            .childTCPOptions(tcp)
            .childChannelInitializer(self.forwardingChannelConstructor)
            .bind(host: self.bindHost, port: self.bindPort)
            .get()

        self.channel = channel
        guard let port = channel.localAddress?.port else {
            throw PortForwardingServerError.unavailableLocalAddress
        }
        return port
    }

    func close() async {
        guard let channel = self.channel else {
            return
        }

        self.channel = nil
        try? await channel.close().get()
    }
}

private enum PortForwardingServerError: Error {
    case unavailableLocalAddress
}

nonisolated final class SSHWrapperHandler: ChannelDuplexHandler, Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)

        guard case .channel = data.type, case .byteBuffer(let buffer) = data.data else {
            context.close(promise: nil)
            return
        }

        context.fireChannelRead(self.wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(data))
        context.write(self.wrapOutboundOut(wrapped), promise: promise)
    }
}

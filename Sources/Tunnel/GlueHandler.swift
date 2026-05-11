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

// Event-loop confined — all mutations occur on the pipeline event loop
nonisolated final class GlueHandler: @unchecked Sendable {
    private var partner: GlueHandler?

    private var context: ChannelHandlerContext?

    private var pendingRead: Bool = false

    private init() {}
}

extension GlueHandler {
    nonisolated static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()

        first.partner = second
        second.partner = first

        return (first, second)
    }
}

extension GlueHandler {
    nonisolated private func partnerWrite(_ data: NIOAny) {
        self.context?.write(data, promise: nil)
    }

    nonisolated private func partnerFlush() {
        self.context?.flush()
    }

    nonisolated private func partnerWriteEOF() {
        self.context?.close(mode: .output, promise: nil)
    }

    nonisolated private func partnerCloseFull() {
        self.context?.close(promise: nil)
    }

    nonisolated private func partnerBecameWritable() {
        if self.pendingRead {
            self.pendingRead = false
            self.context?.read()
        }
    }

    nonisolated private var partnerWritable: Bool {
        self.context?.channel.isWritable ?? false
    }
}

nonisolated extension GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    nonisolated func handlerAdded(context: ChannelHandlerContext) {
        self.context = context

        if context.channel.isWritable {
            self.partner?.partnerBecameWritable()
        }
    }

    nonisolated func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.partner = nil
    }

    nonisolated func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.partner?.partnerWrite(data)
    }

    nonisolated func channelReadComplete(context: ChannelHandlerContext) {
        self.partner?.partnerFlush()
    }

    nonisolated func channelInactive(context: ChannelHandlerContext) {
        self.partner?.partnerCloseFull()
    }

    nonisolated func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            self.partner?.partnerWriteEOF()
        }
    }

    nonisolated func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.partner?.partnerCloseFull()
    }

    nonisolated func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            self.partner?.partnerBecameWritable()
        }
    }

    nonisolated func read(context: ChannelHandlerContext) {
        if let partner = self.partner, partner.partnerWritable {
            context.read()
        } else {
            self.pendingRead = true
        }
    }
}

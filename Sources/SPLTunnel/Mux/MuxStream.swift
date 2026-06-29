// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum MuxConstants {
    static let initialCredit: UInt32 = 1 << 20
    static let maxConcurrentStreams: Int = 256
    static let recommendedChunk: Int = 64 << 10
    static let windowGrantThreshold: Int = 64 << 10
    static let windowLowWaterMark: Int = 16 << 10
}

public enum StreamState: Sendable, Equatable {
    case open
    case halfClosedLocal
    case halfClosedRemote
    case closed
    case resetLocal
    case resetRemote
}

public final actor MuxStream {
    public let id: UInt32
    public private(set) var state: StreamState
    public let inbound: AsyncThrowingStream<Data, Error>

    private let sink: @Sendable (Data) async throws -> Void
    private let onTerminal: @Sendable (UInt32) async -> Void
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private var inboundFinished = false
    private var didNotifyTerminal = false
    private var sendCredit = Int(MuxConstants.initialCredit)
    private var receiveWindow = Int(MuxConstants.initialCredit)
    private var consumedSinceLastGrant = 0
    private var creditWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        id: UInt32,
        state: StreamState = .open,
        sink: @escaping @Sendable (Data) async throws -> Void,
        onTerminal: @escaping @Sendable (UInt32) async -> Void
    ) {
        self.id = id
        self.state = state
        self.sink = sink
        self.onTerminal = onTerminal

        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.inbound = AsyncThrowingStream { continuation = $0 }
        self.inboundContinuation = continuation
    }

    deinit {
        inboundContinuation.finish()
    }

    public func write(_ payload: Data) async throws {
        var offset = 0
        while offset < payload.count {
            let count = min(MuxConstants.recommendedChunk, payload.count - offset)
            try await waitForCredit(count)

            let chunk = Data(payload[offset..<(offset + count)])
            let frame = try encodeFrame(buildData(streamID: id, payload: chunk))
            try await sink(frame)
            offset += count
        }

        if payload.isEmpty {
            try ensureWritable()
            let frame = try encodeFrame(buildData(streamID: id, payload: Data()))
            try await sink(frame)
        }
    }

    public func close() async throws {
        try ensureWritable()
        let frame = try encodeFrame(buildClose(streamID: id))
        try await sink(frame)

        switch state {
        case .open:
            state = .halfClosedLocal
        case .halfClosedRemote:
            state = .closed
            finishInbound(nil)
            resumeCreditWaiters()
            await notifyTerminal()
        case .halfClosedLocal, .closed, .resetLocal, .resetRemote:
            throw MuxError.writeAfterClose
        }
    }

    public func reset(reason: ResetReason) async {
        guard state != .resetLocal && state != .resetRemote && state != .closed else {
            return
        }

        let frame = buildReset(streamID: id, reason: reason)
        if let data = try? encodeFrame(frame) {
            try? await sink(data)
        }
        state = .resetLocal
        finishInbound(MuxError.streamReset(streamID: id, reason: reason, rawByte: reason.rawValue))
        resumeCreditWaiters()
        await notifyTerminal()
    }

    func deliverInboundData(_ payload: Data) async throws {
        guard state == .open || state == .halfClosedLocal else {
            return
        }
        guard payload.count <= receiveWindow else {
            await reset(reason: .flowControlError)
            throw MuxError.flowControlError
        }

        receiveWindow -= payload.count
        consumedSinceLastGrant += payload.count
        inboundContinuation.yield(payload)

        if consumedSinceLastGrant >= MuxConstants.windowGrantThreshold ||
            receiveWindow < MuxConstants.windowLowWaterMark {
            try await emitWindowGrant()
        }
    }

    func deliverInboundClose() async {
        switch state {
        case .open:
            state = .halfClosedRemote
            finishInbound(nil)
        case .halfClosedLocal:
            state = .closed
            finishInbound(nil)
            resumeCreditWaiters()
            await notifyTerminal()
        case .halfClosedRemote, .closed, .resetLocal, .resetRemote:
            finishInbound(nil)
        }
    }

    func deliverInboundReset(reason: ResetReason, rawByte: UInt8) async {
        guard state != .closed && state != .resetLocal && state != .resetRemote else {
            return
        }
        state = .resetRemote
        finishInbound(MuxError.streamReset(streamID: id, reason: reason, rawByte: rawByte))
        resumeCreditWaiters()
        await notifyTerminal()
    }

    func grantSendCredit(_ credit: UInt32) {
        sendCredit += Int(credit)
        resumeCreditWaiters()
    }

    func tearDown(reason: TearDownReason) {
        state = .closed
        switch reason {
        case .normalShutdown:
            finishInbound(nil)
        case .transportFailure, .protocolError:
            finishInbound(MuxError.transportClosed)
        }
        resumeCreditWaiters()
    }

    private func waitForCredit(_ byteCount: Int) async throws {
        while sendCredit < byteCount {
            try ensureWritable()
            await withCheckedContinuation { continuation in
                creditWaiters.append(continuation)
            }
        }

        try ensureWritable()
        sendCredit -= byteCount
    }

    private func ensureWritable() throws {
        switch state {
        case .open, .halfClosedRemote:
            return
        case .halfClosedLocal, .closed, .resetLocal, .resetRemote:
            throw MuxError.writeAfterClose
        }
    }

    private func emitWindowGrant() async throws {
        let grant = consumedSinceLastGrant
        guard grant > 0 else {
            return
        }

        consumedSinceLastGrant = 0
        receiveWindow += grant
        let frame = try encodeFrame(buildWindow(streamID: id, credit: UInt32(grant)))
        try await sink(frame)
    }

    private func finishInbound(_ error: Error?) {
        guard !inboundFinished else {
            return
        }

        inboundFinished = true
        if let error {
            inboundContinuation.finish(throwing: error)
        } else {
            inboundContinuation.finish()
        }
    }

    private func notifyTerminal() async {
        guard !didNotifyTerminal else {
            return
        }
        didNotifyTerminal = true
        await onTerminal(id)
    }

    private func resumeCreditWaiters() {
        let waiters = creditWaiters
        creditWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

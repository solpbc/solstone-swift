// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@testable import SPLTunnel

func makeRawFrameBytes(streamID: UInt32, flags: UInt8, payload: Data = Data()) -> Data {
    var data = Data()
    data.reserveCapacity(8 + payload.count)
    data.append(UInt8((streamID >> 24) & 0xff))
    data.append(UInt8((streamID >> 16) & 0xff))
    data.append(UInt8((streamID >> 8) & 0xff))
    data.append(UInt8(streamID & 0xff))
    data.append(flags)
    data.append(UInt8((payload.count >> 16) & 0xff))
    data.append(UInt8((payload.count >> 8) & 0xff))
    data.append(UInt8(payload.count & 0xff))
    data.append(payload)
    return data
}

final class BlockingFirstMuxSink: @unchecked Sendable {
    private let lock = NSLock()
    private var hasEnteredFirstCall = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    var didEnterFirstCall: Bool {
        lock.withLock {
            hasEnteredFirstCall
        }
    }

    func send(_: Data) async throws {
        let shouldBlock = lock.withLock {
            guard !hasEnteredFirstCall else {
                return false
            }
            hasEnteredFirstCall = true
            return true
        }

        guard shouldBlock else {
            return
        }

        await waitForRelease()
    }

    func release() {
        let continuation = lock.withLock {
            isReleased = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private func waitForRelease() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldResume = lock.withLock {
                if isReleased {
                    return true
                }
                self.continuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

final class CapturingMuxSink: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = FrameDecoder()
    private var capturedFrames: [Frame] = []

    var frames: [Frame] {
        lock.withLock {
            capturedFrames
        }
    }

    func send(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        decoder.feed(data)
        while let frame = try decoder.next() {
            capturedFrames.append(frame)
        }
    }
}

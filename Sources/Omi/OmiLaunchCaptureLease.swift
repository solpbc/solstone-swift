// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct OmiLaunchCaptureReadPosition: Equatable, Sendable {
    let generationID: UUID
    let nextSequence: UInt64
    let offset: Int
}

nonisolated struct OmiLaunchCaptureLease: Equatable, Sendable {
    let generationID: UUID
    let startSequence: UInt64
    let startOffset: Int
    let throughSequence: UInt64
    let endOffset: Int
    let records: [OmiLaunchCaptureRecord]
}

nonisolated enum OmiLaunchCaptureLeaseFailureReason: String, Equatable, Sendable {
    case captureUnreadable
    case cursorUnreadable
    case cursorDoesNotMatchCapture
}

nonisolated enum OmiLaunchCaptureLeaseOutcome: Equatable, Sendable {
    case lease(OmiLaunchCaptureLease)
    case empty
    case unavailable(OmiLaunchCaptureLeaseFailureReason)
}

nonisolated enum OmiLaunchCaptureLeaseLogic {
    static func headerEnd(
        generationID: UUID,
        startSequence: UInt64,
        startOffset: Int,
        throughSequence: UInt64,
        read: (Int, Int) throws -> Data
    ) throws -> Int? {
        guard throughSequence >= startSequence else { return startOffset }
        var sequence = startSequence
        var offset = startOffset
        while sequence <= throughSequence {
            let data = try read(offset, OmiLaunchCaptureFormat.headerByteCount)
            guard data.count == OmiLaunchCaptureFormat.headerByteCount,
                  case .success(let header) = OmiLaunchCaptureHeader.decode(data),
                  header.generationID == generationID,
                  header.sequence == sequence
            else { return nil }
            offset += OmiLaunchCaptureFormat.headerByteCount + header.declaredPayloadBytes + OmiLaunchCaptureFormat.recordTagByteCount
            if sequence == UInt64.max { return nil }
            sequence += 1
        }
        return offset
    }
}

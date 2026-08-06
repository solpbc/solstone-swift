// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum OmiLaunchCaptureLogic {
    static func unixMicros(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded(.towardZero))
    }

    static func scan(
        generationID: UUID,
        fileSize: Int,
        read: (Int, Int) throws -> Data
    ) -> OmiLaunchCaptureRecoveryResult {
        guard fileSize > 0 else {
            return OmiLaunchCaptureRecoveryResult(verifiedRecords: [])
        }

        var records: [OmiLaunchCaptureRecord] = []
        var offset = 0
        var expectedSequence: UInt64 = 0

        while offset < fileSize {
            let headerData: Data
            do {
                headerData = try read(offset, OmiLaunchCaptureFormat.headerByteCount)
            } catch {
                return self.boundary(records, sequence: nil, reason: .readFailed, offset: offset)
            }
            guard headerData.count == OmiLaunchCaptureFormat.headerByteCount else {
                return self.boundary(records, sequence: nil, reason: .incompleteHeader, offset: offset)
            }

            let header: OmiLaunchCaptureHeader
            switch OmiLaunchCaptureHeader.decode(headerData) {
            case .success(let decoded):
                header = decoded
            case .failure(let reason):
                return self.boundary(records, sequence: nil, reason: reason, offset: offset)
            }
            guard header.generationID == generationID else {
                return self.boundary(records, sequence: header.sequence, reason: .generationMismatch, offset: offset)
            }
            guard header.sequence == expectedSequence else {
                return self.boundary(records, sequence: header.sequence, reason: .sequenceMismatch, offset: offset)
            }

            let bodyByteCount = header.declaredPayloadBytes + OmiLaunchCaptureFormat.recordTagByteCount
            let body: Data
            do {
                body = try read(offset + OmiLaunchCaptureFormat.headerByteCount, bodyByteCount)
            } catch {
                return self.boundary(records, sequence: nil, reason: .readFailed, offset: offset)
            }
            // A trusted reservation header makes a short body a visible gap. Never scan past it.
            guard body.count == bodyByteCount else {
                return self.boundary(
                    records,
                    sequence: header.sequence,
                    reason: .incompleteReservedRecord,
                    offset: offset
                )
            }

            let payload = body.prefix(header.declaredPayloadBytes)
            let storedTag = body.suffix(OmiLaunchCaptureFormat.recordTagByteCount)
            guard OmiLaunchCaptureDigest.recordTag(header: headerData, payload: Data(payload)) == storedTag else {
                return self.boundary(records, sequence: header.sequence, reason: .recordTagMismatch, offset: offset)
            }

            records.append(OmiLaunchCaptureRecord(
                generationID: header.generationID,
                sequence: header.sequence,
                acquiredAtUnixMicros: header.acquiredAtUnixMicros,
                payload: Data(payload)
            ))
            offset += OmiLaunchCaptureFormat.headerByteCount + bodyByteCount
            expectedSequence += 1
        }

        return OmiLaunchCaptureRecoveryResult(verifiedRecords: records)
    }

    private static func boundary(
        _ records: [OmiLaunchCaptureRecord],
        sequence: UInt64?,
        reason: OmiLaunchCaptureBoundaryReason,
        offset: Int
    ) -> OmiLaunchCaptureRecoveryResult {
        OmiLaunchCaptureRecoveryResult(
            verifiedRecords: records,
            boundarySequence: sequence,
            boundaryReason: reason,
            boundaryOffset: offset
        )
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Crypto
import Foundation

nonisolated enum OmiLaunchCaptureMaterializationIdentity {
    static func itemID(generationID: UUID, partitionOrdinal: Int, startSequence: UInt64, startSampleOffset: UInt64) -> UUID {
        var bytes = Data("omi-launch-capture-materializer-item-v1".utf8)
        bytes.append(uuidBytes: generationID)
        bytes.appendLittleEndian(UInt64(partitionOrdinal))
        bytes.appendLittleEndian(startSequence)
        bytes.appendLittleEndian(startSampleOffset)
        var raw = Array(SHA256.hash(data: bytes).prefix(16))
        raw[6] = (raw[6] & 0x0F) | 0x50
        raw[8] = (raw[8] & 0x3F) | 0x80
        return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7], raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
    }
}

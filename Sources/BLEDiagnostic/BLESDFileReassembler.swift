// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct BLESDFileReassembler: Equatable, Sendable {
    private var buffer = Data()

    mutating func ingest(_ payload: Data) -> BLEReassemblyOutput {
        guard !payload.isEmpty else {
            return BLEReassemblyOutput()
        }

        self.buffer.append(payload)

        var completedFrames: [Data] = []
        var markers: [BLEAudioMarker] = []
        var cursor = self.buffer.startIndex

        while cursor < self.buffer.endIndex {
            let prefix = self.buffer[cursor]

            if prefix == 0x00 {
                cursor = self.buffer.index(after: cursor)
                continue
            }

            if prefix == 0xFF {
                let unitEnd = self.buffer.index(cursor, offsetBy: 5, limitedBy: self.buffer.endIndex)
                guard let unitEnd else {
                    break
                }

                let epochStart = self.buffer.index(after: cursor)
                let epochBytes = Array(self.buffer[epochStart..<unitEnd])
                let epoch = UInt32(epochBytes[0])
                    | (UInt32(epochBytes[1]) << 8)
                    | (UInt32(epochBytes[2]) << 16)
                    | (UInt32(epochBytes[3]) << 24)
                markers.append(.audio(epoch: epoch))
                cursor = unitEnd
                continue
            }

            let length = Int(prefix)
            let payloadStart = self.buffer.index(after: cursor)
            let payloadEnd = self.buffer.index(payloadStart, offsetBy: length, limitedBy: self.buffer.endIndex)
            guard let payloadEnd else {
                break
            }

            completedFrames.append(Data(self.buffer[payloadStart..<payloadEnd]))
            cursor = payloadEnd
        }

        if cursor > self.buffer.startIndex {
            self.buffer.removeSubrange(self.buffer.startIndex..<cursor)
        }

        return BLEReassemblyOutput(completedFrames: completedFrames, markers: markers)
    }
}

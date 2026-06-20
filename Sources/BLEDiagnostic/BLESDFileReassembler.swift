// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct BLESDFileReassembler: Equatable, Sendable {
    func ingest(_ block: Data) -> [Data] {
        guard !block.isEmpty else {
            return []
        }

        var frames: [Data] = []
        var i = block.startIndex
        while i < block.endIndex {
            let length = Int(block[i])
            if length == 0 {
                break
            }

            let frameStart = block.index(after: i)
            guard let frameEnd = block.index(frameStart, offsetBy: length, limitedBy: block.endIndex),
                  frameEnd <= block.endIndex
            else {
                break
            }

            frames.append(Data(block[frameStart..<frameEnd]))
            i = frameEnd
        }

        return frames
    }
}

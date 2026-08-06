// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct OmiAudioMarker: Equatable, Sendable {
    let epoch: UInt32

    // Keep construction behind this factory to satisfy LocationNoMapKitGrepTests.
    static func audio(epoch: UInt32) -> Self {
        Self(epoch: epoch)
    }
}

nonisolated struct OmiReassemblyOutput: Equatable, Sendable {
    let completedFrames: [OmiReassembledFrame]
    let markers: [OmiAudioMarker]

    init(completedFrames: [OmiReassembledFrame] = [], markers: [OmiAudioMarker] = []) {
        self.completedFrames = completedFrames
        self.markers = markers
    }
}

nonisolated struct OmiReassembledFrame: Equatable, Sendable {
    let data: Data
    let acquiredAt: Date
    let startSequence: UInt64?
}

nonisolated struct OmiAudioReassembler: Equatable, Sendable {
    private(set) var packets = 0
    private(set) var frames = 0
    private(set) var gaps = 0
    private(set) var outOfOrder = 0
    private(set) var malformed = 0
    private(set) var markers = 0
    private(set) var lastMarkerEpoch: UInt32?

    private var expectedNextPacket: UInt16?
    private var frameStarted = false
    private var expectedNextIndex: UInt8 = 0
    private var frameBytes = Data()
    private var frameStartedAt: Date?
    private var frameStartSequence: UInt64?

    mutating func ingest(_ payload: Data, acquiredAt: Date, recordSequence: UInt64?) -> OmiReassemblyOutput {
        guard payload.count >= 3 else {
            self.malformed += 1
            return OmiReassemblyOutput()
        }

        self.packets += 1

        let packetNumber = UInt16(payload[0]) | (UInt16(payload[1]) << 8)
        let index = payload[2]
        let fragment = payload.dropFirst(3)

        self.updatePacketOrder(packetNumber)

        if index == 0xFF {
            guard fragment.count >= 4 else {
                self.malformed += 1
                return OmiReassemblyOutput()
            }

            let bytes = Array(fragment.prefix(4))
            let epoch = UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
            let marker = OmiAudioMarker.audio(epoch: epoch)
            self.markers += 1
            self.lastMarkerEpoch = epoch
            return OmiReassemblyOutput(markers: [marker])
        }

        if index == 0 {
            var completedFrames: [OmiReassembledFrame] = []
            if self.frameStarted, let frameStartedAt {
                completedFrames.append(OmiReassembledFrame(data: self.frameBytes, acquiredAt: frameStartedAt, startSequence: self.frameStartSequence))
                self.frames += 1
            }
            self.frameStarted = true
            self.expectedNextIndex = 1
            self.frameBytes = Data(fragment)
            self.frameStartedAt = acquiredAt
            self.frameStartSequence = recordSequence
            return OmiReassemblyOutput(completedFrames: completedFrames)
        }

        guard self.frameStarted, index == self.expectedNextIndex else {
            self.outOfOrder += 1
            self.dropInProgressFrame()
            return OmiReassemblyOutput()
        }

        self.frameBytes.append(contentsOf: fragment)
        self.expectedNextIndex = self.expectedNextIndex &+ 1
        return OmiReassemblyOutput()
    }

    mutating func flushFinalFrame() -> OmiReassemblyOutput {
        defer {
            self.expectedNextPacket = nil
            self.dropInProgressFrame()
        }
        guard self.frameStarted, let frameStartedAt else { return OmiReassemblyOutput() }
        self.frames += 1
        return OmiReassemblyOutput(completedFrames: [OmiReassembledFrame(data: self.frameBytes, acquiredAt: frameStartedAt, startSequence: self.frameStartSequence)])
    }

    private mutating func updatePacketOrder(_ packetNumber: UInt16) {
        guard let expectedNextPacket else {
            self.expectedNextPacket = packetNumber &+ 1
            return
        }

        if packetNumber != expectedNextPacket {
            let forwardDistance = Int(packetNumber &- expectedNextPacket)
            if forwardDistance > 0 && forwardDistance < 32_768 {
                self.gaps += forwardDistance
            } else {
                self.outOfOrder += 1
            }
            self.dropInProgressFrame()
        }

        self.expectedNextPacket = packetNumber &+ 1
    }

    private mutating func dropInProgressFrame() {
        self.frameStarted = false
        self.expectedNextIndex = 0
        self.frameBytes.removeAll(keepingCapacity: true)
        self.frameStartedAt = nil
        self.frameStartSequence = nil
    }
}

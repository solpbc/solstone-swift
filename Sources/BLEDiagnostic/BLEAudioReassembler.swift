// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct BLEAudioMarker: Equatable, Sendable {
    let epoch: UInt32

    // Keep construction behind this factory to satisfy LocationNoMapKitGrepTests.
    static func audio(epoch: UInt32) -> Self {
        Self(epoch: epoch)
    }
}

nonisolated struct BLEReassemblyOutput: Equatable, Sendable {
    let completedFrames: [Data]
    let markers: [BLEAudioMarker]

    init(completedFrames: [Data] = [], markers: [BLEAudioMarker] = []) {
        self.completedFrames = completedFrames
        self.markers = markers
    }
}

nonisolated struct BLEAudioReassembler: Equatable, Sendable {
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

    mutating func ingest(_ payload: Data) -> BLEReassemblyOutput {
        guard payload.count >= 3 else {
            self.malformed += 1
            return BLEReassemblyOutput()
        }

        self.packets += 1

        let packetNumber = UInt16(payload[0]) | (UInt16(payload[1]) << 8)
        let index = payload[2]
        let fragment = payload.dropFirst(3)

        self.updatePacketOrder(packetNumber)

        if index == 0xFF {
            guard fragment.count >= 4 else {
                self.malformed += 1
                return BLEReassemblyOutput()
            }

            let bytes = Array(fragment.prefix(4))
            let epoch = UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
            let marker = BLEAudioMarker.audio(epoch: epoch)
            self.markers += 1
            self.lastMarkerEpoch = epoch
            return BLEReassemblyOutput(markers: [marker])
        }

        if index == 0 {
            var completedFrames: [Data] = []
            if self.frameStarted {
                completedFrames.append(self.frameBytes)
                self.frames += 1
            }
            self.frameStarted = true
            self.expectedNextIndex = 1
            self.frameBytes = Data(fragment)
            return BLEReassemblyOutput(completedFrames: completedFrames)
        }

        guard self.frameStarted, index == self.expectedNextIndex else {
            self.outOfOrder += 1
            self.dropInProgressFrame()
            return BLEReassemblyOutput()
        }

        self.frameBytes.append(contentsOf: fragment)
        self.expectedNextIndex = self.expectedNextIndex &+ 1
        return BLEReassemblyOutput()
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
    }
}

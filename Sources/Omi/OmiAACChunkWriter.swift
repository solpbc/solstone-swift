// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation

@MainActor
protocol OmiAACChunkWriting: AnyObject {
    func open(at url: URL) throws
    func write(samples: ArraySlice<Int16>) throws
    func close() throws
    func synchronize(at url: URL) throws
}

@MainActor
final class AVFoundationOmiAACChunkWriter: OmiAACChunkWriting {
    private let io: any OmiLaunchCaptureIO
    private var file: AVAudioFile?

    init(io: any OmiLaunchCaptureIO) { self.io = io }
    func open(at url: URL) throws { self.file = try AVAudioFile(forWriting: url, settings: OmiAudioChunkFormat.aacSettings, commonFormat: .pcmFormatInt16, interleaved: false) }
    func write(samples: ArraySlice<Int16>) throws {
        guard let file, let buffer = OmiAudioChunkFormat.makeBuffer(samples) else { throw CocoaError(.fileWriteUnknown) }
        try file.write(from: buffer)
    }
    func close() throws { self.file?.close(); self.file = nil }
    func synchronize(at url: URL) throws {
        let token = try self.io.openOrCreateAppendFile(at: url)
        defer { try? self.io.close(token) }
        try self.io.fullSynchronize(token)
    }
}

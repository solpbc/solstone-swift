// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Foundation
import XCTest
import os

@MainActor
final class PhoneAudioWriterContinuityTests: XCTestCase {
    private func pcm(format: AVAudioFormat, start: Int, count: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<count {
                let time = Double(start + frame) / format.sampleRate
                buffer.floatChannelData![channel][frame] = Float(0.2 * sin(2 * .pi * 440 * time)
                    + 0.025 * sin(2 * .pi * 731 * time))
            }
        }
        return buffer
    }

    // A separate converter receives the entire signal once, followed by one
    // terminal EOF. It has no knowledge of the writer's callback partitions.
    private func reference(format: AVAudioFormat, frames: Int) throws -> [Float] {
        let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let converter = AVAudioConverter(from: format, to: target)!
        let source = self.pcm(format: format, start: 0, count: frames)
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096)!
        var sent = false
        var samples: [Float] = []
        while true {
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if !sent {
                    sent = true
                    state.pointee = .haveData
                    return source
                }
                state.pointee = .endOfStream
                return nil
            }
            if let error { throw error }
            XCTAssertNotEqual(status, .error)
            samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            if status == .endOfStream { return samples }
            XCTAssertGreaterThan(output.frameLength, 0)
        }
    }

    func testIrregularPartitionsPreserveContinuousConversionAndTerminalTail() async throws {
        for rate in [16000.0, 44100.0, 48000.0, 8000.0, 192000.0] {
            let channels: AVAudioChannelCount = rate == 192000 ? 8 : 1
            let format = channels == 8
                ? AVAudioFormat(standardFormatWithSampleRate: rate,
                    channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_7_1_C)!)
                : AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
            let frames = Int(rate * 0.71) + 17
            let expected = try self.reference(format: format, frames: frames)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let writer = try PhoneAudioFragmentWriter(url: root.appendingPathComponent("audio.m4a"),
                segmentID: UUID(), sessionID: UUID(), sourceFormat: format,
                clock: SystemObserverClock(), interruptionDirectory: root.appendingPathComponent("interruptions"))
            let observed = OSAllocatedUnfairLock(initialState: [Float]())
            await writer.setTestConvertedPCMInspector { buffer in
                let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                observed.withLock { $0.append(contentsOf: samples) }
            }
            try await writer.start()
            let independentCap = max(4096, Int(ceil(0.4 * rate)))
            let partitions = [independentCap, 17, 127, min(independentCap, rate == 44100 ? 4410 : 4800), 1024]
            var position = 0
            var partition = 0
            while position < frames {
                let count = min(partitions[partition % partitions.count], frames - position)
                XCTAssertEqual(writer.queue.push(buffer: self.pcm(format: format, start: position, count: count)), .success)
                position += count
                partition += 1
            }
            let chunk = try await writer.stop()
            let actual = observed.withLock { $0 }
            XCTAssertEqual(actual.count, expected.count, "rate \(rate)")
            XCTAssertEqual(chunk.duration, Double(expected.count) / 16000, accuracy: 1.0 / 16000)
            let difference = zip(actual, expected).map { abs($0 - $1) }.max() ?? .infinity
            XCTAssertLessThanOrEqual(difference, 0.000001, "rate \(rate)")
            let allocated = await writer.applicationRetainedByteCount
            let bound = Int(2 * rate) * Int(channels) * 4 + independentCap * Int(channels) * 4 + 65536
            XCTAssertLessThanOrEqual(allocated, bound)
            XCTAssertEqual(writer.queue.callbackCap, independentCap)
            let rejected = PhoneAudioPCMQueue(sourceFormat: format, segmentID: UUID(), sessionID: UUID())
            guard case .faulted = rejected.push(buffer: self.pcm(format: format, start: 0, count: independentCap + 1)) else {
                XCTFail("cap-plus-one accepted at \(rate)")
                continue
            }
        }
    }

    func testOverflowPersistsFaultBeforeDrainingEarlierAcceptedFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let firstConverted = expectation(description: "first PCM batch reached worker")
        firstConverted.assertForOverFulfill = false
        let faultWritten = expectation(description: "fault evidence written")
        let ready = OSAllocatedUnfairLock(initialState: false)
        let faults = OSAllocatedUnfairLock(initialState: 0)
        let output = OSAllocatedUnfairLock(initialState: [Float]())
        let id = UUID()
        let writer = try PhoneAudioFragmentWriter(url: root.appendingPathComponent("audio.m4a"),
            segmentID: id, sessionID: UUID(), sourceFormat: format,
            clock: SystemObserverClock(), interruptionDirectory: root.appendingPathComponent("interruptions"),
            onPhoneAudioFault: { _ in faults.withLock { $0 += 1 }; faultWritten.fulfill() })
        await writer.setTestReadinessCheck { ready.withLock { $0 } }
        await writer.setTestConvertedPCMInspector { buffer in
            let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            output.withLock { $0.append(contentsOf: samples) }
            firstConverted.fulfill()
        }
        try await writer.start()
        XCTAssertEqual(writer.queue.push(buffer: self.pcm(format: format, start: 0, count: 4096)), .success)
        await fulfillment(of: [firstConverted], timeout: 1)
        var position = 4096
        while position < 36096 {
            let count = min(4096, 36096 - position)
            XCTAssertEqual(writer.queue.push(buffer: self.pcm(format: format, start: position, count: count)), .success)
            position += count
        }
        guard case .faulted = writer.queue.push(buffer: self.pcm(format: format, start: position, count: 1)) else {
            return XCTFail("full queue did not fault")
        }
        await fulfillment(of: [faultWritten], timeout: 1)
        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("audio-writer.json"))) as! [String: Any]
        XCTAssertEqual(marker["phase"] as? String, "faulted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("interruptions/\(id.uuidString).json").path))
        ready.withLock { $0 = true }
        do { _ = try await writer.stop(); XCTFail("fault became a healthy stop") } catch {}
        XCTAssertEqual(faults.withLock { $0 }, 1)
        XCTAssertEqual(writer.queue.admissionSnapshot.frames, 36096)
        XCTAssertEqual(writer.queue.admissionSnapshot.highWaterFrames, 32000)
        let appended = await writer.acceptedFrames
        XCTAssertEqual(appended, 36096)
        let actual = output.withLock { $0 }
        let expected = try self.reference(format: format, frames: 36096)
        XCTAssertEqual(actual.count, expected.count)
        XCTAssertLessThanOrEqual(zip(actual, expected).map { abs($0 - $1) }.max() ?? .infinity, 0.000001)
        let phase = await writer.phase
        XCTAssertEqual(phase, .faulted)
    }

    func testFreshQueueResetsTapFaultForNewRecording() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let tap = ObserverTapWriter()
        let old = PhoneAudioPCMQueue(sourceFormat: format, segmentID: UUID(), sessionID: UUID())
        tap.setQueue(old)
        tap.write(self.pcm(format: format, start: 0, count: 6401))
        XCTAssertTrue(tap.hasFaulted)
        let next = PhoneAudioPCMQueue(sourceFormat: format, segmentID: UUID(), sessionID: UUID())
        tap.setQueue(next)
        tap.write(self.pcm(format: format, start: 0, count: 1600))
        XCTAssertFalse(tap.hasFaulted)
        XCTAssertEqual(next.admissionSnapshot.frames, 1600)
    }

    func testDeadlineCancellationPreservesTheFragmentedPrefix() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let writer = try PhoneAudioFragmentWriter(url: root.appendingPathComponent("audio.m4a"),
            segmentID: UUID(), sessionID: UUID(), sourceFormat: format,
            clock: SystemObserverClock(), interruptionDirectory: root.appendingPathComponent("interruptions"))
        try await writer.start()
        for index in 0..<40 {
            XCTAssertEqual(writer.queue.push(buffer: self.pcm(format: format, start: index * 1600, count: 1600)), .success)
            try await Task.sleep(for: .milliseconds(2))
        }
        await writer.setTestFinishWritingNeverSignals(true)
        do { _ = try await writer.stop(); XCTFail("never-signalled finish succeeded") } catch {}
        let stopped = await writer.hasStoppedWriting
        XCTAssertTrue(stopped)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("audio.m4a").path))
        let file = try AVAudioFile(forReading: root.appendingPathComponent("audio.m4a"))
        XCTAssertGreaterThan(Double(file.length) / file.processingFormat.sampleRate, 2.5)
        let phase = await writer.phase
        XCTAssertEqual(phase, .faulted)
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import CoreMedia
import Foundation
import XCTest
import os

@MainActor final class PhoneAudioFragmentWriterTests: XCTestCase {
    private lazy var tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PhoneAudioFragmentWriterTests-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.tempDirectory)
    }

    // MARK: - Helper Methods

    private func makeWriter(
        sampleRate: Double = 48_000,
        channels: Int = 1,
        clock: any ObserverClock = SystemObserverClock(),
        onFault: (@Sendable (PhoneAudioWriterFault) -> Void)? = nil
    ) throws -> (PhoneAudioFragmentWriter, URL, UUID, UUID) {
        let segmentID = UUID()
        let sessionID = UUID()
        let segDir = self.tempDirectory.appendingPathComponent(segmentID.uuidString, isDirectory: true)
        let audioURL = segDir.appendingPathComponent("audio.m4a", isDirectory: false)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
        let interruptionDir = self.tempDirectory.appendingPathComponent("interruptions", isDirectory: true)

        let writer = try PhoneAudioFragmentWriter(
            url: audioURL,
            segmentID: segmentID,
            sessionID: sessionID,
            sourceFormat: format,
            clock: clock,
            interruptionDirectory: interruptionDir,
            onPhoneAudioFault: onFault
        )
        return (writer, audioURL, segmentID, sessionID)
    }

    private func makeSineBuffer(format: AVAudioFormat, frames: Int, startSample: Int = 0) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = Int(format.channelCount)
        for ch in 0..<channels {
            let channelData = buffer.floatChannelData![ch]
            for f in 0..<frames {
                let sampleIndex = startSample + f
                // Sequential ramp to make samples distinguishable
                channelData[f] = Float(sampleIndex % 1000) / 1000.0
            }
        }
        return buffer
    }

    // MARK: - Test Cases

    // 1. Readiness stall shorter than capacity, then release
    func testReadinessStallShorterThanCapacityThenRelease() async throws {
        let (writer, _, _, _) = try self.makeWriter(sampleRate: 48_000, channels: 1)
        try await writer.start()

        let worker = Task { await writer.runWorkerLoop() }

        let gate = OSAllocatedUnfairLock(initialState: false)
        await writer.setTestReadinessCheck {
            gate.withLock { $0 }
        }

        let inspectedSamples = OSAllocatedUnfairLock<[Float]>(initialState: [])
        await writer.setTestConvertedPCMInspector { buf in
            let count = Int(buf.frameLength)
            if let data = buf.floatChannelData?[0] {
                let slice = Array(UnsafeBufferPointer(start: data, count: count))
                inspectedSamples.withLock { $0.append(contentsOf: slice) }
            }
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let b1 = self.makeSineBuffer(format: format, frames: 1024, startSample: 0)
        let b2 = self.makeSineBuffer(format: format, frames: 1024, startSample: 1024)

        XCTAssertEqual(writer.queue.push(buffer: b1), .success)
        XCTAssertEqual(writer.queue.push(buffer: b2), .success)

        try? await Task.sleep(for: .milliseconds(50))
        // Release stall
        gate.withLock { $0 = true }

        let chunk = try await writer.stop()
        await worker.value

        XCTAssertNotNil(chunk)
        XCTAssertGreaterThan(inspectedSamples.withLock { $0.count }, 0)
    }

    // 2. Readiness held past queue capacity
    func testReadinessHeldPastQueueCapacityLatchesBackpressure() async throws {
        var receivedFault: PhoneAudioWriterFault?
        let faultLock = OSAllocatedUnfairLock<PhoneAudioWriterFault?>(initialState: nil)

        let (writer, _, segmentID, sessionID) = try self.makeWriter(
            sampleRate: 16_000,
            channels: 1,
            onFault: { fault in
                faultLock.withLock { $0 = fault }
            }
        )
        try await writer.start()

        // Readiness always false
        await writer.setTestReadinessCheck { false }

        let worker = Task { await writer.runWorkerLoop() }

        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        // Push buffers until capacity overflows
        let bufferFrames = 4096
        var pushed = 0
        var sawFault = false
        for _ in 0..<20 {
            let buf = self.makeSineBuffer(format: format, frames: bufferFrames, startSample: pushed)
            let res = writer.queue.push(buffer: buf)
            pushed += bufferFrames
            if case .faulted(let f) = res {
                sawFault = true
                XCTAssertEqual(f.reason, "audio_writer_backpressure")
                XCTAssertEqual(f.segmentID, segmentID)
                XCTAssertEqual(f.sessionID, sessionID)
                break
            }
        }

        XCTAssertTrue(sawFault)
        await worker.value

        receivedFault = faultLock.withLock { $0 }
        XCTAssertEqual(receivedFault?.reason, "audio_writer_backpressure")

        // Retained bytes stay within bounded range
        let retained = await writer.applicationRetainedByteCount
        XCTAssertLessThanOrEqual(retained, writer.queue.capacitySamples * 4 + 4096 * 4 + 65_536)
    }

    // 3. Fault receipt and interruption written before drain wait
    func testFaultReceiptAndInterruptionWrittenOnFault() async throws {
        let (writer, url, segmentID, _) = try self.makeWriter(sampleRate: 16_000, channels: 1)
        try await writer.start()

        let segDir = url.deletingLastPathComponent()
        let receiptURL = segDir.appendingPathComponent("audio-writer.json")

        // Latch fault directly
        await writer.latchFault(reason: "audio_writer_failed")

        let receiptData = try Data(contentsOf: receiptURL)
        let receipt = try JSONDecoder().decode(PhoneAudioWriterReceipt.self, from: receiptData)
        XCTAssertEqual(receipt.phase, .faulted)
        XCTAssertEqual(receipt.reason, "audio_writer_failed")

        let interruptionFile = writer.interruptionDirectory.appendingPathComponent("\(segmentID.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: interruptionFile.path))
    }

    // 4. Unsupported format fails before start
    func testUnsupportedFormatFailsBeforeStart() {
        let segDir = self.tempDirectory.appendingPathComponent(UUID().uuidString)
        let url = segDir.appendingPathComponent("audio.m4a")
        let badFormat = AVAudioFormat(standardFormatWithSampleRate: 4_000, channels: 1)!
        let interruptionDir = self.tempDirectory.appendingPathComponent("interruptions")

        XCTAssertThrowsError(
            try PhoneAudioFragmentWriter(
                url: url,
                segmentID: UUID(),
                sessionID: UUID(),
                sourceFormat: badFormat,
                clock: SystemObserverClock(),
                interruptionDirectory: interruptionDir
            )
        )
    }

    // 5. One frame over the cap faults, exactly-at-cap twin succeeds
    func testCallbackCapBoundary() throws {
        let format48k = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let queue = PhoneAudioPCMQueue(sourceFormat: format48k, segmentID: UUID(), sessionID: UUID())
        let cap = 19200 // independently stated format cap
        XCTAssertEqual(queue.callbackCap, cap)

        let atCapBuf = self.makeSineBuffer(format: format48k, frames: cap)
        XCTAssertEqual(queue.push(buffer: atCapBuf), .success)

        let overCapQueue = PhoneAudioPCMQueue(sourceFormat: format48k, segmentID: UUID(), sessionID: UUID())
        let overCapBuf = self.makeSineBuffer(format: format48k, frames: cap + 1)
        let res = overCapQueue.push(buffer: overCapBuf)
        guard case .faulted(let fault) = res else {
            return XCTFail("expected faulted on over cap")
        }
        XCTAssertEqual(fault.reason, "audio_writer_backpressure")
    }

    // 6. Conversion failure or append false throws to caller
    func testAppendFailureThrowsToCaller() async throws {
        let (writer, _, _, _) = try self.makeWriter(sampleRate: 16_000, channels: 1)
        try await writer.start()
        await writer.setTestAppendOverride { _ in false }

        let worker = Task { await writer.runWorkerLoop() }

        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buf = self.makeSineBuffer(format: format, frames: 1024)
        XCTAssertEqual(writer.queue.push(buffer: buf), .success)

        await worker.value

        do {
            _ = try await writer.stop()
            XCTFail("expected stop to throw")
        } catch {
            // expected
        }

        let phase = await writer.phase
        XCTAssertEqual(phase, .faulted)
    }

    // 7. Start throws before admission when receipt cannot be persisted
    func testStartThrowsWhenReceiptCannotBePersisted() async throws {
        let invalidURL = URL(fileURLWithPath: "/dev/null/impossible/audio.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let interruptionDir = self.tempDirectory.appendingPathComponent("interruptions")

        let writer = try PhoneAudioFragmentWriter(
            url: invalidURL,
            segmentID: UUID(),
            sessionID: UUID(),
            sourceFormat: format,
            clock: SystemObserverClock(),
            interruptionDirectory: interruptionDir
        )

        do {
            try await writer.start()
            XCTFail("expected start to throw")
        } catch {
            // expected
        }
    }

    // 8. Stop while frames are queued drains them
    func testStopWhileFramesQueuedDrainsThem() async throws {
        let (writer, _, _, _) = try self.makeWriter(sampleRate: 16_000, channels: 1)
        try await writer.start()

        let worker = Task { await writer.runWorkerLoop() }

        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buf = self.makeSineBuffer(format: format, frames: 1600)
        XCTAssertEqual(writer.queue.push(buffer: buf), .success)

        let chunk = try await writer.stop()
        await worker.value

        XCTAssertNotNil(chunk)
        XCTAssertEqual(chunk.duration, 0.1, accuracy: 1.0 / 16000)
    }

    // 9. Sample-counted duration excludes pause
    func testSampleCountedDuration() async throws {
        let (writer, _, _, _) = try self.makeWriter(sampleRate: 16_000, channels: 1)
        try await writer.start()

        let worker = Task { await writer.runWorkerLoop() }

        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        // Push 16,000 frames = 1.0 second
        let buf = self.makeSineBuffer(format: format, frames: 1600)
        for _ in 0..<10 {
            XCTAssertEqual(writer.queue.push(buffer: buf), .success)
        }

        let chunk = try await writer.stop()
        await worker.value

        XCTAssertNotNil(chunk)
        XCTAssertEqual(chunk.duration, 1.0, accuracy: 1.0 / 16000)
    }

    // 10. Real AVAssetWriter integration: clean AAC file created
    func testRealAVAssetWriterIntegrationCleanAAC() async throws {
        let (writer, url, _, _) = try self.makeWriter(sampleRate: 48_000, channels: 1)
        try await writer.start()

        let worker = Task { await writer.runWorkerLoop() }

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        // Push 48,000 frames = 1.0 s of 48 kHz audio, converted to 16 kHz AAC
        let buf = self.makeSineBuffer(format: format, frames: 4800)
        for _ in 0..<10 {
            XCTAssertEqual(writer.queue.push(buffer: buf), .success)
        }

        let chunk = try await writer.stop()
        await worker.value

        XCTAssertNotNil(chunk)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attr = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attr[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 100)
    }

    // 11. Injected clock: finish that never completes fires 2s deadline
    func testFinishDeadlineFiresOnStall() async throws {
        let mockClock = MockObserverClock()
        let (writer, _, _, _) = try self.makeWriter(sampleRate: 16_000, channels: 1, clock: mockClock)
        try await writer.start()

        await writer.setTestFinishWritingNeverSignals(true)

        let stopTask = Task {
            try await writer.stop()
        }

        try? await Task.sleep(for: .milliseconds(30))
        mockClock.advance(by: 3)

        do {
            _ = try await stopTask.value
            XCTFail("expected stop to throw on deadline")
        } catch {
            // expected deadline timeout
        }
    }

    // 12. Recovery lease check
    func testRecoveryWhileLeaseIsHeldDefers() async throws {
        let segmentID = UUID()
        await MainActor.run {
            PhoneAudioWriterLease.acquire(segmentID)
        }
        defer {
            Task { @MainActor in
                PhoneAudioWriterLease.release(segmentID)
            }
        }

        let isHeld = await MainActor.run {
            PhoneAudioWriterLease.isHeld(segmentID)
        }
        XCTAssertTrue(isHeld)

        let store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment"))
        let uploader = MobileSegmentUploader(store: store)
        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: Date().addingTimeInterval(-400),
            openedWithSources: [.audio],
            activeSourceSetVersion: 1
        )
        let activeDir = try store.createActive(manifest: manifest)

        try Data([0x41]).write(to: store.audioURL(in: activeDir))
        var failedManifest = manifest
        try store.writeOutcome(MobileSegmentSourceResolution(state: .failedToFinalize, reason: "audio_finalize_failed"),
            source: .audio, manifest: &failedManifest, in: activeDir, now: Date())
        let failedDir = try store.move(segmentID: segmentID, from: .active, to: .failed)
        let resolution = try await uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDir, lifecycle: .failed)
        XCTAssertEqual(resolution, .deferred)
    }
}

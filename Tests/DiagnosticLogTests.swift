// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class DiagnosticLogTests: XCTestCase {
    @MainActor private var log = DiagnosticLog()

    @MainActor
    func testAppendAddsEvent() {
        self.log.append(category: .tunnel, message: "connected")
        XCTAssertEqual(self.log.events.count, 1)
        XCTAssertEqual(self.log.events[0].message, "connected")
        XCTAssertEqual(self.log.events[0].category, .tunnel)
    }

    @MainActor
    func testRingBufferOverflow() {
        let log = DiagnosticLog(capacity: 5)
        for i in 0..<10 {
            log.append(category: .tunnel, message: "event \(i)")
        }
        XCTAssertEqual(log.events.count, 5)
        XCTAssertEqual(log.events[0].message, "event 5")
        XCTAssertEqual(log.events[4].message, "event 9")
    }

    @MainActor
    func testRingBufferOverflowDefaultCapacity() {
        for i in 0..<210 {
            self.log.append(category: .tunnel, message: "event \(i)")
        }
        XCTAssertEqual(self.log.events.count, 200)
        XCTAssertEqual(self.log.events[0].message, "event 10")
        XCTAssertEqual(self.log.events[199].message, "event 209")
    }

    @MainActor
    func testFilterByCategory() {
        self.log.append(category: .tunnel, message: "tunnel event")
        self.log.append(category: .voice, message: "voice event")
        self.log.append(category: .brain, message: "brain event")
        self.log.append(category: .tunnel, message: "tunnel event 2")

        let tunnelOnly = self.log.filtered(by: [.tunnel])
        XCTAssertEqual(tunnelOnly.count, 2)
        XCTAssertTrue(tunnelOnly.allSatisfy { $0.category == .tunnel })

        let voiceAndBrain = self.log.filtered(by: [.voice, .brain])
        XCTAssertEqual(voiceAndBrain.count, 2)

        let all = self.log.filtered(by: Set(DiagnosticCategory.allCases))
        XCTAssertEqual(all.count, 4)
    }

    @MainActor
    func testClear() {
        self.log.append(category: .tunnel, message: "event")
        XCTAssertEqual(self.log.events.count, 1)
        self.log.clear()
        XCTAssertEqual(self.log.events.count, 0)
    }

    @MainActor
    func testEventProperties() {
        self.log.append(
            category: .voice,
            severity: .error,
            message: "failed",
            detail: "timeout after 5s"
        )
        let event = self.log.events[0]
        XCTAssertEqual(event.category, .voice)
        XCTAssertEqual(event.severity, .error)
        XCTAssertEqual(event.message, "failed")
        XCTAssertEqual(event.detail, "timeout after 5s")
        XCTAssertNotNil(event.id)
        XCTAssertNotNil(event.timestamp)
    }

    @MainActor
    func testSnapshotRedactsSecretValues() {
        self.log.append(
            category: .tunnel,
            severity: .warning,
            message: "manual probe failed Bearer abc123TOKEN",
            detail: "secret=hunter2 around diagnostic text"
        )

        let snapshot = self.log.snapshot(
            tunnel: TunnelManager(),
            voice: VoiceManager(),
            brain: BrainStatusMonitor()
        )

        XCTAssertFalse(snapshot.contains("abc123TOKEN"))
        XCTAssertFalse(snapshot.contains("hunter2"))
        XCTAssertTrue(snapshot.contains("‹redacted›"))
        XCTAssertTrue(snapshot.contains("manual probe failed"))
        XCTAssertTrue(snapshot.contains("around diagnostic text"))
    }

    @MainActor
    func testExportFileURLWritesRedactedSnapshot() throws {
        self.log.append(
            category: .upload,
            severity: .error,
            message: "upload failed",
            detail: "Authorization: Bearer abc123TOKEN secret=hunter2"
        )

        let exportURL = try XCTUnwrap(self.log.exportFileURL(
            tunnel: TunnelManager(),
            voice: VoiceManager(),
            brain: BrainStatusMonitor()
        ))
        let report = try String(contentsOf: exportURL, encoding: .utf8)

        XCTAssertFalse(report.contains("abc123TOKEN"))
        XCTAssertFalse(report.contains("hunter2"))
        XCTAssertTrue(report.contains("‹redacted›"))
        XCTAssertTrue(report.contains("upload failed"))
    }
}

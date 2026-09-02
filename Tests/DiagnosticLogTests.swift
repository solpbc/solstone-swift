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
    func testProtectedTunnelEventsSurviveUploadBurst() {
        for i in 0..<5 {
            self.log.append(category: .tunnel, message: "tunnel event \(i)")
        }
        for i in 0..<250 {
            self.log.append(category: .upload, message: "upload event \(i)")
        }

        XCTAssertLessThanOrEqual(self.log.events.count, 200)
        let tunnelEvents = self.log.filtered(by: [.tunnel])
        XCTAssertEqual(tunnelEvents.map(\.message), (0..<5).map { "tunnel event \($0)" })

        let snapshot = self.log.snapshot(tunnel: TunnelManager())
        for i in 0..<5 {
            XCTAssertTrue(snapshot.contains("tunnel event \(i)"))
        }
    }

    @MainActor
    func testFilterByCategory() {
        self.log.append(category: .tunnel, message: "tunnel event")
        self.log.append(category: .network, message: "network event")
        self.log.append(category: .upload, message: "upload event")
        self.log.append(category: .tunnel, message: "tunnel event 2")

        let tunnelOnly = self.log.filtered(by: [.tunnel])
        XCTAssertEqual(tunnelOnly.count, 2)
        XCTAssertTrue(tunnelOnly.allSatisfy { $0.category == .tunnel })

        let networkAndUpload = self.log.filtered(by: [.network, .upload])
        XCTAssertEqual(networkAndUpload.count, 2)

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
            category: .upload,
            severity: .error,
            message: "failed",
            detail: "timeout after 5s"
        )
        let event = self.log.events[0]
        XCTAssertEqual(event.category, .upload)
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

        let snapshot = self.log.snapshot(tunnel: TunnelManager())

        XCTAssertFalse(snapshot.contains("abc123TOKEN"))
        XCTAssertFalse(snapshot.contains("hunter2"))
        XCTAssertTrue(snapshot.contains("‹redacted›"))
        XCTAssertTrue(snapshot.contains("manual probe failed"))
        XCTAssertTrue(snapshot.contains("around diagnostic text"))
    }

    @MainActor
    func testSnapshotIncludesTunnelReconnectBreakdown() {
        let manager = TunnelManager()
        manager.reconnectCount = 3
        manager.reconnectReasonCounts = [
            .transportClosed: 2,
            .other: 1,
        ]

        let snapshot = self.log.snapshot(tunnel: manager)

        XCTAssertTrue(snapshot.contains("tunnel reconnects: 3 ("))
        XCTAssertTrue(snapshot.contains("transport closed 2"))
        XCTAssertTrue(snapshot.contains("other 1"))
        XCTAssertTrue(snapshot.contains("tunnel inbound-closed faults: (none)"))
        XCTAssertTrue(snapshot.contains("tunnel reconnects (last 5m): 0"))
    }

    @MainActor
    func testSnapshotNewDiagnosticFieldsStayCoarse() {
        self.log.append(
            category: .tunnel,
            severity: .warning,
            message: "forcing reconnect",
            detail: "keepalive missed port=none epoch=1 scope=direct"
        )
        self.log.append(
            category: .tunnel,
            severity: .warning,
            message: "forcing reconnect",
            detail: "transport closed port=none epoch=1 fault=someFault"
        )
        self.log.append(
            category: .tunnel,
            message: "scheduling reconnect",
            detail: "delayMs=1000 error=muxTeardown"
        )
        self.log.append(
            category: .tunnel,
            severity: .warning,
            message: "relay not entitled repeated",
            detail: "consecutiveNotEntitled=3 limit=3"
        )
        self.log.append(
            category: .upload,
            message: "waiting",
            detail: "source=alpha item=00000000-0000-0000-0000-000000000091 from=dispatching to=queued attempt=3 elapsedSinceFirstAttemptMs=2000 detail=retrying"
        )
        self.log.append(
            category: .upload,
            severity: .warning,
            message: "needs attention",
            detail: "kind=relay"
        )
        self.log.append(
            category: .upload,
            severity: .warning,
            message: "needs attention",
            detail: "kind=handoff"
        )
        self.log.append(
            category: .upload,
            severity: .warning,
            message: "needs attention",
            detail: "kind=orphan"
        )
        self.log.append(
            category: .upload,
            severity: .warning,
            message: "needs attention",
            detail: "source=omi reason=pendantNotFound"
        )
        self.log.append(
            category: .upload,
            severity: .info,
            message: "waiting",
            detail: "source=omi reason=systemReconnecting"
        )

        let snapshot = self.log.snapshot(tunnel: TunnelManager())

        XCTAssertTrue(snapshot.contains("scope=direct"))
        XCTAssertTrue(snapshot.contains("fault=someFault"))
        XCTAssertTrue(snapshot.contains("delayMs=1000"))
        XCTAssertTrue(snapshot.contains("error=muxTeardown"))
        XCTAssertTrue(snapshot.contains("consecutiveNotEntitled=3 limit=3"))
        XCTAssertTrue(snapshot.contains("elapsedSinceFirstAttemptMs=2000"))
        XCTAssertTrue(snapshot.contains("kind=relay"))
        XCTAssertTrue(snapshot.contains("kind=handoff"))
        XCTAssertTrue(snapshot.contains("kind=orphan"))
        XCTAssertTrue(snapshot.contains("source=omi reason=pendantNotFound"))
        XCTAssertTrue(snapshot.contains("source=omi reason=systemReconnecting"))
        XCTAssertTrue(snapshot.contains("tunnel reconnects (last 5m): 0"))
        XCTAssertFalse(snapshot.contains("10.0.0.10"))
        XCTAssertFalse(snapshot.contains(":7657"))
        XCTAssertFalse(snapshot.contains("192.168."))
        XCTAssertFalse(snapshot.contains("BEGIN CERTIFICATE"))
        XCTAssertFalse(snapshot.contains("The operation couldn’t complete"))
        XCTAssertFalse(snapshot.contains("tls handshake failed with host"))
        XCTAssertFalse(snapshot.contains("AA:BB:CC:DD:EE:FF"))
        XCTAssertFalse(snapshot.contains("peripheral="))
    }

    @MainActor
    func testUploadSinkDetailIncludesElapsedSinceFirstAttemptMs() async throws {
        let sink = ObserverAudioTransferDiagnostics.makeSink(diagnosticLog: self.log)
        sink(TransferDiagnosticEvent(
            source: "alpha",
            itemID: UUID(uuidString: "00000000-0000-0000-0000-000000000091")!,
            previousState: .dispatching,
            nextState: .queued,
            outcome: .retrying,
            attempt: 3,
            shortDetail: "retrying",
            at: Date(),
            elapsedSinceFirstAttempt: 1.5
        ))

        let didLog = await Self.waitUntil {
            self.log.events.contains { event in
                event.detail?.contains("elapsedSinceFirstAttemptMs=1500") ?? false
            }
        }
        XCTAssertTrue(didLog)
        let detail = try XCTUnwrap(self.log.events.last?.detail)
        XCTAssertTrue(detail.contains("attempt=3"))
        XCTAssertTrue(detail.contains("elapsedSinceFirstAttemptMs=1500"))
        XCTAssertFalse(detail.contains("10.0.0.10"))
        XCTAssertFalse(detail.contains(":7657"))
    }

    @MainActor
    func testSnapshotIncludesInboundClosedFaultBreakdown() {
        let manager = TunnelManager()
        manager.inboundClosedFaultCounts = [
            "streamReset(streamID: 3)": 2,
            "<unspecified>": 1,
        ]

        let snapshot = self.log.snapshot(tunnel: manager)
        let line = "tunnel inbound-closed faults: <unspecified> 1, streamReset(streamID: 3) 2"

        XCTAssertTrue(snapshot.contains(line))
        XCTAssertEqual(DiagnosticLog.redact(line), line)
    }

    @MainActor
    func testExportFileURLWritesRedactedSnapshot() throws {
        self.log.append(
            category: .upload,
            severity: .error,
            message: "upload failed",
            detail: "Authorization: Bearer abc123TOKEN secret=hunter2"
        )

        let exportURL = try XCTUnwrap(self.log.exportFileURL(tunnel: TunnelManager()))
        let report = try String(contentsOf: exportURL, encoding: .utf8)

        XCTAssertFalse(report.contains("abc123TOKEN"))
        XCTAssertFalse(report.contains("hunter2"))
        XCTAssertTrue(report.contains("‹redacted›"))
        XCTAssertTrue(report.contains("upload failed"))
    }

    @MainActor
    private static func waitUntil(
        _ condition: () -> Bool,
        timeout: Duration = .seconds(1),
        interval: Duration = .milliseconds(20)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: interval)
        }
        return condition()
    }
}

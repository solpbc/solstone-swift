// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

/// Writes that arrive together for one diagnostic collapse into one row and keep every increment.
@MainActor
final class JournalEventWriteTests: XCTestCase {
    private var tempDirectory: URL!
    private var events: JournalEventStore!
    private let now = Date(timeIntervalSince1970: 1_780_480_800)

    override func setUp() async throws {
        try await super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalEventWrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        let mobile = self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true)
        self.events = JournalEventStore(rootURL: JournalEventStore.directory(besideMobileSegmentRoot: mobile))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.events = nil
        self.tempDirectory = nil
        try await super.tearDown()
    }

    func testSameDiagnosticWrittenTogetherKeepsEveryIncrement() async throws {
        let events = self.events!
        let now = self.now
        let burst = 40
        let gate = BurstGate(total: burst)
        let outcome = BurstOutcome()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<burst {
                group.addTask {
                    await Task.detached {
                        await gate.arriveAndWait()
                        do {
                            try events.recordDiagnostic(
                                segmentID: nil,
                                source: .audio,
                                reason: "observer_tap_write_stall",
                                captureAt: nil,
                                now: now
                            )
                        } catch {
                            outcome.record(error)
                        }
                    }.value
                }
            }
        }
        XCTAssertTrue(outcome.messages.isEmpty, outcome.messages.joined(separator: "\n"))
        guard case .events(let rows) = events.readEvents() else {
            return XCTFail("journal events unreadable")
        }
        let row = try XCTUnwrap(rows.first { $0.reason == "observer_tap_write_stall" })
        XCTAssertEqual(row.count, burst)
        XCTAssertEqual(rows.filter { $0.reason == "observer_tap_write_stall" }.count, 1)
    }
}

/// Releases every waiter once they have all arrived, so the writes overlap.
private final class BurstGate: @unchecked Sendable {
    private let lock = NSLock()
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let total: Int

    init(total: Int) {
        self.total = total
    }

    func arriveAndWait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.lock.lock()
            self.arrived += 1
            if self.arrived >= self.total {
                let pending = self.waiters
                self.waiters.removeAll()
                self.lock.unlock()
                continuation.resume()
                for waiter in pending {
                    waiter.resume()
                }
            } else {
                self.waiters.append(continuation)
                self.lock.unlock()
            }
        }
    }
}

private final class BurstOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String] = []

    func record(_ error: Error) {
        self.lock.lock()
        self.failures.append(String(describing: error))
        self.lock.unlock()
    }

    var messages: [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.failures
    }
}

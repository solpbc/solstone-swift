// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import XCTest

@MainActor
final class WatchAudioRecorderTerminalRetentionTests: XCTestCase {
    func testDelayedFinishReleasesPairAndPreservesBoundSource() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let expectation = self.expectation(description: "finish forwarded")
        let sink = RetentionSink(expectation: expectation)
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let source = WatchCaptureSourceToken(sessionID: "A")
        let pair = try self.retirePair(retention: retention, sink: sink, source: source)

        await self.drain(until: { clock.pendingSleeperCount == 1 })
        XCTAssertNotNil(pair.recorder)
        XCTAssertNotNil(pair.forwarder)

        pair.finish(successfully: false)
        await self.fulfillment(of: [expectation], timeout: 1)
        await self.drain(until: { pair.recorder == nil && pair.forwarder == nil })

        XCTAssertEqual(sink.finishEvents.count, 1)
        XCTAssertEqual(sink.finishEvents.first?.0, false)
        XCTAssertEqual(sink.finishEvents.first?.1, source)
    }

    func testDelayedEncodeErrorReleasesPairAndPreservesBoundSource() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let expectation = self.expectation(description: "encode forwarded")
        let sink = RetentionSink(expectation: expectation)
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let source = WatchCaptureSourceToken(sessionID: "A")
        let pair = try self.retirePair(retention: retention, sink: sink, source: source)

        await self.drain(until: { clock.pendingSleeperCount == 1 })
        pair.encodeError()
        await self.fulfillment(of: [expectation], timeout: 1)
        await self.drain(until: { pair.recorder == nil && pair.forwarder == nil })

        XCTAssertEqual(sink.encodeSources, [source])
    }

    func testSuccessfulFinishStillReleasesPair() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let expectation = self.expectation(description: "successful finish forwarded")
        let sink = RetentionSink(expectation: expectation)
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let pair = try self.retirePair(
            retention: retention,
            sink: sink,
            source: WatchCaptureSourceToken(sessionID: "A")
        )

        await self.drain(until: { clock.pendingSleeperCount == 1 })
        pair.finish(successfully: true)
        await self.fulfillment(of: [expectation], timeout: 1)
        await self.drain(until: { pair.recorder == nil && pair.forwarder == nil })

        XCTAssertEqual(sink.finishEvents.first?.0, true)
    }

    func testExpiryRetainsUntilFiveSecondsThenReleasesBothPairs() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let first = try self.retirePair(retention: retention, sink: nil, source: WatchCaptureSourceToken(sessionID: "A"))
        let second = try self.retirePair(retention: retention, sink: nil, source: WatchCaptureSourceToken(sessionID: "B"))

        await self.drain(until: { clock.pendingSleeperCount == 2 })
        await clock.advance(by: .milliseconds(4_999))
        await self.settle()
        XCTAssertNotNil(first.recorder)
        XCTAssertNotNil(first.forwarder)
        XCTAssertNotNil(second.recorder)
        XCTAssertNotNil(second.forwarder)

        await clock.advance(by: .milliseconds(1))
        await self.drain(until: {
            first.recorder == nil && first.forwarder == nil && second.recorder == nil && second.forwarder == nil
        })
    }

    func testThirdRetirementEvictsOldestPair() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let first = try self.retirePair(retention: retention, sink: nil, source: WatchCaptureSourceToken(sessionID: "A"))
        let second = try self.retirePair(retention: retention, sink: nil, source: WatchCaptureSourceToken(sessionID: "B"))
        let third = try self.retirePair(retention: retention, sink: nil, source: WatchCaptureSourceToken(sessionID: "C"))

        await self.drain(until: { first.recorder == nil && first.forwarder == nil })
        XCTAssertNotNil(second.recorder)
        XCTAssertNotNil(second.forwarder)
        XCTAssertNotNil(third.recorder)
        XCTAssertNotNil(third.forwarder)
    }

    func testEnrollOverCurrentRetiresIncumbentAndKeepsNewPairCurrent() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let incumbent = RetiredPairFixture()
        let current = RetiredPairFixture()

        try autoreleasepool {
            let recorder = try self.makeRecorder()
            incumbent.recorder = recorder
            retention.enroll(recorder: recorder, source: WatchCaptureSourceToken(sessionID: "A"), sink: nil)
            incumbent.forwarder = recorder.delegate as? WatchAudioRecorderTerminalForwarder

            let replacement = try self.makeRecorder()
            current.recorder = replacement
            retention.enroll(recorder: replacement, source: WatchCaptureSourceToken(sessionID: "B"), sink: nil)
            current.forwarder = replacement.delegate as? WatchAudioRecorderTerminalForwarder
        }

        await self.drain(until: { clock.pendingSleeperCount == 1 })

        XCTAssertNotNil(incumbent.recorder)
        XCTAssertNotNil(incumbent.forwarder)
        XCTAssertNotNil(current.recorder)
        XCTAssertNotNil(current.forwarder)
        XCTAssertEqual(retention.currentURL(), current.recorder?.url)
    }

    func testCallbackBeforeExpiryForwardsAfterExpiryAdvance() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let expectation = self.expectation(description: "finish forwarded after clock advance")
        let sink = RetentionSink(expectation: expectation)
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let source = WatchCaptureSourceToken(sessionID: "A")
        let pair = try self.retirePair(retention: retention, sink: sink, source: source)

        await self.drain(until: { clock.pendingSleeperCount == 1 })
        pair.finish(successfully: false)
        await clock.advance(by: .seconds(5))
        await self.fulfillment(of: [expectation], timeout: 1)

        XCTAssertEqual(sink.finishEvents.count, 1)
        XCTAssertEqual(sink.finishEvents.first?.0, false)
        XCTAssertEqual(sink.finishEvents.first?.1, source)
    }

    func testDuplicateCallbacksReleaseIdempotently() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let expectation = self.expectation(description: "two finish callbacks forwarded")
        expectation.expectedFulfillmentCount = 2
        let sink = RetentionSink(expectation: expectation)
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let pair = try self.retirePair(retention: retention, sink: sink, source: WatchCaptureSourceToken(sessionID: "A"))

        await self.drain(until: { clock.pendingSleeperCount == 1 })
        // This is deliberately not a lifetime probe: retain the forwarder so the
        // second manually-invoked duplicate callback can enter after the first
        // releases retention's strong pair.
        let recorder = try XCTUnwrap(pair.recorder)
        let forwarder = try XCTUnwrap(pair.forwarder)
        forwarder.audioRecorderDidFinishRecording(recorder, successfully: false)
        forwarder.audioRecorderDidFinishRecording(recorder, successfully: false)
        await self.fulfillment(of: [expectation], timeout: 1)

        XCTAssertEqual(sink.finishEvents.count, 2)
    }

    func testSynchronousFinishDuringStopReleasesRetiredPair() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let expectation = self.expectation(description: "synchronous finish forwarded")
        let sink = RetentionSink(expectation: expectation)
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let fixture = RetiredPairFixture()

        try autoreleasepool {
            let recorder = try SynchronousFinishAudioRecorder(
                url: self.makeRecorderURL,
                settings: self.recorderSettings
            )
            recorder.stopCallback = .unsuccessfulFinish
            fixture.recorder = recorder
            retention.enroll(
                recorder: recorder,
                source: WatchCaptureSourceToken(sessionID: "A"),
                sink: sink
            )
            fixture.forwarder = recorder.delegate as? WatchAudioRecorderTerminalForwarder
            _ = retention.stopCurrent()
        }

        await self.fulfillment(of: [expectation], timeout: 1)
        await self.drain(until: { fixture.recorder == nil && fixture.forwarder == nil })
        XCTAssertEqual(sink.finishEvents.count, 1)
    }

    /// The expiry worker must consume an ABSOLUTE deadline: between the worker body
    /// starting and its sleep registering it must perform ZERO clock reads. Any
    /// relative form (`remaining = deadline - now`, then sleeping that interval) has
    /// to re-read the clock, and is observable here even when the arithmetic happens
    /// to land on the same instant. This test advances no time; it counts reads.
    func testExpiryWorkerConsumesAbsoluteDeadlineWithoutRereadingTheClock() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let readsAtSpawn = LockedIntBox()
        let retention = WatchAudioRecorderTerminalRetention(
            clock: clock,
            spawnExpiryTask: { body in
                Task {
                    readsAtSpawn.set(clock.monotonicReadCount)
                    await body()
                }
            }
        )
        let pair = try self.retirePair(retention: retention, sink: nil, source: WatchCaptureSourceToken(sessionID: "A"))

        await self.drain(until: { clock.readCountAtFirstRegistration != nil })
        let atSpawn = try XCTUnwrap(readsAtSpawn.get())
        let atRegistration = try XCTUnwrap(clock.readCountAtFirstRegistration)
        XCTAssertEqual(
            atRegistration - atSpawn,
            0,
            "expiry worker re-read the monotonic clock; deadline must be absolute"
        )

        await clock.advance(by: .seconds(5))
        await self.drain(until: { pair.recorder == nil && pair.forwarder == nil })
    }

    /// Interposes at the exact window an absolute deadline must be immune to: the clock
    /// is advanced past the deadline AFTER the expiry worker body begins but BEFORE its
    /// sleep registers, and no further time is advanced. Only an absolute deadline can
    /// release from that state; a relative form would wait a stale full interval against
    /// a clock nobody moves again.
    func testExpiryReleasesImmediatelyWhenDeadlinePassesBeforeSleepRegisters() async throws {
        // Hook established at construction, strictly before retirePair spawns the
        // expiry task, so the sleeper cannot register ahead of it.
        let clock = FakeWatchAudioRecorderRetentionClock(onBeforeRegister: { clock in
            clock.advanceImmediately(by: .seconds(5))
        })
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let pair = try self.retirePair(retention: retention, sink: nil, source: WatchCaptureSourceToken(sessionID: "A"))

        // No further advance: release must come from the absolute deadline alone.
        await self.drain(until: { pair.recorder == nil && pair.forwarder == nil })
        XCTAssertNil(pair.recorder)
        XCTAssertNil(pair.forwarder)
        XCTAssertEqual(clock.pendingSleeperCount, 0)
    }

    func testExpiryReleasesAtAnchoredDeadlineWhenWorkerStartsLate() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let gate = RetentionWorkerStartGate()
        let retention = WatchAudioRecorderTerminalRetention(
            clock: clock,
            spawnExpiryTask: { body in Task { await gate.suspend(); await body() } }
        )
        let pair = try self.retirePair(retention: retention, sink: nil, source: WatchCaptureSourceToken(sessionID: "A"))

        await self.waitForWorker(gate)
        await clock.advance(by: .seconds(5))
        XCTAssertNotNil(pair.recorder)
        await gate.release()
        await self.drain(until: { pair.recorder == nil && pair.forwarder == nil })
    }

    func testExpiryHoldsRetirementAnchoredDeadlineAcrossMinimalDispatchLag() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let gate = RetentionWorkerStartGate()
        let retention = WatchAudioRecorderTerminalRetention(
            clock: clock,
            spawnExpiryTask: { body in Task { await gate.suspend(); await body() } }
        )
        let pair = try self.retirePair(retention: retention, sink: nil, source: WatchCaptureSourceToken(sessionID: "A"))

        await self.waitForWorker(gate)
        await clock.advance(by: .milliseconds(1))
        await gate.release()
        await self.drain(until: { clock.pendingSleeperCount == 1 })
        await clock.advance(by: .milliseconds(4_998))
        XCTAssertNotNil(pair.recorder)
        XCTAssertNotNil(pair.forwarder)
        await clock.advance(by: .milliseconds(1))
        await self.drain(until: { pair.recorder == nil && pair.forwarder == nil })
    }

    /// Production only ever receives `monotonicNow()` and `sleep(until:)`, both of which
    /// traffic exclusively in `ContinuousClock.Instant`. A wall-clock regression in the
    /// retention deadline is therefore unobservable through that interface and cannot be
    /// proven behaviourally. This is the permitted structural/type gate: the deadline must
    /// be a monotonic instant and must never be derived from wall time.
    func testRetentionDeadlineIsMonotonicAndNeverWallDerived() throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let monotonic: ContinuousClock.Instant = clock.monotonicNow()
        XCTAssertTrue(type(of: monotonic) == ContinuousClock.Instant.self)

        let worktreeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func read(_ path: String) throws -> String {
            try String(contentsOfFile: worktreeRoot.appendingPathComponent(path).path, encoding: .utf8)
        }
        let retentionSource = try read("Sources/WatchCapture/WatchAudioRecorderTerminalRetention.swift")
        let clockSource = try read("Sources/WatchCapture/WatchAudioRecorderRetentionClock.swift")

        XCTAssertTrue(retentionSource.contains("let deadline: ContinuousClock.Instant"))
        // The live clock must derive its instant from ContinuousClock directly; returning
        // a ContinuousClock.Instant that was computed from wall time would still satisfy
        // the type alone, so assert the derivation too.
        XCTAssertTrue(clockSource.contains("self.clock.now"))
        XCTAssertTrue(clockSource.contains("self.clock.sleep(until: deadline)"))
        for (name, source) in [("retention", retentionSource), ("live clock", clockSource)] {
            for wallDerived in ["Date()", "Date.now", "Date(timeIntervalSince", "timeIntervalSince", "wallNow", "CFAbsoluteTime", "gettimeofday"] {
                XCTAssertFalse(
                    source.contains(wallDerived),
                    "\(name) deadline surface must not be wall-derived: found \(wallDerived)"
                )
            }
        }
    }

    /// The ordinary retirement deadline must be minted INSIDE the state transaction.
    /// Time is advanced in the window immediately BEFORE the transaction acquires the
    /// lock, so a deadline read taken before that window yields a strictly earlier
    /// expiry: the pair would already be gone at transition+4.999.
    func testOrdinaryCurrentRetirementDeadlineIsMintedInsideTheStateTransaction() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let retention = WatchAudioRecorderTerminalRetention(
            clock: clock,
            beforeRetirementTransition: { clock.advanceImmediately(by: .seconds(3)) }
        )
        let handle = try self.enrollSynchronousRecorder(
            in: retention,
            source: WatchCaptureSourceToken(sessionID: "A"),
            sink: nil
        )
        _ = retention.stopCurrent()

        await self.drain(until: { clock.pendingSleeperCount == 1 })
        // Deadline is transition-relative: the 3s advance happened before the
        // transaction, so the full window remains from that point.
        await clock.advance(by: .milliseconds(4_999))
        XCTAssertFalse(handle.isReleased)
        await clock.advance(by: .milliseconds(1))
        await self.drain(until: { handle.isReleased })
    }

    func testReplacementDeadlineAnchorsWhenIncumbentIsRetired() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let incumbent = RetiredPairFixture()
        var first: AVAudioRecorder? = try self.makeRecorder()
        incumbent.recorder = first
        retention.enroll(recorder: try XCTUnwrap(first), source: WatchCaptureSourceToken(sessionID: "A"), sink: nil)
        incumbent.forwarder = first?.delegate as? WatchAudioRecorderTerminalForwarder
        await clock.advance(by: .seconds(2))
        let replacement = try self.makeRecorder()
        retention.enroll(recorder: replacement, source: WatchCaptureSourceToken(sessionID: "B"), sink: nil)
        first = nil

        await self.drain(until: { clock.pendingSleeperCount == 1 })
        await clock.advance(by: .milliseconds(4_999))
        XCTAssertNotNil(incumbent.recorder)
        await clock.advance(by: .milliseconds(1))
        await self.drain(until: { incumbent.recorder == nil && incumbent.forwarder == nil })
    }

    func testThirdRetirementEvictsOnlyOldestRetiredPair() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let first = try self.retirePair(retention: retention, sink: nil, source: WatchCaptureSourceToken(sessionID: "A"))
        let second = try self.retirePair(retention: retention, sink: nil, source: WatchCaptureSourceToken(sessionID: "B"))
        let third = try self.retirePair(retention: retention, sink: nil, source: WatchCaptureSourceToken(sessionID: "C"))

        await self.drain(until: { first.recorder == nil && first.forwarder == nil })
        XCTAssertNotNil(second.recorder)
        XCTAssertNotNil(third.recorder)
        await clock.advance(by: .seconds(5))
        await self.drain(until: {
            second.recorder == nil && second.forwarder == nil && third.recorder == nil && third.forwarder == nil
        })
    }

    func testEnrollOverActiveStopsIncumbentAfterReplacementAndPreservesCallbackIdentity() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let expectation = self.expectation(description: "incumbent callback forwarded")
        let sink = RetentionSink(expectation: expectation)
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let source = WatchCaptureSourceToken(sessionID: "A")

        let replacementURL = self.makeRecorderURL
        let replacementTelemetry = RecorderTelemetry()
        // duringStop is installed before enrollment; it captures only the replacement's
        // URL and independent telemetry, never a recorder reference.
        let incumbent = try self.enrollSynchronousRecorder(
            in: retention,
            source: source,
            sink: sink,
            configure: { recorder in
                recorder.stopCallback = .unsuccessfulFinish
                recorder.duringStop = {
                    XCTAssertEqual(retention.currentURL(), replacementURL)
                    XCTAssertEqual(replacementTelemetry.stopCallCount, 0)
                }
            }
        )
        XCTAssertTrue(incumbent.recorder?.record() ?? false)
        let replacement = try self.enrollSynchronousRecorder(
            in: retention,
            source: WatchCaptureSourceToken(sessionID: "B"),
            sink: sink,
            url: replacementURL,
            telemetry: replacementTelemetry
        )

        await self.fulfillment(of: [expectation], timeout: 1)
        await self.drain(until: { incumbent.isReleased })
        XCTAssertEqual(incumbent.telemetry.recordCallCount, 1)
        XCTAssertEqual(incumbent.telemetry.stopCallCount, 1)
        XCTAssertEqual(replacement.telemetry.stopCallCount, 0)
        XCTAssertEqual(retention.currentURL(), replacement.recorder?.url)
        XCTAssertFalse(replacement.isReleased)
        XCTAssertEqual(sink.finishEvents.count, 1)
        XCTAssertEqual(sink.finishEvents.first?.0, false)
        XCTAssertEqual(sink.finishEvents.first?.1, source)
    }

    func testEnrollClaimsTerminalPendingWithFreshDeadlineAfterPendingHold() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let predecessor = try self.enrollSynchronousRecorder(
            in: retention,
            source: WatchCaptureSourceToken(sessionID: "B"),
            sink: nil
        )
        predecessor.recorder?.fireFinish(successfully: false)
        await clock.advance(by: .seconds(60))
        XCTAssertNotNil(predecessor.recorder)
        XCTAssertNotNil(predecessor.forwarder)
        XCTAssertEqual(predecessor.telemetry.stopCallCount, 0)

        let successor = try self.enrollSynchronousRecorder(
            in: retention,
            source: WatchCaptureSourceToken(sessionID: "C"),
            sink: nil
        )
        XCTAssertEqual(predecessor.telemetry.stopCallCount, 1)
        XCTAssertEqual(successor.telemetry.stopCallCount, 0)
        XCTAssertEqual(retention.currentURL(), successor.recorder?.url)
        await self.drain(until: { clock.pendingSleeperCount == 1 })

        await clock.advance(by: .milliseconds(4_999))
        XCTAssertFalse(predecessor.isReleased)
        await clock.advance(by: .milliseconds(1))
        await self.drain(until: { predecessor.isReleased })
    }

    /// A duplicate terminal callback that arrives while the pair is still in
    /// terminal-pending must be an ownership no-op. If callback entry removed pending
    /// ownership, exact cleanup would later find nothing to stop and the concrete
    /// recorder would never be closed.
    func testDuplicatePendingCallbackDoesNotStripCleanupOwnership() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let handle = try self.enrollSynchronousRecorder(
            in: retention,
            source: WatchCaptureSourceToken(sessionID: "A"),
            sink: nil
        )
        handle.recorder?.fireFinish(successfully: false)
        XCTAssertEqual(handle.telemetry.stopCallCount, 0)

        // Duplicate while still pending: ownership must be unchanged.
        handle.recorder?.fireFinish(successfully: false)
        XCTAssertFalse(handle.isReleased)
        XCTAssertEqual(handle.telemetry.stopCallCount, 0)

        // Exact cleanup must still find and stop the pair exactly once.
        _ = retention.stopCurrent()
        XCTAssertEqual(handle.telemetry.stopCallCount, 1)

        await self.drain(until: { clock.pendingSleeperCount == 1 })
        await clock.advance(by: .seconds(5))
        await self.drain(until: { handle.isReleased })
    }

    func testPendingClaimRebasesDeadlineAfterSlowStopReturns() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let predecessor = try self.enrollSynchronousRecorder(
            in: retention,
            source: WatchCaptureSourceToken(sessionID: "B"),
            sink: nil
        )
        predecessor.recorder?.duringStop = {
            clock.advanceImmediately(by: .seconds(3))
        }
        predecessor.recorder?.fireFinish(successfully: false)

        _ = retention.stopCurrent()
        XCTAssertEqual(predecessor.telemetry.stopCallCount, 1)
        await self.drain(until: { clock.pendingSleeperCount == 1 })

        await clock.advance(by: .milliseconds(4_999))
        XCTAssertFalse(predecessor.isReleased)
        await clock.advance(by: .milliseconds(1))
        await self.drain(until: { predecessor.isReleased })
    }

    func testSynchronousPendingFinishDuringEnrollCannotReleaseSuccessor() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let expectation = self.expectation(description: "pending callbacks forwarded")
        expectation.expectedFulfillmentCount = 2
        let sink = RetentionSink(expectation: expectation)
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let source = WatchCaptureSourceToken(sessionID: "B")
        let predecessor = try self.enrollSynchronousRecorder(in: retention, source: source, sink: sink)
        predecessor.recorder?.fireFinish(successfully: false)
        predecessor.recorder?.stopCallback = .unsuccessfulFinish

        let successor = try self.enrollSynchronousRecorder(
            in: retention,
            source: WatchCaptureSourceToken(sessionID: "C"),
            sink: sink
        )
        await self.fulfillment(of: [expectation], timeout: 1)
        await self.drain(until: { predecessor.isReleased })
        XCTAssertEqual(predecessor.telemetry.stopCallCount, 1)
        XCTAssertEqual(successor.telemetry.stopCallCount, 0)
        XCTAssertEqual(retention.currentURL(), successor.recorder?.url)
        XCTAssertFalse(successor.isReleased)
        XCTAssertEqual(sink.finishEvents.map(\.1), [source, source])
    }

    func testTerminalPendingDoesNotDisplaceTwoRetiredPairsBeforeSuccessorClaimsIt() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let first = try self.enrollSynchronousRecorder(
            in: retention,
            source: WatchCaptureSourceToken(sessionID: "A"),
            sink: nil
        )
        let second = try self.enrollSynchronousRecorder(
            in: retention,
            source: WatchCaptureSourceToken(sessionID: "B"),
            sink: nil
        )
        let third = try self.enrollSynchronousRecorder(
            in: retention,
            source: WatchCaptureSourceToken(sessionID: "C"),
            sink: nil
        )

        // A and B are retired; C is current. Its callback occupies the separate
        // terminal-pending slot and must not evict either retired pair.
        third.recorder?.fireFinish(successfully: false)
        await self.drain(until: { clock.pendingSleeperCount == 2 })
        XCTAssertFalse(first.isReleased)
        XCTAssertFalse(second.isReleased)
        XCTAssertFalse(third.isReleased)
        XCTAssertEqual(third.telemetry.stopCallCount, 0)

        let successor = try self.enrollSynchronousRecorder(
            in: retention,
            source: WatchCaptureSourceToken(sessionID: "D"),
            sink: nil
        )
        await self.drain(until: { first.isReleased })
        XCTAssertFalse(second.isReleased)
        XCTAssertFalse(third.isReleased)
        XCTAssertEqual(third.telemetry.stopCallCount, 1)
        XCTAssertEqual(successor.telemetry.stopCallCount, 0)
        XCTAssertEqual(retention.currentURL(), successor.recorder?.url)

        await clock.advance(by: .seconds(5))
        await self.drain(until: { second.isReleased && third.isReleased })
        XCTAssertFalse(successor.isReleased)
    }

    func testSynchronousTerminalAtCurrentToRetiredHandoffFindsRetiredPair() async throws {
        let clock = FakeWatchAudioRecorderRetentionClock()
        let expectation = self.expectation(description: "handoff callback forwarded")
        let source = WatchCaptureSourceToken(sessionID: "A")
        let sink = RetentionSink(expectation: expectation)
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let handle = try self.enrollSynchronousRecorder(in: retention, source: source, sink: sink)
        handle.recorder?.stopCallback = .unsuccessfulFinish

        // The delegate is invoked synchronously from stop(). The production
        // transition has already moved this pair to retired before stop(), so
        // a two-lock mutation that clears current, stops, then appends retired
        // leaves the callback with no owner and fails the release assertion.
        _ = retention.stopCurrent()
        await self.fulfillment(of: [expectation], timeout: 1)
        await self.drain(until: { handle.isReleased })
        XCTAssertEqual(handle.telemetry.stopCallCount, 1)
        XCTAssertEqual(sink.finishEvents.count, 1)
        XCTAssertEqual(sink.finishEvents.first?.0, false)
        XCTAssertEqual(sink.finishEvents.first?.1, source)
        XCTAssertNil(retention.currentURL())
    }

    private func retirePair(
        retention: WatchAudioRecorderTerminalRetention,
        sink: RetentionSink?,
        source: WatchCaptureSourceToken
    ) throws -> RetiredPairFixture {
        let fixture = RetiredPairFixture()
        try autoreleasepool {
            let recorder = try self.makeRecorder()
            fixture.recorder = recorder
            retention.enroll(recorder: recorder, source: source, sink: sink)
            fixture.forwarder = recorder.delegate as? WatchAudioRecorderTerminalForwarder
            XCTAssertNotNil(fixture.forwarder)
            _ = retention.stopCurrent()
        }
        return fixture
    }

    private func makeRecorder() throws -> AVAudioRecorder {
        try AVAudioRecorder(url: self.makeRecorderURL, settings: self.recorderSettings)
    }

    private func enrollSynchronousRecorder(
        in retention: WatchAudioRecorderTerminalRetention,
        source: WatchCaptureSourceToken,
        sink: RetentionSink?,
        url: URL? = nil,
        telemetry: RecorderTelemetry = RecorderTelemetry(),
        configure: ((SynchronousFinishAudioRecorder) -> Void)? = nil
    ) throws -> WeakRecorderHandle {
        let recorderURL = url ?? self.makeRecorderURL
        let handle = WeakRecorderHandle(telemetry: telemetry)
        // Construct, configure and enroll inside ONE explicit autorelease pool, while a
        // strong local holds the recorder. Retention takes the only surviving strong
        // reference before the pool drains, so nothing outside this scope keeps the
        // recorder alive and the weak lifetime assertions cannot pass on ambient
        // autorelease. Only the weak handle and independent telemetry escape.
        try autoreleasepool {
            let recorder = try SynchronousFinishAudioRecorder(
                url: recorderURL,
                settings: self.recorderSettings,
                telemetry: telemetry
            )
            configure?(recorder)
            retention.enroll(recorder: recorder, source: source, sink: sink)
            handle.recorder = recorder
            handle.forwarder = recorder.delegate as? WatchAudioRecorderTerminalForwarder
        }
        return handle
    }

    private var makeRecorderURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchAudioRecorderTerminalRetentionTests-\(UUID().uuidString).m4a")
    }

    private var recorderSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
    }

    private func drain(until predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for test convergence")
    }

    private func settle() async {
        for _ in 0..<200 {
            await Task.yield()
        }
    }

    private func waitForWorker(_ gate: RetentionWorkerStartGate) async {
        for _ in 0..<200 {
            if await gate.waiting() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for expiry worker")
    }
}

@MainActor
private final class RetentionSink: WatchAudioRecorderEventSink {
    private let expectation: XCTestExpectation?
    var finishEvents: [(Bool, WatchCaptureSourceToken)] = []
    var encodeSources: [WatchCaptureSourceToken] = []

    init(expectation: XCTestExpectation?) {
        self.expectation = expectation
    }

    func audioRecorderDidFinish(successfully: Bool, source: WatchCaptureSourceToken) {
        self.finishEvents.append((successfully, source))
        self.expectation?.fulfill()
    }

    func audioRecorderEncodeError(_ error: (any Error)?, source: WatchCaptureSourceToken) {
        self.encodeSources.append(source)
        self.expectation?.fulfill()
    }
}

@MainActor
private final class RetiredPairFixture {
    weak var recorder: AVAudioRecorder?
    weak var forwarder: WatchAudioRecorderTerminalForwarder?

    func finish(successfully: Bool) {
        guard let recorder, let forwarder else { return }
        forwarder.audioRecorderDidFinishRecording(recorder, successfully: successfully)
    }

    func encodeError() {
        guard let recorder, let forwarder else { return }
        forwarder.audioRecorderEncodeErrorDidOccur(recorder, error: nil)
    }
}

private actor RetentionWorkerStartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isWaiting = false

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.isWaiting = true
        }
        self.isWaiting = false
    }

    func waiting() -> Bool { self.isWaiting }

    func release() {
        self.continuation?.resume()
        self.continuation = nil
    }
}

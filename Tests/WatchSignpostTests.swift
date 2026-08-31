// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

@MainActor
final class WatchSignpostTests: XCTestCase {
    func testEnabledSinkBalancesNestedIntervalsExactly() {
        let sink = WatchSignpostTestSink()
        let signposter = WatchSignposter(sink: sink)

        let outer = signposter.begin(.reconciliation)
        let child = signposter.begin(.manifestScan)
        signposter.end(child, fields: WatchSignpostFields(result: .completed))
        signposter.end(outer, fields: WatchSignpostFields(result: .completed))

        XCTAssertEqual(sink.events.map(\.kind), [.begin, .begin, .end, .end])
        XCTAssertEqual(sink.events.map(\.boundary), [.reconciliation, .manifestScan, .manifestScan, .reconciliation])
        XCTAssertEqual(sink.openInvocationCount, 0)
    }

    func testDisabledSinkDoesNotAllocateAnInvocation() {
        let signposter = WatchSignposter(sink: NoOpWatchSignpostIntervalSink())

        XCTAssertNil(signposter.begin(.relayDrain))
    }

    func testClosedEnumsAndWorkloadBandBoundaries() {
        XCTAssertEqual(RelayTrigger.allCases, [
            .launchReconciliation,
            .segmentFinalization,
            .connectivityActivation,
            .connectivityReachability,
            .durableACK,
            .testDirect,
        ])
        XCTAssertEqual(RelayResult.allCases, [.completed, .partial, .failed])
        XCTAssertEqual(RelayActivation.allCases, [.activated, .notActivated])
        XCTAssertEqual(WorkloadBand.allCases, [.unknown, .notSampled, .empty, .small, .medium, .large])
        XCTAssertEqual(WorkloadBand.band(for: nil), .unknown)
        XCTAssertEqual(WorkloadBand.band(for: 0), .empty)
        XCTAssertEqual(WorkloadBand.band(for: 1), .small)
        XCTAssertEqual(WorkloadBand.band(for: 25), .small)
        XCTAssertEqual(WorkloadBand.band(for: 26), .medium)
        XCTAssertEqual(WorkloadBand.band(for: 200), .medium)
        XCTAssertEqual(WorkloadBand.band(for: 201), .large)
    }

    func testPublicFieldsRemainClosedTypedSchema() {
        let fields = WatchSignpostFields()
        let labels = Mirror(reflecting: fields).children.compactMap(\.label)

        XCTAssertEqual(labels, [
            "trigger",
            "result",
            "activation",
            "entryWorkload",
            "refreshedWorkload",
            "transferCandidateCount",
            "failureCount",
            "usedFallback",
            "retainedObservationCount",
            "encodedByteCount",
        ])
        XCTAssertFalse(labels.contains("description"))
        XCTAssertFalse(labels.contains("error"))
        XCTAssertFalse(labels.contains("identifier"))
        XCTAssertFalse(labels.contains("url"))
    }
}

@MainActor
final class WatchSignpostTestSink: WatchSignpostIntervalSink {
    enum Kind: Equatable {
        case begin
        case end
    }

    struct Event: Equatable {
        let kind: Kind
        let boundary: WatchSignpostBoundary
        let fields: WatchSignpostFields
    }

    let isEnabled = true
    private(set) var events: [Event] = []
    private var openInvocations: [ObjectIdentifier: WatchSignpostBoundary] = [:]

    var openInvocationCount: Int { self.openInvocations.count }
    var openBoundaries: [WatchSignpostBoundary] { Array(self.openInvocations.values) }

    func begin(
        _ boundary: WatchSignpostBoundary,
        fields: WatchSignpostFields
    ) -> WatchSignpostInvocation {
        let invocation = WatchSignpostInvocation(boundary: boundary)
        self.openInvocations[ObjectIdentifier(invocation)] = boundary
        self.events.append(Event(kind: .begin, boundary: boundary, fields: fields))
        return invocation
    }

    func end(
        _ invocation: WatchSignpostInvocation,
        fields: WatchSignpostFields
    ) {
        self.openInvocations.removeValue(forKey: ObjectIdentifier(invocation))
        self.events.append(Event(kind: .end, boundary: invocation.boundary, fields: fields))
    }
}

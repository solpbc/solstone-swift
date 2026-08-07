// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

final class OmiLaunchCaptureCutReservationTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiLaunchCaptureCutReservationTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.rootURL)
    }

    func testFixedLayoutRoundTripsAndIsNotAGenerationName() {
        let reservation = OmiLaunchCaptureCutReservation(
            sealedGenerationID: UUID(),
            reservedGenerationID: UUID()
        )
        XCTAssertEqual(reservation.encoded().count, 60)
        XCTAssertEqual(OmiLaunchCaptureCutReservation.decode(reservation.encoded()), .success(reservation))
        XCTAssertNotEqual(OmiLaunchCaptureCutReservationFormat.fileURL(rootURL: self.rootURL).pathExtension, OmiLaunchCaptureFormat.fileExtension)
        XCTAssertFalse(OmiLaunchCaptureCutReservationFormat.fileURL(rootURL: self.rootURL).lastPathComponent.hasPrefix(OmiLaunchCaptureFormat.filePrefix))
    }

    func testCommitRestoresOnlyAfterDurableBarrier() throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let store = OmiLaunchCaptureCutReservationStore(rootURL: self.rootURL, io: io)
        let reservation = OmiLaunchCaptureCutReservation(
            sealedGenerationID: UUID(),
            reservedGenerationID: UUID()
        )
        XCTAssertEqual(store.commit(reservation), .committed)
        try io.restoreLastSynchronizedState()
        XCTAssertEqual(store.read(), .valid(reservation))
    }

    func testWriteFailureMakesNoClaim() {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let store = OmiLaunchCaptureCutReservationStore(rootURL: self.rootURL, io: io)
        io.failNext(.barrier)
        XCTAssertEqual(
            store.commit(OmiLaunchCaptureCutReservation(sealedGenerationID: UUID(), reservedGenerationID: UUID())),
            .refused(.writeFailed)
        )
        XCTAssertEqual(store.read(), .absent)
    }

    func testFinalFixedLayoutRoundTripsAfterDurableBarrier() throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let final = OmiLaunchCaptureCutFinal(
            sealedGenerationID: UUID(),
            sealedNextSequence: 42,
            sealedEndOffset: 84,
            reservedGenerationID: UUID()
        )
        XCTAssertEqual(final.encoded().count, 76)
        XCTAssertEqual(OmiLaunchCaptureCutFinal.decode(final.encoded()), .success(final))
        let store = OmiLaunchCaptureCutFinalStore(rootURL: self.rootURL, io: io)
        XCTAssertEqual(store.commit(final), .committed)
        try io.restoreLastSynchronizedState()
        XCTAssertEqual(store.read(), .valid(final))
    }
}

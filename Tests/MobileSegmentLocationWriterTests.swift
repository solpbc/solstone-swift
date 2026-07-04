// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

final class MobileSegmentLocationWriterTests: XCTestCase {
    func testLiveRecoveryDropsTornTrailingLine() throws {
        let segmentID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_780_480_800)
        let completeFix = Self.fix(at: startedAt.addingTimeInterval(30))
        var data = Data()
        data.append(try MobileSegmentLocationWriter.liveStateLine(
            segmentID: segmentID,
            segmentStart: startedAt,
            tier: .balanced,
            accuracy: .full,
            gap: false,
            recordedAt: startedAt
        ))
        data.append(try MobileSegmentLocationWriter.liveFixLine(completeFix))
        let tornFix = String(
            decoding: try MobileSegmentLocationWriter.liveFixLine(Self.fix(at: startedAt.addingTimeInterval(60))),
            as: UTF8.self
        ).dropLast(16)
        data.append(Data(tornFix.utf8))

        let recovered = try MobileSegmentLocationWriter.recoverLiveLocation(segmentID: segmentID, from: data)

        XCTAssertEqual(recovered.fixes, [completeFix])
        XCTAssertEqual(recovered.visits, [])
        XCTAssertEqual(recovered.droppedLineCount, 0)
    }

    func testCompleteUnknownLiveLineDropsAfterState() throws {
        let segmentID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_780_480_800)
        var data = try MobileSegmentLocationWriter.liveStateLine(
            segmentID: segmentID,
            segmentStart: startedAt,
            tier: .balanced,
            accuracy: .full,
            gap: false,
            recordedAt: startedAt
        )
        data.append(Data(#"{"kind":"mystery","schema":"solstone.location.live.mystery/1"}"#.utf8))
        data.append(0x0A)

        let recovered = try MobileSegmentLocationWriter.recoverLiveLocation(segmentID: segmentID, from: data)

        XCTAssertEqual(recovered.droppedLineCount, 1)
        XCTAssertEqual(recovered.fixes, [])
    }

    func testLiveRecoverySkipsInteriorCorruptLinesAndKeepsValidBeforeAndAfter() throws {
        let segmentID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_780_480_800)
        let firstFix = Self.fix(at: startedAt.addingTimeInterval(30), lat: 37.1)
        let secondFix = Self.fix(at: startedAt.addingTimeInterval(90), lat: 37.2)
        var data = try MobileSegmentLocationWriter.liveStateLine(
            segmentID: segmentID,
            segmentStart: startedAt,
            tier: .balanced,
            accuracy: .full,
            gap: false,
            recordedAt: startedAt
        )
        data.append(try MobileSegmentLocationWriter.liveFixLine(firstFix))
        data.append(Data("not json\n".utf8))
        data.append(Data(#"{"kind":"mystery","schema":"solstone.location.live.mystery/1"}"#.utf8))
        data.append(0x0A)
        data.append(try MobileSegmentLocationWriter.liveFixLine(secondFix))

        let recovered = try MobileSegmentLocationWriter.recoverLiveLocation(segmentID: segmentID, from: data)

        XCTAssertEqual(recovered.fixes, [firstFix, secondFix])
        XCTAssertEqual(recovered.droppedLineCount, 2)
    }

    func testLiveRecoverySkipsSegmentMismatchStateWithoutCountingDrop() throws {
        let segmentID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_780_480_800)
        let fix = Self.fix(at: startedAt.addingTimeInterval(30))
        var data = try MobileSegmentLocationWriter.liveStateLine(
            segmentID: UUID(),
            segmentStart: startedAt,
            tier: .balanced,
            accuracy: .full,
            gap: false,
            recordedAt: startedAt
        )
        data.append(try MobileSegmentLocationWriter.liveStateLine(
            segmentID: segmentID,
            segmentStart: startedAt,
            tier: .balanced,
            accuracy: .full,
            gap: false,
            recordedAt: startedAt
        ))
        data.append(try MobileSegmentLocationWriter.liveFixLine(fix))

        let recovered = try MobileSegmentLocationWriter.recoverLiveLocation(segmentID: segmentID, from: data)

        XCTAssertEqual(recovered.fixes, [fix])
        XCTAssertEqual(recovered.droppedLineCount, 0)
    }

    func testLiveRecoveryCorruptAndMissingStateRemainFatal() throws {
        let segmentID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_780_480_800)
        let stateLine = String(decoding: try MobileSegmentLocationWriter.liveStateLine(
            segmentID: segmentID,
            segmentStart: startedAt,
            tier: .balanced,
            accuracy: .full,
            gap: false,
            recordedAt: startedAt
        ), as: UTF8.self)
        let corruptState = stateLine.replacingOccurrences(of: #""tier":"balanced""#, with: #""tier":"bogus""#)

        XCTAssertThrowsError(try MobileSegmentLocationWriter.recoverLiveLocation(segmentID: segmentID, from: Data(corruptState.utf8))) { error in
            XCTAssertEqual(error as? MobileSegmentLocationLiveRecoveryError, .corruptRecord)
        }

        let fixOnly = try MobileSegmentLocationWriter.liveFixLine(Self.fix(at: startedAt.addingTimeInterval(30)))
        XCTAssertThrowsError(try MobileSegmentLocationWriter.recoverLiveLocation(segmentID: segmentID, from: fixOnly)) { error in
            XCTAssertEqual(error as? MobileSegmentLocationLiveRecoveryError, .missingState)
        }
    }

    func testFreezeFromLiveMatchesFreezeFromBufferBytes() throws {
        let segmentID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_780_480_800)
        let endedAt = startedAt.addingTimeInterval(120)
        let fixes = [
            Self.fix(at: startedAt.addingTimeInterval(30), lat: 37.1),
            Self.fix(at: startedAt.addingTimeInterval(90), lat: 37.2)
        ]
        let visits = [
            LocationVisit(
                arrival: startedAt.addingTimeInterval(40),
                departure: startedAt.addingTimeInterval(100),
                lat: 37.3,
                lon: -122.0,
                hAcc: 20
            )
        ]
        let batch = LocationSegmentBatch(
            tier: .full,
            accuracy: .reduced,
            segmentStart: startedAt,
            coveredSeconds: 120,
            fixes: fixes,
            visits: visits,
            gap: true
        )
        var liveData = Data()
        liveData.append(try MobileSegmentLocationWriter.liveStateLine(
            segmentID: segmentID,
            segmentStart: startedAt,
            tier: .balanced,
            accuracy: .full,
            gap: false,
            recordedAt: startedAt
        ))
        for fix in fixes {
            liveData.append(try MobileSegmentLocationWriter.liveFixLine(fix))
        }
        for visit in visits {
            liveData.append(try MobileSegmentLocationWriter.liveVisitLine(visit))
        }
        liveData.append(try MobileSegmentLocationWriter.liveStateLine(
            segmentID: segmentID,
            segmentStart: startedAt,
            tier: .full,
            accuracy: .reduced,
            gap: true,
            recordedAt: endedAt
        ))

        let recovered = try MobileSegmentLocationWriter.recoverLiveLocation(segmentID: segmentID, from: liveData)
        let liveFrozen = try MobileSegmentLocationWriter.freeze(recovered.batch(endedAt: endedAt))
        let bufferFrozen = try MobileSegmentLocationWriter.freeze(batch)

        XCTAssertEqual(liveFrozen.data, bufferFrozen.data)
        XCTAssertEqual(liveFrozen.fixCount, bufferFrozen.fixCount)
        XCTAssertEqual(recovered.droppedLineCount, 0)
    }

    private static func fix(at date: Date, lat: Double = 37.3349) -> LocationFix {
        LocationFix(
            t: date,
            lat: lat,
            lon: -122.0090,
            hAcc: 12,
            alt: nil,
            vAcc: nil,
            speed: nil,
            course: nil,
            stationary: false
        )
    }
}

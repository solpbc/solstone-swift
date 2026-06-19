// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import CoreBluetooth
import XCTest

nonisolated final class BLEDiagnosticStorageTests: XCTestCase {
    func testReadCommandBytesUseBigEndianOffset() {
        XCTAssertEqual(
            BLEDiagnosticStorage.readCommandBytes(fileNumber: 0x00, offset: 790_240),
            [0x11, 0x00, 0x00, 0x0C, 0x0E, 0xE0]
        )
        XCTAssertEqual(
            BLEDiagnosticStorage.readCommandBytes(fileNumber: 0x2A, offset: 0x12345678),
            [0x11, 0x2A, 0x12, 0x34, 0x56, 0x78]
        )
    }

    func testWriteTypeSelectionPrefersWithResponseThenWithoutResponse() {
        XCTAssertEqual(BLEDiagnosticStorage.writeType(for: [.write]), .withResponse)
        XCTAssertEqual(BLEDiagnosticStorage.writeType(for: [.writeWithoutResponse]), .withoutResponse)
        XCTAssertEqual(BLEDiagnosticStorage.writeType(for: [.write, .writeWithoutResponse]), .withResponse)
        XCTAssertNil(BLEDiagnosticStorage.writeType(for: CBCharacteristicProperties(rawValue: 0)))
    }

    func testReadTimeoutTransitionOnlyFailsReadingWithZeroBytes() {
        XCTAssertEqual(
            BLEDiagnosticStorage.readTimeoutTransition(currentState: .reading, bytesReceived: 0),
            .failed("no storage data received within 5s — read command likely wrong for this firmware")
        )
        XCTAssertNil(BLEDiagnosticStorage.readTimeoutTransition(currentState: .reading, bytesReceived: 1))
        XCTAssertNil(BLEDiagnosticStorage.readTimeoutTransition(currentState: .ready, bytesReceived: 0))
    }

    func testStorageStatusDecoderMapsFirmwareStatuses() {
        let expected: [(UInt8, BLEStorageStatus, String, Bool)] = [
            (0, .ok, "OK", false),
            (6, .invalidCommand, "INVALID_COMMAND", true),
            (7, .fileNotFound, "FILE_NOT_FOUND", true),
            (8, .fileIndexOutOfRange, "FILE_INDEX_OUT_OF_RANGE", true),
            (9, .storageNotReady, "STORAGE_NOT_READY", true),
            (100, .transferComplete, "transfer complete", false),
            (42, .unknown(42), "status 42", false)
        ]

        for (rawValue, status, label, isFailure) in expected {
            let decoded = BLEStorageStatus(rawValue: rawValue)
            XCTAssertEqual(decoded, status)
            XCTAssertEqual(decoded.label, label)
            XCTAssertEqual(decoded.isFailure, isFailure)
        }
    }

    func testStorageFrameParserSplitsStatusesDataAndUnexpectedBytes() {
        XCTAssertEqual(BLEDiagnosticStorage.parseFrame(Data([0x06])), .status(0x06))
        XCTAssertEqual(
            BLEDiagnosticStorage.parseFrame(Data([0x12, 0x34, 0x56, 0x78, 0x03, 0xAA, 0xBB, 0xCC])),
            .data(timestamp: 0x12345678, payload: Data([0x03, 0xAA, 0xBB, 0xCC]))
        )
        XCTAssertEqual(BLEDiagnosticStorage.parseFrame(Data([0xAA, 0xBB, 0xCC])), .unexpected)
    }

    func testStorageFileListParserUsesLittleEndianEntries() {
        let entries = BLEDiagnosticStorage.parseFileList(Data([
            0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
            0x03, 0x00, 0x00, 0x00, 0xE0, 0x0E, 0x0C, 0x00
        ]))

        XCTAssertEqual(entries, [
            BLESDFileEntry(id: 0, fileNumber: 0, sizeBytes: 1_024, savedOffset: 0),
            BLESDFileEntry(id: 3, fileNumber: 3, sizeBytes: 790_240, savedOffset: 0)
        ])
    }

    func testStorageFileListParserCapsAtFiftyEntries() {
        var data = Data()
        for index in 0..<52 {
            let value = UInt32(index)
            data.append(contentsOf: [
                UInt8(value & 0x000000FF),
                UInt8((value >> 8) & 0x000000FF),
                UInt8((value >> 16) & 0x000000FF),
                UInt8((value >> 24) & 0x000000FF),
                UInt8(value & 0x000000FF),
                0x00,
                0x00,
                0x00
            ])
        }

        let entries = BLEDiagnosticStorage.parseFileList(data)

        XCTAssertEqual(entries.count, 50)
        XCTAssertEqual(entries.first?.fileNumber, 0)
        XCTAssertEqual(entries.last?.fileNumber, 49)
    }

    func testStorageFileListParserIgnoresTrailingTail() {
        let entries = BLEDiagnosticStorage.parseFileList(Data([
            0x02, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00,
            0xAA, 0xBB, 0xCC
        ]))

        XCTAssertEqual(entries, [
            BLESDFileEntry(id: 2, fileNumber: 2, sizeBytes: 16, savedOffset: 0)
        ])
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OnThisPhoneMigrationTests: XCTestCase {
    @MainActor
    func testMigrationFoldsSendingIntoOnThisPhoneAndExcludesDelivered() {
        let migration = onThisPhoneMigration(
            snapshot: Self.snapshot(states: [
                .savedOnThisPhone,
                .savedOnThisPhone,
                .savedOnThisPhone,
                .sending,
                .sending,
                .sending,
                .sending,
                .sending,
                .inYourJournal,
                .needsAttention,
                .needsAttention,
            ])
        )

        XCTAssertEqual(migration.onThisPhone, 8)
        XCTAssertEqual(migration.needsAttention, 2)
        XCTAssertEqual(migration.total, 10)
        XCTAssertFalse(migration.isEmpty)
    }

    @MainActor
    func testEmptyAndDeliveredOnlySnapshotsAreEmpty() {
        let empty = onThisPhoneMigration(snapshot: Self.snapshot(states: []))
        let delivered = onThisPhoneMigration(
            snapshot: Self.snapshot(states: [.inYourJournal, .inYourJournal])
        )

        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(delivered.onThisPhone, 0)
        XCTAssertEqual(delivered.needsAttention, 0)
        XCTAssertEqual(delivered.total, 0)
    }

    @MainActor
    func testNeedsAttentionOnlyDoesNotFabricateOnThisPhoneCount() {
        let migration = onThisPhoneMigration(
            snapshot: Self.snapshot(states: [.needsAttention, .needsAttention])
        )

        XCTAssertEqual(migration.onThisPhone, 0)
        XCTAssertEqual(migration.needsAttention, 2)
        XCTAssertEqual(migration.total, 2)
    }

    @MainActor
    func testRetryableFailedItemsCountAsOnThisPhone() {
        let items = (0..<3).map { index in
            Self.item(
                id: "retryable-\(index)",
                location: .failed,
                canRetry: true,
                isActivelyUploading: false
            )
        }
        let migration = onThisPhoneMigration(snapshot: Self.snapshot(items: items))

        XCTAssertEqual(migration.onThisPhone, 3)
        XCTAssertEqual(migration.needsAttention, 0)
    }

    @MainActor
    func testPermanentFailedItemsStillCountAsNeedsAttention() {
        let migration = onThisPhoneMigration(
            snapshot: Self.snapshot(items: [
                Self.item(
                    id: "permanent-failure",
                    location: .failed,
                    canRetry: false,
                    isActivelyUploading: false
                ),
            ])
        )

        XCTAssertEqual(migration.onThisPhone, 0)
        XCTAssertEqual(migration.needsAttention, 1)
    }

    @MainActor
    func testRetryableFailedItemsProduceSyncingHeadlineWhenPairedAndConnected() {
        let items = (0..<2).map { index in
            Self.item(
                id: "retryable-headline-\(index)",
                location: .failed,
                canRetry: true,
                isActivelyUploading: false
            )
        }
        let migration = onThisPhoneMigration(snapshot: Self.snapshot(items: items))
        let headline = onThisPhoneHeadline(
            migration: migration,
            isPaired: true,
            isConnected: true
        )

        XCTAssertEqual(headline.role, .syncing)
        XCTAssertEqual(headline.onThisPhone, 2)
        XCTAssertEqual(headline.needsAttention, 0)
    }
}

private extension OnThisPhoneMigrationTests {
    static func snapshot(states: [OnThisPhoneSendState]) -> OnThisPhoneAggregateSnapshot {
        let items = states.enumerated().map { index, state in
            Self.item(id: "item-\(index)", sendState: state)
        }
        return Self.snapshot(items: items)
    }

    static func snapshot(items: [OnThisPhoneItem]) -> OnThisPhoneAggregateSnapshot {
        return OnThisPhoneAggregateSnapshot(
            sources: [
                OnThisPhoneSourceSnapshot(sourceKind: .share, result: .loaded(items: items)),
            ],
            items: items
        )
    }

    static func item(
        id: String,
        location: OnThisPhoneLocation,
        canRetry: Bool,
        isActivelyUploading: Bool
    ) -> OnThisPhoneItem {
        Self.item(
            id: id,
            sendState: onThisPhoneSendState(
                location: location,
                canRetry: canRetry,
                isActivelyUploading: isActivelyUploading
            )
        )
    }

    static func item(id: String, sendState: OnThisPhoneSendState) -> OnThisPhoneItem {
        OnThisPhoneItem(
            id: id,
            sourceKind: .share,
            sendState: sendState,
            contentType: nil,
            filename: nil,
            bytes: nil,
            originApp: nil,
            basis: nil,
            itemTime: nil,
            targetJournal: nil,
            stream: nil,
            day: nil,
            segment: nil,
            deliveredAt: nil,
            rawFileURL: nil
        )
    }
}

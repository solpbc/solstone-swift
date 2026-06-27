// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class OnThisPhoneHeadlineTests: XCTestCase {
    func testConnectionAwareRolesCarryCounts() {
        let cases: [(OnThisPhoneMigration, Bool, Bool, OnThisPhoneHeadline.Role)] = [
            (Self.migration(onThisPhone: 8, needsAttention: 2), true, true, .syncing),
            (Self.migration(onThisPhone: 8, needsAttention: 2), true, false, .offline),
            (Self.migration(), true, true, .upToDate),
            (Self.migration(needsAttention: 2), true, true, .needsAttentionOnly),
            (Self.migration(needsAttention: 2), false, true, .needsAttentionOnly),
            (Self.migration(), false, false, .none),
        ]

        for (migration, isPaired, isConnected, expectedRole) in cases {
            let headline = onThisPhoneHeadline(
                migration: migration,
                isPaired: isPaired,
                isConnected: isConnected
            )

            XCTAssertEqual(headline.role, expectedRole)
            XCTAssertEqual(headline.onThisPhone, migration.onThisPhone)
            XCTAssertEqual(headline.needsAttention, migration.needsAttention)
        }
    }
}

private extension OnThisPhoneHeadlineTests {
    static func migration(
        onThisPhone: Int = 0,
        needsAttention: Int = 0
    ) -> OnThisPhoneMigration {
        OnThisPhoneMigration(
            onThisPhone: onThisPhone,
            needsAttention: needsAttention
        )
    }
}

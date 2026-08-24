// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SwiftUI
import XCTest

/// The deck's width to layout decision, exercised at synthetic widths.
///
/// There is no programmatic iPad window resizing and XCUITest cannot drag window
/// chrome, so the half, third and quadrant widths are reachable only here. The
/// band values are referenced symbolically on purpose: they are a styling choice,
/// and a correct retune must not turn these red.
nonisolated final class DeckLayoutTests: XCTestCase {
    /// Non-accessibility sizes, smallest first.
    private static let standardSizes: [DynamicTypeSize] = [
        .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
    ]

    private static let accessibilitySizes: [DynamicTypeSize] = [
        .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5,
    ]

    /// The text size the pinned band was derived to hold two tiles at: one step
    /// above the default.
    private static let derivedTypeBound: DynamicTypeSize = .xLarge

    private static var bandWidths: [CGFloat] {
        [DeckMetrics.columnMinimum, DeckMetrics.columnIdeal, DeckMetrics.columnMaximum]
    }

    // MARK: - the pinned band

    /// AC9. Two columns at each pinned width, at the default size and one step up.
    func testBandHoldsTwoColumnsThroughTheDerivedTypeBound() {
        for width in Self.bandWidths {
            for size in Self.standardSizes where size <= Self.derivedTypeBound {
                XCTAssertEqual(
                    deckLayout(columnWidth: width, dynamicTypeSize: size).columnCount,
                    2,
                    "width \(width) at \(size)"
                )
            }
        }
    }

    /// The band's own arithmetic: each pinned width really does carry two tiles
    /// plus the spacing plus the deck's 32 pt of padding.
    func testBandWidthsCoverTwoTilesPlusSpacingAndPadding() {
        for width in Self.bandWidths {
            let layout = deckLayout(columnWidth: width, dynamicTypeSize: Self.derivedTypeBound)
            let needed = 2 * layout.tileMinimum + DeckMetrics.tileSpacing + DeckMetrics.horizontalPadding
            XCTAssertGreaterThanOrEqual(width, needed, "width \(width) needs \(needed)")
        }
    }

    func testBandIsOrdered() {
        XCTAssertLessThanOrEqual(DeckMetrics.columnMinimum, DeckMetrics.columnIdeal)
        XCTAssertLessThanOrEqual(DeckMetrics.columnIdeal, DeckMetrics.columnMaximum)
    }

    /// The band deliberately sits above the width where two tiles merely fit at
    /// the default size: fitting is not the same as staying readable one step up.
    func testBandStartsAboveTheBareTwoColumnThreshold() {
        XCTAssertGreaterThan(DeckMetrics.columnMinimum, DeckMetrics.twoColumnThreshold)
    }

    // MARK: - the collapse threshold

    /// AC10. `columnMinimum` is the named upper bound on the collapse threshold:
    /// at that width and above, a two-column deck is guaranteed, so collapsing is
    /// forbidden.
    func testTwoColumnsGuaranteedAtAndAboveTheNamedUpperBound() {
        var width = DeckMetrics.columnMinimum
        while width <= 1400 {
            for size in Self.standardSizes where size <= Self.derivedTypeBound {
                XCTAssertGreaterThanOrEqual(
                    deckLayout(columnWidth: width, dynamicTypeSize: size).columnCount,
                    2,
                    "width \(width) at \(size)"
                )
            }
            width += 1
        }
    }

    /// The split's own predicate agrees with the bound: it does not ask to
    /// collapse at any text size the band was derived for.
    func testSplitDoesNotCollapseThroughTheDerivedTypeBound() {
        for size in Self.standardSizes where size <= Self.derivedTypeBound {
            XCTAssertFalse(splitCollapses(dynamicTypeSize: size), "\(size)")
        }
    }

    /// Constraint 9: past the band's text-size bound the deck cannot hold two
    /// tiles, so the split collapses rather than showing a one-column deck.
    func testSplitCollapsesRatherThanShowingOneColumn() {
        for size in Self.standardSizes where size > Self.derivedTypeBound {
            let layout = deckLayout(columnWidth: DeckMetrics.columnIdeal, dynamicTypeSize: size)
            XCTAssertEqual(layout.columnCount, 1, "expected one column at \(size)")
            XCTAssertTrue(splitCollapses(dynamicTypeSize: size), "\(size)")
        }
    }

    /// The predicate is exactly "the pinned column cannot hold two tiles", with no
    /// second rule of its own.
    func testSplitCollapsePredicateTracksThePinnedColumn() {
        for size in Self.standardSizes + Self.accessibilitySizes {
            XCTAssertEqual(
                splitCollapses(dynamicTypeSize: size),
                deckLayout(columnWidth: DeckMetrics.columnIdeal, dynamicTypeSize: size).columnCount < 2,
                "\(size)"
            )
        }
    }

    /// Two columns, once achieved, are never lost by widening the column.
    func testTwoColumnsAreMonotonicInWidth() {
        for size in Self.standardSizes {
            var seenTwo = false
            var width: CGFloat = 0
            while width <= 1400 {
                let count = deckLayout(columnWidth: width, dynamicTypeSize: size).columnCount
                if count >= 2 {
                    seenTwo = true
                } else {
                    XCTAssertFalse(seenTwo, "two columns lost by widening to \(width) at \(size)")
                }
                width += 1
            }
        }
    }

    // MARK: - accessibility sizes

    /// AC11. One column, and the shell behaves as compact.
    func testAccessibilitySizesCollapseToOneColumnAndReadAsCompact() {
        for size in Self.accessibilitySizes {
            for width in Self.bandWidths + [1032, 1376] {
                XCTAssertEqual(
                    deckLayout(columnWidth: width, dynamicTypeSize: size).columnCount,
                    1,
                    "width \(width) at \(size)"
                )
            }
            XCTAssertTrue(splitCollapses(dynamicTypeSize: size), "\(size)")
        }
    }

    // MARK: - the phone deck

    /// Constraint: the full-width phone deck keeps its tile minimum and its two
    /// columns. There is only one tile minimum, so nothing can lower it.
    func testPhoneWidthsKeepTheTileMinimumAndTwoColumns() {
        for width in [375, 390, 402, 414, 440] as [CGFloat] {
            let layout = deckLayout(columnWidth: width, dynamicTypeSize: .large)
            XCTAssertEqual(layout.tileMinimum, DeckMetrics.tileMinimum, "width \(width)")
            XCTAssertEqual(layout.columnCount, 2, "width \(width)")
        }
    }

    /// The derived threshold is exactly where two tiles first fit at the default
    /// size, padding included.
    func testTwoColumnThresholdIsWhereTwoTilesFirstFit() {
        XCTAssertEqual(
            deckLayout(columnWidth: DeckMetrics.twoColumnThreshold, dynamicTypeSize: .large).columnCount,
            2
        )
        XCTAssertEqual(
            deckLayout(columnWidth: DeckMetrics.twoColumnThreshold - 1, dynamicTypeSize: .large).columnCount,
            1
        )
    }

    /// A narrow deck reports one column rather than two overlapping ones.
    func testVeryNarrowWidthsReportOneColumn() {
        for width in [0, 100, 200, 320] as [CGFloat] {
            XCTAssertEqual(
                deckLayout(columnWidth: width, dynamicTypeSize: .large).columnCount,
                1,
                "width \(width)"
            )
        }
    }

    // MARK: - the scale table

    func testBodyTextScaleIsOneAtTheDefaultAndRisesMonotonically() {
        XCTAssertEqual(bodyTextScale(for: .large), 1)
        let all = Self.standardSizes + Self.accessibilitySizes
        for (smaller, larger) in zip(all, all.dropFirst()) {
            XCTAssertLessThan(
                bodyTextScale(for: smaller),
                bodyTextScale(for: larger),
                "\(smaller) vs \(larger)"
            )
        }
    }

    /// The tile minimum scales with the text size, which is what keeps a label
    /// from being squeezed as type grows.
    func testTileMinimumScalesWithTextSize() {
        let base = deckLayout(columnWidth: DeckMetrics.columnIdeal, dynamicTypeSize: .large).tileMinimum
        let stepped = deckLayout(columnWidth: DeckMetrics.columnIdeal, dynamicTypeSize: .xLarge).tileMinimum
        XCTAssertGreaterThan(stepped, base)
    }
}

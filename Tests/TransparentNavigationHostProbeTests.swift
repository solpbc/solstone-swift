// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SwiftUI
import UIKit
import XCTest

/// Exercises `TransparentNavigationHostProbe.ProbeView`'s clearing mechanism against
/// real, publicly-instantiable UIKit hosts (`UINavigationController`,
/// `UISplitViewController`, `UIHostingController`) rather than source text — a probe
/// attached to a window inside each of these must observe `backgroundColor` cleared,
/// `isOpaque` left untouched, and must never touch an unrelated ancestor view.
///
/// `isOpaque` is asserted explicitly UNCHANGED, not merely unasserted: a full
/// screenshot matrix proved that flipping it to `false` — even though an opaque
/// `CALayer` can occlude a clear `UIColor` fill in principle — intermittently dropped
/// deck tile contents and collapsed the deck into unframed glyphs in several
/// normal-appearance captures. `backgroundColor` alone is what the evidence supports.
///
/// The two additional matches this probe also clears — SwiftUI's private
/// `HostingView` and `NavigationStackHostingController` — are not covered here: they
/// are undocumented framework-internal types this test target cannot construct or
/// reliably reproduce the runtime type name of, so their clearing is validated by the
/// on-device diagnostic evidence that motivated matching them, and by the owner-pixel
/// screenshot pass, not by a hermetic unit test.
@MainActor
final class TransparentNavigationHostProbeTests: XCTestCase {
    func testClearsBackgroundOnHostingNavigationControllerWithoutTouchingOpacity() {
        let probe = TransparentNavigationHostProbe.ProbeView(frame: .zero)
        let content = UIViewController()
        content.view.addSubview(probe)

        let navigationController = UINavigationController(rootViewController: content)
        navigationController.view.backgroundColor = .white
        navigationController.view.isOpaque = true

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = navigationController
        window.makeKeyAndVisible()

        XCTAssertEqual(navigationController.view.backgroundColor, .clear)
        XCTAssertTrue(navigationController.view.isOpaque)
    }

    func testClearsBackgroundOnHostingSplitViewControllerWithoutTouchingOpacity() {
        let probe = TransparentNavigationHostProbe.ProbeView(frame: .zero)
        let detail = UIViewController()
        detail.view.addSubview(probe)

        let splitViewController = UISplitViewController(style: .doubleColumn)
        splitViewController.setViewController(UIViewController(), for: .primary)
        splitViewController.setViewController(detail, for: .secondary)
        splitViewController.view.backgroundColor = .white
        splitViewController.view.isOpaque = true

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.rootViewController = splitViewController
        window.makeKeyAndVisible()

        XCTAssertEqual(splitViewController.view.backgroundColor, .clear)
        XCTAssertTrue(splitViewController.view.isOpaque)
    }

    func testClearsBackgroundOnHostingUIHostingControllerWithoutTouchingOpacity() {
        let probe = TransparentNavigationHostProbe.ProbeView(frame: .zero)
        let hostingController = UIHostingController(rootView: Text("probe host"))
        hostingController.view.addSubview(probe)
        hostingController.view.backgroundColor = .white
        hostingController.view.isOpaque = true

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = hostingController
        window.makeKeyAndVisible()

        XCTAssertEqual(hostingController.view.backgroundColor, .clear)
        XCTAssertTrue(hostingController.view.isOpaque)
    }

    /// Negative twin: an ordinary ancestor view — standing in for a deck tile's or a
    /// card's own `deckSurface` fill — must never be touched, only view controllers
    /// matching the probe's narrow allowlist.
    func testDoesNotTouchAnUnrelatedAncestorView() {
        let probe = TransparentNavigationHostProbe.ProbeView(frame: .zero)
        let cardView = UIView()
        cardView.backgroundColor = .white
        cardView.isOpaque = true
        cardView.addSubview(probe)

        let viewController = UIViewController()
        viewController.view.addSubview(cardView)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.rootViewController = viewController
        window.makeKeyAndVisible()

        XCTAssertEqual(cardView.backgroundColor, .white)
        XCTAssertTrue(cardView.isOpaque)
    }
}

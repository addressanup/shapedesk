import XCTest
@testable import ShapeDesk

final class DisplayGeometryTests: XCTestCase {
    // Primary display 1440×900 with a 25 pt menu bar.
    private let primaryTop: CGFloat = 900

    func testPrimaryDisplayKeepsTheMenuBarInset() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        XCTAssertEqual(ViewModel.finderRect(visible: visible, primaryTop: primaryTop),
                       CGRect(x: 0, y: 25, width: 1440, height: 875))
    }

    func testTallerDisplayToTheRightIsMeasuredFromThePrimaryTop() {
        // 1920×1200 display to the right, bottom-aligned: AppKit frame (1440, 0, 1920, 1200).
        let visible = CGRect(x: 1440, y: 0, width: 1920, height: 1175)
        // Its top edge sits 300 pt above the primary's, so Finder sees y = -300 + 25.
        XCTAssertEqual(ViewModel.finderRect(visible: visible, primaryTop: primaryTop),
                       CGRect(x: 1440, y: -275, width: 1920, height: 1175))
    }

    func testDisplayBelowAndLeftOfThePrimary() {
        // 1280×800 display below and to the left, without a menu bar: AppKit frame (-1280, -800, 1280, 800).
        let visible = CGRect(x: -1280, y: -800, width: 1280, height: 800)
        XCTAssertEqual(ViewModel.finderRect(visible: visible, primaryTop: primaryTop),
                       CGRect(x: -1280, y: 900, width: 1280, height: 800))
    }
}

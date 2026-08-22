import CoreGraphics
import XCTest
@testable import UsageInk

final class ActivityFocusLayoutTests: XCTestCase {
    func testContentRectAndRowHeightsMatchSpec() {
        XCTAssertEqual(ActivityFocusLayout.contentRect, CGRect(x: 14, y: 10, width: 372, height: 282))
        XCTAssertEqual(ActivityFocusLayout.titleRect, CGRect(x: 14, y: 10, width: 372, height: 31))
        XCTAssertEqual(ActivityFocusLayout.bodyRect, CGRect(x: 14, y: 41, width: 372, height: 223))
        XCTAssertEqual(ActivityFocusLayout.footerRect, CGRect(x: 14, y: 264, width: 372, height: 28))
        XCTAssertEqual(ActivityFocusLayout.titleFontSize, 11)
        XCTAssertEqual(ActivityFocusLayout.primaryValueFontSize, 43)
        XCTAssertEqual(ActivityFocusLayout.secondaryValueFontSize, 21)
        XCTAssertEqual(ActivityFocusLayout.quotaValueFontSize, 21)
        XCTAssertEqual(ActivityFocusLayout.quotaLabelFontSize, 11)
        XCTAssertEqual(ActivityFocusLayout.resetFontSize, 9)
        XCTAssertEqual(ActivityFocusLayout.footerFontSize, 8)
        XCTAssertEqual(ActivityFocusLayout.quotaRowHeight, 73)
        XCTAssertEqual(ActivityFocusLayout.primaryColumnWidth, 233)
        XCTAssertEqual(ActivityFocusLayout.secondaryColumnWidth, 139)
        XCTAssertEqual(ActivityFocusLayout.normalRule, 1)
        XCTAssertEqual(ActivityFocusLayout.strongRule, 2)
    }

    func testLocalAndQuotaRegionsUseFixedIntegerGeometry() {
        XCTAssertEqual(ActivityFocusLayout.localRegionHeight(hasQuotas: true), 150)
        XCTAssertEqual(ActivityFocusLayout.localRegionHeight(hasQuotas: false), 223)
        XCTAssertEqual(
            ActivityFocusLayout.primaryRect(hasSecondary: true, hasQuotas: true),
            CGRect(x: 14, y: 41, width: 233, height: 150)
        )
        XCTAssertEqual(
            ActivityFocusLayout.primaryRect(hasSecondary: false, hasQuotas: true),
            CGRect(x: 14, y: 41, width: 372, height: 150)
        )
        XCTAssertEqual(
            ActivityFocusLayout.primaryRect(hasSecondary: false, hasQuotas: false),
            CGRect(x: 14, y: 41, width: 372, height: 223)
        )

        let secondary = ActivityFocusLayout.secondaryRects(count: 3, hasQuotas: true)
        XCTAssertEqual(secondary.map(\.width), [139, 139, 139])
        XCTAssertEqual(secondary.map(\.height), [50, 50, 50])
        XCTAssertEqual(secondary[0].origin, CGPoint(x: 247, y: 41))
        XCTAssertEqual(secondary[2].maxY, 191)

        let twoNoQuota = ActivityFocusLayout.secondaryRects(count: 2, hasQuotas: false)
        XCTAssertEqual(twoNoQuota.map(\.height), [112, 111])
        XCTAssertEqual(twoNoQuota[0].origin, CGPoint(x: 247, y: 41))
        XCTAssertEqual(twoNoQuota[1].maxY, 264)
        XCTAssertEqual(ActivityFocusLayout.secondaryRects(count: 0, hasQuotas: true), [])
        XCTAssertEqual(ActivityFocusLayout.secondaryRects(count: 9, hasQuotas: true).count, 3)
    }

    func testQuotaRemainderPixelsGoToEarlierCells() {
        XCTAssertEqual(ActivityFocusLayout.split(372, into: 1), [372])
        XCTAssertEqual(ActivityFocusLayout.split(372, into: 2), [186, 186])
        let one = ActivityFocusLayout.quotaRects(count: 1)
        XCTAssertEqual(one, [CGRect(x: 14, y: 191, width: 372, height: 73)])
        let two = ActivityFocusLayout.quotaRects(count: 2)
        XCTAssertEqual(two[0], CGRect(x: 14, y: 191, width: 186, height: 73))
        XCTAssertEqual(two[1], CGRect(x: 200, y: 191, width: 186, height: 73))
        XCTAssertEqual(two[1].maxX, 386)
        XCTAssertEqual(two[1].maxY, 264)
        XCTAssertEqual(ActivityFocusLayout.quotaRects(count: 0), [])
    }
}

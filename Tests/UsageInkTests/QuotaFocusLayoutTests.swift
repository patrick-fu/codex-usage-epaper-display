import CoreGraphics
import XCTest
@testable import UsageInk

final class QuotaFocusLayoutTests: XCTestCase {
    func testContentRectAndRowHeightsMatchSpec() {
        XCTAssertEqual(QuotaFocusLayout.contentRect, CGRect(x: 14, y: 10, width: 372, height: 282))
        XCTAssertEqual(QuotaFocusLayout.titleRect, CGRect(x: 14, y: 10, width: 372, height: 38))
        XCTAssertEqual(QuotaFocusLayout.heroRect, CGRect(x: 14, y: 48, width: 372, height: 145))
        XCTAssertEqual(QuotaFocusLayout.tickerRect, CGRect(x: 14, y: 193, width: 372, height: 73))
        XCTAssertEqual(QuotaFocusLayout.footerRect, CGRect(x: 14, y: 266, width: 372, height: 26))
        XCTAssertEqual(QuotaFocusLayout.titleFontSize, 13)
        XCTAssertEqual(QuotaFocusLayout.heroValueFontSize, 65)
        XCTAssertEqual(QuotaFocusLayout.heroValueLineHeight, 56)
        XCTAssertEqual(QuotaFocusLayout.tickerValueFontSize, 21)
        XCTAssertEqual(QuotaFocusLayout.footerFontSize, 8)
        XCTAssertEqual(QuotaFocusLayout.normalRule, 1)
        XCTAssertEqual(QuotaFocusLayout.strongRule, 2)
    }

    func testTickerRemainderPixelsGoToEarlierCells() {
        XCTAssertEqual(QuotaFocusLayout.split(372, into: 3), [124, 124, 124])
        XCTAssertEqual(QuotaFocusLayout.split(372, into: 5), [75, 75, 74, 74, 74])
        let rects = QuotaFocusLayout.tickerCellRects(count: 5)
        XCTAssertEqual(rects.map(\.width), [75, 75, 74, 74, 74])
        XCTAssertEqual(rects.first?.minX, 14)
        XCTAssertEqual(rects.last?.maxX, 386)
        XCTAssertEqual(QuotaFocusLayout.tickerCellRects(count: 0), [])
        XCTAssertEqual(QuotaFocusLayout.tickerCellRects(count: 9).count, 5)
    }
}

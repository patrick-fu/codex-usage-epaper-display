import CoreGraphics
import XCTest
@testable import UsageInk

final class BalancedLayoutTests: XCTestCase {
    func testContentRectAndRowHeightsMatchSpec() {
        XCTAssertEqual(BalancedLayout.contentRect, CGRect(x: 16, y: 11, width: 368, height: 280))
        XCTAssertEqual(BalancedLayout.titleRect, CGRect(x: 16, y: 11, width: 368, height: 38))
        XCTAssertEqual(BalancedLayout.bodyRect, CGRect(x: 16, y: 49, width: 368, height: 215))
        XCTAssertEqual(BalancedLayout.footerRect, CGRect(x: 16, y: 264, width: 368, height: 27))
        XCTAssertEqual(BalancedLayout.titleFontSize, 17)
        XCTAssertEqual(BalancedLayout.quotaValueFontSize, 29)
        XCTAssertEqual(BalancedLayout.metricValueFontSize, 25)
        XCTAssertEqual(BalancedLayout.quotaLabelFontSize, 11)
        XCTAssertEqual(BalancedLayout.metricLabelFontSize, 9)
        XCTAssertEqual(BalancedLayout.resetFontSize, 9)
        XCTAssertEqual(BalancedLayout.footerFontSize, 8)
    }

    func testEntryRemainderPixelsGoToEarlierColumnsAndRows() {
        XCTAssertEqual(BalancedLayout.split(368, into: 2), [184, 184])
        XCTAssertEqual(BalancedLayout.split(215, into: 3), [72, 72, 71])
        XCTAssertEqual(BalancedLayout.split(215, into: 2), [108, 107])
        let six = BalancedLayout.entryRects(count: 6)
        XCTAssertEqual(six.map(\.width), [184, 184, 184, 184, 184, 184])
        XCTAssertEqual(six.map(\.height), [72, 72, 72, 72, 71, 71])
        XCTAssertEqual(six.first?.minX, 16)
        XCTAssertEqual(six[1].minX, 200)
        XCTAssertEqual(six.last?.maxX, 384)
        XCTAssertEqual(six.last?.maxY, 264)
        let one = BalancedLayout.entryRects(count: 1)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0], CGRect(x: 16, y: 49, width: 184, height: 215))
        XCTAssertEqual(BalancedLayout.entryRects(count: 0), [])
        XCTAssertEqual(BalancedLayout.entryRects(count: 9).count, 6)
    }

    func testCellInsetIsIntegerAndLabelResetDoNotOverlap() {
        XCTAssertEqual(BalancedLayout.cellInset, 6)
        let cell = BalancedLayout.entryRects(count: 2)[0]
        let content = DisplayCellGeometry.insetRect(in: cell, inset: BalancedLayout.cellInset)
        XCTAssertEqual(Int(content.minX), Int(cell.minX) + 6)
        XCTAssertEqual(Int(content.width), Int(cell.width) - 12)
        let (label, reset) = DisplayCellGeometry.splitLeadingRow(content, height: 14)
        XCTAssertEqual(label.maxX, reset.minX)
        XCTAssertEqual(label.width + reset.width, content.width)
        XCTAssertLessThanOrEqual(label.maxX, reset.minX)
        XCTAssertEqual(label.origin.x.rounded(.towardZero), label.origin.x)
        XCTAssertEqual(reset.origin.x.rounded(.towardZero), reset.origin.x)
    }
}

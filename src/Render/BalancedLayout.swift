import CoreGraphics
import Foundation

enum BalancedLayout {
    static let canvasWidth = 400
    static let canvasHeight = 300
    static let contentRect = CGRect(x: 16, y: 11, width: 368, height: 280)
    static let titleHeight: CGFloat = 38
    static let bodyHeight: CGFloat = 215
    static let footerHeight: CGFloat = 27
    static let titleFontSize: CGFloat = 17
    static let quotaValueFontSize: CGFloat = 29
    static let metricValueFontSize: CGFloat = 25
    static let quotaLabelFontSize: CGFloat = 11
    static let metricLabelFontSize: CGFloat = 9
    static let resetFontSize: CGFloat = 9
    static let footerFontSize: CGFloat = 8
    static let maxEntries = 6
    static let maxBodyEntries = 6
    static let columnCount = 2
    static let normalRule: CGFloat = 1
    static let strongRule: CGFloat = 2
    static let cellInset = 6
    static var cellHorizontalInset: Int { cellInset }
    static var cellVerticalInset: Int { cellInset }
    static let progressTrackHeight: CGFloat = 6
    static let badgeHeight: CGFloat = 12

    static let titleRect = CGRect(
        x: contentRect.minX,
        y: contentRect.minY,
        width: contentRect.width,
        height: titleHeight
    )

    static let bodyRect = CGRect(
        x: contentRect.minX,
        y: titleRect.maxY,
        width: contentRect.width,
        height: bodyHeight
    )

    static let footerRect = CGRect(
        x: contentRect.minX,
        y: bodyRect.maxY,
        width: contentRect.width,
        height: footerHeight
    )

    static var titleRuleRect: CGRect {
        CGRect(
            x: titleRect.minX,
            y: titleRect.maxY - normalRule,
            width: titleRect.width,
            height: normalRule
        )
    }

    static func split(_ length: Int, into count: Int) -> [Int] {
        IntegerSplit.split(length, into: count)
    }

    static func bodyCellRects(count: Int) -> [CGRect] {
        entryRects(count: count)
    }

    static func entryRects(count: Int) -> [CGRect] {
        let n = min(max(count, 0), maxEntries)
        guard n > 0 else { return [] }
        let rows = (n + columnCount - 1) / columnCount
        let widths = split(Int(bodyRect.width), into: columnCount)
        let heights = split(Int(bodyRect.height), into: rows)
        var rects: [CGRect] = []
        var y = Int(bodyRect.minY)
        for row in 0..<rows {
            var x = Int(bodyRect.minX)
            for col in 0..<columnCount {
                let index = row * columnCount + col
                if index < n {
                    rects.append(
                        CGRect(x: x, y: y, width: widths[col], height: heights[row])
                    )
                }
                x += widths[col]
            }
            y += heights[row]
        }
        return rects
    }

    static func contentRect(in cell: CGRect) -> CGRect {
        DisplayCellGeometry.insetRect(in: cell, inset: cellInset)
    }
}

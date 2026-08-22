import CoreGraphics
import Foundation

enum ActivityFocusLayout {
    static let canvasWidth = 400
    static let canvasHeight = 300
    static let contentRect = CGRect(x: 14, y: 10, width: 372, height: 282)
    static let titleHeight: CGFloat = 31
    static let bodyHeight: CGFloat = 223
    static let footerHeight: CGFloat = 28
    static let quotaRowHeight: CGFloat = 73
    static let primaryColumnWidth = 233
    static let secondaryColumnWidth = 139
    static let titleFontSize: CGFloat = 11
    static let primaryValueFontSize: CGFloat = 43
    static let secondaryValueFontSize: CGFloat = 21
    static let quotaValueFontSize: CGFloat = 21
    static let quotaLabelFontSize: CGFloat = 11
    static let metricLabelFontSize: CGFloat = 9
    static let resetFontSize: CGFloat = 9
    static let footerFontSize: CGFloat = 8
    static let maxSecondaryCells = 3
    static let normalRule: CGFloat = 1
    static let strongRule: CGFloat = 2
    static let cellInset = 8
    static var cellHorizontalInset: Int { cellInset }
    static var cellVerticalInset: Int { cellInset }
    static let progressTrackHeight: CGFloat = 8
    static let progressBottomInset: CGFloat = 12

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

    static func localRegionHeight(hasLocals: Bool = true, hasQuotas: Bool) -> Int {
        guard hasLocals else { return 0 }
        return hasQuotas ? Int(bodyHeight - quotaRowHeight) : Int(bodyHeight)
    }

    static func localRegionRect(hasLocals: Bool = true, hasQuotas: Bool) -> CGRect {
        CGRect(
            x: bodyRect.minX,
            y: bodyRect.minY,
            width: bodyRect.width,
            height: CGFloat(localRegionHeight(hasLocals: hasLocals, hasQuotas: hasQuotas))
        )
    }

    static func primaryRect(hasSecondary: Bool, hasLocals: Bool = true, hasQuotas: Bool) -> CGRect {
        let local = localRegionRect(hasLocals: hasLocals, hasQuotas: hasQuotas)
        let width = hasSecondary ? primaryColumnWidth : Int(local.width)
        return CGRect(x: local.minX, y: local.minY, width: CGFloat(width), height: local.height)
    }

    static func secondaryRects(count: Int, hasLocals: Bool = true, hasQuotas: Bool) -> [CGRect] {
        let n = min(max(count, 0), maxSecondaryCells)
        guard n > 0 else { return [] }
        let local = localRegionRect(hasLocals: hasLocals, hasQuotas: hasQuotas)
        let heights = split(Int(local.height), into: n)
        var y = Int(local.minY)
        return heights.map { height in
            let rect = CGRect(
                x: Int(local.minX) + primaryColumnWidth,
                y: y,
                width: secondaryColumnWidth,
                height: height
            )
            y += height
            return rect
        }
    }

    static func quotaBandHeight(hasLocals: Bool) -> Int {
        hasLocals ? Int(quotaRowHeight) : Int(bodyHeight)
    }

    static func quotaRects(count: Int, hasLocals: Bool = true) -> [CGRect] {
        let n = max(count, 0)
        guard n > 0 else { return [] }
        let height = quotaBandHeight(hasLocals: hasLocals)
        let y = Int(bodyRect.minY) + localRegionHeight(hasLocals: hasLocals, hasQuotas: true)
        let widths = split(Int(bodyRect.width), into: n)
        var x = Int(bodyRect.minX)
        return widths.map { width in
            let rect = CGRect(
                x: x,
                y: y,
                width: width,
                height: height
            )
            x += width
            return rect
        }
    }

    static func quotaTopRuleRect(hasLocals: Bool = true) -> CGRect {
        let y = Int(bodyRect.minY) + localRegionHeight(hasLocals: hasLocals, hasQuotas: true)
        return CGRect(
            x: bodyRect.minX,
            y: CGFloat(y),
            width: bodyRect.width,
            height: strongRule
        )
    }
}

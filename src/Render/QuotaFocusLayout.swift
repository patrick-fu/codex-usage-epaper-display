import CoreGraphics
import Foundation

enum QuotaFocusLayout {
    static let canvasWidth = 400
    static let canvasHeight = 300
    static let contentRect = CGRect(x: 14, y: 10, width: 372, height: 282)
    static let titleHeight: CGFloat = 38
    static let heroHeight: CGFloat = 145
    static let tickerHeight: CGFloat = 73
    static let footerHeight: CGFloat = 26

    static let titleFontSize: CGFloat = 13
    static let heroValueFontSize: CGFloat = 65
    static let heroValueLineHeight: CGFloat = 56
    static let heroLabelFontSize: CGFloat = 11
    static let resetFontSize: CGFloat = 9
    static let tickerValueFontSize: CGFloat = 21
    static let tickerLabelFontSize: CGFloat = 9
    static let footerFontSize: CGFloat = 8
    static let planMaxDisplayedCharacters = 8
    static let normalRule: CGFloat = 1
    static let strongRule: CGFloat = 2
    static let maxTickerCells = 5

    static let titleRect = CGRect(
        x: contentRect.minX,
        y: contentRect.minY,
        width: contentRect.width,
        height: titleHeight
    )

    static let heroRect = CGRect(
        x: contentRect.minX,
        y: titleRect.maxY,
        width: contentRect.width,
        height: heroHeight
    )

    static let tickerRect = CGRect(
        x: contentRect.minX,
        y: heroRect.maxY,
        width: contentRect.width,
        height: tickerHeight
    )

    static let footerRect = CGRect(
        x: contentRect.minX,
        y: tickerRect.maxY,
        width: contentRect.width,
        height: footerHeight
    )

    static let tickerCellHorizontalInset: CGFloat = 6
    static let tickerCellVerticalInset: CGFloat = 8
    static let tickerLabelHeight: CGFloat = 12
    static let tickerBadgeHeight: CGFloat = 14
    static let heroProgressTrackHeight: CGFloat = 8
    static let heroProgressBottomInset: CGFloat = 18
    static let heroValueTopInset: CGFloat = 28
    static let heroBadgeHeight: CGFloat = 14

    static var titleRuleRect: CGRect {
        CGRect(
            x: titleRect.minX,
            y: titleRect.maxY - normalRule,
            width: titleRect.width,
            height: normalRule
        )
    }

    static var tickerTopRuleRect: CGRect {
        CGRect(x: tickerRect.minX, y: tickerRect.minY, width: tickerRect.width, height: strongRule)
    }

    static var tickerBottomRuleRect: CGRect {
        CGRect(
            x: tickerRect.minX,
            y: tickerRect.maxY - strongRule,
            width: tickerRect.width,
            height: strongRule
        )
    }

    static var heroProgressTrackRect: CGRect {
        CGRect(
            x: heroRect.minX,
            y: heroRect.maxY - heroProgressBottomInset,
            width: heroRect.width,
            height: heroProgressTrackHeight
        )
    }

    static var heroBadgeRect: CGRect {
        CGRect(
            x: heroRect.minX,
            y: heroRect.minY + heroValueTopInset + heroValueLineHeight + 4,
            width: heroRect.width,
            height: heroBadgeHeight
        )
    }

    static func tickerContentRect(in cell: CGRect) -> CGRect {
        CGRect(
            x: cell.minX + tickerCellHorizontalInset,
            y: cell.minY + tickerCellVerticalInset,
            width: cell.width - 2 * tickerCellHorizontalInset,
            height: cell.height - 2 * tickerCellVerticalInset
        )
    }

    static func tickerLabelRect(in cell: CGRect) -> CGRect {
        let inset = tickerContentRect(in: cell)
        return CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: tickerLabelHeight)
    }

    static func tickerBadgeRect(in cell: CGRect) -> CGRect {
        let inset = tickerContentRect(in: cell)
        return CGRect(
            x: inset.minX,
            y: inset.maxY - tickerBadgeHeight,
            width: inset.width,
            height: tickerBadgeHeight
        )
    }

    static func tickerValueRect(in cell: CGRect, hasBadge: Bool) -> CGRect {
        let inset = tickerContentRect(in: cell)
        let top = inset.minY + tickerLabelHeight + 2
        let bottom = hasBadge ? tickerBadgeRect(in: cell).minY - 2 : inset.maxY
        return CGRect(x: inset.minX, y: top, width: inset.width, height: max(0, bottom - top))
    }

    static func tickerCellRects(count: Int) -> [CGRect] {
        let cells = min(max(count, 0), maxTickerCells)
        guard cells > 0 else { return [] }
        let widths = split(Int(tickerRect.width), into: cells)
        var x = Int(tickerRect.minX)
        return widths.map { width in
            let rect = CGRect(
                x: x,
                y: Int(tickerRect.minY),
                width: width,
                height: Int(tickerRect.height)
            )
            x += width
            return rect
        }
    }

    static func split(_ width: Int, into count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let base = width / count
        let remainder = width % count
        return (0..<count).map { index in
            base + (index < remainder ? 1 : 0)
        }
    }
}

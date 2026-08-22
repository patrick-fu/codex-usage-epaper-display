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

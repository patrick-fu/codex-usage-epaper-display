import CoreGraphics
import CoreText
import Foundation

enum FrameRasterizer {
    static func rasterize(_ model: QuotaFocusFrameModel) -> DisplayPlanes {
        let width = PlaneEncoder.width
        let height = PlaneEncoder.height
        var buffer = [UInt8](repeating: 255, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return
            }
            ctx.setFillColor(Self.white)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
            draw(model, in: ctx, language: model.language)
            ctx.restoreGState()
        }
        return PlaneEncoder.encode { x, y in
            let row = height - 1 - y
            let offset = (row * width + x) * 4
            return inkColor(r: buffer[offset], g: buffer[offset + 1], b: buffer[offset + 2])
        }
    }

    private static let white = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1, 1, 1, 1])!
    private static let black = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 0, 1])!
    private static let red = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1, 0, 0, 1])!

    private static func draw(
        _ model: QuotaFocusFrameModel,
        in ctx: CGContext,
        language: ResolvedInterfaceLanguage
    ) {
        ctx.clip(to: cgRect(QuotaFocusLayout.contentRect))
        let lang = DisplayCopy.languageCode(language)
        drawHeader(model, in: ctx, languageCode: lang)
        if let hero = model.hero {
            drawHero(hero, in: ctx, languageCode: lang)
        } else if let mark = model.unavailableMark {
            drawCentered(
                mark,
                font: font(size: 21, languageCode: lang, heavy: true, monoDigits: false),
                color: black,
                in: QuotaFocusLayout.heroRect,
                ctx: ctx
            )
        }
        drawTicker(model.ticker, in: ctx, languageCode: lang)
        drawFooter(model, in: ctx, languageCode: lang)
    }

    private static func drawHeader(
        _ model: QuotaFocusFrameModel,
        in ctx: CGContext,
        languageCode: String
    ) {
        let rect = QuotaFocusLayout.titleRect
        let titleFont = font(size: QuotaFocusLayout.titleFontSize, languageCode: languageCode, heavy: true, monoDigits: false)
        let planFont = font(size: QuotaFocusLayout.titleFontSize, languageCode: languageCode, heavy: false, monoDigits: true)
        var titleWidth = rect.width
        if model.showPlan, let plan = model.plan {
            let planWidth = min(120, rect.width * 0.4)
            drawText(
                plan,
                font: planFont,
                color: black,
                in: CGRect(x: rect.maxX - planWidth, y: rect.minY, width: planWidth, height: rect.height - 4),
                align: .right,
                vertical: .center,
                ctx: ctx
            )
            titleWidth = rect.width - planWidth - 8
        }
        drawText(
            model.title,
            font: titleFont,
            color: black,
            in: CGRect(x: rect.minX, y: rect.minY, width: titleWidth, height: rect.height - 4),
            align: .left,
            vertical: .center,
            ctx: ctx
        )
        fillRule(CGRect(x: rect.minX, y: rect.maxY - QuotaFocusLayout.normalRule, width: rect.width, height: QuotaFocusLayout.normalRule), ctx: ctx)
    }

    private static func drawHero(
        _ field: QuotaFocusFrameModel.Field,
        in ctx: CGContext,
        languageCode: String
    ) {
        let rect = QuotaFocusLayout.heroRect
        let ink = field.usesRed ? red : black
        drawText(
            field.label,
            font: font(size: QuotaFocusLayout.heroLabelFontSize, languageCode: languageCode, heavy: true, monoDigits: false),
            color: black,
            in: CGRect(x: rect.minX, y: rect.minY + 8, width: rect.width * 0.55, height: 16),
            align: .left,
            vertical: .center,
            ctx: ctx
        )
        if let secondary = field.secondaryText {
            drawText(
                secondary,
                font: font(size: QuotaFocusLayout.resetFontSize, languageCode: languageCode, heavy: false, monoDigits: false),
                color: black,
                in: CGRect(x: rect.minX + rect.width * 0.45, y: rect.minY + 8, width: rect.width * 0.55, height: 16),
                align: .right,
                vertical: .center,
                ctx: ctx
            )
        }
        let valueTop = rect.minY + 28
        drawText(
            field.displayedValue,
            font: font(size: QuotaFocusLayout.heroValueFontSize, languageCode: languageCode, heavy: true, monoDigits: true),
            color: ink,
            in: CGRect(x: rect.minX, y: valueTop, width: rect.width, height: QuotaFocusLayout.heroValueLineHeight),
            align: .left,
            vertical: .center,
            ctx: ctx
        )
        if let badge = field.badge {
            drawText(
                badge,
                font: font(size: QuotaFocusLayout.resetFontSize, languageCode: languageCode, heavy: false, monoDigits: false),
                color: black,
                in: CGRect(x: rect.minX, y: valueTop + QuotaFocusLayout.heroValueLineHeight + 4, width: rect.width, height: 14),
                align: .left,
                vertical: .center,
                ctx: ctx
            )
        }
        if let percent = field.progressPercent {
            let track = CGRect(x: rect.minX, y: rect.maxY - 18, width: rect.width, height: 8)
            drawProgress(percent: percent, in: track, fill: ink, ctx: ctx)
        }
    }

    private static func drawTicker(
        _ fields: [QuotaFocusFrameModel.Field],
        in ctx: CGContext,
        languageCode: String
    ) {
        let rect = QuotaFocusLayout.tickerRect
        fillRule(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: QuotaFocusLayout.strongRule), ctx: ctx)
        fillRule(CGRect(x: rect.minX, y: rect.maxY - QuotaFocusLayout.strongRule, width: rect.width, height: QuotaFocusLayout.strongRule), ctx: ctx)
        let cells = QuotaFocusLayout.tickerCellRects(count: fields.count)
        for (index, field) in fields.enumerated() {
            let cell = cells[index]
            if index > 0 {
                fillRule(
                    CGRect(x: cell.minX, y: rect.minY + QuotaFocusLayout.strongRule, width: QuotaFocusLayout.normalRule, height: rect.height - 2 * QuotaFocusLayout.strongRule),
                    ctx: ctx
                )
            }
            let inset = CGRect(x: cell.minX + 6, y: cell.minY + 8, width: cell.width - 12, height: cell.height - 16)
            drawText(
                field.label,
                font: font(size: QuotaFocusLayout.tickerLabelFontSize, languageCode: languageCode, heavy: true, monoDigits: false),
                color: black,
                in: CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: 14),
                align: .left,
                vertical: .center,
                ctx: ctx
            )
            drawText(
                field.displayedValue,
                font: font(size: QuotaFocusLayout.tickerValueFontSize, languageCode: languageCode, heavy: true, monoDigits: true),
                color: field.usesRed ? red : black,
                in: CGRect(x: inset.minX, y: inset.minY + 16, width: inset.width, height: inset.height - 16),
                align: .left,
                vertical: .center,
                ctx: ctx
            )
        }
    }

    private static func drawFooter(
        _ model: QuotaFocusFrameModel,
        in ctx: CGContext,
        languageCode: String
    ) {
        let rect = QuotaFocusLayout.footerRect
        let footerFont = font(size: QuotaFocusLayout.footerFontSize, languageCode: languageCode, heavy: false, monoDigits: true)
        if let updated = model.footerUpdated {
            drawText(
                updated,
                font: footerFont,
                color: black,
                in: CGRect(x: rect.minX, y: rect.minY, width: rect.width * 0.6, height: rect.height),
                align: .left,
                vertical: .center,
                ctx: ctx
            )
        }
        if let status = model.footerStatus {
            drawText(
                status,
                font: footerFont,
                color: black,
                in: CGRect(x: rect.minX + rect.width * 0.4, y: rect.minY, width: rect.width * 0.6, height: rect.height),
                align: .right,
                vertical: .center,
                ctx: ctx
            )
        }
    }

    private static func drawProgress(percent: Int, in rect: CGRect, fill: CGColor, ctx: CGContext) {
        fillRule(rect, ctx: ctx)
        let inset = rect.insetBy(dx: 1, dy: 1)
        ctx.setFillColor(white)
        ctx.fill(cgRect(inset))
        let innerWidth = max(0, Int(inset.width) * percent / 100)
        if innerWidth > 0 {
            ctx.setFillColor(fill)
            ctx.fill(cgRect(CGRect(x: inset.minX, y: inset.minY, width: CGFloat(innerWidth), height: inset.height)))
        }
    }

    private static func fillRule(_ rect: CGRect, ctx: CGContext) {
        ctx.setFillColor(black)
        ctx.fill(cgRect(rect))
    }

    private static func drawCentered(
        _ text: String,
        font: CTFont,
        color: CGColor,
        in rect: CGRect,
        ctx: CGContext
    ) {
        drawText(text, font: font, color: color, in: rect, align: .center, vertical: .center, ctx: ctx)
    }

    private enum HorizontalAlign {
        case left, right, center
    }

    private enum VerticalAlign {
        case center
    }

    private static func drawText(
        _ text: String,
        font: CTFont,
        color: CGColor,
        in rect: CGRect,
        align: HorizontalAlign,
        vertical: VerticalAlign,
        ctx: CGContext
    ) {
        _ = vertical
        ctx.saveGState()
        ctx.clip(to: cgRect(rect))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        var line = CTLineCreateWithAttributedString(attributed)
        let ellipsis = CTLineCreateWithAttributedString(
            NSAttributedString(string: "…", attributes: attributes)
        )
        let fitted = CTLineCreateTruncatedLine(line, Double(rect.width), .end, ellipsis) ?? line
        line = fitted
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let bitmapRect = cgRect(rect)
        let x: CGFloat
        switch align {
        case .left:
            x = bitmapRect.minX
        case .right:
            x = bitmapRect.maxX - lineWidth
        case .center:
            x = bitmapRect.minX + (bitmapRect.width - lineWidth) / 2
        }
        let y = bitmapRect.minY + (bitmapRect.height - (ascent + descent)) / 2
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func font(
        size: CGFloat,
        languageCode: String,
        heavy: Bool,
        monoDigits: Bool
    ) -> CTFont {
        let uiType: CTFontUIFontType = heavy ? .emphasizedSystem : .system
        let base = CTFontCreateUIFontForLanguage(uiType, size, languageCode as CFString)
            ?? CTFontCreateWithName((heavy ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        if languageCode == "zh-Hans" {
            let pingfangName = heavy ? "PingFangSC-Semibold" : "PingFangSC-Regular"
            if let pingfang = CTFontCreateWithName(pingfangName as CFString, size, nil) as CTFont? {
                return applyMonoDigits(pingfang, enabled: monoDigits, size: size)
            }
        }
        return applyMonoDigits(base, enabled: monoDigits, size: size)
    }

    private static func applyMonoDigits(_ font: CTFont, enabled: Bool, size: CGFloat) -> CTFont {
        guard enabled else { return font }
        let features: [[CFString: Any]] = [[
            kCTFontFeatureTypeIdentifierKey: 6,
            kCTFontFeatureSelectorIdentifierKey: 0
        ]]
        let attributes = [kCTFontFeatureSettingsAttribute: features] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
        return CTFontCreateCopyWithAttributes(font, size, nil, descriptor)
    }

    private static func cgRect(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: CGFloat(PlaneEncoder.height) - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private static func inkColor(r: UInt8, g: UInt8, b: UInt8) -> InkColor {
        let rf = Double(r) / 255
        let gf = Double(g) / 255
        let bf = Double(b) / 255
        if rf - gf >= 0.2 && rf - bf >= 0.2 {
            let coverage = 1 - ((gf + bf) / 2)
            return coverage >= 0.5 ? .red : .paper
        }
        let coverage = 1 - ((rf + gf + bf) / 3)
        return coverage >= 0.5 ? .black : .paper
    }

}

import CoreGraphics
import CoreText
import Foundation

enum FrameRasterizer {
    static func rasterize(_ model: QuotaFocusFrameModel) -> DisplayPlanes {
        rasterize { draw(model, in: $0) }
    }

    static func rasterize(_ model: BalancedFrameModel) -> DisplayPlanes {
        rasterize { draw(model, in: $0) }
    }

    static func rasterize(_ model: ActivityFocusFrameModel) -> DisplayPlanes {
        rasterize { draw(model, in: $0) }
    }

    private static func rasterize(_ draw: (CGContext) -> Void) -> DisplayPlanes {
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
            draw(ctx)
            ctx.restoreGState()
        }
        return PlaneEncoder.encode { x, y in
            let offset = (y * width + x) * 4
            return inkColor(r: buffer[offset], g: buffer[offset + 1], b: buffer[offset + 2])
        }
    }

    private static let white = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1, 1, 1, 1])!
    private static let black = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 0, 1])!
    private static let red = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1, 0, 0, 1])!

    private static func draw(
        _ model: QuotaFocusFrameModel,
        in ctx: CGContext
    ) {
        ctx.clip(to: cgRect(QuotaFocusLayout.contentRect))
        let lang = DisplayCopy.languageCode(model.language)
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

    private static func draw(
        _ model: BalancedFrameModel,
        in ctx: CGContext
    ) {
        ctx.clip(to: cgRect(BalancedLayout.contentRect))
        let lang = DisplayCopy.languageCode(model.language)
        drawChromeHeader(
            title: model.title,
            plan: model.plan,
            showPlan: model.showPlan,
            titleRect: BalancedLayout.titleRect,
            titleRule: BalancedLayout.titleRuleRect,
            titleFontSize: BalancedLayout.titleFontSize,
            languageCode: lang,
            ctx: ctx
        )
        if model.entries.isEmpty, let mark = model.unavailableMark {
            drawCentered(
                mark,
                font: font(size: BalancedLayout.metricValueFontSize, languageCode: lang, heavy: true, monoDigits: false),
                color: black,
                in: BalancedLayout.bodyRect,
                ctx: ctx
            )
        } else {
            drawBalancedEntries(model.entries, in: ctx, languageCode: lang)
        }
        drawChromeFooter(
            updated: model.footerUpdated,
            status: model.footerStatus,
            rect: BalancedLayout.footerRect,
            fontSize: BalancedLayout.footerFontSize,
            languageCode: lang,
            ctx: ctx
        )
    }

    private static func draw(
        _ model: ActivityFocusFrameModel,
        in ctx: CGContext
    ) {
        ctx.clip(to: cgRect(ActivityFocusLayout.contentRect))
        let lang = DisplayCopy.languageCode(model.language)
        drawChromeHeader(
            title: model.title,
            plan: model.plan,
            showPlan: model.showPlan,
            titleRect: ActivityFocusLayout.titleRect,
            titleRule: ActivityFocusLayout.titleRuleRect,
            titleFontSize: ActivityFocusLayout.titleFontSize,
            languageCode: lang,
            ctx: ctx
        )
        let hasQuotas = !model.quotas.isEmpty
        let hasSecondary = !model.secondary.isEmpty
        if model.primary == nil && model.quotas.isEmpty, let mark = model.unavailableMark {
            drawCentered(
                mark,
                font: font(size: ActivityFocusLayout.secondaryValueFontSize, languageCode: lang, heavy: true, monoDigits: false),
                color: black,
                in: ActivityFocusLayout.bodyRect,
                ctx: ctx
            )
        } else {
            let local = ActivityFocusLayout.localRegionRect(hasQuotas: hasQuotas)
            fillRule(
                CGRect(x: local.minX, y: local.minY, width: local.width, height: ActivityFocusLayout.strongRule),
                ctx: ctx
            )
            fillRule(
                CGRect(x: local.minX, y: local.maxY - ActivityFocusLayout.strongRule, width: local.width, height: ActivityFocusLayout.strongRule),
                ctx: ctx
            )
            fillRule(
                CGRect(x: local.minX, y: local.minY, width: ActivityFocusLayout.strongRule, height: local.height),
                ctx: ctx
            )
            fillRule(
                CGRect(x: local.maxX - ActivityFocusLayout.strongRule, y: local.minY, width: ActivityFocusLayout.strongRule, height: local.height),
                ctx: ctx
            )
            if let primary = model.primary {
                drawMetricCell(
                    primary,
                    in: ActivityFocusLayout.primaryRect(hasSecondary: hasSecondary, hasQuotas: hasQuotas),
                    valueSize: ActivityFocusLayout.primaryValueFontSize,
                    labelSize: ActivityFocusLayout.metricLabelFontSize,
                    languageCode: lang,
                    ctx: ctx
                )
            }
            let secondaryRects = ActivityFocusLayout.secondaryRects(count: model.secondary.count, hasQuotas: hasQuotas)
            for (index, field) in model.secondary.enumerated() {
                let cell = secondaryRects[index]
                if index == 0 {
                    fillRule(
                        CGRect(
                            x: cell.minX,
                            y: local.minY + ActivityFocusLayout.strongRule,
                            width: ActivityFocusLayout.normalRule,
                            height: local.height - 2 * ActivityFocusLayout.strongRule
                        ),
                        ctx: ctx
                    )
                }
                if index > 0 {
                    fillRule(
                        CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: ActivityFocusLayout.normalRule),
                        ctx: ctx
                    )
                }
                drawMetricCell(
                    field,
                    in: cell,
                    valueSize: ActivityFocusLayout.secondaryValueFontSize,
                    labelSize: ActivityFocusLayout.metricLabelFontSize,
                    languageCode: lang,
                    ctx: ctx
                )
            }
            if hasQuotas {
                fillRule(ActivityFocusLayout.quotaTopRuleRect, ctx: ctx)
                let quotaRects = ActivityFocusLayout.quotaRects(count: model.quotas.count)
                for (index, field) in model.quotas.enumerated() {
                    let cell = quotaRects[index]
                    if index > 0 {
                        fillRule(
                            CGRect(
                                x: cell.minX,
                                y: cell.minY + ActivityFocusLayout.strongRule,
                                width: ActivityFocusLayout.normalRule,
                                height: cell.height - ActivityFocusLayout.strongRule
                            ),
                            ctx: ctx
                        )
                    }
                    drawQuotaCell(field, in: cell, languageCode: lang, ctx: ctx)
                }
            }
        }
        drawChromeFooter(
            updated: model.footerUpdated,
            status: model.footerStatus,
            rect: ActivityFocusLayout.footerRect,
            fontSize: ActivityFocusLayout.footerFontSize,
            languageCode: lang,
            ctx: ctx
        )
    }

    private static func drawBalancedEntries(
        _ fields: [DisplayField],
        in ctx: CGContext,
        languageCode: String
    ) {
        let cells = BalancedLayout.entryRects(count: fields.count)
        for (index, field) in fields.enumerated() {
            let cell = cells[index]
            if index % BalancedLayout.columnCount == 1 {
                fillRule(
                    CGRect(x: cell.minX, y: cell.minY, width: BalancedLayout.normalRule, height: cell.height),
                    ctx: ctx
                )
            }
            if index >= BalancedLayout.columnCount {
                fillRule(
                    CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: BalancedLayout.normalRule),
                    ctx: ctx
                )
            }
            if field.isQuota {
                drawQuotaCell(field, in: cell, languageCode: languageCode, ctx: ctx, quotaValueSize: BalancedLayout.quotaValueFontSize)
            } else {
                drawMetricCell(
                    field,
                    in: cell,
                    valueSize: BalancedLayout.metricValueFontSize,
                    labelSize: BalancedLayout.metricLabelFontSize,
                    languageCode: languageCode,
                    ctx: ctx
                )
            }
        }
    }

    private static func drawQuotaCell(
        _ field: DisplayField,
        in cell: CGRect,
        languageCode: String,
        ctx: CGContext,
        quotaValueSize: CGFloat = ActivityFocusLayout.quotaValueFontSize
    ) {
        let inset = CGRect(
            x: cell.minX + 6,
            y: cell.minY + 6,
            width: max(0, cell.width - 12),
            height: max(0, cell.height - 12)
        )
        let ink = field.usesRed ? red : black
        drawText(
            field.label,
            font: font(size: 11, languageCode: languageCode, heavy: true, monoDigits: false),
            color: black,
            in: CGRect(x: inset.minX, y: inset.minY, width: inset.width * 0.55, height: 14),
            align: .left,
            ctx: ctx
        )
        if let secondary = field.secondaryText {
            drawText(
                secondary,
                font: font(size: 9, languageCode: languageCode, heavy: false, monoDigits: false),
                color: black,
                in: CGRect(x: inset.minX + inset.width * 0.4, y: inset.minY, width: inset.width * 0.6, height: 14),
                align: .right,
                ctx: ctx
            )
        }
        var valueBottom = inset.maxY
        if let percent = field.progressPercent {
            let track = CGRect(
                x: inset.minX,
                y: inset.maxY - 8,
                width: inset.width,
                height: 8
            )
            drawProgress(percent: percent, in: track, fill: ink, ctx: ctx)
            valueBottom = track.minY - 2
        }
        if let badge = field.badge {
            let badgeRect = CGRect(x: inset.minX, y: valueBottom - 12, width: inset.width, height: 12)
            drawText(
                badge,
                font: font(size: 9, languageCode: languageCode, heavy: false, monoDigits: false),
                color: black,
                in: badgeRect,
                align: .left,
                ctx: ctx
            )
            valueBottom = badgeRect.minY - 2
        }
        drawText(
            field.displayedValue,
            font: font(size: quotaValueSize, languageCode: languageCode, heavy: true, monoDigits: true),
            color: ink,
            in: CGRect(x: inset.minX, y: inset.minY + 16, width: inset.width, height: max(0, valueBottom - (inset.minY + 16))),
            align: .left,
            ctx: ctx
        )
    }

    private static func drawMetricCell(
        _ field: DisplayField,
        in cell: CGRect,
        valueSize: CGFloat,
        labelSize: CGFloat,
        languageCode: String,
        ctx: CGContext
    ) {
        let inset = CGRect(
            x: cell.minX + 6,
            y: cell.minY + 6,
            width: max(0, cell.width - 12),
            height: max(0, cell.height - 12)
        )
        drawText(
            field.label,
            font: font(size: labelSize, languageCode: languageCode, heavy: true, monoDigits: false),
            color: black,
            in: CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: 14),
            align: .left,
            ctx: ctx
        )
        var valueBottom = inset.maxY
        if let badge = field.badge {
            let badgeRect = CGRect(x: inset.minX, y: inset.maxY - 12, width: inset.width, height: 12)
            drawText(
                badge,
                font: font(size: 9, languageCode: languageCode, heavy: false, monoDigits: false),
                color: black,
                in: badgeRect,
                align: .left,
                ctx: ctx
            )
            valueBottom = badgeRect.minY - 2
        }
        drawText(
            field.displayedValue,
            font: font(size: valueSize, languageCode: languageCode, heavy: true, monoDigits: true),
            color: black,
            in: CGRect(x: inset.minX, y: inset.minY + 16, width: inset.width, height: max(0, valueBottom - (inset.minY + 16))),
            align: .left,
            ctx: ctx
        )
    }

    private static func drawChromeHeader(
        title: String,
        plan: String?,
        showPlan: Bool,
        titleRect: CGRect,
        titleRule: CGRect,
        titleFontSize: CGFloat,
        languageCode: String,
        ctx: CGContext
    ) {
        let titleFont = font(size: titleFontSize, languageCode: languageCode, heavy: true, monoDigits: false)
        let planFont = font(size: titleFontSize, languageCode: languageCode, heavy: false, monoDigits: true)
        var titleWidth = titleRect.width
        if showPlan, let plan {
            let planWidth = min(120, titleRect.width * 0.4)
            drawText(
                plan,
                font: planFont,
                color: black,
                in: CGRect(x: titleRect.maxX - planWidth, y: titleRect.minY, width: planWidth, height: titleRect.height - 4),
                align: .right,
                ctx: ctx
            )
            titleWidth = titleRect.width - planWidth - 8
        }
        drawText(
            title,
            font: titleFont,
            color: black,
            in: CGRect(x: titleRect.minX, y: titleRect.minY, width: titleWidth, height: titleRect.height - 4),
            align: .left,
            ctx: ctx
        )
        fillRule(titleRule, ctx: ctx)
    }

    private static func drawChromeFooter(
        updated: String?,
        status: String?,
        rect: CGRect,
        fontSize: CGFloat,
        languageCode: String,
        ctx: CGContext
    ) {
        let footerFont = font(size: fontSize, languageCode: languageCode, heavy: false, monoDigits: true)
        if let updated {
            drawText(
                updated,
                font: footerFont,
                color: black,
                in: CGRect(x: rect.minX, y: rect.minY, width: rect.width * 0.6, height: rect.height),
                align: .left,
                ctx: ctx
            )
        }
        if let status {
            drawText(
                status,
                font: footerFont,
                color: black,
                in: CGRect(x: rect.minX + rect.width * 0.4, y: rect.minY, width: rect.width * 0.6, height: rect.height),
                align: .right,
                ctx: ctx
            )
        }
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
            ctx: ctx
        )
        fillRule(QuotaFocusLayout.titleRuleRect, ctx: ctx)
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
            ctx: ctx
        )
        if let secondary = field.secondaryText {
            drawText(
                secondary,
                font: font(size: QuotaFocusLayout.resetFontSize, languageCode: languageCode, heavy: false, monoDigits: false),
                color: black,
                in: CGRect(x: rect.minX + rect.width * 0.45, y: rect.minY + 8, width: rect.width * 0.55, height: 16),
                align: .right,
                ctx: ctx
            )
        }
        drawText(
            field.displayedValue,
            font: font(size: QuotaFocusLayout.heroValueFontSize, languageCode: languageCode, heavy: true, monoDigits: true),
            color: ink,
            in: CGRect(x: rect.minX, y: rect.minY + QuotaFocusLayout.heroValueTopInset, width: rect.width, height: QuotaFocusLayout.heroValueLineHeight),
            align: .left,
            ctx: ctx
        )
        if let badge = field.badge {
            drawText(
                badge,
                font: font(size: QuotaFocusLayout.resetFontSize, languageCode: languageCode, heavy: false, monoDigits: false),
                color: black,
                in: QuotaFocusLayout.heroBadgeRect,
                align: .left,
                ctx: ctx
            )
        }
        if let percent = field.progressPercent {
            drawProgress(percent: percent, in: QuotaFocusLayout.heroProgressTrackRect, fill: ink, ctx: ctx)
        }
    }

    private static func drawTicker(
        _ fields: [QuotaFocusFrameModel.Field],
        in ctx: CGContext,
        languageCode: String
    ) {
        let rect = QuotaFocusLayout.tickerRect
        fillRule(QuotaFocusLayout.tickerTopRuleRect, ctx: ctx)
        fillRule(QuotaFocusLayout.tickerBottomRuleRect, ctx: ctx)
        let cells = QuotaFocusLayout.tickerCellRects(count: fields.count)
        for (index, field) in fields.enumerated() {
            let cell = cells[index]
            if index > 0 {
                fillRule(
                    CGRect(x: cell.minX, y: rect.minY + QuotaFocusLayout.strongRule, width: QuotaFocusLayout.normalRule, height: rect.height - 2 * QuotaFocusLayout.strongRule),
                    ctx: ctx
                )
            }
            drawText(
                field.label,
                font: font(size: QuotaFocusLayout.tickerLabelFontSize, languageCode: languageCode, heavy: true, monoDigits: false),
                color: black,
                in: QuotaFocusLayout.tickerLabelRect(in: cell),
                align: .left,
                ctx: ctx
            )
            drawText(
                field.displayedValue,
                font: font(size: QuotaFocusLayout.tickerValueFontSize, languageCode: languageCode, heavy: true, monoDigits: true),
                color: field.usesRed ? red : black,
                in: QuotaFocusLayout.tickerValueRect(in: cell, hasBadge: field.badge != nil),
                align: .left,
                ctx: ctx
            )
            if let badge = field.badge {
                drawText(
                    badge,
                    font: font(size: QuotaFocusLayout.resetFontSize, languageCode: languageCode, heavy: false, monoDigits: false),
                    color: black,
                    in: QuotaFocusLayout.tickerBadgeRect(in: cell),
                    align: .left,
                    ctx: ctx
                )
            }
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
        drawText(text, font: font, color: color, in: rect, align: .center, ctx: ctx)
    }

    private enum HorizontalAlign {
        case left, right, center
    }

    private static func drawText(
        _ text: String,
        font: CTFont,
        color: CGColor,
        in rect: CGRect,
        align: HorizontalAlign,
        ctx: CGContext
    ) {
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

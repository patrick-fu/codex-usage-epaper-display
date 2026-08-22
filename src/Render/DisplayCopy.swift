import Foundation

enum DisplayCopy {
    static let emDash = "—"

    static func resolvedLanguage(
        preference: InterfaceLanguagePreference,
        preferredLanguages: [String]
    ) -> ResolvedInterfaceLanguage {
        switch preference {
        case .english:
            return .english
        case .simplifiedChinese:
            return .simplifiedChinese
        case .system:
            return ResolvedInterfaceLanguage.resolveSystem(preferredLanguages: preferredLanguages)
        }
    }

    static func languageCode(_ language: ResolvedInterfaceLanguage) -> String {
        switch language {
        case .english:
            return "en"
        case .simplifiedChinese:
            return "zh-Hans"
        }
    }

    static func windowLabel(durationMinutes: Int, language: ResolvedInterfaceLanguage) -> String {
        if durationMinutes > 0, durationMinutes.isMultiple(of: 60 * 24) {
            let days = durationMinutes / (60 * 24)
            return language == .english ? "\(days) d" : "\(days) 天"
        }
        if durationMinutes > 0, durationMinutes.isMultiple(of: 60) {
            let hours = durationMinutes / 60
            return language == .english ? "\(hours) hr" : "\(hours) 小时"
        }
        return language == .english ? "\(durationMinutes) min" : "\(durationMinutes) 分钟"
    }

    static func localLabel(kind: LocalMetricKind, language: ResolvedInterfaceLanguage) -> String {
        switch (kind, language) {
        case (.today, .english): return "Local Today"
        case (.today, .simplifiedChinese): return "本机今日"
        case (.weekTokens, .english): return "Local This Week"
        case (.weekTokens, .simplifiedChinese): return "本机本周"
        case (.cache, .english): return "Cache hit rate"
        case (.cache, .simplifiedChinese): return "缓存命中率"
        case (.tps, .english): return "TPS"
        case (.tps, .simplifiedChinese): return "TPS"
        }
    }

    static func footerStatus(language: ResolvedInterfaceLanguage) -> String {
        switch language {
        case .english: return "Display connected"
        case .simplifiedChinese: return "显示器已连接"
        }
    }

    static func footerUpdated(
        composedAt: Date,
        calendar: Calendar,
        timeZone: TimeZone,
        language: ResolvedInterfaceLanguage
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = locale(language)
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: composedAt)
        switch language {
        case .english: return "Updated \(time)"
        case .simplifiedChinese: return "更新 \(time)"
        }
    }

    static func formatPercent(_ value: Double) -> Int? {
        guard value.isFinite, value >= 0, value <= 100 else {
            return nil
        }
        return roundHalfAwayFromZero(value)
    }

    static func formatPercentText(_ value: Double) -> String? {
        formatPercent(value).map { "\($0)%" }
    }

    static func formatTokens(_ value: Int) -> String {
        let magnitude = abs(value)
        if magnitude < 1_000 {
            return "\(value)"
        }
        if magnitude < 1_000_000 {
            return trimTrailingZeros(formatFixed(Double(value) / 1_000, digits: 1)) + "K"
        }
        if magnitude < 1_000_000_000 {
            return trimTrailingZeros(formatFixed(Double(value) / 1_000_000, digits: 2)) + "M"
        }
        return trimTrailingZeros(formatFixed(Double(value) / 1_000_000_000, digits: 2)) + "B"
    }

    static func formatCacheRate(_ rate: Double) -> String? {
        guard rate.isFinite, rate >= 0 else {
            return nil
        }
        let percent = roundHalfAwayFromZero(rate * 100)
        return "\(percent)%"
    }

    static func formatTPS(_ value: Double) -> String? {
        guard value.isFinite, value >= 0 else {
            return nil
        }
        return formatFixed(value, digits: 1)
    }

    static func displayedPlan(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else {
            return nil
        }
        if raw.count <= QuotaFocusLayout.planMaxDisplayedCharacters {
            return raw
        }
        return String(raw.prefix(QuotaFocusLayout.planMaxDisplayedCharacters))
    }

    static func resetText(
        resetsAt: Int?,
        composedAt: Date,
        dateFormat: DateFormatPreference,
        calendar: Calendar,
        timeZone: TimeZone,
        language: ResolvedInterfaceLanguage
    ) -> String? {
        guard let resetsAt, let date = date(fromUnixSeconds: resetsAt, calendar: calendar) else {
            return nil
        }
        switch dateFormat {
        case .relative:
            return relativeReset(from: composedAt, to: date, language: language)
        case .absolute:
            return absoluteReset(
                date,
                calendar: calendar,
                timeZone: timeZone,
                language: language
            )
        }
    }

    static func degradedMessage(
        availability: ObservationAvailability,
        failure: String?,
        source: SourceKind,
        language: ResolvedInterfaceLanguage
    ) -> String? {
        if let failure, let mapped = failureMessage(failure, language: language) {
            return mapped
        }
        switch availability {
        case .authRequired:
            return localized("Sign in to Codex", "请在 Codex 登录", language)
        case .stale:
            return source == .account
                ? localized("Account data stale", "账户数据已过期", language)
                : nil
        case .unknown:
            return source == .local
                ? localized("Local activity unknown", "本机活动未知", language)
                : nil
        case .unavailable:
            return source == .local
                ? localized("Local source unavailable", "本机来源不可用", language)
                : nil
        case .fresh:
            return nil
        }
    }

    static func date(fromUnixSeconds seconds: Int, calendar: Calendar) -> Date? {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let year = calendar.component(.year, from: date)
        guard year >= 1, year <= 9999 else {
            return nil
        }
        return date
    }

    static func roundHalfAwayFromZero(_ value: Double) -> Int {
        if value >= 0 {
            return Int(floor(value + 0.5))
        }
        return Int(ceil(value - 0.5))
    }

    enum SourceKind {
        case account
        case local
    }

    private static func failureMessage(_ failure: String, language: ResolvedInterfaceLanguage) -> String? {
        switch failure {
        case "authRequired":
            return localized("Sign in to Codex", "请在 Codex 登录", language)
        case "binaryMissing":
            return localized("Codex not found", "未找到 Codex", language)
        case "versionTooOld":
            return localized("Update Codex", "请升级 Codex", language)
        case "protocolIncompatible":
            return localized("Codex incompatible", "Codex 协议不兼容", language)
        case "rateLimitUnavailable":
            return localized("Quota unavailable", "限额暂不可用", language)
        case "sourceUnavailable":
            return localized("Local source unavailable", "本机来源不可用", language)
        case "sourceUnreadable", "sourcePermissionDenied":
            return localized("Local source unreadable", "本机来源不可读", language)
        case "sourceMalformed", "sourcePartialTail":
            return localized("Local data partial", "本机数据不完整", language)
        case "firmwareIncompatible":
            return localized("Display firmware incompatible", "显示器固件不兼容", language)
        default:
            return nil
        }
    }

    private static func relativeReset(
        from start: Date,
        to end: Date,
        language: ResolvedInterfaceLanguage
    ) -> String {
        let totalMinutes = max(0, Int(floor(end.timeIntervalSince(start) / 60)))
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let minutes = totalMinutes % 60
        var parts: [String] = []
        if days > 0 {
            parts.append(language == .english ? "\(days)d" : "\(days) 天")
        }
        if hours > 0 {
            parts.append(language == .english ? "\(hours)h" : "\(hours) 小时")
        }
        if minutes > 0 || parts.isEmpty {
            parts.append(language == .english ? "\(minutes)m" : "\(minutes) 分钟")
        }
        let body = parts.joined(separator: language == .english ? " " : "")
        switch language {
        case .english:
            return "Resets in \(body)"
        case .simplifiedChinese:
            return "\(body)后重置"
        }
    }

    private static func absoluteReset(
        _ date: Date,
        calendar: Calendar,
        timeZone: TimeZone,
        language: ResolvedInterfaceLanguage
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = locale(language)
        formatter.dateFormat = language == .english ? "M/d/yyyy HH:mm" : "yyyy/M/d HH:mm"
        let formatted = formatter.string(from: date)
        switch language {
        case .english: return "Resets \(formatted)"
        case .simplifiedChinese: return "重置 \(formatted)"
        }
    }

    private static func locale(_ language: ResolvedInterfaceLanguage) -> Locale {
        switch language {
        case .english: return Locale(identifier: "en_US_POSIX")
        case .simplifiedChinese: return Locale(identifier: "zh_CN")
        }
    }

    private static func localized(
        _ english: String,
        _ chinese: String,
        _ language: ResolvedInterfaceLanguage
    ) -> String {
        language == .english ? english : chinese
    }

    private static func formatFixed(_ value: Double, digits: Int) -> String {
        let scale = pow(10.0, Double(digits))
        let scaled = Int(floor(value * scale + 0.5))
        let maxFraction = Int(scale)
        let wholePart = scaled / maxFraction
        let fraction = scaled % maxFraction
        if digits == 0 {
            return "\(Int(floor(value + 0.5)))"
        }
        return "\(wholePart).\(String(format: "%0\(digits)d", fraction))"
    }

    private static func trimTrailingZeros(_ text: String) -> String {
        guard text.contains(".") else { return text }
        var result = text
        while result.last == "0" {
            result.removeLast()
        }
        if result.last == "." {
            result.removeLast()
        }
        return result
    }
}

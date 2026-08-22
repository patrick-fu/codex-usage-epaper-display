import Foundation

enum MetricFormatting {
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

    static func roundHalfAwayFromZero(_ value: Double) -> Int {
        if value >= 0 {
            return Int(floor(value + 0.5))
        }
        return Int(ceil(value - 0.5))
    }

    static func formatFixed(_ value: Double, digits: Int) -> String {
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

    static func trimTrailingZeros(_ text: String) -> String {
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

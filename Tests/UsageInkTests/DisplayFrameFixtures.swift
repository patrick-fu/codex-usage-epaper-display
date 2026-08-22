import CoreGraphics
import CryptoKit
import Foundation
@testable import UsageInk

enum DisplayFrameFixtures {
    static let composedAt = Date(timeIntervalSince1970: 1_704_067_200)
    static let timeZone = TimeZone(secondsFromGMT: 8 * 3600)!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func input(
        preferences: DisplayPreferences = .default,
        account: AccountObservation = typicalAccount(),
        local: LocalActivityObservation = typicalLocal(),
        composedAt: Date = composedAt,
        preferredLanguages: [String] = ["en-US"]
    ) -> DisplayFrameInput {
        DisplayFrameInput(
            preferences: preferences,
            account: account,
            localActivity: local,
            composedAt: composedAt,
            calendar: calendar,
            timeZone: timeZone,
            preferredLanguages: preferredLanguages
        )
    }

    static func account(windowCount: Int) -> AccountObservation {
        let typical = typicalAccount()
        switch windowCount {
        case 0:
            return AccountObservation(
                availability: typical.availability,
                failure: typical.failure,
                planType: typical.planType,
                windows: []
            )
        case 1:
            return AccountObservation(
                availability: typical.availability,
                failure: typical.failure,
                planType: typical.planType,
                windows: [typical.windows[0]]
            )
        default:
            return typical
        }
    }

    static func typicalAccount() -> AccountObservation {
        AccountObservation(
            availability: .fresh,
            failure: nil,
            planType: "Plus",
            windows: [
                UsageWindowObservation(
                    slot: .primary,
                    usedPercent: 42.4,
                    windowDurationMins: 300,
                    resetsAt: Int(composedAt.timeIntervalSince1970) + 3_600
                ),
                UsageWindowObservation(
                    slot: .secondary,
                    usedPercent: 81,
                    windowDurationMins: 10_080,
                    resetsAt: Int(composedAt.timeIntervalSince1970) + 86_400
                )
            ]
        )
    }

    static func typicalLocal() -> LocalActivityObservation {
        LocalActivityObservation(
            availability: .fresh,
            failure: nil,
            todayTokens: 1_500,
            weekTokens: 12_000,
            cacheHitRate: 0.255,
            tps: 1.25,
            coverageComplete: true
        )
    }

    static func ink(atX x: Int, y: Int, frame: DisplayFrame) -> InkColor {
        let byteIndex = y * PlaneEncoder.bytesPerRow + x / 8
        let shift = 7 - (x % 8)
        let blackBit = (frame.blackPlane[byteIndex] >> shift) & 1
        let redBit = (frame.redPlane[byteIndex] >> shift) & 1
        if redBit == 0 {
            return .red
        }
        if blackBit == 0 {
            return .black
        }
        return .paper
    }

    static func staleAccount() -> AccountObservation {
        var account = typicalAccount()
        account.availability = .stale
        return account
    }

    static func unavailableAccount() -> AccountObservation {
        AccountObservation(
            availability: .unavailable,
            failure: "rateLimitUnavailable",
            planType: "Plus",
            windows: []
        )
    }

    static func unavailableLocal() -> LocalActivityObservation {
        LocalActivityObservation(
            availability: .unknown,
            failure: nil,
            todayTokens: nil,
            weekTokens: nil,
            cacheHitRate: nil,
            tps: nil,
            coverageComplete: false
        )
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func contains(_ color: InkColor, in rect: CGRect, frame: DisplayFrame) -> Bool {
        let minX = max(0, Int(rect.minX))
        let minY = max(0, Int(rect.minY))
        let maxX = min(PlaneEncoder.width, Int(rect.maxX))
        let maxY = min(PlaneEncoder.height, Int(rect.maxY))
        for y in minY..<maxY {
            for x in minX..<maxX {
                if ink(atX: x, y: y, frame: frame) == color {
                    return true
                }
            }
        }
        return false
    }
}

import XCTest
@testable import UsageInk

final class DisplayStyleMatrixTests: XCTestCase {
    func testSyntheticMatrixCoversStylesWindowsAndLocalMetrics() throws {
        let localCases: [(String, DisplayModules)] = [
            ("none", modules(today: false, week: false, cache: false, tps: false)),
            ("today", modules(today: true, week: false, cache: false, tps: false)),
            ("week", modules(today: false, week: true, cache: false, tps: false)),
            ("cache", modules(today: false, week: false, cache: true, tps: false)),
            ("tps", modules(today: false, week: false, cache: false, tps: true)),
            ("today-week", modules(today: true, week: true, cache: false, tps: false)),
            ("all-locals", modules(today: true, week: true, cache: true, tps: true)),
        ]

        for style in DisplayStyle.allCases {
            for windowCount in 0...2 {
                for (label, modules) in localCases {
                    var preferences = DisplayPreferences.default
                    preferences.displayStyle = style
                    preferences.modules = modules
                    let account = account(windowCount: windowCount)
                    let input = DisplayFrameFixtures.input(preferences: preferences, account: account)
                    let frame = try DisplayFrameComposer.compose(input)
                    XCTAssertEqual(frame.blackPlane.count, 15_000, "\(style.rawValue) w\(windowCount) \(label)")
                    XCTAssertEqual(frame.redPlane.count, 15_000, "\(style.rawValue) w\(windowCount) \(label)")
                    XCTAssertEqual(frame.fingerprint.count, 64, "\(style.rawValue) w\(windowCount) \(label)")

                    switch style {
                    case .balanced:
                        let model = BalancedModelBuilder.build(input)
                        XCTAssertFalse(model.body.contains { $0.id == "quota.secondary" } && windowCount < 2)
                        if windowCount == 0 {
                            XCTAssertFalse(model.body.contains { $0.id.hasPrefix("quota.") })
                        }
                        if windowCount >= 1, modules.quota {
                            XCTAssertTrue(model.body.contains { $0.id == "quota.primary" })
                        }
                        XCTAssertLessThanOrEqual(model.body.count, 6)
                    case .activityFocus:
                        let model = ActivityFocusModelBuilder.build(input)
                        XCTAssertEqual(model.quotas.count, modules.quota ? windowCount : 0)
                        let enabledLocals = [
                            modules.today ? "local.today" : nil,
                            modules.weekTokens ? "local.weekTokens" : nil,
                            modules.cache ? "local.cache" : nil,
                            modules.tps ? "local.tps" : nil,
                        ].compactMap { $0 }
                        XCTAssertEqual(model.primary?.id, enabledLocals.first)
                        XCTAssertEqual(model.secondary.map(\.id), Array(enabledLocals.dropFirst().prefix(3)))
                    case .quotaFocus:
                        let model = QuotaFocusModelBuilder.build(input)
                        if windowCount == 0, !modules.today, !modules.weekTokens, !modules.cache, !modules.tps {
                            XCTAssertNil(model.hero)
                            XCTAssertEqual(model.unavailableMark, DisplayCopy.emDash)
                        }
                    }
                }
            }
        }
    }

    private func modules(today: Bool, week: Bool, cache: Bool, tps: Bool) -> DisplayModules {
        DisplayModules(
            title: true,
            plan: true,
            quota: true,
            today: today,
            weekTokens: week,
            cache: cache,
            tps: tps,
            updated: true,
            status: true
        )
    }

    private func account(windowCount: Int) -> AccountObservation {
        switch windowCount {
        case 0:
            return .unknown
        case 1:
            var account = DisplayFrameFixtures.typicalAccount()
            account.windows = [account.windows[0]]
            return account
        default:
            return DisplayFrameFixtures.typicalAccount()
        }
    }
}

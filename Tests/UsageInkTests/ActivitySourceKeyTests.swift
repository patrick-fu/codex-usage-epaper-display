import XCTest
@testable import UsageInk

final class ActivitySourceKeyTests: XCTestCase {
    func testVerifiedUUIDAndSourceKeyGolden() {
        let basename = ActivityFixtures.rolloutName()
        XCTAssertEqual(ActivitySourceKey.canonicalRolloutId(basename: basename), ActivityFixtures.uuidA)
        XCTAssertEqual(ActivitySourceKey.sourceKey(basename: basename), ActivityFixtures.sourceKeyA)
        XCTAssertEqual(ActivityFixtures.sourceKeyA.count, 64)
        XCTAssertTrue(ActivityFixtures.sourceKeyA.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 102 })
    }

    func testRevertSuffixUsesTheSameSourceKey() {
        let ordinary = ActivityFixtures.rolloutName(revert: false)
        let revert = ActivityFixtures.rolloutName(revert: true)
        XCTAssertEqual(
            ActivitySourceKey.sourceKey(basename: ordinary),
            ActivitySourceKey.sourceKey(basename: revert)
        )
        XCTAssertEqual(ActivitySourceKey.canonicalRolloutId(basename: revert), ActivityFixtures.uuidA)
    }

    func testInvalidBasenamesProduceNoSourceKey() {
        let invalid = [
            "session.jsonl",
            "rollout-short.jsonl",
            "rollout-2026-08-22T00-00-00-not-a-uuid.jsonl",
            "rollout-2026-08-22T00-00-00-AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.jsonl",
            "rollout-2026-08-22T00-00-00-\(ActivityFixtures.uuidA).jsonl.part",
            "rollout-2026-08-22T00-00-00-\(ActivityFixtures.uuidA).jsonl.jsonl",
        ]
        for name in invalid {
            XCTAssertNil(ActivitySourceKey.sourceKey(basename: name), name)
        }
    }
}

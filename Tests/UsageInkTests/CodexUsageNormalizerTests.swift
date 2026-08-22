import XCTest
@testable import UsageInk

final class CodexUsageNormalizerTests: XCTestCase {
    func testNonNullProAccountIsLoggedInEvenWhenRequiresOpenaiAuthIsTrue() throws {
        let result: [String: Any] = [
            "account": [
                "type": "chatgpt",
                "email": "user@example.com",
                "planType": "pro",
            ],
            "requiresOpenaiAuth": true,
        ]

        let account = try CodexUsageNormalizer.account(from: result).get()

        XCTAssertTrue(account.isLoggedIn)
        XCTAssertFalse(account.authRequired)
        XCTAssertNil(account.failure)
        XCTAssertEqual(account.planType, "pro")
    }

    func testNullAccountIsAuthRequiredAndIgnoresRequiresOpenaiAuthHint() {
        let result: [String: Any] = [
            "account": NSNull(),
            "requiresOpenaiAuth": false,
        ]

        switch CodexUsageNormalizer.account(from: result) {
        case .failure(.authRequired):
            break
        case let other:
            XCTFail("expected authRequired, got \(other)")
        }
    }

    func testCanonicalWindowsAcceptNullOneAndTwoSlotsWithoutInventingMissing() throws {
        let none = try CodexUsageNormalizer.windows(from: [
            "rateLimits": [
                "limitId": "codex",
                "primary": NSNull(),
                "secondary": NSNull(),
            ]
        ]).get()
        XCTAssertEqual(none, [])

        let primaryOnly = try CodexUsageNormalizer.windows(from: [
            "rateLimits": [
                "primary": [
                    "usedPercent": 13,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_787_499_508,
                ],
                "secondary": NSNull(),
                "credits": ["hasCredits": false, "balance": "0"],
            ]
        ]).get()
        XCTAssertEqual(
            primaryOnly,
            [
                UsageWindowObservation(
                    slot: .primary,
                    usedPercent: 13,
                    windowDurationMins: 10080,
                    resetsAt: 1_787_499_508
                )
            ]
        )

        let both = try CodexUsageNormalizer.windows(from: [
            "rateLimits": [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 13,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_787_499_508,
                ],
                "secondary": [
                    "usedPercent": 42.5,
                    "windowDurationMins": 300,
                    "resetsAt": 1_787_400_000,
                ],
            ]
        ]).get()
        XCTAssertEqual(
            both,
            [
                UsageWindowObservation(
                    slot: .primary,
                    usedPercent: 13,
                    windowDurationMins: 10080,
                    resetsAt: 1_787_499_508
                ),
                UsageWindowObservation(
                    slot: .secondary,
                    usedPercent: 42.5,
                    windowDurationMins: 300,
                    resetsAt: 1_787_400_000
                ),
            ]
        )
    }

    func testCodexMapKeyWinsAndInvalidMapValueDoesNotFallback() throws {
        let mapWins = try CodexUsageNormalizer.windows(from: [
            "rateLimits": [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 99,
                    "windowDurationMins": 60,
                    "resetsAt": 10,
                ],
            ],
            "rateLimitsByLimitId": [
                "chatgpt": [
                    "limitId": "chatgpt",
                    "primary": [
                        "usedPercent": 1,
                        "windowDurationMins": 5,
                        "resetsAt": 1,
                    ],
                ],
                "codex": [
                    "limitId": "codex",
                    "primary": [
                        "usedPercent": 13,
                        "windowDurationMins": 10080,
                        "resetsAt": 1_787_499_508,
                    ],
                    "secondary": NSNull(),
                ],
            ],
        ]).get()
        XCTAssertEqual(
            mapWins,
            [
                UsageWindowObservation(
                    slot: .primary,
                    usedPercent: 13,
                    windowDurationMins: 10080,
                    resetsAt: 1_787_499_508
                )
            ]
        )

        switch CodexUsageNormalizer.windows(from: [
            "rateLimits": [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 13,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_787_499_508,
                ],
            ],
            "rateLimitsByLimitId": [
                "codex": NSNull(),
            ],
        ]) {
        case .failure(.schemaInvalid):
            break
        case let other:
            XCTFail("null map value must be schemaInvalid, got \(other)")
        }

        switch CodexUsageNormalizer.windows(from: [
            "rateLimits": [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 13,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_787_499_508,
                ],
            ],
            "rateLimitsByLimitId": [
                "codex": [
                    "limitId": "chatgpt",
                    "primary": [
                        "usedPercent": 13,
                        "windowDurationMins": 10080,
                        "resetsAt": 1_787_499_508,
                    ],
                ],
            ],
        ]) {
        case .failure(.schemaInvalid):
            break
        case let other:
            XCTFail("mismatched inner limitId must be schemaInvalid, got \(other)")
        }
    }

    func testTopLevelRateLimitsUsedOnlyWhenMapKeyAbsentAndLimitIdIsCodexOrMissing() throws {
        let absentMap = try CodexUsageNormalizer.windows(from: [
            "rateLimits": [
                "primary": [
                    "usedPercent": 7,
                    "windowDurationMins": 1440,
                    "resetsAt": 100,
                ]
            ]
        ]).get()
        XCTAssertEqual(
            absentMap,
            [
                UsageWindowObservation(
                    slot: .primary,
                    usedPercent: 7,
                    windowDurationMins: 1440,
                    resetsAt: 100
                )
            ]
        )

        switch CodexUsageNormalizer.windows(from: [
            "rateLimits": [
                "limitId": "chatgpt",
                "primary": [
                    "usedPercent": 7,
                    "windowDurationMins": 1440,
                    "resetsAt": 100,
                ],
            ]
        ]) {
        case .failure(.schemaInvalid):
            break
        case let other:
            XCTFail("non-codex top-level limitId must be schemaInvalid, got \(other)")
        }
    }

    func testUnknownOptionalsAreIgnoredOnValidWindows() throws {
        let windows = try CodexUsageNormalizer.windows(from: [
            "rateLimits": [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 10,
                    "windowDurationMins": 300,
                    "resetsAt": 200,
                    "mystery": "ignore-me",
                ],
                "secondary": NSNull(),
                "credits": ["hasCredits": true, "balance": "12.5"],
                "rateLimitReachedType": NSNull(),
            ]
        ]).get()
        XCTAssertEqual(
            windows,
            [
                UsageWindowObservation(
                    slot: .primary,
                    usedPercent: 10,
                    windowDurationMins: 300,
                    resetsAt: 200
                )
            ]
        )
    }

    func testNonNullMalformedWindowsAreSchemaInvalid() {
        let cases: [[String: Any]] = [
            [
                "rateLimits": [
                    "limitId": "codex",
                    "primary": [
                        "usedPercent": 101,
                        "windowDurationMins": 60,
                        "resetsAt": 100,
                    ],
                    "secondary": NSNull(),
                ]
            ],
            [
                "rateLimits": [
                    "limitId": "codex",
                    "primary": [
                        "usedPercent": 10,
                        "windowDurationMins": 300,
                        "resetsAt": 200,
                    ],
                    "secondary": [
                        "usedPercent": "full",
                        "windowDurationMins": 60,
                        "resetsAt": 100,
                    ],
                ]
            ],
            [
                "rateLimits": [
                    "limitId": "codex",
                    "primary": 12,
                    "secondary": NSNull(),
                ]
            ],
            [
                "rateLimits": [
                    "limitId": "codex",
                    "primary": [
                        "usedPercent": 10,
                        "windowDurationMins": 0,
                        "resetsAt": 200,
                    ],
                    "secondary": NSNull(),
                ]
            ],
        ]
        for payload in cases {
            switch CodexUsageNormalizer.windows(from: payload) {
            case .failure(.schemaInvalid):
                break
            case let other:
                XCTFail("malformed window must be schemaInvalid, got \(other) for \(payload)")
            }
        }
    }
}

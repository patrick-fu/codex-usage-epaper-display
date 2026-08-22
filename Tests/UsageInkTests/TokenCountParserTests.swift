import XCTest
@testable import UsageInk

final class TokenCountParserTests: XCTestCase {
    private let poll = Date(timeIntervalSince1970: 1_787_356_800)

    func testParsesAllowlistedTokenCountLine() {
        let line = ActivityFixtures.tokenLine(
            timestamp: "2026-08-22T00:00:00.000Z",
            input: 40,
            cached: 8,
            output: 12,
            reasoning: 3,
            lastInput: 999,
            lastOutput: 999
        )
        switch TokenCountParser.parseLine(line, pollStart: poll) {
        case .counters(let observedAt, let total):
            XCTAssertEqual(observedAt, 1_787_356_800)
            XCTAssertEqual(total.input, 40)
            XCTAssertEqual(total.cachedInput, 8)
            XCTAssertEqual(total.output, 12)
            XCTAssertEqual(total.reasoning, 3)
        case .ignored:
            XCTFail("ignored")
        case .malformed(let reason):
            XCTFail("malformed \(reason)")
        }
    }

    func testLastTokenUsageZeroCountersStillParseAndDoNotContributeFacts() {
        let line = ActivityFixtures.tokenLine(
            timestamp: "2026-08-22T00:00:00.000Z",
            input: 40,
            cached: 8,
            output: 12,
            reasoning: 3,
            lastInput: 0,
            lastOutput: 0
        )
        switch TokenCountParser.parseLine(line, pollStart: poll) {
        case .counters(_, let total):
            XCTAssertEqual(total, TokenCounters(input: 40, cachedInput: 8, output: 12, reasoning: 3))
        case .ignored:
            XCTFail("ignored")
        case .malformed(let reason):
            XCTFail("malformed \(reason)")
        }
    }

    func testMissingLastTokenUsageIsAccepted() {
        let line = """
        {"timestamp":"2026-08-22T00:00:00.000Z","type":"event_msg","payload":{"type":"token_count","total_token_usage":{"input_tokens":5,"cached_input_tokens":1,"output_tokens":2,"reasoning_output_tokens":0}}}
        """
        switch TokenCountParser.parseLine(line, pollStart: poll) {
        case .counters(_, let total):
            XCTAssertEqual(total.input, 5)
            XCTAssertEqual(total.cachedInput, 1)
            XCTAssertEqual(total.output, 2)
        case .ignored:
            XCTFail("ignored")
        case .malformed(let reason):
            XCTFail("malformed \(reason)")
        }
    }

    func testNullLastTokenUsageIsAccepted() {
        let line = """
        {"timestamp":"2026-08-22T00:00:00.000Z","type":"event_msg","payload":{"type":"token_count","total_token_usage":{"input_tokens":5,"output_tokens":1},"last_token_usage":null}}
        """
        switch TokenCountParser.parseLine(line, pollStart: poll) {
        case .counters(_, let total):
            XCTAssertEqual(total.input, 5)
            XCTAssertEqual(total.output, 1)
            XCTAssertEqual(total.cachedInput, 0)
        case .ignored:
            XCTFail("ignored")
        case .malformed(let reason):
            XCTFail("malformed \(reason)")
        }
    }

    func testUnparseableLastTokenUsageIsMalformed() {
        let line = """
        {"timestamp":"2026-08-22T00:00:00.000Z","type":"event_msg","payload":{"type":"token_count","total_token_usage":{"input_tokens":5,"output_tokens":1},"last_token_usage":{"input_tokens":true,"output_tokens":1}}}
        """
        XCTAssertEqual(TokenCountParser.parseLine(line, pollStart: poll), .malformed("last_token_usage"))
    }

    func testExtraKeysAreIgnored() {
        let line = """
        {"timestamp":"2026-08-22T00:00:00.000Z","type":"event_msg","payload":{"type":"token_count","model":"gpt","total_token_usage":{"input_tokens":9,"cached_input_tokens":1,"output_tokens":2,"reasoning_output_tokens":0,"extra":99},"last_token_usage":{"input_tokens":1,"output_tokens":1}}}
        """
        switch TokenCountParser.parseLine(line, pollStart: poll) {
        case .counters(_, let total):
            XCTAssertEqual(total.input, 9)
            XCTAssertEqual(total.cachedInput, 1)
            XCTAssertEqual(total.output, 2)
        case .ignored:
            XCTFail("ignored")
        case .malformed(let reason):
            XCTFail("malformed \(reason)")
        }
    }

    func testMatchingCachedAliasesAreEquivalent() {
        let line = """
        {"timestamp":"2026-08-22T00:00:00.000Z","type":"event_msg","payload":{"type":"token_count","total_token_usage":{"input_tokens":20,"cache_read_input_tokens":5,"cache_read_tokens":5,"output_tokens":1}}}
        """
        switch TokenCountParser.parseLine(line, pollStart: poll) {
        case .counters(_, let total):
            XCTAssertEqual(total.cachedInput, 5)
            XCTAssertEqual(total.input, 20)
        case .ignored:
            XCTFail("ignored")
        case .malformed(let reason):
            XCTFail("malformed \(reason)")
        }
    }

    func testCachedAliasMismatchIsMalformed() {
        let line = """
        {"timestamp":"2026-08-22T00:00:00.000Z","type":"event_msg","payload":{"type":"token_count","total_token_usage":{"input_tokens":8,"cached_input_tokens":1,"cache_read_tokens":2,"output_tokens":1}}}
        """
        XCTAssertEqual(TokenCountParser.parseLine(line, pollStart: poll), .malformed("total_token_usage"))
    }

    func testFractionalAndNegativeCountersAreMalformed() {
        let fractional = """
        {"timestamp":"2026-08-22T00:00:00.000Z","type":"event_msg","payload":{"type":"token_count","total_token_usage":{"input_tokens":1.5,"output_tokens":1}}}
        """
        let negative = """
        {"timestamp":"2026-08-22T00:00:00.000Z","type":"event_msg","payload":{"type":"token_count","total_token_usage":{"input_tokens":-1,"output_tokens":1}}}
        """
        XCTAssertEqual(TokenCountParser.parseLine(fractional, pollStart: poll), .malformed("total_token_usage"))
        XCTAssertEqual(TokenCountParser.parseLine(negative, pollStart: poll), .malformed("total_token_usage"))
    }

    func testBooleanAndNonNumericCountersAreMalformed() {
        let boolean = """
        {"timestamp":"2026-08-22T00:00:00.000Z","type":"event_msg","payload":{"type":"token_count","total_token_usage":{"input_tokens":true,"output_tokens":1}}}
        """
        let text = """
        {"timestamp":"2026-08-22T00:00:00.000Z","type":"event_msg","payload":{"type":"token_count","total_token_usage":{"input_tokens":"40","output_tokens":1}}}
        """
        XCTAssertEqual(TokenCountParser.parseLine(boolean, pollStart: poll), .malformed("total_token_usage"))
        XCTAssertEqual(TokenCountParser.parseLine(text, pollStart: poll), .malformed("total_token_usage"))
    }

    func testInt64MaxIsAcceptedAndOverflowIsMalformed() {
        let maximum = """
        {"timestamp":"2026-08-22T00:00:00.000Z","type":"event_msg","payload":{"type":"token_count","total_token_usage":{"input_tokens":9223372036854775807,"output_tokens":1},"last_token_usage":{"input_tokens":0,"output_tokens":0}}}
        """
        switch TokenCountParser.parseLine(maximum, pollStart: poll) {
        case .counters(_, let total):
            XCTAssertEqual(total.input, Int64.max)
            XCTAssertEqual(total.output, 1)
        case .ignored:
            XCTFail("ignored")
        case .malformed(let reason):
            XCTFail("malformed \(reason)")
        }
        let overflow = """
        {"timestamp":"2026-08-22T00:00:00.000Z","type":"event_msg","payload":{"type":"token_count","total_token_usage":{"input_tokens":9223372036854775808,"output_tokens":1}}}
        """
        XCTAssertEqual(TokenCountParser.parseLine(overflow, pollStart: poll), .malformed("total_token_usage"))
    }
}

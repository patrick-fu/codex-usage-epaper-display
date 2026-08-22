import Foundation

struct TokenCounters: Sendable, Equatable {
    var input: Int64
    var cachedInput: Int64
    var output: Int64
    var reasoning: Int64
}

enum TokenCountLine: Sendable, Equatable {
    case ignored
    case malformed(String)
    case counters(observedAt: Int, total: TokenCounters)
}

enum TokenCountParser {
    static func parseLine(_ line: String, pollStart: Date) -> TokenCountLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .ignored
        }
        guard let data = trimmed.data(using: .utf8) else {
            return .malformed("utf8")
        }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return .malformed("json")
        }
        guard let object = dictionary(json) else {
            return .malformed("object")
        }
        guard let type = object["type"] as? String, type == "event_msg" else {
            return .ignored
        }
        guard let payloadRaw = object["payload"], let payload = dictionary(payloadRaw) else {
            return .ignored
        }
        guard let payloadType = payload["type"] as? String, payloadType == "token_count" else {
            return .ignored
        }
        guard let timestampRaw = object["timestamp"] as? String,
              let observedAt = parseTimestamp(timestampRaw) else {
            return .malformed("timestamp")
        }
        if observedAt < 0 {
            return .malformed("timestamp-negative")
        }
        let deadline = Int(pollStart.timeIntervalSince1970) + 5 * 60
        if observedAt > deadline {
            return .malformed("timestamp-future")
        }
        if let last = payload["last_token_usage"], !isNull(last) {
            if parseCounters(last) == nil {
                return .malformed("last_token_usage")
            }
        }
        guard let totalRaw = payload["total_token_usage"],
              let total = parseCounters(totalRaw) else {
            return .malformed("total_token_usage")
        }
        return .counters(observedAt: observedAt, total: total)
    }

    static func parseTimestamp(_ raw: String) -> Int? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        let posixFraction = DateFormatter()
        posixFraction.locale = Locale(identifier: "en_US_POSIX")
        posixFraction.timeZone = TimeZone(secondsFromGMT: 0)
        posixFraction.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        let posixBasic = DateFormatter()
        posixBasic.locale = Locale(identifier: "en_US_POSIX")
        posixBasic.timeZone = TimeZone(secondsFromGMT: 0)
        posixBasic.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        guard let date = withFraction.date(from: raw)
            ?? basic.date(from: raw)
            ?? posixFraction.date(from: raw)
            ?? posixBasic.date(from: raw) else {
            return nil
        }
        let seconds = date.timeIntervalSince1970
        guard seconds >= 0, seconds <= Double(Int.max) else {
            return nil
        }
        return Int(seconds.rounded(.towardZero))
    }

    private static func parseCounters(_ raw: Any) -> TokenCounters? {
        guard let object = dictionary(raw) else {
            return nil
        }
        guard let input = integer(object["input_tokens"]),
              let output = integer(object["output_tokens"]) else {
            return nil
        }
        let cached: Int64
        do {
            cached = try cachedInput(from: object)
        } catch {
            return nil
        }
        let reasoning: Int64
        if object["reasoning_output_tokens"] == nil || isNull(object["reasoning_output_tokens"]) {
            reasoning = 0
        } else if let value = integer(object["reasoning_output_tokens"]) {
            reasoning = value
        } else {
            return nil
        }
        guard cached <= input, reasoning <= output else {
            return nil
        }
        return TokenCounters(input: input, cachedInput: cached, output: output, reasoning: reasoning)
    }

    private static func cachedInput(from object: [String: Any]) throws -> Int64 {
        let keys = ["cached_input_tokens", "cache_read_input_tokens", "cache_read_tokens"]
        var values: [Int64] = []
        for key in keys {
            if object[key] == nil || isNull(object[key]) {
                continue
            }
            guard let value = integer(object[key]) else {
                throw ParserFailure.malformed
            }
            values.append(value)
        }
        if values.isEmpty {
            return 0
        }
        let unique = Set(values)
        guard unique.count == 1, let value = unique.first else {
            throw ParserFailure.malformed
        }
        return value
    }

    private static func integer(_ raw: Any?) -> Int64? {
        guard let raw, !isNull(raw) else { return nil }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            let cf = number as CFNumber
            var int64: Int64 = 0
            guard CFNumberGetValue(cf, .sInt64Type, &int64) else {
                return nil
            }
            if CFNumberIsFloatType(cf) {
                var doubleValue: Double = 0
                guard CFNumberGetValue(cf, .doubleType, &doubleValue),
                      doubleValue.isFinite,
                      doubleValue == Double(int64) else {
                    return nil
                }
            }
            return int64 >= 0 ? int64 : nil
        }
        if let value = raw as? Double {
            guard value.isFinite, value >= 0, value < 0x1p63, value.rounded(.towardZero) == value else {
                return nil
            }
            return Int64(value)
        }
        if let value = raw as? Float {
            guard value.isFinite, value >= 0, Double(value) < 0x1p63, value.rounded(.towardZero) == value else {
                return nil
            }
            return Int64(value)
        }
        if let value = raw as? Int, value >= 0 {
            return Int64(value)
        }
        if let value = raw as? Int64, value >= 0 {
            return value
        }
        return nil
    }

    private static func dictionary(_ raw: Any) -> [String: Any]? {
        if let object = raw as? [String: Any] {
            return object
        }
        guard let object = raw as? NSDictionary else {
            return nil
        }
        var result: [String: Any] = [:]
        result.reserveCapacity(object.count)
        for (key, value) in object {
            guard let key = key as? String else { return nil }
            result[key] = value
        }
        return result
    }

    private static func isNull(_ raw: Any?) -> Bool {
        raw == nil || raw is NSNull
    }

    private enum ParserFailure: Error {
        case malformed
    }
}

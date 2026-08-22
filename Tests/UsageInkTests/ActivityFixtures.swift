import Foundation
import XCTest
@testable import UsageInk

enum ActivityFixtures {
    static let uuidA = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    static let uuidB = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
    static let sourceKeyA = "52baa9bcc8b0d989c07f228067c508d411f47dfb71780c73f9efd109c5f14fb7"

    static func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageink-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("archived_sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        return url
    }

    static func makeStoreRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usageink-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func rolloutName(
        timestamp: String = "2026-08-22T00-00-00-",
        uuid: String = uuidA,
        revert: Bool = false
    ) -> String {
        let suffix = revert ? "_\(uuid)" : ""
        return "rollout-\(timestamp)\(uuid)\(suffix).jsonl"
    }

    static func tokenLine(
        timestamp: String,
        input: Int,
        cached: Int = 0,
        output: Int,
        reasoning: Int = 0,
        lastInput: Int = 0,
        lastOutput: Int = 0
    ) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"reasoning_output_tokens":\(reasoning)},"last_token_usage":{"input_tokens":\(lastInput),"cached_input_tokens":0,"output_tokens":\(lastOutput),"reasoning_output_tokens":0}}}
        """
    }

    @discardableResult
    static func writeRollout(
        home: URL,
        layer: ActivityLayer,
        basename: String,
        lines: [String],
        incompleteTail: String? = nil,
        subdirectory: String? = nil
    ) throws -> URL {
        var directory = home.appendingPathComponent(layer.rawValue, isDirectory: true)
        if let subdirectory {
            directory = directory.appendingPathComponent(subdirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let url = directory.appendingPathComponent(basename)
        var body = lines.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }.joined()
        if let incompleteTail {
            body += incompleteTail
        }
        try Data(body.utf8).write(to: url)
        return url
    }

    static func isoUTC(_ seconds: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    static func calendar(timeZone: TimeZone) -> Calendar {
        LocalActivityMetrics.isoCalendar(timeZone: timeZone)
    }

    static func ingest(
        home: URL,
        root: URL,
        now: Date,
        timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!,
        tpsWindowMinutes: Int = 15,
        limits: ActivityScanLimits = .specification,
        prior: LocalActivityObservation = .unknown
    ) -> (ActivityStore, LocalActivityObservation) {
        let store = ActivityStore(root: root)
        var calendar = calendar(timeZone: timeZone)
        calendar.timeZone = timeZone
        let observation = store.ingest(
            codexHome: home,
            pollStart: now,
            now: now,
            calendar: calendar,
            timeZone: timeZone,
            tpsWindowMinutes: tpsWindowMinutes,
            limits: limits,
            prior: prior
        )
        return (store, observation)
    }
}

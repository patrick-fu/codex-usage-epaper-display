import Foundation
@testable import UsageInk

final class ManualCodexClock: CodexScheduling {
    var now: TimeInterval = 0
    private var items: [(id: String, deadline: TimeInterval, body: () -> Void)] = []

    func schedule(id: String, after: TimeInterval, _ body: @escaping () -> Void) {
        items.removeAll { $0.id == id }
        items.append((id, now + after, body))
    }

    func cancel(id: String) {
        items.removeAll { $0.id == id }
    }

    func cancelAll() {
        items.removeAll()
    }

    func advance(_ interval: TimeInterval) {
        now += interval
        let due = items.filter { $0.deadline <= now }
        items.removeAll { item in due.contains { $0.id == item.id && $0.deadline == item.deadline } }
        for item in due {
            item.body()
        }
    }
}

final class ScriptedCodexSession: CodexStdioSession {
    var outputHandler: ((Data) -> Void)?
    var exitHandler: ((Int32) -> Void)?
    var sent: [[String: Any]] = []
    var startError: Error?
    var exitStatusOnStart: Int32?
    var inputClosed = false
    var aborted = false
    var onSend: (([String: Any]) -> Void)?

    func start() throws {
        if let startError {
            throw startError
        }
        if let exitStatusOnStart {
            exitHandler?(exitStatusOnStart)
        }
    }

    func send(_ data: Data) {
        let objects = decodeLines(data)
        sent.append(contentsOf: objects)
        for object in objects {
            onSend?(object)
        }
    }

    func closeInput() {
        inputClosed = true
    }

    func abort() {
        aborted = true
    }

    func respondJSON(_ object: [String: Any]) {
        respond(raw: encodeLine(object))
    }

    func respond(raw: Data) {
        outputHandler?(raw)
    }

    func exit(_ status: Int32) {
        exitHandler?(status)
    }
}

final class ScriptedCodexFactory: CodexSessionFactory {
    var sessions: [ScriptedCodexSession] = []
    var next: () -> ScriptedCodexSession = { ScriptedCodexSession() }

    func openAppServer(executable: String) throws -> CodexStdioSession {
        let session = next()
        sessions.append(session)
        return session
    }
}

func encodeLine(_ object: [String: Any]) -> Data {
    var data = try! JSONSerialization.data(withJSONObject: object)
    data.append(0x0a)
    return data
}

func decodeLines(_ data: Data) -> [[String: Any]] {
    data.split(separator: 0x0a, omittingEmptySubsequences: true).compactMap { line in
        try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    }
}

func initializeResult() -> [String: Any] {
    [
        "userAgent": "Codex Desktop/0.147.0 test (usageink; 0.1.0)",
        "codexHome": "/tmp/does-not-get-recorded",
        "platformFamily": "unix",
        "platformOs": "macos",
        "extraOptional": true,
    ]
}

func proAccountResult() -> [String: Any] {
    [
        "account": [
            "type": "chatgpt",
            "email": "user@example.com",
            "planType": "pro",
        ],
        "requiresOpenaiAuth": true,
        "mystery": "ignore",
    ]
}

func oneWindowResult() -> [String: Any] {
    [
        "rateLimits": [
            "limitId": "codex",
            "primary": [
                "usedPercent": 13,
                "windowDurationMins": 10080,
                "resetsAt": 1_787_499_508,
            ],
            "secondary": NSNull(),
            "credits": ["hasCredits": false, "balance": "0"],
        ]
    ]
}

func twoWindowResult() -> [String: Any] {
    [
        "rateLimitsByLimitId": [
            "codex": [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 13,
                    "windowDurationMins": 10080,
                    "resetsAt": 1_787_499_508,
                ],
                "secondary": [
                    "usedPercent": 42,
                    "windowDurationMins": 300,
                    "resetsAt": 1_787_400_000,
                ],
            ]
        ]
    ]
}

func jsonRPCResult(id: Int, result: Any) -> [String: Any] {
    ["id": id, "result": result]
}

func jsonRPCError(id: Int, code: Int, data: Any? = nil) -> [String: Any] {
    var error: [String: Any] = ["code": code, "message": "ignored"]
    if let data {
        error["data"] = data
    }
    return ["id": id, "error": error]
}

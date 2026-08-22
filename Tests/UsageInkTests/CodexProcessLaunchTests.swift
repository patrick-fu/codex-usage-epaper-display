import XCTest
@testable import UsageInk

final class CodexProcessLaunchTests: XCTestCase {
    func testLiveSessionStartsAppServerStdioAndDoesNotReadCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fake = root.appendingPathComponent("codex")
        let script = """
        #!/usr/bin/env python3
        import json, sys
        if len(sys.argv) == 2 and sys.argv[1] == "--version":
            print("codex-cli 0.147.0")
            sys.exit(0)
        if sys.argv[1:] != ["app-server", "--stdio"]:
            sys.stderr.write("unexpected argv\\n")
            sys.exit(2)
        sent = []
        def reply(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()
        for line in sys.stdin:
            message = json.loads(line)
            sent.append(message.get("method"))
            method = message.get("method")
            if method == "initialize":
                reply({"id": 1, "result": {
                    "userAgent": "Codex Desktop/0.147.0",
                    "codexHome": "/forbidden/codex-home",
                    "platformFamily": "unix",
                    "platformOs": "macos"
                }})
            elif method == "account/read":
                reply({"id": 2, "result": {
                    "account": {"type": "chatgpt", "email": "user@example.com", "planType": "pro"},
                    "requiresOpenaiAuth": True
                }})
            elif method == "account/rateLimits/read":
                reply({"id": 3, "result": {
                    "rateLimits": {
                        "limitId": "codex",
                        "primary": {"usedPercent": 13, "windowDurationMins": 10080, "resetsAt": 1787499508},
                        "secondary": None
                    }
                }})
                break
        if "account/login/start" in sent or "shutdown" in sent:
            sys.exit(3)
        """
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let discovery = CodexDiscovery(
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            pathEnvironment: "",
            homeDirectory: "/tmp",
            runVersion: CodexVersionProbe.run(executable:)
        )
        let resolved = try discovery.resolve(explicitPath: fake.path).get()
        XCTAssertEqual(resolved.version, .minimum)

        let queue = DispatchQueue(label: "test.codex.process")
        let client = CodexAppServerClient(
            factory: ProcessCodexSessionFactory(),
            clock: DispatchCodexClock(queue: queue),
            queue: queue
        )
        let finished = expectation(description: "process poll")
        var snapshot: CodexUsageSnapshot?
        var failure: CodexFailure?
        client.poll(executable: fake.path, appVersion: "0.1.0") { result in
            switch result {
            case .success(let value):
                snapshot = value
            case .failure(let value):
                failure = value
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5.0)
        XCTAssertNil(failure, "process poll failed: \(String(describing: failure))")
        XCTAssertEqual(snapshot?.planType, "pro")
        XCTAssertEqual(snapshot?.windows.count, 1)
        XCTAssertEqual(snapshot?.windows.first?.usedPercent, 13)
    }
}

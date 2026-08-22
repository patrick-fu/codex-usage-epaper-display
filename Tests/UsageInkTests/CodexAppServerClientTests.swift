import XCTest
@testable import UsageInk

final class CodexAppServerClientTests: XCTestCase {
    func testExactJSONLSequenceThenClosesStdinWithoutShutdownOrAuthWrite() {
        let (client, factory, _, queue) = makeClient()
        let session = ScriptedCodexSession()
        factory.next = { session }

        let finished = expectation(description: "poll")
        var snapshot: CodexUsageSnapshot?
        session.onSend = { object in
            let method = object["method"] as? String
            if method == "initialize" {
                session.respondJSON(jsonRPCResult(id: 1, result: initializeResult()))
            } else if method == "account/read" || method == "account/rateLimits/read" {
                if session.sent.contains(where: { $0["method"] as? String == "account/read" })
                    && session.sent.contains(where: { $0["method"] as? String == "account/rateLimits/read" }) {
                    session.respondJSON(jsonRPCResult(id: 2, result: proAccountResult()))
                    session.respondJSON(jsonRPCResult(id: 3, result: oneWindowResult()))
                }
            }
        }

        client.poll(executable: "/tmp/fake-codex", appVersion: "0.1.0") { result in
            snapshot = try? result.get()
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1.0)

        XCTAssertEqual(session.sent.map { $0["method"] as? String }, [
            "initialize", "initialized", "account/read", "account/rateLimits/read",
        ])
        XCTAssertEqual(session.sent[0]["id"] as? Int, 1)
        let initParams = session.sent[0]["params"] as? [String: Any]
        let clientInfo = initParams?["clientInfo"] as? [String: Any]
        XCTAssertEqual(clientInfo?["name"] as? String, "usageink")
        XCTAssertEqual(clientInfo?["title"] as? String, "UsageInk")
        XCTAssertEqual(clientInfo?["version"] as? String, "0.1.0")
        XCTAssertNil(initParams?["capabilities"])
        XCTAssertNil(initParams?["experimentalApi"])
        let initializedParams = session.sent[1]["params"] as? [String: Any]
        XCTAssertEqual(initializedParams?.isEmpty, true)
        XCTAssertNil(session.sent[1]["id"])
        XCTAssertEqual(session.sent[2]["id"] as? Int, 2)
        let refreshToken = (session.sent[2]["params"] as? [String: Any])?["refreshToken"] as? NSNumber
        XCTAssertEqual(refreshToken?.boolValue, false)
        XCTAssertEqual(session.sent[3]["id"] as? Int, 3)
        XCTAssertTrue(session.inputClosed)
        XCTAssertFalse(session.aborted)
        XCTAssertEqual(snapshot?.planType, "pro")
        XCTAssertEqual(snapshot?.windows.count, 1)
        XCTAssertFalse(session.sent.contains(where: { ($0["method"] as? String)?.contains("auth") == true }))
        XCTAssertFalse(session.sent.contains(where: { ($0["method"] as? String)?.contains("login") == true }))
        XCTAssertFalse(session.sent.contains(where: { ($0["method"] as? String) == "shutdown" }))
        for object in session.sent {
            let encoded = encodeLine(object)
            let text = String(data: encoded, encoding: .utf8) ?? ""
            XCTAssertFalse(text.contains("jsonrpc"))
            XCTAssertFalse(text.contains("user@example.com"))
            XCTAssertFalse(text.contains("codexHome"))
        }
        _ = queue
    }

    func testSparseRateLimitNotificationDoesNotMutateSnapshot() {
        let (client, factory, _, _) = makeClient()
        let session = ScriptedCodexSession()
        factory.next = { session }
        let finished = expectation(description: "poll")
        var snapshot: CodexUsageSnapshot?

        session.onSend = { object in
            if object["method"] as? String == "initialize" {
                session.respondJSON(jsonRPCResult(id: 1, result: initializeResult()))
            } else if object["method"] as? String == "account/read" {
                session.respondJSON([
                    "method": "account/rateLimits/updated",
                    "params": [
                        "rateLimits": [
                            "primary": [
                                "usedPercent": 99,
                                "windowDurationMins": 5,
                                "resetsAt": 1,
                            ]
                        ]
                    ],
                ])
                session.respondJSON(jsonRPCResult(id: 2, result: proAccountResult()))
                session.respondJSON(jsonRPCResult(id: 3, result: oneWindowResult()))
            }
        }

        client.poll(executable: "/tmp/fake-codex", appVersion: "0.1.0") { result in
            snapshot = try? result.get()
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1.0)
        XCTAssertEqual(snapshot?.windows.first?.usedPercent, 13)
        XCTAssertEqual(snapshot?.windows.first?.windowDurationMins, 10080)
    }

    func testOversizedFramedLineIsSchemaInvalidAndUnframedOversizeIsInvalidJSON() {
        let (client, factory, _, _) = makeClient()
        let framed = ScriptedCodexSession()
        factory.next = { framed }
        let framedDone = expectation(description: "framed")
        var framedFailure: CodexFailure?
        framed.onSend = { object in
            if object["method"] as? String == "initialize" {
                var line = Data(repeating: 0x61, count: CodexJSONLFramer.maxLineBytes + 1)
                line.append(0x0a)
                framed.respond(raw: line)
            }
        }
        client.poll(executable: "/tmp/fake-codex", appVersion: "0.1.0") { result in
            if case .failure(let failure) = result {
                framedFailure = failure
            }
            framedDone.fulfill()
        }
        wait(for: [framedDone], timeout: 1.0)
        XCTAssertEqual(framedFailure, .schemaInvalid)
        XCTAssertTrue(framed.aborted)

        let unframed = ScriptedCodexSession()
        factory.next = { unframed }
        let unframedDone = expectation(description: "unframed")
        var unframedFailure: CodexFailure?
        unframed.onSend = { object in
            if object["method"] as? String == "initialize" {
                unframed.respond(raw: Data(repeating: 0x61, count: CodexJSONLFramer.maxLineBytes + 1))
            }
        }
        client.poll(executable: "/tmp/fake-codex", appVersion: "0.1.0") { result in
            if case .failure(let failure) = result {
                unframedFailure = failure
            }
            unframedDone.fulfill()
        }
        wait(for: [unframedDone], timeout: 1.0)
        XCTAssertEqual(unframedFailure, .invalidJSON)
    }

    func testOrdinaryTimeoutRetriesOnceOnAFreshProcess() {
        let (client, factory, clock, queue) = makeClient()
        let first = ScriptedCodexSession()
        let second = ScriptedCodexSession()
        var created = 0
        factory.next = {
            created += 1
            return created == 1 ? first : second
        }
        let finished = expectation(description: "retry")
        var snapshot: CodexUsageSnapshot?
        let initializeSent = expectation(description: "first initialize")
        first.onSend = { object in
            if object["method"] as? String == "initialize" {
                initializeSent.fulfill()
            }
        }
        second.onSend = { object in
            if object["method"] as? String == "initialize" {
                second.respondJSON(jsonRPCResult(id: 1, result: initializeResult()))
            } else if object["method"] as? String == "account/read" {
                second.respondJSON(jsonRPCResult(id: 2, result: proAccountResult()))
                second.respondJSON(jsonRPCResult(id: 3, result: twoWindowResult()))
            }
        }

        client.poll(executable: "/tmp/fake-codex", appVersion: "0.1.0") { result in
            snapshot = try? result.get()
            finished.fulfill()
        }
        wait(for: [initializeSent], timeout: 1.0)
        queue.sync {
            clock.advance(CodexAppServerClient.initializeTimeout)
        }
        wait(for: [finished], timeout: 1.0)
        XCTAssertEqual(factory.sessions.count, 2)
        XCTAssertTrue(first.aborted)
        XCTAssertEqual(snapshot?.windows.count, 2)
        XCTAssertFalse(sessionSendsAuth(second))
    }

    func testOverloadRetriesAtMostThreeTimesInsideThirtySeconds() {
        let (client, factory, clock, queue) = makeClient()
        let session = ScriptedCodexSession()
        factory.next = { session }
        var initializeCount = 0
        let finished = expectation(description: "overload")
        let first = expectation(description: "first overload")
        first.assertForOverFulfill = false
        var failure: CodexFailure?
        session.onSend = { object in
            if object["method"] as? String == "initialize" {
                initializeCount += 1
                if initializeCount == 1 {
                    first.fulfill()
                }
                session.respondJSON(jsonRPCError(id: 1, code: -32001))
            }
        }
        client.poll(executable: "/tmp/fake-codex", appVersion: "0.1.0") { result in
            if case .failure(let value) = result {
                failure = value
            }
            finished.fulfill()
        }
        wait(for: [first], timeout: 1.0)
        queue.sync {
            clock.advance(0.5)
            clock.advance(1.0)
            clock.advance(2.0)
        }
        wait(for: [finished], timeout: 1.0)
        XCTAssertEqual(failure, .overloaded)
        XCTAssertEqual(initializeCount, 4)
        XCTAssertEqual(factory.sessions.count, 1)
    }

    func testAccountReadRPCErrorIsNeverAuthRequired() {
        let (client, factory, _, _) = makeClient()
        let session = ScriptedCodexSession()
        factory.next = { session }
        let finished = expectation(description: "rpc")
        var failure: CodexFailure?
        session.onSend = { object in
            if object["method"] as? String == "initialize" {
                session.respondJSON(jsonRPCResult(id: 1, result: initializeResult()))
            } else if object["method"] as? String == "account/read" {
                session.respondJSON(jsonRPCError(id: 2, code: -32000, data: ["httpStatus": 401]))
                session.respondJSON(jsonRPCResult(id: 3, result: oneWindowResult()))
            }
        }
        client.poll(executable: "/tmp/fake-codex", appVersion: "0.1.0") { result in
            if case .failure(let value) = result {
                failure = value
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1.0)
        XCTAssertEqual(failure, .backendUnauthorized)
    }

    func testTransportStartFailureIsClassifiedWithoutLaunchingReads() {
        let (client, factory, _, _) = makeClient()
        let session = ScriptedCodexSession()
        session.startError = CodexFailure.transportStart
        factory.next = { session }
        let finished = expectation(description: "start")
        var failure: CodexFailure?
        client.poll(executable: "/missing", appVersion: "0.1.0") { result in
            if case .failure(let value) = result {
                failure = value
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1.0)
        XCTAssertEqual(failure, .transportStart)
        XCTAssertTrue(session.sent.isEmpty)
    }

    func testInitializeTimeoutDoesNotSendReadsUntilResponse() {
        let (client, factory, _, _) = makeClient()
        let session = ScriptedCodexSession()
        factory.next = { session }
        let sent = expectation(description: "initialize")
        session.onSend = { object in
            if object["method"] as? String == "initialize" {
                sent.fulfill()
            }
        }
        client.poll(executable: "/tmp/fake-codex", appVersion: "0.1.0") { _ in }
        wait(for: [sent], timeout: 1.0)
        XCTAssertEqual(session.sent.map { $0["method"] as? String }, ["initialize"])
    }

    private func makeClient() -> (CodexAppServerClient, ScriptedCodexFactory, ManualCodexClock, DispatchQueue) {
        let queue = DispatchQueue(label: "test.codex.client")
        let factory = ScriptedCodexFactory()
        let clock = ManualCodexClock()
        let client = CodexAppServerClient(factory: factory, clock: clock, jitter: { 1 }, queue: queue)
        return (client, factory, clock, queue)
    }

    private func sessionSendsAuth(_ session: ScriptedCodexSession) -> Bool {
        session.sent.contains { object in
            let method = object["method"] as? String ?? ""
            return method.contains("auth") || method.contains("login") || method.contains("logout")
        }
    }
}

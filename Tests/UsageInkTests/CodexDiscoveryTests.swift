import XCTest
@testable import UsageInk

final class CodexDiscoveryTests: XCTestCase {
    func testExplicitAbsolutePathWinsOverPATHAndFallbacks() throws {
        let discovery = CodexDiscovery(
            isExecutable: { path in
                ["/explicit/codex", "/opt/homebrew/bin/codex", "/on-path/codex"].contains(path)
            },
            pathEnvironment: "/on-path",
            homeDirectory: "/Users/tester",
            runVersion: { path in
                XCTAssertEqual(path, "/explicit/codex")
                return .success("codex-cli 0.147.0")
            }
        )

        let resolved = try discovery.resolve(explicitPath: "/explicit/codex").get()
        XCTAssertEqual(resolved.path, "/explicit/codex")
        XCTAssertEqual(resolved.version, CodexVersion(major: 0, minor: 147, patch: 0))
    }

    func testPATHCodexIsPreferredBeforeHardcodedFallbacks() throws {
        let probed = Box<[String]>([])
        let discovery = CodexDiscovery(
            isExecutable: { path in
                probed.value.append(path)
                return path == "/custom/bin/codex"
            },
            pathEnvironment: "/custom/bin:/opt/homebrew/bin",
            homeDirectory: "/Users/tester",
            runVersion: { _ in .success("codex-cli 0.150.1") }
        )

        let resolved = try discovery.resolve(explicitPath: nil).get()
        XCTAssertEqual(resolved.path, "/custom/bin/codex")
        XCTAssertEqual(resolved.version, CodexVersion(major: 0, minor: 150, patch: 1))
        XCTAssertEqual(probed.value.first, "/custom/bin/codex")
        XCTAssertFalse(probed.value.contains("/opt/homebrew/bin/codex"))
    }

    func testFallbackOrderIsHomebrewThenUsrLocalThenHomeLocal() throws {
        let probed = Box<[String]>([])
        let discovery = CodexDiscovery(
            isExecutable: { path in
                probed.value.append(path)
                return path == "/Users/tester/.local/bin/codex"
            },
            pathEnvironment: "",
            homeDirectory: "/Users/tester",
            runVersion: { _ in .success("0.147.0") }
        )

        let resolved = try discovery.resolve(explicitPath: nil).get()
        XCTAssertEqual(resolved.path, "/Users/tester/.local/bin/codex")
        XCTAssertEqual(probed.value, [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Users/tester/.local/bin/codex",
        ])
    }

    func testVersionBelowMinimumIsVersionTooOld() {
        let discovery = CodexDiscovery(
            isExecutable: { $0 == "/opt/homebrew/bin/codex" },
            pathEnvironment: "",
            homeDirectory: "/Users/tester",
            runVersion: { _ in .success("codex-cli 0.146.9") }
        )

        switch discovery.resolve(explicitPath: nil) {
        case .failure(.versionTooOld):
            break
        case let other:
            XCTFail("expected versionTooOld, got \(other)")
        }
    }

    func testMissingBinaryIsBinaryMissing() {
        let discovery = CodexDiscovery(
            isExecutable: { _ in false },
            pathEnvironment: "/usr/bin",
            homeDirectory: "/Users/tester",
            runVersion: { _ in
                XCTFail("must not probe version when no executable exists")
                return .success("codex-cli 0.147.0")
            }
        )

        switch discovery.resolve(explicitPath: nil) {
        case .failure(.binaryMissing):
            break
        case let other:
            XCTFail("expected binaryMissing, got \(other)")
        }
    }

    func testUnexecutableExplicitPathDoesNotFallThrough() {
        let discovery = CodexDiscovery(
            isExecutable: { $0 == "/opt/homebrew/bin/codex" },
            pathEnvironment: "",
            homeDirectory: "/Users/tester",
            runVersion: { _ in .success("codex-cli 0.147.0") }
        )

        switch discovery.resolve(explicitPath: "/missing/codex") {
        case .failure(.binaryMissing):
            break
        case let other:
            XCTFail("explicit miss must be binaryMissing, got \(other)")
        }
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) {
        self.value = value
    }
}

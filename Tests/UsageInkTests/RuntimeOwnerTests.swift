import XCTest
@testable import UsageInk

final class RuntimeOwnerTests: XCTestCase {
    func testStartPublishesDefaultQuotaFocusUnboundSnapshotFromRuntimeQueue() {
        let snapshotArrived = expectation(description: "initial snapshot")
        let box = SnapshotBox()

        let runtime = UsageInkRuntime(language: .english) { snapshot in
            box.snapshot = snapshot
            box.queueLabel = String(cString: __dispatch_queue_get_label(nil))
            snapshotArrived.fulfill()
        }
        runtime.start()

        wait(for: [snapshotArrived], timeout: 1.0)
        XCTAssertEqual(box.queueLabel, UsageInkRuntime.queueLabel)
        XCTAssertEqual(box.snapshot?.displayStyle, .quotaFocus)
        XCTAssertEqual(box.snapshot?.binding, .unbound)
        XCTAssertFalse(box.snapshot?.hasReadyWakeupConfiguration ?? true)
        XCTAssertEqual(box.snapshot?.statusSummary, "— · Local activity unknown")
    }

    func testDisplayStyleCommandsAreSerializedOnTheRuntimeOwner() {
        let started = expectation(description: "start")
        let finished = expectation(description: "commands")
        finished.expectedFulfillmentCount = 3
        let box = SnapshotBox()

        let runtime = UsageInkRuntime(language: .english) { snapshot in
            let count = box.append(snapshot)
            if count == 1 {
                started.fulfill()
            } else {
                finished.fulfill()
            }
        }
        runtime.start()
        wait(for: [started], timeout: 1.0)

        runtime.submit(.setDisplayStyle(.balanced))
        runtime.submit(.setDisplayStyle(.activityFocus))
        runtime.submit(.setDisplayStyle(.quotaFocus))
        wait(for: [finished], timeout: 1.0)

        XCTAssertEqual(
            box.snapshots.map(\.displayStyle),
            [.quotaFocus, .balanced, .activityFocus, .quotaFocus]
        )
    }

    func testBindRefreshAndResetCommandsDoNotInventDisplayOrWakeupState() {
        let started = expectation(description: "start")
        let finished = expectation(description: "commands")
        finished.expectedFulfillmentCount = 4
        let box = SnapshotBox()

        let runtime = UsageInkRuntime(language: .english) { snapshot in
            let count = box.append(snapshot)
            if count == 1 {
                started.fulfill()
            } else {
                finished.fulfill()
            }
        }
        runtime.start()
        wait(for: [started], timeout: 1.0)
        runtime.submit(.refreshNow)
        runtime.submit(.findAndBindDisplay)
        runtime.submit(.rebuildLocalMetrics)
        runtime.submit(.resetUsageInkData)
        wait(for: [finished], timeout: 1.0)
        XCTAssertEqual(box.snapshot?.binding, .unbound)
        XCTAssertEqual(box.snapshot?.displayStyle, .quotaFocus)
        XCTAssertFalse(box.snapshot?.hasReadyWakeupConfiguration ?? true)
    }
}

private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot: RuntimeSnapshot?
    private var _snapshots: [RuntimeSnapshot] = []
    private var _queueLabel = ""

    var snapshot: RuntimeSnapshot? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _snapshot
        }
        set {
            lock.lock()
            _snapshot = newValue
            lock.unlock()
        }
    }

    var snapshots: [RuntimeSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return _snapshots
    }

    var queueLabel: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _queueLabel
        }
        set {
            lock.lock()
            _queueLabel = newValue
            lock.unlock()
        }
    }

    func append(_ snapshot: RuntimeSnapshot) -> Int {
        lock.lock()
        defer { lock.unlock() }
        _snapshot = snapshot
        _snapshots.append(snapshot)
        return _snapshots.count
    }
}

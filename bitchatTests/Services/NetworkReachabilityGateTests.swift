import Combine
import XCTest
@testable import PlaneChat

/// Covers the reachability-gate decision logic (pure debounce).
@MainActor
final class NetworkReachabilityGateTests: XCTestCase {

    // MARK: - Pure debounce logic

    func test_debounce_satisfiedStaysReachable() {
        var d = ReachabilityDebounce(interval: 2.5, initial: true)
        let t0 = Date()
        // An interface remains present: no change, no pending.
        XCTAssertNil(d.observe(reachable: true, at: t0))
        XCTAssertTrue(d.committed)
        XCTAssertFalse(d.hasPendingChange)
    }

    func test_debounce_unsatisfiedSuppressesAfterInterval() {
        var d = ReachabilityDebounce(interval: 2.5, initial: true)
        let t0 = Date()
        // Path drops: not committed immediately (within debounce window).
        XCTAssertNil(d.observe(reachable: false, at: t0))
        XCTAssertTrue(d.committed)
        XCTAssertTrue(d.hasPendingChange)
        // Still within window.
        XCTAssertNil(d.flush(at: t0.addingTimeInterval(1.0)))
        XCTAssertTrue(d.committed)
        // Past the window: commit unreachable.
        XCTAssertEqual(d.flush(at: t0.addingTimeInterval(2.5)), false)
        XCTAssertFalse(d.committed)
        XCTAssertFalse(d.hasPendingChange)
    }

    func test_debounce_flapIsIgnored() {
        var d = ReachabilityDebounce(interval: 2.5, initial: true)
        let t0 = Date()
        // Drop then recover well within the window — must never commit a change.
        XCTAssertNil(d.observe(reachable: false, at: t0))
        XCTAssertTrue(d.hasPendingChange)
        XCTAssertNil(d.observe(reachable: true, at: t0.addingTimeInterval(0.5)))
        XCTAssertFalse(d.hasPendingChange, "recovery should cancel the pending drop")
        // A late flush after the original deadline is a no-op (nothing pending).
        XCTAssertNil(d.flush(at: t0.addingTimeInterval(3.0)))
        XCTAssertTrue(d.committed)
    }

    func test_debounce_recoverAfterOutageCommitsAfterInterval() {
        var d = ReachabilityDebounce(interval: 2.5, initial: false)
        let t0 = Date()
        XCTAssertNil(d.observe(reachable: true, at: t0))
        XCTAssertTrue(d.hasPendingChange)
        XCTAssertEqual(d.flush(at: t0.addingTimeInterval(2.5)), true)
        XCTAssertTrue(d.committed)
    }

    func test_debounce_duplicateObservationsPreservePendingDeadline() {
        var d = ReachabilityDebounce(interval: 2.5, initial: true)
        let t0 = Date()
        XCTAssertNil(d.observe(reachable: false, at: t0))
        // Duplicate unsatisfied updates mid-window keep the original deadline.
        XCTAssertNil(d.observe(reachable: false, at: t0.addingTimeInterval(1.0)))
        XCTAssertEqual(d.pendingRemaining(at: t0.addingTimeInterval(1.0)), 1.5)
        // A duplicate arriving past the deadline commits immediately.
        XCTAssertEqual(d.observe(reachable: false, at: t0.addingTimeInterval(2.5)), false)
        XCTAssertNil(d.pendingRemaining(at: t0.addingTimeInterval(2.5)))
    }

    func test_monitor_duplicateUpdatesDoNotPostponeOfflineCommit() async {
        let monitor = NWPathReachabilityMonitor(debounceInterval: 1.0)
        var received: [Bool] = []
        let cancellable = monitor.reachabilityPublisher.sink { received.append($0) }
        defer { cancellable.cancel() }

        let start = Date()
        monitor.ingest(reachable: false)
        try? await Task.sleep(nanoseconds: 500_000_000)
        // Duplicate unsatisfied update mid-window (e.g. interface detail change
        // while still offline) must not restart the debounce window.
        monitor.ingest(reachable: false)

        let committed = await waitUntil(timeout: 2.0) { !received.isEmpty }
        XCTAssertTrue(committed)
        XCTAssertEqual(received, [false])
        // The flush must fire at the original ~1.0s deadline, not ~1.5s
        // (a full interval after the duplicate).
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.4)
    }

    // MARK: - Harness

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}


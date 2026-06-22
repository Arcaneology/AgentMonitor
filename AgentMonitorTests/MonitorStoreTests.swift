import XCTest
@testable import AgentMonitor

@MainActor
final class MonitorStoreTests: XCTestCase {
    func testRefreshPublishesSnapshot() async {
        let expected = MonitorSnapshot(
            services: [],
            issues: [MonitorIssue(source: .ports, message: "partial")],
            collectedAt: Date(),
            collectionDuration: 0.1
        )
        let store = MonitorStore(discoverer: StaticDiscoverer(snapshot: expected))

        await store.refresh()

        XCTAssertEqual(store.snapshot, expected)
        XCTAssertFalse(store.isRefreshing)
    }

    func testConcurrentRefreshIsIgnored() async {
        let discoverer = SuspendedDiscoverer()
        let store = MonitorStore(discoverer: discoverer)

        let firstRefresh = Task { await store.refresh() }
        while await discoverer.callCount == 0 {
            await Task.yield()
        }

        await store.refresh()
        let callCount = await discoverer.callCount
        XCTAssertEqual(callCount, 1)

        await discoverer.resume(returning: .empty)
        await firstRefresh.value
    }
}

private struct StaticDiscoverer: ServiceDiscovering {
    let snapshot: MonitorSnapshot

    func discover() async -> MonitorSnapshot {
        snapshot
    }
}

private actor SuspendedDiscoverer: ServiceDiscovering {
    private var calls = 0
    private var continuation: CheckedContinuation<MonitorSnapshot, Never>?

    var callCount: Int { calls }

    func discover() async -> MonitorSnapshot {
        calls += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(returning snapshot: MonitorSnapshot) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}

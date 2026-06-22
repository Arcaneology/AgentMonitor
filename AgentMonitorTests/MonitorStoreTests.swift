import SwiftUI
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

    func testMenuContentReservesRoomForServiceRows() async {
        let service = makeExampleService()
        let snapshot = MonitorSnapshot(
            services: [service],
            issues: [],
            collectedAt: Date(),
            collectionDuration: 0.04
        )
        let store = MonitorStore(discoverer: StaticDiscoverer(snapshot: snapshot))
        await store.refresh()

        let hostingView = NSHostingView(rootView: MenuBarContentView(store: store))
        hostingView.layoutSubtreeIfNeeded()

        let height = hostingView.fittingSize.height
        XCTAssertGreaterThanOrEqual(height, 450, "Menu fitting height was \(height)")
    }

    func testStopConfirmationIsRenderedInsideMenuContent() async {
        let service = makeExampleService()
        let snapshot = MonitorSnapshot(
            services: [service],
            issues: [],
            collectedAt: Date(),
            collectionDuration: 0.04
        )
        let store = MonitorStore(discoverer: StaticDiscoverer(snapshot: snapshot))
        await store.refresh()

        let regularView = NSHostingView(rootView: MenuBarContentView(store: store))
        let confirmationView = NSHostingView(rootView: MenuBarContentView(
            store: store,
            serviceToStop: service
        ))
        regularView.layoutSubtreeIfNeeded()
        confirmationView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            confirmationView.fittingSize.height,
            regularView.fittingSize.height + 40
        )
    }

    private func makeExampleService() -> MonitoredService {
        let process = MonitoredProcess(
            id: ProcessIdentity(pid: 42, startTime: Date(timeIntervalSince1970: 42)),
            ownerUID: 501,
            executablePath: "/usr/bin/node",
            arguments: [],
            workingDirectory: URL(fileURLWithPath: "/tmp/example", isDirectory: true),
            memoryBytes: 32 * 1_024 * 1_024
        )
        return MonitoredService(
            id: "example",
            displayName: "Example Project",
            kind: .localProject,
            projectRoot: process.workingDirectory,
            launchAgentLabel: nil,
            processes: [process],
            endpoints: [ListeningEndpoint(address: "127.0.0.1", port: 3_000, transport: .tcp)]
        )
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

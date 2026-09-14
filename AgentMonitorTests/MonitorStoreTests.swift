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

    func testRefreshKeepsSnapshotWhenOnlyCollectionMetadataChanges() async {
        let first = MonitorSnapshot(
            services: [],
            issues: [],
            collectedAt: Date(timeIntervalSince1970: 1),
            collectionDuration: 0.1
        )
        let second = MonitorSnapshot(
            services: [],
            issues: [],
            collectedAt: Date(timeIntervalSince1970: 2),
            collectionDuration: 0.2
        )
        let store = MonitorStore(discoverer: SequencedDiscoverer([first, second]))

        await store.refresh()
        await store.refresh()

        XCTAssertEqual(store.snapshot, first)
    }

    func testMenuContentCanExpandServiceRows() async {
        let service = makeExampleService()
        let snapshot = MonitorSnapshot(
            services: [service],
            issues: [],
            collectedAt: Date(),
            collectionDuration: 0.04
        )
        let store = MonitorStore(discoverer: StaticDiscoverer(snapshot: snapshot))
        await store.refresh()

        let collapsedView = NSHostingView(rootView: MenuBarContentView(
            store: store,
            tokenUsageStore: makeTokenUsageStore()
        ))
        let expandedView = NSHostingView(rootView: MenuBarContentView(
            store: store,
            tokenUsageStore: makeTokenUsageStore(),
            isServiceMonitorExpanded: true
        ))
        collapsedView.layoutSubtreeIfNeeded()
        expandedView.layoutSubtreeIfNeeded()

        let collapsedHeight = collapsedView.fittingSize.height
        let expandedHeight = expandedView.fittingSize.height
        // Expanding reveals the service row, so the viewport grows with it.
        XCTAssertGreaterThan(
            expandedHeight,
            collapsedHeight + 60,
            "Collapsed \(collapsedHeight), expanded \(expandedHeight)"
        )
    }

    func testMenuContentCollapsesServiceRowsByDefault() async {
        let service = makeExampleService()
        let snapshot = MonitorSnapshot(
            services: [service],
            issues: [],
            collectedAt: Date(),
            collectionDuration: 0.04
        )
        let store = MonitorStore(discoverer: StaticDiscoverer(snapshot: snapshot))
        await store.refresh()

        let collapsedView = NSHostingView(rootView: MenuBarContentView(
            store: store,
            tokenUsageStore: makeTokenUsageStore()
        ))
        let expandedView = NSHostingView(rootView: MenuBarContentView(
            store: store,
            tokenUsageStore: makeTokenUsageStore(),
            isServiceMonitorExpanded: true
        ))
        collapsedView.layoutSubtreeIfNeeded()
        expandedView.layoutSubtreeIfNeeded()

        let collapsedHeight = collapsedView.fittingSize.height
        let expandedHeight = expandedView.fittingSize.height
        // The viewport fits short content instead of padding it to the
        // 960pt cap, and the service rows stay hidden until expanded.
        XCTAssertLessThan(collapsedHeight, 960, "Menu fitting height was \(collapsedHeight)")
        XCTAssertLessThan(collapsedHeight, expandedHeight)
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

        let regularView = NSHostingView(rootView: MenuBarContentView(
            store: store,
            tokenUsageStore: makeTokenUsageStore()
        ))
        let confirmationView = NSHostingView(rootView: MenuBarContentView(
            store: store,
            serviceToStop: service,
            tokenUsageStore: makeTokenUsageStore()
        ))
        regularView.layoutSubtreeIfNeeded()
        confirmationView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            confirmationView.fittingSize.height,
            regularView.fittingSize.height + 40
        )
    }

    func testSortsServicesByNameInBothDirections() {
        let alpha = makeExampleService(id: "alpha", displayName: "Alpha")
        let zulu = makeExampleService(id: "zulu", displayName: "Zulu")

        XCTAssertEqual(
            ServiceSortOrder.nameAscending.sorted([zulu, alpha]).map(\.displayName),
            ["Alpha", "Zulu"]
        )
        XCTAssertEqual(
            ServiceSortOrder.nameDescending.sorted([alpha, zulu]).map(\.displayName),
            ["Zulu", "Alpha"]
        )
    }

    func testSelectPowerModeUpdatesRequestedModeBeforeSystemChangeFinishes() async {
        let controller = DelayedFakeServerModeController()
        let store = MonitorStore(
            discoverer: StaticDiscoverer(snapshot: .empty),
            serverModeController: controller
        )

        store.selectPowerMode(.normal)

        XCTAssertEqual(store.serverModeSnapshot.requestedMode, .normal)
        XCTAssertEqual(store.serverModeSnapshot.displayedPowerMode, .normal)
        XCTAssertTrue(store.isChangingServerMode)
        await controller.waitUntilBlocked()

        await controller.resume()
        while store.isChangingServerMode {
            await Task.yield()
        }

        XCTAssertEqual(store.serverModeSnapshot.requestedMode, .normal)
        XCTAssertFalse(store.isChangingServerMode)
    }

    func testRefreshServerModeIsSkippedWhilePowerModeIsChanging() async {
        let controller = DelayedFakeServerModeController()
        let store = MonitorStore(
            discoverer: StaticDiscoverer(snapshot: .empty),
            serverModeController: controller
        )

        store.selectPowerMode(.server)
        await controller.waitUntilBlocked()
        await store.refreshServerMode()
        XCTAssertEqual(controller.refreshCount, 0)

        await controller.resume()
        while store.isChangingServerMode {
            await Task.yield()
        }
        await store.refreshServerMode()
        XCTAssertEqual(controller.refreshCount, 1)
    }

    func testAsyncPowerModeRequestsNeverOverlapAndLatestRequestWins() async {
        let controller = ConcurrencyTrackingServerModeController()
        let store = MonitorStore(
            discoverer: StaticDiscoverer(snapshot: .empty),
            serverModeController: controller
        )

        let first = Task { await store.setPowerMode(.server) }
        await Task.yield()
        let second = Task { await store.setPowerMode(.normal) }
        await first.value
        await second.value

        XCTAssertEqual(controller.maximumConcurrentCalls, 1)
        XCTAssertEqual(controller.receivedModes, [.server, .normal])
        XCTAssertEqual(store.serverModeSnapshot.requestedMode, .normal)
        XCTAssertFalse(store.isChangingServerMode)
    }

    func testUserPowerRequestWaitsForScheduledReconciliation() async {
        let controller = ScheduledOverlapServerModeController()
        let store = MonitorStore(
            discoverer: StaticDiscoverer(snapshot: .empty),
            serverModeController: controller
        )

        let refresh = Task { await store.refreshServerMode() }
        await controller.waitUntilScheduleBlocked()
        store.selectPowerMode(.normal)
        await Task.yield()

        XCTAssertEqual(controller.setModeCount, 0)
        XCTAssertEqual(controller.maximumConcurrentCalls, 1)

        controller.resumeSchedule()
        await refresh.value
        while store.isChangingServerMode {
            await Task.yield()
        }

        XCTAssertEqual(controller.setModeCount, 1)
        XCTAssertEqual(controller.maximumConcurrentCalls, 1)
        XCTAssertEqual(store.serverModeSnapshot.requestedMode, .normal)
    }

    /// Services without a project or LaunchAgent remain visible as user services.
    func testIncludesServicesWithoutAProjectOrLaunchAgent() async {
        let project = makeExampleService(id: "project", displayName: "Project")
        let strayPort = makeExampleService(
            id: "stray",
            displayName: "Example Port",
            kind: .userProcess
        )
        let snapshot = MonitorSnapshot(
            services: [project, strayPort],
            issues: [],
            collectedAt: Date(),
            collectionDuration: 0.1
        )
        let store = MonitorStore(discoverer: StaticDiscoverer(snapshot: snapshot))

        await store.refresh()

        XCTAssertEqual(store.services.count, 2)
        XCTAssertEqual(store.services.map(\.id), ["project", "stray"])
        XCTAssertEqual(store.serviceCount, 2)
    }

    func testSortsServicesByMemoryInBothDirections() {
        let low = makeExampleService(id: "low", displayName: "Low", memoryBytes: 8)
        let high = makeExampleService(id: "high", displayName: "High", memoryBytes: 64)

        XCTAssertEqual(
            ServiceSortOrder.memoryDescending.sorted([low, high]).map(\.id),
            ["high", "low"]
        )
        XCTAssertEqual(
            ServiceSortOrder.memoryAscending.sorted([high, low]).map(\.id),
            ["low", "high"]
        )
    }

    private func makeExampleService(
        id: String = "example",
        displayName: String = "Example Project",
        memoryBytes: UInt64 = 32 * 1_024 * 1_024,
        kind: MonitoredService.Kind = .localProject
    ) -> MonitoredService {
        let process = MonitoredProcess(
            id: ProcessIdentity(pid: 42, startTime: Date(timeIntervalSince1970: 42)),
            ownerUID: 501,
            executablePath: "/usr/bin/node",
            arguments: [],
            workingDirectory: URL(fileURLWithPath: "/tmp/example", isDirectory: true),
            memoryBytes: memoryBytes
        )
        return MonitoredService(
            id: id,
            displayName: displayName,
            kind: kind,
            projectRoot: process.workingDirectory,
            launchAgentLabel: nil,
            processes: [process],
            endpoints: [ListeningEndpoint(address: "127.0.0.1", port: 3_000, transport: .tcp)]
        )
    }

    private func makeTokenUsageStore() -> TokenUsageStore {
        TokenUsageStore(reader: EmptyTokenUsageReader())
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

private actor SequencedDiscoverer: ServiceDiscovering {
    private var snapshots: [MonitorSnapshot]

    init(_ snapshots: [MonitorSnapshot]) {
        self.snapshots = snapshots
    }

    func discover() async -> MonitorSnapshot {
        snapshots.isEmpty ? .empty : snapshots.removeFirst()
    }
}

private struct EmptyTokenUsageReader: TokenUsageReading {
    func records(from start: Date, through end: Date) async throws -> [TokenUsageRecord] {
        []
    }
}

@MainActor
private final class DelayedFakeServerModeController: ServerModeControlling {
    private(set) var refreshCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func refresh() async -> ServerModeSnapshot {
        refreshCount += 1
        return ServerModeSnapshot.unknown
    }

    func setEnabled(_ enabled: Bool) async -> ServerModeSnapshot {
        await setMode(enabled ? .server : .normal)
    }

    func setMode(_ mode: PowerMode) async -> ServerModeSnapshot {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return ServerModeSnapshot(
            state: mode == .server ? .enabled : .disabled,
            requestedMode: mode,
            effectiveMode: mode == .server ? .server : .normal,
            isCaffeinateRunning: mode == .server,
            schedule: .default,
            message: nil
        )
    }

    func setSchedule(_ schedule: PowerModeSchedule, now: Date) async -> ServerModeSnapshot {
        ServerModeSnapshot.unknown
    }

    func reconcileSchedule(now: Date) async -> ServerModeSnapshot? {
        nil
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    func waitUntilBlocked() async {
        while continuation == nil {
            await Task.yield()
        }
    }
}

@MainActor
private final class ConcurrencyTrackingServerModeController: ServerModeControlling {
    private(set) var activeCalls = 0
    private(set) var maximumConcurrentCalls = 0
    private(set) var receivedModes: [PowerMode] = []

    func refresh() async -> ServerModeSnapshot { .unknown }

    func setEnabled(_ enabled: Bool) async -> ServerModeSnapshot {
        await setMode(enabled ? .server : .normal)
    }

    func setMode(_ mode: PowerMode) async -> ServerModeSnapshot {
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        receivedModes.append(mode)
        try? await Task.sleep(for: .milliseconds(20))
        activeCalls -= 1
        return ServerModeSnapshot(
            state: mode == .server ? .enabled : .disabled,
            requestedMode: mode,
            effectiveMode: mode == .server ? .server : .normal,
            isCaffeinateRunning: mode == .server,
            schedule: .default,
            message: nil
        )
    }

    func setSchedule(_ schedule: PowerModeSchedule, now: Date) async -> ServerModeSnapshot { .unknown }
    func reconcileSchedule(now: Date) async -> ServerModeSnapshot? { nil }
}

@MainActor
private final class ScheduledOverlapServerModeController: ServerModeControlling {
    private var activeCalls = 0
    private var scheduleContinuation: CheckedContinuation<Void, Never>?
    private(set) var maximumConcurrentCalls = 0
    private(set) var setModeCount = 0

    func refresh() async -> ServerModeSnapshot { .unknown }

    func setEnabled(_ enabled: Bool) async -> ServerModeSnapshot {
        await setMode(enabled ? .server : .normal)
    }

    func setMode(_ mode: PowerMode) async -> ServerModeSnapshot {
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        setModeCount += 1
        activeCalls -= 1
        return ServerModeSnapshot(
            state: mode == .server ? .enabled : .disabled,
            requestedMode: mode,
            effectiveMode: mode == .server ? .server : .normal,
            isCaffeinateRunning: mode == .server,
            schedule: .default,
            message: nil
        )
    }

    func setSchedule(_ schedule: PowerModeSchedule, now: Date) async -> ServerModeSnapshot { .unknown }

    func reconcileSchedule(now: Date) async -> ServerModeSnapshot? {
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        await withCheckedContinuation { scheduleContinuation = $0 }
        activeCalls -= 1
        return nil
    }

    func waitUntilScheduleBlocked() async {
        while scheduleContinuation == nil {
            await Task.yield()
        }
    }

    func resumeSchedule() {
        scheduleContinuation?.resume()
        scheduleContinuation = nil
    }
}

import Combine
import Foundation

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var snapshot = MonitorSnapshot.empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var stoppingServiceIDs: Set<String> = []
    @Published private(set) var serverModeSnapshot = ServerModeSnapshot.unknown
    @Published private(set) var isChangingServerMode = false

    private let discoverer: any ServiceDiscovering
    private let serviceStopper: (any ServiceStopping)?
    private let serverModeController: (any ServerModeControlling)?
    private let refreshInterval: Duration
    private let serverModeRefreshInterval: Duration
    private var refreshTask: Task<Void, Never>?
    private var serverModeRefreshTask: Task<Void, Never>?
    private var refreshInFlight = false
    private var pendingPowerMode: PowerMode?
    private var powerModeTask: Task<Void, Never>?
    private var powerModeWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        discoverer: any ServiceDiscovering,
        serviceStopper: (any ServiceStopping)? = nil,
        serverModeController: (any ServerModeControlling)? = nil,
        refreshInterval: Duration = .seconds(10),
        serverModeRefreshInterval: Duration = .seconds(30)
    ) {
        self.discoverer = discoverer
        self.serviceStopper = serviceStopper
        self.serverModeController = serverModeController
        self.refreshInterval = refreshInterval
        self.serverModeRefreshInterval = serverModeRefreshInterval
    }

    var services: [MonitoredService] { snapshot.services }

    var serviceCount: Int { services.count }
    var portCount: Int {
        Set(services.flatMap(\.endpoints)).count
    }

    func start() {
        guard refreshTask == nil else { return }

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()

                do {
                    try await Task.sleep(for: self.refreshInterval)
                } catch {
                    return
                }
            }
        }

        guard serverModeController != nil else { return }
        serverModeRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshServerMode()

                do {
                    try await Task.sleep(for: self.serverModeRefreshInterval)
                } catch {
                    return
                }
            }
        }
    }

    func refresh() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true

        let showsInitialLoading = snapshot.collectedAt == .distantPast
        if showsInitialLoading {
            isRefreshing = true
        }
        defer {
            refreshInFlight = false
            if showsInitialLoading {
                isRefreshing = false
            }
        }

        let nextSnapshot = await discoverer.discover()
        if shouldPublish(nextSnapshot) {
            snapshot = nextSnapshot
        }
    }

    private func shouldPublish(_ nextSnapshot: MonitorSnapshot) -> Bool {
        snapshot.collectedAt == .distantPast
            || snapshot.services != nextSnapshot.services
            || snapshot.issues != nextSnapshot.issues
    }

    func stopMonitoring() {
        refreshTask?.cancel()
        refreshTask = nil
        serverModeRefreshTask?.cancel()
        serverModeRefreshTask = nil
    }

    func refreshServerMode() async {
        guard let serverModeController else { return }
        guard !isChangingServerMode else { return }
        isChangingServerMode = true
        defer {
            isChangingServerMode = false
            startPowerModeTaskIfNeeded()
        }
        if let scheduledSnapshot = await serverModeController.reconcileSchedule(now: Date()) {
            serverModeSnapshot = scheduledSnapshot
        } else {
            serverModeSnapshot = await serverModeController.refresh()
        }
    }

    func setServerModeEnabled(_ enabled: Bool) async {
        await setPowerMode(enabled ? .server : .normal)
    }

    func selectPowerMode(_ mode: PowerMode) {
        previewRequestedMode(mode)
        enqueuePowerMode(mode)
    }

    func setPowerMode(_ mode: PowerMode) async {
        previewRequestedMode(mode)
        await withCheckedContinuation { continuation in
            enqueuePowerMode(mode, waiter: continuation)
        }
    }

    private func previewRequestedMode(_ mode: PowerMode) {
        guard serverModeController != nil else { return }
        var preview = serverModeSnapshot
        preview.requestedMode = mode
        preview.effectiveMode = switch mode {
        case .server: .server
        case .sleep: .sleep
        case .normal: .normal
        }
        preview.message = nil
        serverModeSnapshot = preview
    }

    private func enqueuePowerMode(
        _ mode: PowerMode,
        waiter: CheckedContinuation<Void, Never>? = nil
    ) {
        guard serverModeController != nil else {
            waiter?.resume()
            return
        }
        pendingPowerMode = mode
        if let waiter {
            powerModeWaiters.append(waiter)
        }
        startPowerModeTaskIfNeeded()
    }

    private func startPowerModeTaskIfNeeded() {
        guard !isChangingServerMode, powerModeTask == nil, pendingPowerMode != nil else { return }

        isChangingServerMode = true
        powerModeTask = Task { await drainPowerModeQueue() }
    }

    private func drainPowerModeQueue() async {
        guard let serverModeController else {
            finishPowerModeQueue()
            return
        }

        var latestSnapshot: ServerModeSnapshot?
        while let mode = pendingPowerMode {
            pendingPowerMode = nil
            latestSnapshot = await serverModeController.setMode(mode)
        }
        if let latestSnapshot {
            serverModeSnapshot = latestSnapshot
        }
        finishPowerModeQueue()
    }

    private func finishPowerModeQueue() {
        isChangingServerMode = false
        powerModeTask = nil
        let waiters = powerModeWaiters
        powerModeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func updatePowerModeSchedule(_ schedule: PowerModeSchedule) async {
        guard let serverModeController else { return }
        guard !isChangingServerMode else { return }

        isChangingServerMode = true
        defer {
            isChangingServerMode = false
            startPowerModeTaskIfNeeded()
        }

        serverModeSnapshot = await serverModeController.setSchedule(schedule, now: Date())
    }

    func isStopping(_ service: MonitoredService) -> Bool {
        stoppingServiceIDs.contains(service.id)
    }

    func stop(_ service: MonitoredService) async -> StopOutcome {
        guard let serviceStopper else {
            return .failed(L("停止服务功能尚未配置。", "Service stopping is not configured."))
        }
        guard stoppingServiceIDs.insert(service.id).inserted else {
            return .failed(L("该服务正在停止。", "This service is already stopping."))
        }
        defer { stoppingServiceIDs.remove(service.id) }

        let outcome = await serviceStopper.stop(service)
        if outcome == .stopped {
            await refresh()
        }
        return outcome
    }

    func forceStop(_ service: MonitoredService) async -> StopOutcome {
        guard let serviceStopper else {
            return .failed(L("停止服务功能尚未配置。", "Service stopping is not configured."))
        }
        guard stoppingServiceIDs.insert(service.id).inserted else {
            return .failed(L("该服务正在停止。", "This service is already stopping."))
        }
        defer { stoppingServiceIDs.remove(service.id) }

        let outcome = await serviceStopper.forceStop(service)
        if outcome == .stopped {
            await refresh()
        }
        return outcome
    }
}

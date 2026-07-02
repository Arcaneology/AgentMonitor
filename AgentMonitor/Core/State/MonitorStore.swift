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

    init(
        discoverer: any ServiceDiscovering,
        serviceStopper: (any ServiceStopping)? = nil,
        serverModeController: (any ServerModeControlling)? = nil,
        refreshInterval: Duration = .seconds(2),
        serverModeRefreshInterval: Duration = .seconds(5)
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
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        snapshot = await discoverer.discover()
    }

    func stopMonitoring() {
        refreshTask?.cancel()
        refreshTask = nil
        serverModeRefreshTask?.cancel()
        serverModeRefreshTask = nil
    }

    func refreshServerMode() async {
        guard let serverModeController else { return }
        serverModeSnapshot = await serverModeController.refresh()
    }

    func setServerModeEnabled(_ enabled: Bool) async {
        guard let serverModeController else { return }
        guard !isChangingServerMode else { return }

        isChangingServerMode = true
        defer { isChangingServerMode = false }

        serverModeSnapshot = await serverModeController.setEnabled(enabled)
    }

    func isStopping(_ service: MonitoredService) -> Bool {
        stoppingServiceIDs.contains(service.id)
    }

    func stop(_ service: MonitoredService) async -> StopOutcome {
        guard let serviceStopper else {
            return .failed("停止服务功能尚未配置。")
        }
        guard stoppingServiceIDs.insert(service.id).inserted else {
            return .failed("该服务正在停止。")
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
            return .failed("停止服务功能尚未配置。")
        }
        guard stoppingServiceIDs.insert(service.id).inserted else {
            return .failed("该服务正在停止。")
        }
        defer { stoppingServiceIDs.remove(service.id) }

        let outcome = await serviceStopper.forceStop(service)
        if outcome == .stopped {
            await refresh()
        }
        return outcome
    }
}

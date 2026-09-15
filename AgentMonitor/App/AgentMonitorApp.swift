import Darwin
import AppKit
import SwiftUI

@main
@MainActor
struct AgentMonitorApp: App {
    @State private var isMenuBarInserted = true
    @StateObject private var store: MonitorStore
    @StateObject private var temperatureStore: TemperatureStore
    @StateObject private var heavyProcessStore: HeavyProcessStore
    @StateObject private var tokenUsageStore: TokenUsageStore

    init() {
        LegacyUserDefaultsMigrator.migrateIfNeeded()
        NSApplication.shared.setActivationPolicy(.accessory)
        let dependencies = AppDependencies.make()
        _store = StateObject(wrappedValue: dependencies.store)
        _temperatureStore = StateObject(wrappedValue: dependencies.temperatureStore)
        _heavyProcessStore = StateObject(wrappedValue: dependencies.heavyProcessStore)
#if AGENT_MONITOR_QA
        _tokenUsageStore = StateObject(wrappedValue: TokenUsageStore(reader: TokenUsageQAFixtureReader()))
#else
        _tokenUsageStore = StateObject(wrappedValue: TokenUsageStore())
#endif
        // Hosted unit tests exercise injected stores. Do not also start the
        // real user's scheduled power controller and collectors in the host.
        let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isTestHost {
            dependencies.store.start()
            dependencies.temperatureStore.start()
            dependencies.heavyProcessStore.start()
        }
#if AGENT_MONITOR_QA
        QAWindowPresenter.present(store: dependencies.store)
#endif
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $isMenuBarInserted) {
            MenuBarContentView(
                store: store,
                tokenUsageStore: tokenUsageStore,
                temperatureStore: temperatureStore,
                processStore: heavyProcessStore
            )
        } label: {
            HStack(spacing: 5) {
                PowerModeMenuBarIcon(store: store)
                TemperatureMenuBarLabel(store: temperatureStore)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

#if AGENT_MONITOR_QA
@MainActor
private enum QAWindowPresenter {
    private static var window: NSWindow?

    static func present(store: MonitorStore) {
        DispatchQueue.main.async {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 730),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Agent Monitor QA"
            window.contentView = NSHostingView(rootView: TokenUsageQAView(store: store))
            window.isReleasedWhenClosed = false
            window.center()
            window.orderBack(nil)
            self.window = window
        }
    }
}
#endif

private enum AppDependencies {
    @MainActor
    struct Runtime {
        let store: MonitorStore
        let temperatureStore: TemperatureStore
        let heavyProcessStore: HeavyProcessStore
    }

    @MainActor
    static func make() -> Runtime {
        let ownerUID = getuid()
        let commandRunner = SystemCommandRunner()
        let processCollector = DarwinProcessCollector(ownerUID: ownerUID)
        let launchAgentDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let discoveryEngine = DiscoveryEngine(
            portCollector: LsofPortCollector(
                ownerUID: ownerUID,
                commandRunner: commandRunner
            ),
            processCollector: processCollector,
            launchAgentCollector: LaunchAgentCollector(
                directoryURL: launchAgentDirectory,
                commandRunner: commandRunner
            ),
            serviceGrouper: ServiceGrouper(projectResolver: ProjectResolver())
        )
        let serviceStopper = ServiceStopController(
            ownerUID: ownerUID,
            processCollector: processCollector,
            processSignaler: SystemProcessSignaler(),
            commandRunner: commandRunner
        )
#if AGENT_MONITOR_QA
        let store = MonitorStore(discoverer: discoveryEngine)
#else
        let serverModeController = ServerModeController(commandRunner: commandRunner)
        let store = MonitorStore(
            discoverer: discoveryEngine,
            serviceStopper: serviceStopper,
            serverModeController: serverModeController
        )
#endif
        let heavyProcessStore = HeavyProcessStore(
            collector: DarwinProcessResourceCollector(ownerUID: ownerUID),
            terminator: HeavyProcessTerminator(
                ownerUID: ownerUID,
                processCollector: processCollector
            )
        )
        return Runtime(
            store: store,
            temperatureStore: TemperatureStore(),
            heavyProcessStore: heavyProcessStore
        )
    }
}

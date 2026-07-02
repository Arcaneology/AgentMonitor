import Darwin
import AppKit
import SwiftUI

@main
@MainActor
struct AgentMonitorApp: App {
    @StateObject private var store: MonitorStore

    init() {
        let store = AppDependencies.makeMonitorStore()
        _store = StateObject(wrappedValue: store)
        store.start()
#if AGENT_MONITOR_QA
        QAWindowPresenter.present(store: store)
#endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(store: store)
        } label: {
            Label("\(store.portCount) · Server \(serverModeMenuText)", systemImage: serverModeMenuIcon)
                .accessibilityLabel("Agent Monitor，\(store.portCount) 个端口，Server \(serverModeMenuText)")
        }
        .menuBarExtraStyle(.window)

    }

    private var serverModeMenuText: String {
        switch store.serverModeSnapshot.state {
        case .enabled: "开"
        case .disabled: "关"
        case .unknown: "未知"
        }
    }

    private var serverModeMenuIcon: String {
        switch store.serverModeSnapshot.state {
        case .enabled: "server.rack"
        case .disabled: "network"
        case .unknown: "questionmark.circle"
        }
    }
}

#if AGENT_MONITOR_QA
@MainActor
private enum QAWindowPresenter {
    private static var window: NSWindow?

    static func present(store: MonitorStore) {
        DispatchQueue.main.async {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Agent Monitor QA"
            window.contentView = NSHostingView(rootView: MenuBarContentView(store: store))
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
    static func makeMonitorStore() -> MonitorStore {
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
        let serverModeController = ServerModeController(commandRunner: commandRunner)
        return MonitorStore(
            discoverer: discoveryEngine,
            serviceStopper: serviceStopper,
            serverModeController: serverModeController
        )
    }
}

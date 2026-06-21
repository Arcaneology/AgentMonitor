import SwiftUI

@main
struct AgentMonitorApp: App {
    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
        } label: {
            Label("Agent Monitor", systemImage: "network")
        }
        .menuBarExtraStyle(.window)
    }
}


// Isolated model of AgentMonitor f0e5d674 ServerModeController state handling.
// Does NOT call pmset, caffeinate, IOKit, or alter any system setting.
// A .disabled sample is injected; this does not prove AC changes cause that sample.

enum PowerMode: String { case normal, server, sleep }
enum ServerModeState: String { case enabled, disabled, unknown }

final class Settings {
    var requestedMode: PowerMode = .server
    var hasRequestedMode = true
}

final class Probe {
    let settingsStore = Settings()
    var caffeinateRunning = true
    var stopCount = 0

    // State-reconciliation branch copied from the reviewed source.
    func reconcileRequestedMode(with state: ServerModeState) {
        if settingsStore.requestedMode == .sleep, state != .enabled {
            settingsStore.requestedMode = .normal
            return
        }
        if !settingsStore.hasRequestedMode {
            if state == .enabled {
                settingsStore.requestedMode = .server
            }
            return
        }
        if settingsStore.requestedMode == .server, state == .disabled {
            settingsStore.requestedMode = .normal
        }
    }

    // Models only the successful start/stop branches of refresh().
    func refresh(observed state: ServerModeState) {
        reconcileRequestedMode(with: state)
        if settingsStore.requestedMode == .server {
            caffeinateRunning = true
        } else if caffeinateRunning {
            caffeinateRunning = false
            stopCount += 1
        }
    }
}

let transient = Probe()
for state in [ServerModeState.enabled, .disabled, .enabled] {
    transient.refresh(observed: state)
    print("observed=\(state.rawValue), requested=\(transient.settingsStore.requestedMode.rawValue), caffeinate=\(transient.caffeinateRunning)")
}
precondition(transient.settingsStore.requestedMode == .normal)
precondition(!transient.caffeinateRunning)
precondition(transient.stopCount == 1)
print("PASS: one injected disabled sample clears intent and stops caffeinate; the later enabled sample does not restore it.")

let unknown = Probe()
unknown.refresh(observed: .unknown)
precondition(unknown.settingsStore.requestedMode == .server)
precondition(unknown.caffeinateRunning)
print("PASS: unknown alone does not trigger this branch.")
print("NOT TESTED: real AC reconnect, display blackout, IOKit readings, or the full macOS app.")

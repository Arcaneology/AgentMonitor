// Reduced reproduction of MonitorStore.setPowerMode/applyPowerMode from
// Arcaneology/AgentMonitor @ f0e5d674006c7035e4cedb8bd06d624fc24fb0ab.
// UI, published snapshots and real system commands are intentionally omitted.
// This verifies the concurrency gate, NOT the macOS app or menu-bar behavior.
import Foundation

enum PowerMode: Sendable { case normal, server }

@MainActor
final class ProbeController {
    private(set) var inFlight = 0
    private(set) var maximumInFlight = 0
    func setMode(_ mode: PowerMode) async {
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        try? await Task.sleep(for: .milliseconds(60))
        inFlight -= 1
    }
}

@MainActor
final class ProbeStore {
    private var isChangingServerMode = false
    private var pendingPowerMode: PowerMode?
    private let controller: ProbeController
    private let fixGate: Bool

    init(controller: ProbeController, fixGate: Bool) {
        self.controller = controller
        self.fixGate = fixGate
    }

    func setPowerMode(_ mode: PowerMode) async {
        // Production previewRequestedMode only updates the UI snapshot.
        if isChangingServerMode {
            pendingPowerMode = mode
            while isChangingServerMode {
                await Task.yield()
            }
            return
        }
        // This assignment is missing from the repository's async entry point.
        if fixGate { isChangingServerMode = true }
        await applyPowerMode(mode)
    }

    private func applyPowerMode(_ mode: PowerMode) async {
        defer { isChangingServerMode = false }
        await controller.setMode(mode)
        while let pending = pendingPowerMode {
            pendingPowerMode = nil
            await controller.setMode(pending)
        }
    }
}

@main
struct RaceReproduction {
    @MainActor
    static func main() async {
        for fixGate in [false, true] {
            let controller = ProbeController()
            let store = ProbeStore(controller: controller, fixGate: fixGate)
            let first = Task { await store.setPowerMode(.server) }
            let second = Task { await store.setPowerMode(.normal) }
            await first.value
            await second.value
            let expected = fixGate ? 1 : 2
            precondition(controller.maximumInFlight == expected)
            print("\(fixGate ? "With missing flag restored" : "Repository gating logic"): maximum concurrent setMode calls = \(controller.maximumInFlight)")
        }
    }
}

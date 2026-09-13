import Darwin
import Foundation

struct ProcessResourceSnapshot: Equatable, Sendable {
    let pid: Int32
    let startTime: Date
    let ownerUID: UInt32
    let name: String
    let executablePath: String
    let cpuTime: TimeInterval
    let memoryBytes: UInt64
    let sampledAt: Date

    var identity: ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: startTime)
    }
}

struct HeavyProcess: Identifiable, Equatable, Sendable {
    let name: String
    let executablePath: String
    let members: [ProcessIdentity]
    let cpuPercent: Double
    let memoryBytes: UInt64

    var id: String { name }
    var processCount: Int { members.count }
    var pid: Int32 { members.first?.pid ?? 0 }
    var startTime: Date { members.first?.startTime ?? .distantPast }

    var identity: ProcessIdentity {
        members.first ?? ProcessIdentity(pid: 0, startTime: .distantPast)
    }
}

struct GroupCPUSample: Equatable, Sendable {
    let date: Date
    let cpuPercent: Double
}

enum HeavyProcessAggregator {
    static let averagingWindow: TimeInterval = 15

    /// Every application group owned by the monitored user is returned, sorted
    /// by CPU then memory. The panel
    /// bounds the rendered height instead of dropping rows, so a machine with
    /// hundreds of helpers stays fully inspectable.
    static func ranked(
        current: [ProcessResourceSnapshot],
        previous: [ProcessIdentity: ProcessResourceSnapshot],
        history: [String: [GroupCPUSample]],
        excludingPID: Int32,
        now: Date
    ) -> (processes: [HeavyProcess], history: [String: [GroupCPUSample]]) {
        let groups = grouped(
            current: current,
            previous: previous,
            excludingPID: excludingPID,
            now: now
        )
        var nextHistory: [String: [GroupCPUSample]] = [:]
        let processes = groups.map { group -> HeavyProcess in
            var samples = history[group.name, default: []]
            samples.append(GroupCPUSample(date: now, cpuPercent: group.instantCPU))
            samples = samples.filter { now.timeIntervalSince($0.date) <= averagingWindow }
            nextHistory[group.name] = samples
            let averageCPU = samples.map(\.cpuPercent).reduce(0, +) / Double(samples.count)
            return HeavyProcess(
                name: group.name,
                executablePath: group.executablePath,
                members: group.members,
                cpuPercent: averageCPU,
                memoryBytes: group.memoryBytes
            )
        }
        .sorted { lhs, rhs in
            if lhs.cpuPercent != rhs.cpuPercent {
                return lhs.cpuPercent > rhs.cpuPercent
            }
            return lhs.memoryBytes > rhs.memoryBytes
        }

        return (processes, nextHistory)
    }

    static func applicationGroup(name: String, executablePath: String) -> String {
        if let appName = firstAppBundleName(in: executablePath) {
            return strippingHelperSuffix(appName)
        }
        return strippingHelperSuffix(name)
    }

    static func firstAppBundleName(in path: String) -> String? {
        for component in path.split(separator: "/") where component.hasSuffix(".app") {
            return String(component.dropLast(4))
        }
        return nil
    }

    static func strippingHelperSuffix(_ name: String) -> String {
        guard let range = name.range(of: " Helper") else { return name }
        let stripped = String(name[..<range.lowerBound])
        return stripped.isEmpty ? name : stripped
    }

    static func cpuPercent(
        for snapshot: ProcessResourceSnapshot,
        previous: ProcessResourceSnapshot?,
        now: Date
    ) -> Double {
        guard let previous else { return 0 }
        let elapsed = now.timeIntervalSince(previous.sampledAt)
        guard elapsed > 0 else { return 0 }
        let cpuDelta = max(0, snapshot.cpuTime - previous.cpuTime)
        return min(cpuDelta / elapsed * 100, 800)
    }

    private struct InstantGroup {
        let name: String
        let executablePath: String
        var members: [ProcessIdentity]
        var instantCPU: Double
        var memoryBytes: UInt64
    }

    private static func grouped(
        current: [ProcessResourceSnapshot],
        previous: [ProcessIdentity: ProcessResourceSnapshot],
        excludingPID: Int32,
        now: Date
    ) -> [InstantGroup] {
        var groups: [String: InstantGroup] = [:]
        for snapshot in current where snapshot.pid != excludingPID && snapshot.pid > 1 {
            let name = applicationGroup(name: snapshot.name, executablePath: snapshot.executablePath)
            let cpu = cpuPercent(for: snapshot, previous: previous[snapshot.identity], now: now)
            if var group = groups[name] {
                group.members.append(snapshot.identity)
                group.instantCPU += cpu
                group.memoryBytes += snapshot.memoryBytes
                groups[name] = group
            } else {
                groups[name] = InstantGroup(
                    name: name,
                    executablePath: snapshot.executablePath,
                    members: [snapshot.identity],
                    instantCPU: cpu,
                    memoryBytes: snapshot.memoryBytes
                )
            }
        }
        return Array(groups.values)
    }
}

protocol ProcessResourceCollecting: Sendable {
    func collect(now: Date) -> [ProcessResourceSnapshot]
}

struct DarwinProcessResourceCollector: ProcessResourceCollecting {
    private let ownerUID: UInt32

    init(ownerUID: UInt32) {
        self.ownerUID = ownerUID
    }

    func collect(now: Date) -> [ProcessResourceSnapshot] {
        pidList().compactMap { snapshot(for: $0, now: now) }
    }

    private func snapshot(for pid: Int32, now: Date) -> ProcessResourceSnapshot? {
        guard
            let bsdInfo = bsdInfo(for: pid),
            bsdInfo.pbi_uid == ownerUID
        else {
            return nil
        }

        let startTime = Date(
            timeIntervalSince1970: TimeInterval(bsdInfo.pbi_start_tvsec)
                + TimeInterval(bsdInfo.pbi_start_tvusec) / 1_000_000
        )
        let executablePath = executablePath(for: pid, bsdInfo: bsdInfo)
        return ProcessResourceSnapshot(
            pid: pid,
            startTime: startTime,
            ownerUID: bsdInfo.pbi_uid,
            name: displayName(for: executablePath, bsdInfo: bsdInfo),
            executablePath: executablePath,
            cpuTime: cpuTime(for: pid),
            memoryBytes: memoryUsage(for: pid),
            sampledAt: now
        )
    }

    private func pidList() -> [Int32] {
        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytesNeeded > 0 else { return [] }

        let capacity = Int(bytesNeeded) / MemoryLayout<Int32>.size + 16
        var pids = [Int32](repeating: 0, count: capacity)
        let filledBytes = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<Int32>.size)
            )
        }
        guard filledBytes > 0 else { return [] }
        let count = Int(filledBytes) / MemoryLayout<Int32>.size
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }

    private func bsdInfo(for pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let actualSize = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(expectedSize))
        }
        return actualSize == expectedSize ? info : nil
    }

    private func executablePath(for pid: Int32, bsdInfo: proc_bsdinfo) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        if length > 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }

        var name = bsdInfo.pbi_name
        let nameCapacity = MemoryLayout.size(ofValue: name)
        return withUnsafePointer(to: &name) {
            $0.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
                String(cString: $0)
            }
        }
    }

    private func displayName(for executablePath: String, bsdInfo: proc_bsdinfo) -> String {
        let lastComponent = URL(fileURLWithPath: executablePath).lastPathComponent
        if !lastComponent.isEmpty, lastComponent != "/" {
            return lastComponent
        }

        var name = bsdInfo.pbi_name
        let nameCapacity = MemoryLayout.size(ofValue: name)
        return withUnsafePointer(to: &name) {
            $0.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
                String(cString: $0)
            }
        }
    }

    private func cpuTime(for pid: Int32) -> TimeInterval {
        var info = proc_taskinfo()
        let expectedSize = MemoryLayout<proc_taskinfo>.size
        let actualSize = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, Int32(expectedSize))
        }
        guard actualSize == expectedSize else { return 0 }
        return Double(info.pti_total_user + info.pti_total_system) / 1_000_000_000
    }

    private func memoryUsage(for pid: Int32) -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return 0 }
        return info.ri_phys_footprint > 0 ? info.ri_phys_footprint : info.ri_resident_size
    }
}

@MainActor
protocol HeavyProcessTerminating: AnyObject {
    func terminate(_ process: HeavyProcess) async -> StopOutcome
    func forceTerminate(_ process: HeavyProcess) async -> StopOutcome
}

@MainActor
final class HeavyProcessTerminator: HeavyProcessTerminating {
    private let ownerUID: UInt32
    private let processCollector: any ProcessCollecting
    private let processSignaler: any ProcessSignaling
    private let waitTimeout: TimeInterval
    private let selfPID: Int32

    init(
        ownerUID: UInt32,
        processCollector: any ProcessCollecting,
        processSignaler: any ProcessSignaling = SystemProcessSignaler(),
        waitTimeout: TimeInterval = 2,
        selfPID: Int32 = getpid()
    ) {
        self.ownerUID = ownerUID
        self.processCollector = processCollector
        self.processSignaler = processSignaler
        self.waitTimeout = waitTimeout
        self.selfPID = selfPID
    }

    func terminate(_ process: HeavyProcess) async -> StopOutcome {
        await signal(process, signal: SIGTERM, force: false)
    }

    func forceTerminate(_ process: HeavyProcess) async -> StopOutcome {
        await signal(process, signal: SIGKILL, force: true)
    }

    private func signal(_ process: HeavyProcess, signal: Int32, force: Bool) async -> StopOutcome {
        let targets = validatedMembers(process)
        guard !targets.isEmpty else {
            return .failed("进程已退出或身份已变化。")
        }

        do {
            for current in targets {
                try processSignaler.send(signal: signal, to: current.id.pid)
            }
        } catch {
            let name = signal == SIGKILL ? "SIGKILL" : "SIGTERM"
            return .failed("发送 \(name) 失败：\(error)")
        }
        return await waitForExit(targets, force: force)
    }

    private func validatedMembers(_ process: HeavyProcess) -> [MonitoredProcess] {
        process.members.compactMap { identity in
            guard identity.pid != selfPID else { return nil }
            guard
                let current = processCollector.collect(pid: identity.pid),
                current.ownerUID == ownerUID,
                current.id == identity
            else {
                return nil
            }
            return current
        }
    }

    private func waitForExit(_ processes: [MonitoredProcess], force: Bool) async -> StopOutcome {
        let deadline = Date().addingTimeInterval(waitTimeout)
        while Date() < deadline {
            if alivePIDs(processes).isEmpty {
                return .stopped
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let remaining = alivePIDs(processes)
        if remaining.isEmpty {
            return .stopped
        }
        return force
            ? .failed("进程仍在运行：\(remaining.map(String.init).joined(separator: ", "))")
            : .requiresForce(remaining)
    }

    private func alivePIDs(_ processes: [MonitoredProcess]) -> [Int32] {
        processes.compactMap { process in
            processCollector.collect(pid: process.id.pid)?.id == process.id ? process.id.pid : nil
        }
    }
}

@MainActor
final class HeavyProcessStore: ObservableObject {
    static let refreshInterval: Duration = .seconds(2)

    @Published private(set) var processes: [HeavyProcess] = []
    @Published private(set) var terminatingIDs: Set<String> = []

    private let collector: any ProcessResourceCollecting
    private let terminator: (any HeavyProcessTerminating)?
    private let excludingPID: Int32
    private var previous: [ProcessIdentity: ProcessResourceSnapshot] = [:]
    private var cpuHistory: [String: [GroupCPUSample]] = [:]
    private var refreshTask: Task<Void, Never>?

    init(
        collector: any ProcessResourceCollecting,
        terminator: (any HeavyProcessTerminating)? = nil,
        excludingPID: Int32 = getpid()
    ) {
        self.collector = collector
        self.terminator = terminator
        self.excludingPID = excludingPID
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                do {
                    try await Task.sleep(for: Self.refreshInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh(now: Date = Date()) {
        let current = collector.collect(now: now)
        let ranked = HeavyProcessAggregator.ranked(
            current: current,
            previous: previous,
            history: cpuHistory,
            excludingPID: excludingPID,
            now: now
        )
        processes = ranked.processes
        cpuHistory = ranked.history
        previous = Dictionary(uniqueKeysWithValues: current.map { ($0.identity, $0) })
    }

    func isTerminating(_ process: HeavyProcess) -> Bool {
        terminatingIDs.contains(process.id)
    }

    func terminate(_ process: HeavyProcess) async -> StopOutcome {
        await runTermination(process, force: false)
    }

    func forceTerminate(_ process: HeavyProcess) async -> StopOutcome {
        await runTermination(process, force: true)
    }

    private func runTermination(_ process: HeavyProcess, force: Bool) async -> StopOutcome {
        guard let terminator else {
            return .failed("关闭进程功能尚未配置。")
        }
        guard terminatingIDs.insert(process.id).inserted else {
            return .failed("该进程正在关闭。")
        }
        defer { terminatingIDs.remove(process.id) }

        let outcome = force
            ? await terminator.forceTerminate(process)
            : await terminator.terminate(process)
        if outcome == .stopped {
            refresh()
        }
        return outcome
    }
}

import Darwin
import Foundation
import IOKit

enum ServerModeState: Equatable, Sendable {
    case enabled
    case disabled
    case unknown
}

enum PowerMode: String, CaseIterable, Codable, Equatable, Sendable {
    case normal
    case server
    case sleep

    var title: String {
        switch self {
        case .normal: "Normal"
        case .server: "Server"
        case .sleep: "Sleep"
        }
    }
}

enum PowerModeStatus: Equatable, Sendable {
    case normal
    case server
    case sleep
    case unknown
}

struct ServerModeSnapshot: Equatable, Sendable {
    var state: ServerModeState
    var requestedMode: PowerMode
    var effectiveMode: PowerModeStatus
    var isCaffeinateRunning: Bool
    var schedule: PowerModeSchedule
    var message: String?

    static let unknown = ServerModeSnapshot(
        state: .unknown,
        requestedMode: .normal,
        effectiveMode: .unknown,
        isCaffeinateRunning: false,
        schedule: .default,
        message: nil
    )

    var isEnabled: Bool { state == .enabled }

    var displayedPowerMode: PowerMode {
        switch effectiveMode {
        case .server: .server
        case .sleep: .sleep
        case .normal: .normal
        case .unknown: requestedMode == .sleep ? .normal : requestedMode
        }
    }

    func withMessage(_ message: String?) -> ServerModeSnapshot {
        ServerModeSnapshot(
            state: state,
            requestedMode: requestedMode,
            effectiveMode: effectiveMode,
            isCaffeinateRunning: isCaffeinateRunning,
            schedule: schedule,
            message: message
        )
    }
}

enum PowerModeScheduleRuleID: String, Codable, Equatable, Sendable {
    case nightlySleep
    case workdayServer
}

struct PowerModeScheduleRule: Codable, Equatable, Sendable {
    var id: PowerModeScheduleRuleID
    var mode: PowerMode
    var hour: Int
    var minute: Int
    var weekdays: Set<Int>
    var isEnabled: Bool

    var timeText: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

struct PowerModeSchedule: Codable, Equatable, Sendable {
    var nightlySleep: PowerModeScheduleRule
    var workdayServer: PowerModeScheduleRule

    static let `default` = PowerModeSchedule(
        nightlySleep: PowerModeScheduleRule(
            id: .nightlySleep,
            mode: .sleep,
            hour: 2,
            minute: 0,
            weekdays: Set(1...7),
            isEnabled: false
        ),
        workdayServer: PowerModeScheduleRule(
            id: .workdayServer,
            mode: .server,
            hour: 8,
            minute: 0,
            weekdays: Set(2...6),
            isEnabled: false
        )
    )

    var enabledRules: [PowerModeScheduleRule] {
        [nightlySleep, workdayServer].filter(\.isEnabled)
    }

    func latestEvent(before date: Date, calendar: Calendar) -> PowerModeScheduleEvent? {
        let startOfToday = calendar.startOfDay(for: date)
        return enabledRules
            .flatMap { rule in
                (0...7).compactMap { offset -> PowerModeScheduleEvent? in
                    guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday) else {
                        return nil
                    }
                    let weekday = calendar.component(.weekday, from: day)
                    guard rule.weekdays.contains(weekday) else { return nil }
                    guard let eventDate = calendar.date(bySettingHour: rule.hour, minute: rule.minute, second: 0, of: day) else {
                        return nil
                    }
                    guard eventDate <= date else { return nil }
                    return PowerModeScheduleEvent(ruleID: rule.id, mode: rule.mode, date: eventDate)
                }
            }
            .max { $0.date < $1.date }
    }

    func nextEvent(after date: Date, calendar: Calendar) -> PowerModeScheduleEvent? {
        let startOfToday = calendar.startOfDay(for: date)
        return enabledRules
            .flatMap { rule in
                (0...7).compactMap { offset -> PowerModeScheduleEvent? in
                    guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday) else {
                        return nil
                    }
                    let weekday = calendar.component(.weekday, from: day)
                    guard rule.weekdays.contains(weekday) else { return nil }
                    guard let eventDate = calendar.date(bySettingHour: rule.hour, minute: rule.minute, second: 0, of: day) else {
                        return nil
                    }
                    guard eventDate > date else { return nil }
                    return PowerModeScheduleEvent(ruleID: rule.id, mode: rule.mode, date: eventDate)
                }
            }
            .min { $0.date < $1.date }
    }

    func updatingRule(_ rule: PowerModeScheduleRule) -> PowerModeSchedule {
        var copy = self
        switch rule.id {
        case .nightlySleep:
            copy.nightlySleep = rule
        case .workdayServer:
            copy.workdayServer = rule
        }
        return copy
    }
}

struct PowerModeScheduleEvent: Equatable, Sendable {
    var ruleID: PowerModeScheduleRuleID
    var mode: PowerMode
    var date: Date

    var id: String {
        "\(ruleID.rawValue)-\(Int(date.timeIntervalSince1970))"
    }
}

@MainActor
protocol PowerModeSettingsStoring: AnyObject {
    var requestedMode: PowerMode { get set }
    var hasRequestedMode: Bool { get }
    var schedule: PowerModeSchedule { get set }
    var lastAppliedScheduleEventID: String? { get set }
}

protocol SleepDisabledReading: Sendable {
    func read() -> ServerModeState
}

@MainActor
protocol ServerModeControlling: AnyObject {
    func refresh() async -> ServerModeSnapshot
    func setEnabled(_ enabled: Bool) async -> ServerModeSnapshot
    func setMode(_ mode: PowerMode) async -> ServerModeSnapshot
    func setSchedule(_ schedule: PowerModeSchedule, now: Date) async -> ServerModeSnapshot
    func reconcileSchedule(now: Date) async -> ServerModeSnapshot?
}

@MainActor
protocol CaffeinateManaging: AnyObject {
    var isRunning: Bool { get }

    func start(appPID: Int32) throws
    func stop()
}

@MainActor
final class ServerModeController: ServerModeControlling {
    private let commandRunner: any CommandRunning
    private let caffeinateManager: any CaffeinateManaging
    private let settingsStore: any PowerModeSettingsStoring
    private let sleepDisabledReader: any SleepDisabledReading
    private let appPID: Int32
    private let currentUser: String
    private let calendar: Calendar
    private let sleepDisabledPollAttempts: Int
    private let sleepDisabledPollDelay: Duration

    init(
        commandRunner: any CommandRunning,
        caffeinateManager: any CaffeinateManaging = SystemCaffeinateManager(),
        settingsStore: any PowerModeSettingsStoring = UserDefaultsPowerModeSettingsStore(),
        sleepDisabledReader: any SleepDisabledReading = IOKitSleepDisabledReader(),
        appPID: Int32 = getpid(),
        currentUser: String = NSUserName(),
        calendar: Calendar = .current,
        sleepDisabledPollAttempts: Int = 8,
        sleepDisabledPollDelay: Duration = .milliseconds(150)
    ) {
        self.commandRunner = commandRunner
        self.caffeinateManager = caffeinateManager
        self.settingsStore = settingsStore
        self.sleepDisabledReader = sleepDisabledReader
        self.appPID = appPID
        self.currentUser = currentUser
        self.calendar = calendar
        self.sleepDisabledPollAttempts = max(1, sleepDisabledPollAttempts)
        self.sleepDisabledPollDelay = sleepDisabledPollDelay
    }

    func refresh() async -> ServerModeSnapshot {
        let state = sleepDisabledReader.read()
        reconcileRequestedMode(with: state)

        var caffeinateMessage: String?
        if settingsStore.requestedMode == .server {
            do {
                try ensureCaffeinateRunning()
            } catch {
                caffeinateMessage = "caffeinate 启动失败：\(error.localizedDescription)"
            }
        } else if caffeinateManager.isRunning {
            caffeinateManager.stop()
        }

        return makeSnapshot(
            state: state,
            message: caffeinateMessage ?? mismatchMessage(state: state)
        )
    }

    func setEnabled(_ enabled: Bool) async -> ServerModeSnapshot {
        await setMode(enabled ? .server : .normal)
    }

    func setMode(_ mode: PowerMode) async -> ServerModeSnapshot {
        settingsStore.requestedMode = mode

        do {
            switch mode {
            case .server:
                try await setSleepDisabled(true)
                await waitForSleepDisabled(.enabled)
            case .normal:
                try await setSleepDisabled(false)
                caffeinateManager.stop()
                await waitForSleepDisabled(.disabled)
            case .sleep:
                try await setSleepDisabled(false)
                caffeinateManager.stop()
                await waitForSleepDisabled(.disabled)
                try await runSleepNow()
                settingsStore.requestedMode = .normal
            }
        } catch {
            if mode == .sleep {
                settingsStore.requestedMode = .normal
            }
            return (await refresh()).withMessage("切换 \(mode.title) 失败：\(errorMessage(from: error))")
        }

        let snapshot = await refresh()
        guard snapshot.state != .unknown else { return snapshot }

        if mode == .server && !snapshot.isEnabled {
            settingsStore.requestedMode = .normal
            return (await refresh()).withMessage("pmset 已执行，但系统未进入 Server。")
        }
        if mode != .server && snapshot.isEnabled {
            return snapshot.withMessage("pmset 已执行，但系统仍处于 Server。")
        }
        return snapshot
    }

    func setSchedule(_ schedule: PowerModeSchedule, now: Date) async -> ServerModeSnapshot {
        settingsStore.schedule = schedule
        settingsStore.lastAppliedScheduleEventID = schedule.latestEvent(before: now, calendar: calendar)?.id
        return await refresh()
    }

    func reconcileSchedule(now: Date) async -> ServerModeSnapshot? {
        guard let event = settingsStore.schedule.latestEvent(before: now, calendar: calendar) else {
            return nil
        }
        guard event.id != settingsStore.lastAppliedScheduleEventID else {
            return nil
        }

        settingsStore.lastAppliedScheduleEventID = event.id
        let snapshot = await setMode(event.mode)
        return snapshot.withMessage("\(event.mode.title) 已按定时规则切换。")
    }

    private func ensureCaffeinateRunning() throws {
        guard !caffeinateManager.isRunning else { return }
        try caffeinateManager.start(appPID: appPID)
    }

    private func reconcileRequestedMode(with state: ServerModeState) {
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

    private func waitForSleepDisabled(_ expected: ServerModeState) async {
        for attempt in 0..<sleepDisabledPollAttempts {
            if sleepDisabledReader.read() == expected {
                return
            }
            if attempt + 1 < sleepDisabledPollAttempts {
                try? await Task.sleep(for: sleepDisabledPollDelay)
            }
        }
    }

    private func mismatchMessage(state: ServerModeState) -> String? {
        switch state {
        case .unknown:
            return "无法确认 SleepDisabled 状态。"
        case .enabled, .disabled:
            return nil
        }
    }

    private func makeSnapshot(state: ServerModeState, message: String?) -> ServerModeSnapshot {
        ServerModeSnapshot(
            state: state,
            requestedMode: settingsStore.requestedMode,
            effectiveMode: effectiveMode(state: state),
            isCaffeinateRunning: caffeinateManager.isRunning,
            schedule: settingsStore.schedule,
            message: message
        )
    }

    private func effectiveMode(state: ServerModeState) -> PowerModeStatus {
        if settingsStore.requestedMode == .sleep {
            return .sleep
        }
        switch state {
        case .enabled: return .server
        case .disabled: return .normal
        case .unknown: return .unknown
        }
    }

    private func setSleepDisabled(_ enabled: Bool) async throws {
        let value = enabled ? "1" : "0"
        let firstAttempt = try await runSudoPMSet(["disablesleep", value])
        if firstAttempt.terminationStatus == 0 {
            return
        }

        try await installSudoersRule()

        let retry = try await runSudoPMSet(["disablesleep", value])
        guard retry.terminationStatus == 0 else {
            throw ServerModeError.commandFailed(retry.errorText)
        }
    }

    private func runSleepNow() async throws {
        let firstAttempt = try await runSudoPMSet(["sleepnow"])
        if firstAttempt.terminationStatus == 0 {
            return
        }

        try await installSudoersRule()

        let retry = try await runSudoPMSet(["sleepnow"])
        guard retry.terminationStatus == 0 else {
            throw ServerModeError.commandFailed(retry.errorText)
        }
    }

    private func runSudoPMSet(_ pmsetArguments: [String]) async throws -> CommandResult {
        try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/sudo"),
            arguments: ["-n", "/usr/bin/pmset"] + pmsetArguments,
            timeout: 5
        )
    }

    private func installSudoersRule() async throws {
        let shellCommand = try Self.sudoersInstallShellCommand(for: currentUser)
        let script = "do shell script \(Self.appleScriptLiteral(shellCommand)) with administrator privileges"
        let result = try await commandRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script],
            timeout: 60
        )
        guard result.terminationStatus == 0 else {
            throw ServerModeError.commandFailed(result.errorText)
        }
    }

    static func sleepDisabledState(from output: String) -> ServerModeState {
        for line in output.split(separator: "\n") where line.contains("\"SleepDisabled\"") {
            if line.contains("Yes") { return .enabled }
            if line.contains("No") { return .disabled }
        }
        return .unknown
    }

    static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func sudoersInstallShellCommand(for user: String) throws -> String {
        guard isSupportedSudoersUser(user) else {
            throw ServerModeError.unsupportedUser(user)
        }

        let rule = """
        # Installed by Agent Monitor. Allows only Agent Monitor power mode toggles.
        \(user) ALL=(root) NOPASSWD: /usr/bin/pmset disablesleep 0, /usr/bin/pmset disablesleep 1, /usr/bin/pmset sleepnow
        """
        let sudoersPath = "/private/etc/sudoers.d/agentmonitor-server-mode"
        return """
        umask 022
        tmp=$(/usr/bin/mktemp /private/tmp/agentmonitor-sudoers.XXXXXX) || exit 1
        /bin/cat > "$tmp" <<'AGENT_MONITOR_SUDOERS'
        \(rule)
        AGENT_MONITOR_SUDOERS
        /bin/chmod 0440 "$tmp"
        /usr/sbin/chown root:wheel "$tmp"
        /usr/sbin/visudo -cf "$tmp" || { /bin/rm -f "$tmp"; exit 1; }
        /bin/mv "$tmp" \(shellLiteral(sudoersPath))
        """
    }

    private static func isSupportedSudoersUser(_ user: String) -> Bool {
        guard !user.isEmpty else { return false }
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return user.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    private static func shellLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func errorMessage(from error: Error) -> String {
        if let error = error as? ServerModeError {
            return error.message
        }
        return error.localizedDescription
    }
}

@MainActor
final class SystemCaffeinateManager: CaffeinateManaging {
    private var process: Process?

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    func start(appPID: Int32) throws {
        guard !isRunning else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-i", "-m", "-s", "-w", String(appPID)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
    }

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
    }
}

private enum ServerModeError: Error {
    case commandFailed(String)
    case unsupportedUser(String)

    var message: String {
        switch self {
        case .commandFailed(let text):
            return text.isEmpty ? "命令执行失败。" : text
        case .unsupportedUser(let user):
            return "当前用户名不适合写入 sudoers：\(user)"
        }
    }
}

@MainActor
final class UserDefaultsPowerModeSettingsStore: PowerModeSettingsStoring {
    private enum Key {
        static let requestedMode = "powerMode.requestedMode"
        static let schedule = "powerMode.schedule"
        static let lastAppliedScheduleEventID = "powerMode.lastAppliedScheduleEventID"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var requestedMode: PowerMode {
        get {
            guard let rawValue = userDefaults.string(forKey: Key.requestedMode) else {
                return .normal
            }
            return PowerMode(rawValue: rawValue) ?? .normal
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: Key.requestedMode)
        }
    }

    var hasRequestedMode: Bool {
        userDefaults.object(forKey: Key.requestedMode) != nil
    }

    var schedule: PowerModeSchedule {
        get {
            guard let data = userDefaults.data(forKey: Key.schedule) else {
                return .default
            }
            return (try? JSONDecoder().decode(PowerModeSchedule.self, from: data)) ?? .default
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            userDefaults.set(data, forKey: Key.schedule)
        }
    }

    var lastAppliedScheduleEventID: String? {
        get {
            userDefaults.string(forKey: Key.lastAppliedScheduleEventID)
        }
        set {
            userDefaults.set(newValue, forKey: Key.lastAppliedScheduleEventID)
        }
    }
}

struct IOKitSleepDisabledReader: SleepDisabledReading {
    func read() -> ServerModeState {
        guard let matching = IOServiceMatching("IOPMrootDomain") else {
            return .unknown
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { return .unknown }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return .unknown }
        defer { IOObjectRelease(service) }

        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service,
            "SleepDisabled" as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return .unknown
        }

        return Self.state(from: unmanaged.takeRetainedValue())
    }

    static func state(from value: CFTypeRef) -> ServerModeState {
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self)) ? .enabled : .disabled
        }
        if CFGetTypeID(value) == CFNumberGetTypeID() {
            var number: Int = 0
            let converted = CFNumberGetValue(
                unsafeBitCast(value, to: CFNumber.self),
                .intType,
                &number
            )
            guard converted else { return .unknown }
            return number != 0 ? .enabled : .disabled
        }
        return .unknown
    }
}

private extension CommandResult {
    var errorText: String {
        String(decoding: standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

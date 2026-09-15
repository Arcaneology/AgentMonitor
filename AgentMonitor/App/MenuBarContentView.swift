import AppKit
import SwiftUI

extension View {
    func monitorCard() -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.65),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
    }
}

/// Trailing chevron shared by every module card. A collapsed card keeps only
/// its first row: the title, key figure and switch controls.
struct ModuleCollapseButton: View {
    @Binding var isExpanded: Bool
    let title: String

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isExpanded.toggle()
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? L("收起\(title)", "Collapse \(title)") : L("展开\(title)", "Expand \(title)"))
    }
}

/// Card title that folds the card when clicked, matching the chevron.
struct ModuleTitleToggle: View {
    @Binding var isExpanded: Bool
    let title: String
    let systemImage: String

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isExpanded.toggle()
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? L("收起\(title)", "Collapse \(title)") : L("展开\(title)", "Expand \(title)"))
    }
}

@MainActor
struct MenuBarContentView: View {
    @ObservedObject var store: MonitorStore
    @StateObject private var tokenUsageStore: TokenUsageStore
    @State private var serviceToStop: MonitoredService?
    @State private var actionPrompt: ActionPrompt?
    @State private var sortOrder: ServiceSortOrder = .nameAscending
    @State private var tokenUsageRange: TokenUsageRange = .today
    @State private var isServiceMonitorExpanded: Bool
    @State private var isPowerModeExpanded = true
    @State private var measuredContentHeight: CGFloat?
    private let temperatureStore: TemperatureStore?
    private let processStore: HeavyProcessStore?
    @State private var monitorTab: MonitorTab = .services
    @State private var isAboutPresented = false
    @AppStorage(AppLanguage.storageKey) private var languageRawValue = AppLanguage.systemDefault.rawValue

    /// The panel stacks four module cards (power mode, token usage, temperature
    /// and services). The viewport is sized so the stack is readable without
    /// constant scrolling; the expanded service list adds one more card height.
    /// Both values are caps: folded cards shrink the viewport to fit.
    private static let collapsedContentHeight: CGFloat = 960
    private static let expandedContentHeight: CGFloat = 1200

    private enum MonitorTab: String, CaseIterable {
        case ports = "端口"
        case services = "服务"
        case processes = "进程"

        var title: String {
            switch self {
            case .ports: L("端口", "Ports")
            case .services: L("服务", "Services")
            case .processes: L("进程", "Processes")
            }
        }
    }

    /// Tabs the panel offers. The port list keeps its view and data source but
    /// is intentionally not reachable from the UI for now.
    private static let visibleMonitorTabs: [MonitorTab] = [.services, .processes]

    init(
        store: MonitorStore,
        serviceToStop: MonitoredService? = nil,
        tokenUsageStore: TokenUsageStore = TokenUsageStore(),
        isServiceMonitorExpanded: Bool = false,
        temperatureStore: TemperatureStore? = nil,
        processStore: HeavyProcessStore? = nil
    ) {
        self.store = store
        self.temperatureStore = temperatureStore
        self.processStore = processStore
        _serviceToStop = State(initialValue: serviceToStop)
        _tokenUsageStore = StateObject(wrappedValue: tokenUsageStore)
        _isServiceMonitorExpanded = State(initialValue: isServiceMonitorExpanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            // Strings are resolved when views are built, so a language switch
            // rebuilds the module stack. Collapse state lives here and survives.
            content
                .id(languageRawValue)

            if let serviceToStop {
                Divider()
                stopConfirmation(for: serviceToStop)
            } else if let actionPrompt {
                Divider()
                actionPanel(for: actionPrompt)
            }

            Divider()
            footer
        }
        .frame(width: 420)
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                Image("AppMark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .accessibilityHidden(true)
                Text(verbatim: "Agent Monitor")
                    .font(.headline)

                Spacer()
            }

        }
        .padding(14)
    }

    private var powerModeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                ModuleTitleToggle(isExpanded: $isPowerModeExpanded, title: L("电源模式", "Power Mode"), systemImage: "powerplug")

                Spacer()

                Picker(
                    L("电源模式", "Power Mode"),
                    selection: Binding(
                        get: { store.serverModeSnapshot.displayedPowerMode },
                        set: { mode in store.selectPowerMode(mode) }
                    )
                ) {
                    Text("Normal").tag(PowerMode.normal)
                    Text("Server").tag(PowerMode.server)
                    Text("Sleep").tag(PowerMode.sleep)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 200)
                .disabled(store.isChangingServerMode)
                .help(L("切换电源模式", "Switch power mode"))

                powerModeStatusIndicator

                ModuleCollapseButton(isExpanded: $isPowerModeExpanded, title: L("电源模式", "Power Mode"))
            }

            if isPowerModeExpanded {
                powerModeDetails
            }
        }
        .monitorCard()
    }

    /// Effective state rather than the picker selection: while a switch runs
    /// it shows progress, and an unconfirmed state reads as unknown.
    private var powerModeStatusIndicator: some View {
        Group {
            if store.isChangingServerMode {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
            } else {
                Image(systemName: powerModeStatusIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(powerModeStatusColor)
            }
        }
        .frame(width: 18, height: 18)
        .help(powerModeStatusHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("当前电源状态：", "Current power state: ") + (store.isChangingServerMode ? L("切换中", "Switching") : powerModeStatusText))
    }

    private var powerModeDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("定时", "Schedule"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                powerModeScheduleRow(
                    rule: store.serverModeSnapshot.schedule.nightlySleep,
                    title: "Sleep",
                    systemImage: "moon.zzz"
                )
                powerModeScheduleRow(
                    rule: store.serverModeSnapshot.schedule.workdayServer,
                    title: "Server",
                    systemImage: "server.rack"
                )
            }
            .padding(.top, 2)

            if let message = store.serverModeSnapshot.message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                powerModeSection
                TokenUsageChartView(store: tokenUsageStore, range: $tokenUsageRange)
                if let temperatureStore {
                    TemperatureMonitorSection(temperatureStore: temperatureStore)
                }
                serviceMonitorSection
            }
            .padding(12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                measuredContentHeight = height
            }
        }
        .frame(height: contentViewportHeight)
    }

    private var contentViewportHeight: CGFloat {
        let cap = isServiceMonitorExpanded ? Self.expandedContentHeight : Self.collapsedContentHeight
        guard let measuredContentHeight, measuredContentHeight > 0 else { return cap }
        return min(measuredContentHeight, cap)
    }

    private var initialLoading: some View {
        Text(L("正在扫描用户服务…", "Scanning user services…"))
            .font(.caption)
            .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var issueBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("部分数据暂不可用", "Some data is unavailable"))
                    .font(.subheadline.weight(.semibold))
                Text(store.snapshot.issues.map(issueDescription).joined(separator: L("；", "; ")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var serviceMonitorSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    toggleServiceMonitor()
                } label: {
                    HStack(spacing: 8) {
                        Label(L("服务监测", "Services"), systemImage: "antenna.radiowaves.left.and.right")
                            .font(.subheadline.weight(.semibold))

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isServiceMonitorExpanded ? L("收起服务监测", "Collapse services") : L("展开服务监测", "Expand services"))

                // The count badges double as the tab switcher; the port list is
                // not offered here for now.
                ForEach(Self.visibleMonitorTabs, id: \.self) { tab in
                    ServiceSummaryBadge(
                        title: tab.title,
                        value: monitorTabCount(tab),
                        color: monitorTabTint(tab),
                        isSelected: isServiceMonitorExpanded && monitorTab == tab
                    ) {
                        selectMonitorTab(tab)
                    }
                }

                ModuleCollapseButton(isExpanded: $isServiceMonitorExpanded, title: L("服务监测", "Services"))
            }

            if isServiceMonitorExpanded {
                Group {
                    switch monitorTab {
                    case .ports:
                        portMonitorDetails
                    case .services:
                        serviceMonitorDetails
                    case .processes:
                        if let processStore {
                            HeavyProcessMonitorView(processStore: processStore)
                        } else {
                            Text(L("暂无进程占用数据", "No process usage data"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
        .monitorCard()
    }

    private func monitorTabCount(_ tab: MonitorTab) -> Int {
        switch tab {
        case .ports: store.portCount
        case .services: store.serviceCount
        case .processes: processStore?.processes.count ?? 0
        }
    }

    private func monitorTabTint(_ tab: MonitorTab) -> Color {
        switch tab {
        case .ports, .processes: .green
        case .services: .blue
        }
    }

    private func toggleServiceMonitor() {
        withAnimation(.easeInOut(duration: 0.16)) {
            isServiceMonitorExpanded.toggle()
        }
    }

    /// Selecting a tab also opens the section so a badge tap always has a
    /// visible result.
    private func selectMonitorTab(_ tab: MonitorTab) {
        withAnimation(.easeInOut(duration: 0.16)) {
            monitorTab = tab
            isServiceMonitorExpanded = true
        }
    }

    private var portMonitorDetails: some View {
        let entries = store.services.flatMap { service in
            service.endpoints.map { (service: service, endpoint: $0) }
        }.sorted {
            if $0.endpoint.port != $1.endpoint.port { return $0.endpoint.port < $1.endpoint.port }
            if $0.service.id != $1.service.id { return $0.service.id < $1.service.id }
            return "\($0.endpoint.transport.rawValue):\($0.endpoint.address)"
                < "\($1.endpoint.transport.rawValue):\($1.endpoint.address)"
        }
        return VStack(alignment: .leading, spacing: 8) {
            if !store.snapshot.issues.isEmpty { issueBanner }
            if entries.isEmpty {
                Text(store.isRefreshing ? L("正在扫描端口…", "Scanning ports…") : L("暂无监听端口", "No listening ports"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(entries.indices, id: \.self) { index in
                let entry = entries[index]
                HStack(spacing: 10) {
                    Text(String(entry.endpoint.port))
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .frame(width: 54, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.service.displayName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text("\(entry.endpoint.transport.rawValue.uppercased()) · \(entry.endpoint.address)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var serviceMonitorDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.snapshot.issues.isEmpty {
                issueBanner
            }

            if store.snapshot.collectedAt == .distantPast && store.isRefreshing {
                initialLoading
            } else if store.services.isEmpty {
                emptyState
            } else {
                serviceSection(kind: .localProject, title: L("本地项目", "Local Projects"))
                serviceSection(kind: .launchAgent, title: L("用户 Daemon", "User Daemons"))
                serviceSection(kind: .userProcess, title: L("其他用户端口", "Other User Ports"))
            }
        }
    }

    @ViewBuilder
    private func serviceSection(kind: MonitoredService.Kind, title: String) -> some View {
        let services = sortOrder.sorted(store.services.filter { $0.kind == kind })
        if !services.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.6)

                    Spacer()

                    if firstVisibleKind == kind {
                        sortMenu
                    }
                }

                ForEach(services) { service in
                    ServiceRow(
                        service: service,
                        isStopping: store.isStopping(service),
                        onStop: { serviceToStop = service }
                    )
                }
            }
        }
    }

    private var firstVisibleKind: MonitoredService.Kind? {
        [.localProject, .launchAgent, .userProcess].first { kind in
            store.services.contains { $0.kind == kind }
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(ServiceSortOrder.allCases) { order in
                Button {
                    sortOrder = order
                } label: {
                    HStack {
                        Text(order.title)
                        if sortOrder == order {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label(sortOrder.shortTitle, systemImage: "arrow.up.arrow.down")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.7), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L("排序方式：\(sortOrder.title)", "Sort order: \(sortOrder.title)"))
        .help(L("排序服务", "Sort services"))
    }

    private var emptyState: some View {
        ContentUnavailableView(
            L("暂无用户服务", "No user services"),
            systemImage: "network.slash",
            description: Text(L(
                "启动本地网页项目或用户 LaunchAgent 后，它会自动出现。",
                "Start a local web project or a user LaunchAgent and it will appear here."
            ))
        )
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                isAboutPresented.toggle()
            } label: {
                Label(L("关于", "About"), systemImage: "info.circle")
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $isAboutPresented, arrowEdge: .top) {
                AboutView()
            }

            Picker(L("语言", "Language"), selection: $languageRawValue) {
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.switchTitle).tag(language.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help(L("切换界面语言", "Switch interface language"))

            Spacer()

            Button(L("退出", "Quit")) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func stopConfirmation(for service: MonitoredService) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L("停止 \(service.displayName)？", "Stop \(service.displayName)?"))
                .font(.subheadline.weight(.semibold))
            Text(stopImpact(for: service))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(L("取消", "Cancel")) {
                    serviceToStop = nil
                }
                .buttonStyle(.bordered)

                Button(L("停止", "Stop"), role: .destructive) {
                    serviceToStop = nil
                    Task { await stop(service) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func actionPanel(for prompt: ActionPrompt) -> some View {
        switch prompt {
        case .force(let service, let pids):
            VStack(alignment: .leading, spacing: 9) {
                Text(L("服务仍在运行", "Service is still running"))
                    .font(.subheadline.weight(.semibold))
                Text(L(
                    "PID \(pids.map(String.init).joined(separator: ", ")) 未响应 SIGTERM。强制结束可能导致未保存的数据丢失。",
                    "PID \(pids.map(String.init).joined(separator: ", ")) did not respond to SIGTERM. Force quitting may lose unsaved data."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button(L("取消", "Cancel")) {
                        actionPrompt = nil
                    }
                    .buttonStyle(.bordered)

                    Button(L("强制结束", "Force Quit"), role: .destructive) {
                        actionPrompt = nil
                        Task { await forceStop(service) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

        case .error(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("操作失败", "Action failed"))
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("好", "OK")) {
                    actionPrompt = nil
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var powerModeStatusText: String {
        store.serverModeSnapshot.effectiveMode.statusText
    }

    private var powerModeStatusColor: Color {
        switch store.serverModeSnapshot.effectiveMode {
        case .server: .green
        case .sleep: .blue
        case .normal: .secondary
        case .unknown: .orange
        }
    }

    private var powerModeStatusIcon: String {
        store.serverModeSnapshot.effectiveMode.symbolName
    }

    private var powerModeStatusHelp: String {
        if store.isChangingServerMode { return L("正在切换电源模式…", "Switching power mode…") }
        let status = L("当前状态：\(powerModeStatusText)", "Current state: \(powerModeStatusText)")
        guard let message = store.serverModeSnapshot.message else { return status }
        return "\(status)\n\(message)"
    }

    private func powerModeScheduleRow(
        rule: PowerModeScheduleRule,
        title: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Button {
                    updateScheduleRepeat(rule.id)
                } label: {
                    Text(scheduleRepeatTitle(rule))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.75), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(L("点击切换每天 / 工作日", "Click to switch daily / weekdays"))
                .accessibilityLabel(scheduleRepeatTitle(rule))
                .accessibilityHint(L("点击在每天和工作日之间切换", "Click to switch between daily and weekdays"))
            }

            Spacer()

            DatePicker(
                "",
                selection: Binding(
                    get: { dateForScheduleRule(rule) },
                    set: { date in updateScheduleTime(rule.id, date: date) }
                ),
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .frame(width: 82)

            Toggle(
                "",
                isOn: Binding(
                    get: { rule.isEnabled },
                    set: { isEnabled in updateScheduleEnabled(rule.id, isEnabled: isEnabled) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .disabled(store.isChangingServerMode)
    }

    private func dateForScheduleRule(_ rule: PowerModeScheduleRule) -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = rule.hour
        components.minute = rule.minute
        components.second = 0
        return Calendar.current.date(from: components) ?? Date()
    }

    private func updateScheduleEnabled(_ id: PowerModeScheduleRuleID, isEnabled: Bool) {
        updateScheduleRule(id) { rule in
            rule.isEnabled = isEnabled
        }
    }

    private func updateScheduleRepeat(_ id: PowerModeScheduleRuleID) {
        updateScheduleRule(id) { rule in
            rule.toggleRepeat()
        }
    }

    private func scheduleRepeatTitle(_ rule: PowerModeScheduleRule) -> String {
        rule.repeatsDaily ? L("每天", "Daily") : L("工作日", "Weekdays")
    }

    private func updateScheduleTime(_ id: PowerModeScheduleRuleID, date: Date) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        updateScheduleRule(id) { rule in
            rule.hour = components.hour ?? rule.hour
            rule.minute = components.minute ?? rule.minute
        }
    }

    private func updateScheduleRule(_ id: PowerModeScheduleRuleID, update: (inout PowerModeScheduleRule) -> Void) {
        var schedule = store.serverModeSnapshot.schedule
        var rule: PowerModeScheduleRule
        switch id {
        case .nightlySleep:
            rule = schedule.nightlySleep
        case .workdayServer:
            rule = schedule.workdayServer
        }

        update(&rule)
        schedule = schedule.updatingRule(rule)
        Task { await store.updatePowerModeSchedule(schedule) }
    }

    private func issueDescription(_ issue: MonitorIssue) -> String {
        switch issue.source {
        case .ports: L("端口扫描失败", "Port scan failed")
        case .launchAgents: L("LaunchAgent 扫描失败", "LaunchAgent scan failed")
        }
    }

    private func stopImpact(for service: MonitoredService) -> String {
        let processText = service.processes.count == 1
            ? "PID \(service.processes[0].id.pid)"
            : L("\(service.processes.count) 个进程", "\(service.processes.count) processes")
        guard !service.endpoints.isEmpty else {
            return L("将停止 \(processText)。该服务目前没有监听端口。", "Will stop \(processText). This service has no listening ports.")
        }

        let ports = service.endpoints.map { String($0.port) }.joined(separator: ", ")
        return L("将停止 \(processText)，并释放端口：\(ports)。", "Will stop \(processText) and free ports: \(ports).")
    }

    private func stop(_ service: MonitoredService) async {
        handle(await store.stop(service), service: service)
    }

    private func forceStop(_ service: MonitoredService) async {
        handle(await store.forceStop(service), service: service)
    }

    private func handle(_ outcome: StopOutcome, service: MonitoredService) {
        switch outcome {
        case .stopped:
            break
        case .requiresForce(let pids):
            actionPrompt = .force(service, pids)
        case .failed(let message):
            actionPrompt = .error(message)
        }
    }
}
/// Effective power state shared by the panel indicator and the menu bar item.
extension PowerModeStatus {
    var symbolName: String {
        switch self {
        case .server: "server.rack"
        case .sleep: "moon.zzz.fill"
        case .normal: "laptopcomputer"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var statusText: String {
        switch self {
        case .server: L("Server 生效", "Server active")
        case .sleep: L("Sleep 待机", "Sleeping")
        case .normal: "Normal"
        case .unknown: L("未知", "Unknown")
        }
    }
}

/// Menu bar glyph to the left of the temperature: the effective power mode.
struct PowerModeMenuBarIcon: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        let status = store.serverModeSnapshot.effectiveMode
        Image(systemName: store.isChangingServerMode ? "arrow.triangle.2.circlepath" : status.symbolName)
            .accessibilityLabel(L("电源模式：", "Power mode: ") + status.statusText)
    }
}

/// One listening endpoint rendered as a capsule. TCP endpoints open in the
/// default browser because a local TCP port is normally an HTTP service; UDP
/// endpoints stay inert since a browser cannot talk to them. The capsule itself
/// is the link, so it carries no extra link glyph.
private struct EndpointBadge: View {
    let endpoint: ListeningEndpoint

    var body: some View {
        if let url = endpoint.localServiceURL {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: L("在浏览器打开 \(url.absoluteString)", "Open \(url.absoluteString) in browser")))
            .accessibilityLabel(L("\(endpoint.transport.rawValue.uppercased()) 端口 \(endpoint.port)", "\(endpoint.transport.rawValue.uppercased()) port \(endpoint.port)"))
            .accessibilityHint(L("点击在浏览器打开 \(url.absoluteString)", "Click to open \(url.absoluteString) in browser"))
        } else {
            label
                .help(Text(verbatim: "\(endpoint.address):\(endpoint.port)"))
        }
    }

    private var label: some View {
        Text(verbatim: "\(endpoint.transport.rawValue.uppercased())  \(endpoint.port)")
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.7), in: Capsule())
            .contentShape(Capsule())
    }
}

enum ServiceSortOrder: String, CaseIterable, Identifiable {
    case nameAscending
    case nameDescending
    case memoryDescending
    case memoryAscending

    var id: Self { self }

    var title: String {
        switch self {
        case .nameAscending: L("名称：A 到 Z", "Name: A to Z")
        case .nameDescending: L("名称：Z 到 A", "Name: Z to A")
        case .memoryDescending: L("内存：高到低", "Memory: High to Low")
        case .memoryAscending: L("内存：低到高", "Memory: Low to High")
        }
    }

    var shortTitle: String {
        switch self {
        case .nameAscending: L("名称 ↑", "Name ↑")
        case .nameDescending: L("名称 ↓", "Name ↓")
        case .memoryDescending: L("内存 ↓", "Memory ↓")
        case .memoryAscending: L("内存 ↑", "Memory ↑")
        }
    }

    func sorted(_ services: [MonitoredService]) -> [MonitoredService] {
        services.sorted { lhs, rhs in
            switch self {
            case .nameAscending:
                return compareNames(lhs, rhs, ascending: true)
            case .nameDescending:
                return compareNames(lhs, rhs, ascending: false)
            case .memoryDescending:
                if lhs.memoryBytes != rhs.memoryBytes {
                    return lhs.memoryBytes > rhs.memoryBytes
                }
                return compareNames(lhs, rhs, ascending: true)
            case .memoryAscending:
                if lhs.memoryBytes != rhs.memoryBytes {
                    return lhs.memoryBytes < rhs.memoryBytes
                }
                return compareNames(lhs, rhs, ascending: true)
            }
        }
    }

    private func compareNames(
        _ lhs: MonitoredService,
        _ rhs: MonitoredService,
        ascending: Bool
    ) -> Bool {
        let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if comparison == .orderedSame {
            return lhs.id < rhs.id
        }
        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }
}

private enum ActionPrompt {
    case force(MonitoredService, [Int32])
    case error(String)
}

private struct ServiceSummaryBadge: View {
    let title: String
    let value: Int
    let color: Color
    var isSelected = false
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) {
                content
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) \(value)")
            .accessibilityHint(L("点击切换到\(title)标签页", "Click to switch to the \(title) tab"))
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(title) \(value)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background {
            if isSelected {
                Capsule().fill(color.opacity(0.22))
            } else {
                Capsule().fill(.quaternary.opacity(0.6))
            }
        }
        .overlay {
            Capsule().stroke(isSelected ? color.opacity(0.55) : .clear, lineWidth: 1)
        }
        .contentShape(Capsule())
    }
}

/// Row-level stop control shared by the service and process lists. Both send
/// SIGTERM, so they use the same glyph, size and busy treatment; only the help
/// text names the target.
struct RowStopButton: View {

    let help: String
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
        } else {
            Button(role: .destructive, action: action) {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.borderless)
            .help(help)
        }
    }
}


private struct ServiceRow: View {
    let service: MonitoredService
    let isStopping: Bool
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 3) {
                    Text(service.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(service.memoryBytes),
                        countStyle: .memory
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    RowStopButton(help: L("停止服务", "Stop service"), isBusy: isStopping, action: onStop)
                }
            }

            if service.endpoints.isEmpty {
                Text(L("后台运行 · 无监听端口", "Background · no listening ports"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 76), spacing: 6, alignment: .leading)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(service.endpoints, id: \.self) { endpoint in
                        EndpointBadge(endpoint: endpoint)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 11))
    }

    private var detail: String {
        let pids = service.processes.map { String($0.id.pid) }.joined(separator: ", ")
        if let root = service.projectRoot {
            return "PID \(pids) · \(root.path)"
        }
        let executablePath = service.processes.first?.executablePath ?? ""
        return "PID \(pids) · \(executablePath.isEmpty ? L("未知命令", "unknown command") : executablePath)"
    }

    private var icon: String {
        switch service.kind {
        case .localProject: "folder.badge.gearshape"
        case .launchAgent: "gearshape.2"
        case .userProcess: "terminal"
        }
    }

    private var tint: Color {
        switch service.kind {
        case .localProject: .blue
        case .launchAgent: .purple
        case .userProcess: .orange
        }
    }
}

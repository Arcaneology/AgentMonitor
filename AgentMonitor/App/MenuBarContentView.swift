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

@MainActor
struct MenuBarContentView: View {
    @ObservedObject var store: MonitorStore
    @StateObject private var tokenUsageStore: TokenUsageStore
    @State private var serviceToStop: MonitoredService?
    @State private var actionPrompt: ActionPrompt?
    @State private var sortOrder: ServiceSortOrder = .nameAscending
    @State private var tokenUsageRange: TokenUsageRange = .today
    @State private var isServiceMonitorExpanded: Bool
    private let temperatureStore: TemperatureStore?
    private let processStore: HeavyProcessStore?
    @State private var monitorTab: MonitorTab = .services

    /// The panel stacks four module cards (power mode, token usage, temperature
    /// and services). The viewport is sized so the stack is readable without
    /// constant scrolling; the expanded service list adds one more card height.
    private static let collapsedContentHeight: CGFloat = 960
    private static let expandedContentHeight: CGFloat = 1200

    private enum MonitorTab: String, CaseIterable {
        case ports = "端口"
        case services = "服务"
        case processes = "进程"
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

            content

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
            HStack {
                Label("Agent Monitor", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)

                Spacer()
            }

        }
        .padding(14)
    }

    private var powerModeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Label("电源模式", systemImage: "powerplug")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                if store.isChangingServerMode {
                    ProgressView()
                        .controlSize(.small)
                }
                Picker(
                    "电源模式",
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
                .help("切换电源模式")
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("定时")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(nextPowerModeEventText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                powerModeScheduleRow(
                    rule: store.serverModeSnapshot.schedule.nightlySleep,
                    title: "Sleep",
                    subtitle: "每天",
                    systemImage: "moon.zzz"
                )
                powerModeScheduleRow(
                    rule: store.serverModeSnapshot.schedule.workdayServer,
                    title: "Server",
                    subtitle: "工作日",
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
        .monitorCard()
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
        }
        .frame(height: isServiceMonitorExpanded ? Self.expandedContentHeight : Self.collapsedContentHeight)
    }

    private var initialLoading: some View {
        Text("正在扫描用户服务…")
            .font(.caption)
            .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var issueBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("部分数据暂不可用")
                    .font(.subheadline.weight(.semibold))
                Text(store.snapshot.issues.map(issueDescription).joined(separator: "；"))
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
                        Label("服务监测", systemImage: "network")
                            .font(.subheadline.weight(.semibold))

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isServiceMonitorExpanded ? "收起服务监测" : "展开服务监测")

                // The count badges double as the tab switcher; the port list is
                // not offered here for now.
                ForEach(Self.visibleMonitorTabs, id: \.self) { tab in
                    ServiceSummaryBadge(
                        title: tab.rawValue,
                        value: monitorTabCount(tab),
                        color: monitorTabTint(tab),
                        isSelected: isServiceMonitorExpanded && monitorTab == tab
                    ) {
                        selectMonitorTab(tab)
                    }
                }

                Button {
                    toggleServiceMonitor()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isServiceMonitorExpanded ? 90 : 0))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isServiceMonitorExpanded ? "收起服务监测" : "展开服务监测")
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
                            Text("暂无进程占用数据")
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
                Text(store.isRefreshing ? "正在扫描端口…" : "暂无监听端口")
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
                serviceSection(kind: .localProject, title: "本地项目")
                serviceSection(kind: .launchAgent, title: "用户 Daemon")
                serviceSection(kind: .userProcess, title: "其他用户端口")
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
        .accessibilityLabel("排序方式：\(sortOrder.title)")
        .help("排序服务")
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "暂无用户服务",
            systemImage: "network.slash",
            description: Text("启动本地网页项目或用户 LaunchAgent 后，它会自动出现。")
        )
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var footer: some View {
        HStack {
            Text(updatedText)
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Button("退出") {
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
            Text("停止 \(service.displayName)？")
                .font(.subheadline.weight(.semibold))
            Text(stopImpact(for: service))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") {
                    serviceToStop = nil
                }
                .buttonStyle(.bordered)

                Button("停止", role: .destructive) {
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
                Text("服务仍在运行")
                    .font(.subheadline.weight(.semibold))
                Text("PID \(pids.map(String.init).joined(separator: ", ")) 未响应 SIGTERM。强制结束可能导致未保存的数据丢失。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("取消") {
                        actionPrompt = nil
                    }
                    .buttonStyle(.bordered)

                    Button("强制结束", role: .destructive) {
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
                    Text("操作失败")
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("好") {
                    actionPrompt = nil
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var updatedText: String {
        guard store.snapshot.collectedAt != .distantPast else { return "尚未刷新" }
        return "更新于 \(store.snapshot.collectedAt.formatted(date: .omitted, time: .standard))"
    }

    private var powerModeStatusText: String {
        switch store.serverModeSnapshot.effectiveMode {
        case .server: "Server 生效"
        case .sleep: "Sleep 待机"
        case .normal: "Normal"
        case .unknown: "未知"
        }
    }

    private var powerModeStatusColor: Color {
        switch store.serverModeSnapshot.effectiveMode {
        case .server: .green
        case .sleep: .blue
        case .normal: .secondary
        case .unknown: .orange
        }
    }

    private var nextPowerModeEventText: String {
        guard let event = store.serverModeSnapshot.schedule.nextEvent(after: Date(), calendar: .current) else {
            return "未开启"
        }
        return "\(event.mode.title) \(event.date.formatted(date: .omitted, time: .shortened))"
    }

    private func powerModeScheduleRow(
        rule: PowerModeScheduleRule,
        title: String,
        subtitle: String,
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
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
        case .ports: "端口扫描失败"
        case .launchAgents: "LaunchAgent 扫描失败"
        }
    }

    private func stopImpact(for service: MonitoredService) -> String {
        let processText = service.processes.count == 1
            ? "PID \(service.processes[0].id.pid)"
            : "\(service.processes.count) 个进程"
        guard !service.endpoints.isEmpty else {
            return "将停止 \(processText)。该服务目前没有监听端口。"
        }

        let ports = service.endpoints.map { String($0.port) }.joined(separator: ", ")
        return "将停止 \(processText)，并释放端口：\(ports)。"
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
/// One listening endpoint rendered as a capsule. TCP endpoints open in the
/// default browser because a local TCP port is normally an HTTP service; UDP
/// endpoints stay inert since a browser cannot talk to them.
private struct EndpointBadge: View {
    let endpoint: ListeningEndpoint

    var body: some View {
        if let url = endpoint.localServiceURL {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 4) {
                    label
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption2)
                }
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: "在浏览器打开 \(url.absoluteString)"))
            .accessibilityLabel("\(endpoint.transport.rawValue.uppercased()) 端口 \(endpoint.port)")
            .accessibilityHint("点击在浏览器打开 \(url.absoluteString)")
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
        case .nameAscending: "名称：A 到 Z"
        case .nameDescending: "名称：Z 到 A"
        case .memoryDescending: "内存：高到低"
        case .memoryAscending: "内存：低到高"
        }
    }

    var shortTitle: String {
        switch self {
        case .nameAscending: "名称 ↑"
        case .nameDescending: "名称 ↓"
        case .memoryDescending: "内存 ↓"
        case .memoryAscending: "内存 ↑"
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
            .accessibilityHint("点击切换到\(title)标签页")
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

                    RowStopButton(help: "停止服务", isBusy: isStopping, action: onStop)
                }
            }

            if service.endpoints.isEmpty {
                Text("后台运行 · 无监听端口")
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
        return "PID \(pids) · \(executablePath.isEmpty ? "未知命令" : executablePath)"
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

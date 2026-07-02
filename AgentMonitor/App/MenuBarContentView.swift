import AppKit
import SwiftUI

@MainActor
struct MenuBarContentView: View {
    @ObservedObject var store: MonitorStore
    @StateObject private var tokenUsageStore: TokenUsageStore
    @State private var serviceToStop: MonitoredService?
    @State private var actionPrompt: ActionPrompt?
    @State private var sortOrder: ServiceSortOrder = .nameAscending
    @State private var tokenUsageRange: TokenUsageRange = .today
    @State private var isServiceMonitorExpanded: Bool

    init(
        store: MonitorStore,
        serviceToStop: MonitoredService? = nil,
        tokenUsageStore: TokenUsageStore = TokenUsageStore(),
        isServiceMonitorExpanded: Bool = false
    ) {
        self.store = store
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
                Label("Agent Monitor", systemImage: "network")
                    .font(.headline)

                Spacer()
            }

        }
        .padding(14)
    }

    private var serverModeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label("Server 模式", systemImage: "server.rack")
                    .font(.subheadline.weight(.semibold))

                Text(serverModeStatusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(serverModeStatusColor)

                Spacer()

                if store.isChangingServerMode {
                    ProgressView()
                        .controlSize(.small)
                }

                Toggle(
                    "",
                    isOn: Binding(
                        get: { store.serverModeSnapshot.isEnabled },
                        set: { enabled in
                            Task { await store.setServerModeEnabled(enabled) }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(store.isChangingServerMode)
                .help("切换 Server 保活模式")
            }

            if let message = store.serverModeSnapshot.message {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                TokenUsageChartView(store: tokenUsageStore, range: $tokenUsageRange)
                serverModeSection
                serviceMonitorSection
            }
            .padding(12)
        }
        .frame(height: isServiceMonitorExpanded ? 560 : 430)
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
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isServiceMonitorExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Label("服务监测", systemImage: "network")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    ServiceSummaryBadge(title: "服务", value: store.serviceCount, color: .blue)
                    ServiceSummaryBadge(title: "端口", value: store.portCount, color: .green)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isServiceMonitorExpanded ? 90 : 0))
                        .frame(width: 12, height: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isServiceMonitorExpanded {
                serviceMonitorDetails
                    .padding(.top, 10)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
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

    private var serverModeStatusText: String {
        switch store.serverModeSnapshot.state {
        case .enabled: "开"
        case .disabled: "关"
        case .unknown: "未知"
        }
    }

    private var serverModeStatusColor: Color {
        switch store.serverModeSnapshot.state {
        case .enabled: .green
        case .disabled: .secondary
        case .unknown: .orange
        }
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

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(title) \(value)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
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

                    if isStopping {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button(role: .destructive, action: onStop) {
                            Image(systemName: "stop.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("停止服务")
                    }
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
                        Text(verbatim: "\(endpoint.transport.rawValue.uppercased())  \(endpoint.port)")
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.quaternary.opacity(0.7), in: Capsule())
                            .help(Text(verbatim: "\(endpoint.address):\(endpoint.port)"))
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

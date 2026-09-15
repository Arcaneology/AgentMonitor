import Charts
import SwiftUI

@MainActor
struct HeavyProcessMonitorView: View {
    @ObservedObject var processStore: HeavyProcessStore
    @State private var processToClose: HeavyProcess?
    @State private var actionPrompt: ProcessActionPrompt?

    var body: some View {
        VStack(spacing: 0) {
            heavyProcessSection

            if let processToClose {
                Divider()
                closeConfirmation(for: processToClose)
            } else if let actionPrompt {
                Divider()
                actionPanel(for: actionPrompt)
            }
        }
    }

}

@MainActor
struct TemperatureMonitorSection: View {
    @ObservedObject var temperatureStore: TemperatureStore

    /// Temporarily disabled: keeps the high-temperature controls in code while
    /// they are out of the panel. The alert level still follows the saved
    /// setting, so restoring the switch needs no other change.
    private static let showsHighTemperatureAlertControls = false

    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 10) {
            header
            if isExpanded {
                TemperatureChartView(store: temperatureStore)
            }
        }
        .monitorCard()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ModuleTitleToggle(isExpanded: $isExpanded, title: L("温度监测", "Temperature"), systemImage: "thermometer.medium")

                Spacer()

                if let currentCelsius = temperatureStore.currentCelsius {
                    Text(String(format: "%.0f°C", currentCelsius.rounded()))
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(TemperatureAlertStyle.foreground(for: temperatureStore.alertLevel))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            TemperatureAlertStyle.background(for: temperatureStore.alertLevel),
                            in: Capsule()
                        )
                } else {
                    Text("--°C")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ModuleCollapseButton(isExpanded: $isExpanded, title: L("温度监测", "Temperature"))
            }

            if isExpanded && Self.showsHighTemperatureAlertControls {
                Toggle(L("高温提示", "High temperature alert"), isOn: $temperatureStore.isHighTemperatureAlertEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(L("开启后，温度达到 80°C 显示橙色，达到 95°C 显示红色", "When on, 80°C shows orange and 95°C shows red"))

                Text(L("80°C 橙色 · 95°C 红色", "80°C orange · 95°C red"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

}

private extension HeavyProcessMonitorView {
    /// Tallest the process list grows before it scrolls on its own. The panel
    /// itself already scrolls; without this bound a machine with hundreds of
    /// helper processes would push everything else far out of reach.
    static var listMaxHeight: CGFloat { 360 }

    var heavyProcessSection: some View {
        let processes = processStore.processes
        let totalProcesses = processes.reduce(0) { $0 + $1.processCount }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L("全部进程", "All Processes"))
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                Text(L("共 \(totalProcesses) 个进程 · 按占用排序", "\(totalProcesses) processes · by usage"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if processes.isEmpty {
                Text(L("暂无进程", "No processes"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(processes) { process in
                            HeavyProcessRow(
                                process: process,
                                isTerminating: processStore.isTerminating(process),
                                onClose: { processToClose = process }
                            )

                            if process.id != processes.last?.id {
                                Divider().opacity(0.35)
                            }
                        }
                    }
                }
                .frame(maxHeight: Self.listMaxHeight)
            }
        }
    }

    private func closeConfirmation(for process: HeavyProcess) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L("停止 \(process.name)？", "Stop \(process.name)?"))
                .font(.subheadline.weight(.semibold))
            Text(process.processCount == 1
                 ? L("PID \(process.pid) 将被发送 SIGTERM。", "PID \(process.pid) will receive SIGTERM.")
                 : L("将结束 \(process.processCount) 个进程。", "\(process.processCount) processes will be ended."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(L("取消", "Cancel")) {
                    processToClose = nil
                }
                .buttonStyle(.bordered)

                Button(L("停止", "Stop"), role: .destructive) {
                    processToClose = nil
                    Task { await close(process) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func actionPanel(for prompt: ProcessActionPrompt) -> some View {
        switch prompt {
        case .force(let process):
            VStack(alignment: .leading, spacing: 9) {
                Text(L("进程仍在运行", "Process is still running"))
                    .font(.subheadline.weight(.semibold))
                Text(L("\(process.name) 未响应 SIGTERM。强制结束可能导致未保存的数据丢失。", "\(process.name) did not respond to SIGTERM. Force quitting may lose unsaved data."))
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
                        Task { await forceClose(process) }
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
                    Text(L("停止失败", "Stop failed"))
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

    private func close(_ process: HeavyProcess) async {
        handle(await processStore.terminate(process), process: process)
    }

    private func forceClose(_ process: HeavyProcess) async {
        handle(await processStore.forceTerminate(process), process: process)
    }

    private func handle(_ outcome: StopOutcome, process: HeavyProcess) {
        switch outcome {
        case .stopped:
            break
        case .requiresForce:
            actionPrompt = .force(process)
        case .failed(let message):
            actionPrompt = .error(message)
        }
    }
}

struct TemperatureMenuBarLabel: View {
    @ObservedObject var store: TemperatureStore

    var body: some View {
        Text(store.menuBarText ?? "--°C")
            .monospacedDigit()
            .foregroundStyle(TemperatureAlertStyle.foreground(for: store.alertLevel))
            .padding(.horizontal, store.alertLevel == .none ? 0 : 6)
            .padding(.vertical, store.alertLevel == .none ? 0 : 1)
            .background(
                TemperatureAlertStyle.background(for: store.alertLevel),
                in: Capsule()
            )
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let temperature = store.menuBarText else {
            return L("当前温度暂无读数", "No temperature reading")
        }
        switch store.alertLevel {
        case .none:
            return L("当前温度 \(temperature)", "Temperature \(temperature)")
        case .elevated:
            return L("当前温度 \(temperature)，较高", "Temperature \(temperature), elevated")
        case .critical:
            return L("当前温度 \(temperature)，很高", "Temperature \(temperature), critical")
        }
    }
}

enum TemperatureAlertStyle {
    static func background(for level: TemperatureAlertLevel) -> Color {
        switch level {
        case .none: .clear
        case .elevated: .orange
        case .critical: .red
        }
    }

    static func foreground(for level: TemperatureAlertLevel) -> Color {
        switch level {
        case .none: .primary
        case .elevated, .critical: .white
        }
    }
}

@MainActor
struct TemperatureChartView: View {
    @ObservedObject var store: TemperatureStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("最近 1 小时", "Last hour"))
                .font(.subheadline.weight(.semibold))

            chartContent
                .frame(height: 148)
        }
    }

    @ViewBuilder
    private var chartContent: some View {
        if store.samples.isEmpty {
            Label(L("暂无最近 1 小时温度记录", "No temperature records in the last hour"), systemImage: "chart.xyaxis.line")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            temperatureChart
        }
    }

    private var temperatureChart: some View {
        let now = store.samples.last?.date ?? Date()
        let start = now.addingTimeInterval(-TemperatureAggregator.historyWindow)
        let domain = yDomain

        return Chart(store.samples) { sample in
            LineMark(
                x: .value("时间", sample.date),
                y: .value("温度", sample.celsius)
            )
            .interpolationMethod(.catmullRom)
            .foregroundStyle(.orange)

            AreaMark(
                x: .value("时间", sample.date),
                yStart: .value("下限", domain.lowerBound),
                yEnd: .value("温度", sample.celsius)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [.orange.opacity(0.28), .orange.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .chartXScale(domain: start...now)
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute, count: 15)) { value in
                AxisGridLine()
                    .foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                    .foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let celsius = value.as(Double.self) {
                        Text("\(Int(celsius.rounded()))°C")
                    }
                }
            }
        }
        .accessibilityLabel(L("最近 1 小时温度曲线", "Temperature over the last hour"))
    }

    private var yDomain: ClosedRange<Double> {
        let values = store.samples.map(\.celsius)
        let minimum = values.min() ?? 40
        let maximum = values.max() ?? 60
        return (minimum - 4)...(maximum + 4)
    }
}

private enum ProcessActionPrompt {
    case force(HeavyProcess)
    case error(String)
}

private struct HeavyProcessRow: View {
    let process: HeavyProcess
    let isTerminating: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(process.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(process.processCount == 1
                     ? "PID \(process.pid) · \(memoryText)"
                     : L("\(process.processCount) 个进程 · \(memoryText)", "\(process.processCount) processes · \(memoryText)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(cpuText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            RowStopButton(help: L("停止进程", "Stop process"), isBusy: isTerminating, action: onClose)
        }
        .padding(.vertical, 4)
    }

    private var cpuText: String {
        String(format: "%.0f%%", process.cpuPercent)
    }

    private var memoryText: String {
        ByteCountFormatter.string(fromByteCount: Int64(process.memoryBytes), countStyle: .memory)
    }
}

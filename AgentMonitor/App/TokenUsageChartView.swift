import Charts
import SwiftUI

@MainActor
struct TokenUsageChartView: View {
    @ObservedObject var store: TokenUsageStore
    @Binding var range: TokenUsageRange
    @State private var hoverState: TokenUsageHoverState?

    private static let highUsageThreshold: Int64 = 100_000_000
    private static let tooltipSize = CGSize(width: 164, height: 104)
    private static let tooltipGap: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Token 用量", systemImage: "chart.bar.fill")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                if let snapshot = store.snapshot {
                    Text(TokenCountFormatter.compact(snapshot.totalTokens))
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .monospacedDigit()
                }
            }

            Picker("时间范围", selection: $range) {
                ForEach(TokenUsageRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented)

            chartContent
                .frame(height: 156)

            HStack {
                Text("AgentMonitor 本地记录 · 自动同步 CC Switch")
                Spacer()
                if let collectedAt = store.snapshot?.collectedAt {
                    Text(collectedAt.formatted(date: .omitted, time: .shortened))
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [.blue.opacity(0.10), .purple.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary, lineWidth: 1)
        }
        .task(id: range) {
            while !Task.isCancelled {
                await store.refresh(range: range)
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
            }
        }
    }

    @ViewBuilder
    private var chartContent: some View {
        if let errorDescription = store.errorDescription {
            chartMessage(errorDescription, systemImage: "externaldrive.badge.exclamationmark")
        } else if let snapshot = store.snapshot {
            if snapshot.totalTokens == 0 {
                chartMessage("该时段暂无 Token 记录", systemImage: "chart.bar")
            } else {
                usageChart(snapshot)
            }
        } else {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在读取 CC Switch…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func usageChart(_ snapshot: TokenUsageSnapshot) -> some View {
        let points = snapshot.buckets.flatMap(TokenUsageChartPoint.points)
        let highUsageBuckets = range == .last30Days
            ? snapshot.buckets.filter(isHighUsageBucket)
            : []

        return Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value("时间", point.date),
                    y: .value("Tokens", Double(point.tokens))
                )
                .foregroundStyle(by: .value("类型", point.category.title))
                .cornerRadius(2)
            }

            ForEach(highUsageBuckets) { bucket in
                PointMark(
                    x: .value("时间", bucket.start),
                    y: .value("Tokens", Double(bucket.totalTokens))
                )
                .foregroundStyle(.yellow)
                .symbolSize(42)
            }
        }
        .chartForegroundStyleScale(
            domain: TokenUsageCategory.allCases.map(\.title),
            range: TokenUsageCategory.allCases.map(\.color)
        )
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartXScale(range: .plotDimension(startPadding: 8, endPadding: 20))
        .chartYScale(domain: 0...chartYUpperBound(for: snapshot.buckets))
        .chartXAxis {
            AxisMarks(values: axisDates(snapshot.buckets)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(for: date))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                    .foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let tokens = value.as(Double.self) {
                        Text(TokenCountFormatter.compact(Int64(tokens)))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            chartHoverOverlay(proxy: proxy, buckets: snapshot.buckets)
        }
        .accessibilityLabel("Token 用量柱状图，合计 \(snapshot.totalTokens) Tokens")
    }

    private func chartHoverOverlay(proxy: ChartProxy, buckets: [TokenUsageBucket]) -> some View {
        GeometryReader { geometry in
            if let plotFrame = proxy.plotFrame {
                let plotRect = geometry[plotFrame]

                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())

                    if let hoverState,
                       let bucket = buckets.first(where: { $0.start == hoverState.bucketStart }) {
                        if let lineX = proxy.position(forX: bucket.start) {
                            Path { path in
                                let x = plotRect.minX + lineX
                                path.move(to: CGPoint(x: x, y: plotRect.minY))
                                path.addLine(to: CGPoint(x: x, y: plotRect.maxY))
                            }
                            .stroke(
                                Color.secondary.opacity(0.55),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                            )
                            .allowsHitTesting(false)
                        }

                        tokenTooltip(for: bucket)
                            .position(Self.tooltipPosition(
                                for: hoverState.location,
                                in: geometry.size
                            ))
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location):
                        guard plotRect.contains(location),
                              let date = proxy.value(
                                atX: location.x - plotRect.origin.x,
                                as: Date.self
                              ),
                              let bucket = buckets.min(by: {
                                abs($0.start.timeIntervalSince(date))
                                    < abs($1.start.timeIntervalSince(date))
                              }) else {
                            hoverState = nil
                            return
                        }
                        hoverState = TokenUsageHoverState(
                            bucketStart: bucket.start,
                            location: location
                        )
                    case .ended:
                        hoverState = nil
                    }
                }
            }
        }
    }

    private func tokenTooltip(for bucket: TokenUsageBucket) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(tooltipTitle(for: bucket.start))
                    .font(.caption.weight(.semibold))

                Spacer(minLength: 4)

                if isHighUsageBucket(bucket) {
                    Text("1亿+")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.yellow)
                }
            }

            tokenTooltipRow("输入", value: bucket.inputTokens, color: .cyan)
            tokenTooltipRow("缓存", value: bucket.cacheTokens, color: .indigo)
            tokenTooltipRow("输出", value: bucket.outputTokens, color: .pink)

            Divider()

            HStack {
                Text("合计")
                Spacer()
                Text(bucket.totalTokens, format: .number.grouping(.automatic))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .font(.caption)
        }
        .padding(8)
        .frame(
            width: Self.tooltipSize.width,
            height: Self.tooltipSize.height,
            alignment: .topLeading
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .allowsHitTesting(false)
    }

    static func tooltipPosition(for location: CGPoint, in availableSize: CGSize) -> CGPoint {
        let tooltipX: CGFloat
        if location.x + Self.tooltipGap + Self.tooltipSize.width <= availableSize.width {
            tooltipX = location.x + Self.tooltipGap + Self.tooltipSize.width / 2
        } else {
            tooltipX = location.x - Self.tooltipGap - Self.tooltipSize.width / 2
        }

        return CGPoint(
            x: min(
                max(tooltipX, Self.tooltipSize.width / 2),
                availableSize.width - Self.tooltipSize.width / 2
            ),
            y: min(
                max(location.y, Self.tooltipSize.height / 2),
                availableSize.height - Self.tooltipSize.height / 2
            )
        )
    }

    private func tokenTooltipRow(_ title: String, value: Int64, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
            Spacer()
            Text(value, format: .number.grouping(.automatic))
                .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func tooltipTitle(for date: Date) -> String {
        switch range {
        case .last30Days:
            date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
        case .today:
            date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)))
        case .last24Hours:
            date.formatted(
                .dateTime
                    .month(.defaultDigits)
                    .day(.defaultDigits)
                    .hour(.twoDigits(amPM: .omitted))
            )
        }
    }

    private func isHighUsageBucket(_ bucket: TokenUsageBucket) -> Bool {
        bucket.totalTokens >= Self.highUsageThreshold
    }

    private func chartYUpperBound(for buckets: [TokenUsageBucket]) -> Double {
        let maximum = buckets.map(\.totalTokens).max() ?? 1
        return max(1, Double(maximum) * 1.08)
    }

    private func chartMessage(_ message: String, systemImage: String) -> some View {
        Label(message, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func axisDates(_ buckets: [TokenUsageBucket]) -> [Date] {
        guard !buckets.isEmpty else { return [] }
        let desiredCount = range == .last30Days ? 5 : 4
        let step = max(1, (buckets.count - 1) / max(1, desiredCount - 1))
        return stride(from: 0, to: buckets.count, by: step).map { buckets[$0].start }
    }

    private func axisLabel(for date: Date) -> String {
        switch range {
        case .last30Days:
            date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
        case .today, .last24Hours:
            date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)))
        }
    }
}

private struct TokenUsageHoverState {
    let bucketStart: Date
    let location: CGPoint
}

private struct TokenUsageChartPoint: Identifiable {
    let date: Date
    let category: TokenUsageCategory
    let tokens: Int64

    var id: String { "\(date.timeIntervalSince1970)-\(category.rawValue)" }

    static func points(for bucket: TokenUsageBucket) -> [Self] {
        [
            Self(date: bucket.start, category: .input, tokens: bucket.inputTokens),
            Self(date: bucket.start, category: .cache, tokens: bucket.cacheTokens),
            Self(date: bucket.start, category: .output, tokens: bucket.outputTokens)
        ]
    }
}

private enum TokenUsageCategory: String, CaseIterable {
    case input
    case cache
    case output

    var title: String {
        switch self {
        case .input: "输入"
        case .cache: "缓存"
        case .output: "输出"
        }
    }

    var color: Color {
        switch self {
        case .input: .cyan
        case .cache: .indigo
        case .output: .pink
        }
    }
}

enum TokenCountFormatter {
    static func compact(_ value: Int64) -> String {
        switch value {
        case 100_000_000...:
            format(value, divisor: 100_000_000, suffix: "亿")
        case 10_000...:
            format(value, divisor: 10_000, suffix: "万")
        default:
            String(value)
        }
    }

    private static func format(_ value: Int64, divisor: Double, suffix: String) -> String {
        let scaled = Double(value) / divisor
        return String(format: "%.2f%@", scaled, suffix)
    }
}

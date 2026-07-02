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

                if store.supportsCCSwitchSync {
                    Button {
                        Task { await store.syncFromCCSwitch(range: range) }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.isSyncing)
                    .help("从 CC Switch 同步 Token 记录")
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
                Text("AgentMonitor 本地记录 · 手动同步 CC Switch")
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
            chartMessage("正在读取本地 Token 记录", systemImage: "chart.bar")
        }
    }

    private func usageChart(_ snapshot: TokenUsageSnapshot) -> some View {
        let indexedBuckets = snapshot.buckets.enumerated().map { index, bucket in
            IndexedTokenUsageBucket(index: index, bucket: bucket)
        }
        let points = indexedBuckets.flatMap(TokenUsageChartPoint.points)
        let highUsageBuckets = snapshot.range == .last30Days
            ? indexedBuckets.filter { isHighUsageBucket($0.bucket) }
            : []
        let futureBuckets = futureBuckets(in: indexedBuckets, snapshot: snapshot)

        return chartView(
            snapshot: snapshot,
            indexedBuckets: indexedBuckets,
            points: points,
            highUsageBuckets: highUsageBuckets,
            futureBuckets: futureBuckets
        )
        .id(snapshot.range)
        .accessibilityLabel("Token 用量柱状图，合计 \(snapshot.totalTokens) Tokens")
    }

    private func chartView(
        snapshot: TokenUsageSnapshot,
        indexedBuckets: [IndexedTokenUsageBucket],
        points: [TokenUsageChartPoint],
        highUsageBuckets: [IndexedTokenUsageBucket],
        futureBuckets: [IndexedTokenUsageBucket]
    ) -> some View {
        Chart {
            ForEach(indexedBuckets) { bucket in
                RuleMark(x: .value("时间", bucket.xValue))
                    .foregroundStyle(.clear)
            }

            ForEach(points) { point in
                BarMark(
                    x: .value("时间", point.bucketX),
                    y: .value("Tokens", Double(point.tokens))
                )
                .foregroundStyle(by: .value("类型", point.category.title))
                .cornerRadius(2)
            }

            ForEach(highUsageBuckets) { bucket in
                PointMark(
                    x: .value("时间", bucket.xValue),
                    y: .value("Tokens", Double(bucket.bucket.totalTokens))
                )
                .foregroundStyle(.yellow)
                .symbolSize(42)
            }

            ForEach(futureBuckets) { bucket in
                RuleMark(x: .value("未到时间", bucket.xValue))
                    .foregroundStyle(.secondary.opacity(0.22))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
        }
        .chartForegroundStyleScale(
            domain: TokenUsageCategory.allCases.map(\.title),
            range: TokenUsageCategory.allCases.map(\.color)
        )
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartXScale(
            domain: chartXDomain(bucketCount: indexedBuckets.count),
            range: .plotDimension(startPadding: 10, endPadding: 10)
        )
        .chartYScale(domain: 0...Self.chartYUpperBound(for: snapshot.buckets))
        .chartXAxis {
            AxisMarks(values: axisValues(indexedBuckets, range: snapshot.range)) { value in
                AxisValueLabel {
                    if let xValue = value.as(Double.self),
                       let bucket = bucket(for: xValue, in: indexedBuckets) {
                        Text(axisLabel(for: bucket.start, range: snapshot.range))
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
            chartHoverOverlay(proxy: proxy, snapshot: snapshot)
        }
    }

    private func chartHoverOverlay(proxy: ChartProxy, snapshot: TokenUsageSnapshot) -> some View {
        GeometryReader { geometry in
            if let plotFrame = proxy.plotFrame {
                let plotRect = geometry[plotFrame]

                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())

                    if let hoverState,
                       snapshot.buckets.indices.contains(hoverState.bucketIndex) {
                        let bucket = snapshot.buckets[hoverState.bucketIndex]
                        if let lineX = proxy.position(forX: Double(hoverState.bucketIndex)) {
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

                        tokenTooltip(for: bucket, range: snapshot.range)
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
                              let bucketIndex = nearestBucketIndex(
                                to: location.x - plotRect.origin.x,
                                proxy: proxy,
                                bucketCount: snapshot.buckets.count
                              ) else {
                            hoverState = nil
                            return
                        }
                        hoverState = TokenUsageHoverState(
                            bucketIndex: bucketIndex,
                            location: location
                        )
                    case .ended:
                        hoverState = nil
                    }
                }
            }
        }
    }

    private func tokenTooltip(for bucket: TokenUsageBucket, range: TokenUsageRange) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(tooltipTitle(for: bucket.start, range: range))
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

    private func tooltipTitle(for date: Date, range: TokenUsageRange) -> String {
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

    static func chartYUpperBound(for buckets: [TokenUsageBucket]) -> Double {
        let maximum = buckets.map(\.totalTokens).max() ?? 1
        return max(10_000_000, Double(maximum) * 1.08)
    }

    private func futureBuckets(
        in buckets: [IndexedTokenUsageBucket],
        snapshot: TokenUsageSnapshot
    ) -> [IndexedTokenUsageBucket] {
        guard snapshot.range == .today,
              let currentHour = Calendar.current.dateInterval(
                of: .hour,
                for: snapshot.collectedAt
              )?.start else {
            return []
        }
        return buckets.filter { $0.bucket.start > currentHour }
    }

    private func chartMessage(_ message: String, systemImage: String) -> some View {
        Label(message, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func axisValues(_ buckets: [IndexedTokenUsageBucket], range: TokenUsageRange) -> [Double] {
        guard !buckets.isEmpty else { return [] }
        switch range {
        case .today:
            return Self.axisIndices(bucketCount: buckets.count, desiredCount: 7)
                .map(Double.init)
        case .last24Hours:
            return Self.stridingAxisIndices(bucketCount: buckets.count, step: 2)
                .map(Double.init)
        case .last30Days:
            return Self.stridingAxisIndices(bucketCount: buckets.count, step: 3)
                .map(Double.init)
        }
    }

    static func axisIndices(bucketCount: Int, desiredCount: Int) -> [Int] {
        guard bucketCount > 0 else { return [] }
        guard bucketCount > desiredCount, desiredCount > 1 else {
            return Array(0..<bucketCount)
        }

        let step = Double(bucketCount - 1) / Double(desiredCount - 1)
        return (0..<desiredCount).reduce(into: [Int]()) { indices, offset in
            let index = Int((Double(offset) * step).rounded())
            if indices.last != index {
                indices.append(index)
            }
        }
    }

    static func stridingAxisIndices(bucketCount: Int, step: Int) -> [Int] {
        guard bucketCount > 0 else { return [] }
        let safeStep = max(1, step)
        var indices = Array(stride(from: 0, to: bucketCount, by: safeStep))
        let lastIndex = bucketCount - 1
        if indices.last != lastIndex {
            indices.append(lastIndex)
        }
        return indices
    }

    private func chartXDomain(bucketCount: Int) -> ClosedRange<Double> {
        -0.5...max(0.5, Double(bucketCount) - 0.5)
    }

    private func bucket(
        for xValue: Double,
        in buckets: [IndexedTokenUsageBucket]
    ) -> TokenUsageBucket? {
        let index = Int(xValue.rounded())
        guard buckets.indices.contains(index) else { return nil }
        return buckets[index].bucket
    }

    private func nearestBucketIndex(
        to xPosition: CGFloat,
        proxy: ChartProxy,
        bucketCount: Int
    ) -> Int? {
        guard bucketCount > 0 else { return nil }
        return (0..<bucketCount).min { lhs, rhs in
            let lhsX = proxy.position(forX: Double(lhs)) ?? 0
            let rhsX = proxy.position(forX: Double(rhs)) ?? 0
            return abs(lhsX - xPosition) < abs(rhsX - xPosition)
        }
    }

    private func axisLabel(for date: Date, range: TokenUsageRange) -> String {
        switch range {
        case .last30Days:
            date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
        case .today, .last24Hours:
            date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)))
        }
    }
}

private struct TokenUsageHoverState {
    let bucketIndex: Int
    let location: CGPoint
}

private struct IndexedTokenUsageBucket: Identifiable {
    let index: Int
    let bucket: TokenUsageBucket

    var id: Date { bucket.start }
    var xValue: Double { Double(index) }
}

private struct TokenUsageChartPoint: Identifiable {
    let bucketStart: Date
    let bucketX: Double
    let category: TokenUsageCategory
    let tokens: Int64

    var id: String { "\(bucketStart.timeIntervalSince1970)-\(category.rawValue)" }

    static func points(for indexedBucket: IndexedTokenUsageBucket) -> [Self] {
        let bucket = indexedBucket.bucket
        return [
            Self(
                bucketStart: bucket.start,
                bucketX: indexedBucket.xValue,
                category: .input,
                tokens: bucket.inputTokens
            ),
            Self(
                bucketStart: bucket.start,
                bucketX: indexedBucket.xValue,
                category: .cache,
                tokens: bucket.cacheTokens
            ),
            Self(
                bucketStart: bucket.start,
                bucketX: indexedBucket.xValue,
                category: .output,
                tokens: bucket.outputTokens
            )
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

import Charts
import SwiftUI

@MainActor
struct TokenUsageChartView: View {
    @ObservedObject var store: TokenUsageStore
    @Binding var range: TokenUsageRange

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
                Text("只读自 CC Switch")
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

        return Chart(points) { point in
            BarMark(
                x: .value("时间", point.date),
                y: .value("Tokens", Double(point.tokens))
            )
            .foregroundStyle(by: .value("类型", point.category.title))
            .cornerRadius(2)
        }
        .chartForegroundStyleScale(
            domain: TokenUsageCategory.allCases.map(\.title),
            range: TokenUsageCategory.allCases.map(\.color)
        )
        .chartLegend(position: .bottom, alignment: .leading, spacing: 10)
        .chartXScale(range: .plotDimension(startPadding: 8, endPadding: 20))
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
        .accessibilityLabel("Token 用量柱状图，合计 \(snapshot.totalTokens) Tokens")
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
        case 1_000_000_000...:
            format(value, divisor: 1_000_000_000, suffix: "B")
        case 1_000_000...:
            format(value, divisor: 1_000_000, suffix: "M")
        case 1_000...:
            format(value, divisor: 1_000, suffix: "K")
        default:
            String(value)
        }
    }

    private static func format(_ value: Int64, divisor: Double, suffix: String) -> String {
        let scaled = Double(value) / divisor
        let pattern = scaled >= 100 ? "%.0f%@" : scaled >= 10 ? "%.1f%@" : "%.2f%@"
        return String(format: pattern, scaled, suffix)
    }
}

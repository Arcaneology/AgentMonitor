import AppKit
import Charts
import SwiftUI

@MainActor
struct TokenUsageChartView: View {
    @ObservedObject var store: TokenUsageStore
    @Binding var range: TokenUsageRange
    @State private var hoverState: TokenUsageHoverState?
    @State private var filter: TokenUsageFilter?
    @Environment(\.colorScheme) private var colorScheme

    private static let unit: Int64 = 100_000_000
    // Keep the established dimensions so the menu remains compact. The
    // position helper below also clamps correctly when a host is narrower than
    // this width (for example, a small menu-bar popover).
    private static let tooltipSize = CGSize(width: 164, height: 104)
    private static let tooltipGap: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Token 用量", systemImage: "chart.bar.fill")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                if let snapshot = displayedSnapshot {
                    Text(TokenCountFormatter.compact(snapshot.totalTokens))
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .accessibilityLabel("当前筛选合计 \(TokenCountFormatter.precise(snapshot.totalTokens)) Tokens")
                }

                if store.supportsCCSwitchSync {
                    Button {
                        Task { await store.syncFromCCSwitch(range: range) }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.isSyncing)
                    .help("用 CC Switch 校准一次，只补本地没有的记录")
                    .accessibilityLabel("校准 Token 数据")
                }
            }

            Picker("时间范围", selection: $range) {
                ForEach(TokenUsageRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.segmented)

            modelSelector(snapshot: store.snapshot)

            chartContent
                .frame(height: 176)

            reviewStatus(snapshot: displayedSnapshot)
            scanDiagnosticsStatus
        }
        .monitorCard()
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

    private var displayedSnapshot: TokenUsageSnapshot? {
        guard let snapshot = store.snapshot else { return nil }
        switch filter {
        case let .family(family): return snapshot.filtered(family: family)
        case let .model(modelID): return snapshot.filtered(model: modelID)
        case nil: return snapshot
        }
    }

    private var selectedFamily: TokenModelFamily? {
        guard case let .family(family) = filter else { return nil }
        return family
    }

    private var selectedModelID: String? {
        guard case let .model(modelID) = filter else { return nil }
        return modelID
    }

    @ViewBuilder
    private func reviewStatus(snapshot: TokenUsageSnapshot?) -> some View {
        if let summary = snapshot?.pendingReviewSummary, summary.count > 0 {
            Menu {
                Text("待核对 \(summary.count) 条 · \(TokenCountFormatter.precise(summary.tokens)) Tokens")
                    .font(.caption)
                if !summary.reasons.isEmpty {
                    Divider()
                    ForEach(Array(summary.reasons.sorted { $0.key < $1.key }), id: \.key) { item in
                        Text("\(item.key)：\(item.value) 条")
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle")
                    Text("待核对 \(summary.count) 条")
                    Spacer(minLength: 4)
                    Text(TokenCountFormatter.compact(summary.tokens))
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("待核对 \(summary.count) 条 Token，合计 \(TokenCountFormatter.precise(summary.tokens))")
        }
    }

    @ViewBuilder
    private var scanDiagnosticsStatus: some View {
        if !store.scanDiagnostics.isEmpty {
            Menu {
                ForEach(store.scanDiagnostics.prefix(20)) { diagnostic in
                    Text("\(diagnostic.reason)：\(diagnostic.path)")
                }
                if store.scanDiagnostics.count > 20 {
                    Text("还有 \(store.scanDiagnostics.count - 20) 条")
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("扫描提示 \(store.scanDiagnostics.count) 条")
                    Spacer(minLength: 4)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("扫描提示 \(store.scanDiagnostics.count) 条，点击查看详情")
        }
    }

    @ViewBuilder
    private func modelSelector(snapshot: TokenUsageSnapshot?) -> some View {
        let modelIDs = modelIDs(for: snapshot)
        let legendModelIDs = legendModelIDs(for: snapshot)
        let families = modelFamilies(for: modelIDs)

        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Menu {
                    ForEach(families, id: \.self) { family in
                        Button {
                            filter = TokenUsageFilter.toggling(family, current: filter)
                        } label: {
                            Label(
                                family.title,
                                systemImage: selectedFamily == family ? "checkmark" : "circle"
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.stack.3d.up")
                        Text(selectedFamily?.title ?? "模型系列")
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel(selectedFamily.map { "模型系列，当前 \($0.title)" } ?? "模型系列，当前未筛选")

                Spacer(minLength: 0)
            }

            TokenModelLegend(
                modelIDs: legendModelIDs,
                selectedModelID: selectedModelID
            ) { modelID in
                filter = TokenUsageFilter.toggling(modelID: modelID, current: filter)
            }
        }
    }

    private func modelFamilies(for modelIDs: [String]) -> [TokenModelFamily] {
        var families = Set(modelIDs.map(TokenModelCatalog.family))
        families.remove(.unknown)
        return families.sorted { familySortIndex($0) < familySortIndex($1) }
    }

    private func modelIDs(for snapshot: TokenUsageSnapshot?) -> [String] {
        let observed = snapshot?.modelIDs ?? []
        var all = Set(TokenModelCatalog.knownModelIDs)
        all.formUnion(observed.map(TokenModelCatalog.canonicalID))
        if let selectedModelID {
            all.insert(TokenModelCatalog.canonicalID(selectedModelID))
        }
        return all.sorted(by: modelSort)
    }

    private func legendModelIDs(for snapshot: TokenUsageSnapshot?) -> [String] {
        var observed = Set((snapshot?.modelIDs ?? []).map(TokenModelCatalog.canonicalID))
        if let selectedModelID {
            observed.insert(TokenModelCatalog.canonicalID(selectedModelID))
        }
        return observed.sorted(by: modelSort)
    }

    private func modelSort(_ lhs: String, _ rhs: String) -> Bool {
        let left = TokenModelCatalog.metadata(for: lhs)
        let right = TokenModelCatalog.metadata(for: rhs)
        if left.family != right.family {
            return familySortIndex(left.family) < familySortIndex(right.family)
        }
        if left.rank != right.rank { return left.rank > right.rank }
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }

    private func familySortIndex(_ family: TokenModelFamily) -> Int {
        switch family {
        case .gpt: 0
        case .claude: 1
        case .gemini: 2
        case .grok: 3
        case .kimi: 4
        case .deepSeek: 5
        case .unknown: 6
        }
    }

    @ViewBuilder
    private var chartContent: some View {
        if let errorDescription = store.errorDescription {
            chartMessage(errorDescription, systemImage: "externaldrive.badge.exclamationmark")
        } else if let snapshot = displayedSnapshot {
            if snapshot.totalTokens == 0 {
                let message = filter == nil ? "该时段暂无 Token 记录" : "所选范围在该时段暂无 Token 记录"
                chartMessage(message, systemImage: filter == nil ? "chart.bar" : "magnifyingglass")
                    .accessibilityLabel(message)
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
        let modelIDs = chartModelIDs(in: snapshot)
        let points = indexedBuckets.flatMap {
            TokenUsageChartPoint.points(for: $0, modelIDs: modelIDs)
        }
        let futureBuckets = futureBuckets(in: indexedBuckets, snapshot: snapshot)
        let yUpperBound = Self.chartDisplayYUpperBound(for: snapshot.buckets)
        let unitBoundaries = TokenUsageChartGeometry.unitBoundaries(upTo: yUpperBound)

        return chartView(
            snapshot: snapshot,
            indexedBuckets: indexedBuckets,
            points: points,
            modelIDs: modelIDs,
            futureBuckets: futureBuckets,
            yUpperBound: yUpperBound,
            unitBoundaries: unitBoundaries
        )
        .id(snapshot.range)
        .accessibilityLabel(chartAccessibilityLabel(for: snapshot))
    }

    private func chartModelIDs(in snapshot: TokenUsageSnapshot) -> [String] {
        var observed = Set(snapshot.modelIDs.map(TokenModelCatalog.canonicalID))
        if snapshot.buckets.contains(where: { $0.models.isEmpty && $0.totalTokens > 0 }) {
            observed.insert("unknown")
        }
        guard !observed.isEmpty else {
            // Older locally-created snapshots did not carry model buckets. A
            // synthetic unknown segment keeps their aggregate visible.
            return snapshot.totalTokens > 0 ? ["unknown"] : []
        }
        return Array(observed).sorted(by: modelSort)
    }

    private func chartAccessibilityLabel(for snapshot: TokenUsageSnapshot) -> String {
        let modelText = selectedModelID.map { "，模型 \(TokenModelCatalog.displayName(for: $0))" }
            ?? selectedFamily.map { "，模型系列 \($0.title)" }
            ?? "，全部模型"
        return "Token 用量柱状图\(modelText)，合计 \(TokenCountFormatter.precise(snapshot.totalTokens)) Tokens"
    }

    private func chartView(
        snapshot: TokenUsageSnapshot,
        indexedBuckets: [IndexedTokenUsageBucket],
        points: [TokenUsageChartPoint],
        modelIDs: [String],
        futureBuckets: [IndexedTokenUsageBucket],
        yUpperBound: Double,
        unitBoundaries: [Double]
    ) -> some View {
        Chart {
            // Rule marks preserve empty/future buckets on the x axis.
            ForEach(indexedBuckets) { bucket in
                RuleMark(x: .value("时间", bucket.xValue))
                    .foregroundStyle(.clear)
            }

            // Explicit y ranges keep adjacent model segments contiguous. A
            // model change only changes the fill; no corner radius or spacing
            // is applied at that boundary.
            ForEach(points) { point in
                BarMark(
                    x: .value("时间", point.bucketX),
                    yStart: .value("起点", point.lowerBound),
                    yEnd: .value("终点", point.upperBound)
                )
                .foregroundStyle(by: .value("模型", point.modelID))
                .cornerRadius(0)
            }

            // Global 1 亿 boundaries are independent of each model's segment,
            // so a tall bar remains visibly divided at 1 亿, 2 亿, ... even
            // when a provider/model boundary falls between them.
            ForEach(unitBoundaries, id: \.self) { boundary in
                RuleMark(y: .value("每格1亿 Token", boundary))
                    .foregroundStyle(.secondary.opacity(0.20))
                    .lineStyle(StrokeStyle(lineWidth: 0.75))
            }

            ForEach(futureBuckets) { bucket in
                RuleMark(x: .value("未到时间", bucket.xValue))
                    .foregroundStyle(.secondary.opacity(0.22))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
        }
        .chartForegroundStyleScale(
            domain: modelIDs,
            range: modelIDs.map { TokenModelPalette.color(for: $0, scheme: colorScheme) }
        )
        .chartLegend(.hidden)
        .chartXScale(
            domain: chartXDomain(bucketCount: indexedBuckets.count),
            range: .plotDimension(startPadding: 14, endPadding: 24)
        )
        .chartYScale(domain: 0...yUpperBound)
        .chartXAxis {
            AxisMarks(values: axisValues(indexedBuckets, range: snapshot.range)) { value in
                AxisValueLabel {
                    if let xValue = value.as(Double.self),
                       let bucket = bucket(for: xValue, in: indexedBuckets) {
                        Text(axisLabel(for: bucket.start, range: snapshot.range))
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0] + unitBoundaries) { value in
                AxisGridLine()
                    .foregroundStyle(.secondary.opacity(0.18))
                AxisValueLabel {
                    if let tokens = value.as(Double.self) {
                        Text(TokenCountFormatter.chineseUnit(Int64(tokens.rounded())))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            ZStack {
                unitGapOverlay(proxy: proxy, snapshot: snapshot, unitBoundaries: unitBoundaries)
                chartHoverOverlay(proxy: proxy, snapshot: snapshot)
            }
        }
        .compositingGroup()
    }

    /// Erases a two-pixel strip only over bars that cross a global 1 亿
    /// boundary. Model segments share a boundary and therefore receive no
    /// strip; their only visual distinction is color. The enclosing chart is a
    /// compositing group so destination-out reveals the chart card behind it.
    private func unitGapOverlay(
        proxy: ChartProxy,
        snapshot: TokenUsageSnapshot,
        unitBoundaries: [Double]
    ) -> some View {
        GeometryReader { geometry in
            if let plotFrame = proxy.plotFrame {
                let plotRect = geometry[plotFrame]
                let bucketCount = snapshot.buckets.count
                let columnWidth = plotRect.width / CGFloat(max(bucketCount, 1))
                let barWidth = max(2, columnWidth * 0.62)

                ZStack {
                    ForEach(unitBoundaries, id: \.self) { boundary in
                        if let y = proxy.position(forY: boundary) {
                            ForEach(snapshot.buckets.indices, id: \.self) { index in
                                if snapshot.buckets[index].totalTokens > Int64(boundary) {
                                    if let x = proxy.position(forX: Double(index)) {
                                        Rectangle()
                                            .fill(Color.black)
                                            .frame(width: barWidth, height: 2)
                                            .position(
                                                x: plotRect.minX + x,
                                                y: plotRect.minY + y
                                            )
                                            .blendMode(.destinationOut)
                                    }
                                }
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
            }
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
                .onTapGesture { location in
                    guard plotRect.contains(location),
                          let index = nearestBucketIndex(
                            to: location.x - plotRect.minX,
                            proxy: proxy,
                            bucketCount: snapshot.buckets.count
                          ) else {
                        hoverState = nil
                        return
                    }
                    hoverState = TokenUsageHoverState(bucketIndex: index, location: location)
                }
            }
        }
    }

    private func tokenTooltip(for bucket: TokenUsageBucket, range: TokenUsageRange) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(tooltipTitle(for: bucket.start, range: range))
                    .font(.caption.weight(.semibold))

                if let selectedModelID {
                    Text("· \(TokenModelCatalog.displayName(for: selectedModelID))")
                        .font(.caption2)
                        .lineLimit(1)
                }

                Spacer(minLength: 2)
            }

            tokenTooltipRow("输入", value: bucket.inputTokens)
            tokenTooltipRow("缓存", value: bucket.cacheTokens)
            tokenTooltipRow("输出", value: bucket.outputTokens)

            Divider()

            HStack {
                Text("合计")
                Spacer()
                Text(TokenCountFormatter.precise(bucket.totalTokens))
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tooltipAccessibilityLabel(for: bucket, range: range))
        .allowsHitTesting(false)
    }

    private func tooltipAccessibilityLabel(for bucket: TokenUsageBucket, range: TokenUsageRange) -> String {
        let selection: String
        switch filter {
        case let .family(family): selection = "，模型系列 \(family.title)"
        case let .model(modelID): selection = "，模型 \(TokenModelCatalog.displayName(for: modelID))"
        case nil: selection = ""
        }
        return "\(tooltipTitle(for: bucket.start, range: range))\(selection)：输入 \(TokenCountFormatter.precise(bucket.inputTokens))，缓存 \(TokenCountFormatter.precise(bucket.cacheTokens))，输出 \(TokenCountFormatter.precise(bucket.outputTokens))，合计 \(TokenCountFormatter.precise(bucket.totalTokens)) Tokens"
    }

    static func tooltipPosition(for location: CGPoint, in availableSize: CGSize) -> CGPoint {
        let width = Self.tooltipSize.width
        let height = Self.tooltipSize.height
        let preferredX: CGFloat
        if location.x + Self.tooltipGap + width <= availableSize.width {
            preferredX = location.x + Self.tooltipGap + width / 2
        } else {
            preferredX = location.x - Self.tooltipGap - width / 2
        }

        let halfWidth = width / 2
        let minX = min(halfWidth, availableSize.width / 2)
        let maxX = max(halfWidth, availableSize.width - halfWidth)
        let halfHeight = height / 2
        let minY = min(halfHeight, availableSize.height / 2)
        let maxY = max(halfHeight, availableSize.height - halfHeight)
        return CGPoint(
            x: min(max(preferredX, minX), maxX),
            y: min(max(location.y, minY), maxY)
        )
    }

    private func tokenTooltipRow(_ title: String, value: Int64) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Spacer()
            Text(TokenCountFormatter.precise(value))
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

    /// Kept as a compatibility helper for the existing chart tests. The
    /// rendered chart uses `chartDisplayYUpperBound`, which rounds to global
    /// 1 亿 cells; this helper retains the previous small-range behavior.
    static func chartYUpperBound(for buckets: [TokenUsageBucket]) -> Double {
        let maximum = buckets.map(\.totalTokens).max() ?? 1
        return max(10_000_000, Double(maximum) * 1.08)
    }

    static func chartDisplayYUpperBound(for buckets: [TokenUsageBucket]) -> Double {
        let maximum = max(0, buckets.map(\.totalTokens).max() ?? 0)
        let units = max(1, Int64(ceil(Double(maximum) / Double(Self.unit))))
        return Double(units * Self.unit)
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

private struct TokenModelLegend: View {
    @Environment(\.colorScheme) private var colorScheme
    let modelIDs: [String]
    let selectedModelID: String?
    let onSelect: (String) -> Void

    var body: some View {
        TokenModelFlowLayout(horizontalSpacing: 8, verticalSpacing: 5) {
            ForEach(modelIDs, id: \.self) { modelID in
                let metadata = TokenModelCatalog.metadata(for: modelID)
                TokenModelLegendButton(
                    title: metadata.name,
                    color: TokenModelPalette.color(for: modelID, scheme: colorScheme),
                    isSelected: selectedModelID == modelID
                ) {
                    onSelect(modelID)
                }
                .accessibilityLabel("模型 \(metadata.name)，\(metadata.family.title)")
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("模型图例")
    }
}

private struct TokenModelLegendButton: View {
    let title: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(isSelected ? color.opacity(0.18) : Color.secondary.opacity(0.07))
            )
            .overlay {
                Capsule()
                    .stroke(isSelected ? color.opacity(0.55) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
    }
}

private struct TokenModelFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = makeRows(proposal: proposal, subviews: subviews)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { partial, row in
            partial + row.height + (partial == 0 ? 0 : verticalSpacing)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = makeRows(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func makeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let availableWidth = proposal.width ?? .greatestFiniteMagnitude
        var rows: [Row] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            guard var row = rows.popLast() else {
                rows.append(Row(indices: [index], width: size.width, height: size.height))
                continue
            }
            let proposedWidth = row.indices.isEmpty
                ? size.width
                : row.width + horizontalSpacing + size.width
            if proposedWidth <= availableWidth || row.indices.isEmpty {
                row.indices.append(index)
                row.width = proposedWidth
                row.height = max(row.height, size.height)
                rows.append(row)
            } else {
                rows.append(row)
                rows.append(Row(indices: [index], width: size.width, height: size.height))
            }
        }
        return rows
    }
}

private enum TokenModelPalette {
    static func color(for modelID: String, scheme: ColorScheme) -> Color {
        let metadata = TokenModelCatalog.metadata(for: modelID)
        let hue: Double
        switch metadata.family {
        case .gpt: hue = 0.61
        case .claude: hue = 0.08
        case .gemini: hue = 0.77
        case .grok: hue = 0.50
        case .kimi: hue = 0.94
        case .deepSeek: hue = 0.18
        case .unknown: hue = 0
        }
        // Use SwiftUI's explicit appearance, including preview/QA overrides.
        // Opaque colors avoid reversing rank depth against dark backgrounds.
        let depth = min(1, max(0, metadata.normalizedRank))
        let isDark = scheme == .dark
        if metadata.family == .unknown {
            return Color(white: isDark ? 0.70 : 0.48)
        }
        return Color(
            hue: hue,
            saturation: isDark ? 0.30 + 0.38 * depth : 0.35 + 0.50 * depth,
            brightness: isDark ? 0.98 - 0.12 * depth : 0.92 - 0.34 * depth
        )
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
    let modelID: String
    let tokens: Int64
    let lowerBound: Double
    let upperBound: Double

    var id: String { "\(bucketStart.timeIntervalSince1970)-\(modelID)" }

    static func points(
        for indexedBucket: IndexedTokenUsageBucket,
        modelIDs: [String]
    ) -> [Self] {
        let bucket = indexedBucket.bucket
        var points: [Self] = []
        var lowerBound: Int64 = 0

        for modelID in modelIDs {
            let tokens = bucket.models[modelID]?.totalTokens ?? 0
            guard tokens > 0 else { continue }
            let upperBound = lowerBound + tokens
            points.append(Self(
                bucketStart: bucket.start,
                bucketX: indexedBucket.xValue,
                modelID: modelID,
                tokens: tokens,
                lowerBound: Double(lowerBound),
                upperBound: Double(upperBound)
            ))
            lowerBound = upperBound
        }

        // Snapshots generated before per-model accounting was introduced still
        // have useful aggregate totals. Draw those as an explicitly unknown
        // model instead of dropping the bar.
        if points.isEmpty, bucket.totalTokens > 0 {
            points.append(Self(
                bucketStart: bucket.start,
                bucketX: indexedBucket.xValue,
                modelID: "unknown",
                tokens: bucket.totalTokens,
                lowerBound: 0,
                upperBound: Double(bucket.totalTokens)
            ))
        }
        return points
    }
}

/// Pure geometry used by the chart and its unit tests. The chart's y ranges
/// use these exact boundaries so a 0.3/1/2.4 亿 fixture cannot be rounded into
/// equal-height visual cells.
enum TokenUsageChartGeometry {
    static let tokenUnit: Int64 = 100_000_000

    static func unitBoundaries(upTo upperBound: Double) -> [Double] {
        guard upperBound > 0 else { return [] }
        let count = Int(floor((upperBound + 0.000_001) / Double(tokenUnit)))
        guard count > 0 else { return [] }
        return (1...count).map { Double($0) * Double(tokenUnit) }
    }

    static func unitCellRanges(for totalTokens: Int64) -> [ClosedRange<Double>] {
        guard totalTokens > 0 else { return [] }
        var ranges: [ClosedRange<Double>] = []
        var lower: Int64 = 0
        while lower < totalTokens {
            let upper = min(totalTokens, lower + tokenUnit)
            ranges.append(Double(lower)...Double(upper))
            lower = upper
        }
        return ranges
    }

    static func modelRanges(
        _ totals: [(modelID: String, tokens: Int64)]
    ) -> [TokenUsageModelRange] {
        var lower: Int64 = 0
        return totals.compactMap { modelID, tokens in
            guard tokens > 0 else { return nil }
            let upper = lower + tokens
            defer { lower = upper }
            return TokenUsageModelRange(
                modelID: modelID,
                lowerBound: Double(lower),
                upperBound: Double(upper)
            )
        }
    }
}

struct TokenUsageModelRange: Equatable, Sendable {
    let modelID: String
    let lowerBound: Double
    let upperBound: Double
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

    /// Full precision for tooltips, with grouping but without rounding to 亿/万.
    static func precise(_ value: Int64) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// Chinese unit labels for the chart's fixed 1 亿 grid.
    static func chineseUnit(_ value: Int64) -> String {
        guard value >= 100_000_000 else { return String(value) }
        let scaled = Double(value) / 100_000_000
        if scaled.rounded() == scaled {
            return "\(Int64(scaled))亿"
        }
        return String(format: "%.1f亿", scaled)
    }

    private static func format(_ value: Int64, divisor: Double, suffix: String) -> String {
        let scaled = Double(value) / divisor
        return String(format: "%.2f%@", scaled, suffix)
    }
}

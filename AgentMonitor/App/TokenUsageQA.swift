#if AGENT_MONITOR_QA
import SwiftUI

/// Debug-only fixture window. It never opens the user's usage database.
struct TokenUsageQAFixtureReader: TokenUsageReading {
    var empty = false

    func records(from start: Date, through end: Date) async throws -> [TokenUsageRecord] {
        guard !empty else { return [] }
        let hour = Calendar.current.dateInterval(of: .hour, for: end)!.start
        let samples: [(Int, String, Int64)] = [
            (-3, "gpt-5.6-luna", 30_000_000),
            (-2, "gpt-5.6-sol", 100_000_000),
            (-1, "gpt-6-astra", 240_000_000),
            (0, "gpt-6-astra", 150_000_000),
            (0, "claude-opus-5", 70_000_000),
            (0, "gemini-3.8-flash-high", 20_000_000)
        ]
        return samples.map { offset, model, total in
            TokenUsageRecord(
                timestamp: hour.addingTimeInterval(Double(offset) * 3_600),
                appType: "codex", inputTokens: total * 9 / 10,
                outputTokens: total / 10, cacheReadTokens: total / 2,
                cacheCreationTokens: 0, inputTokenSemantics: InputTokenSemantics.total.rawValue,
                model: model
            )
        }
    }
}

@MainActor
struct TokenUsageQAView: View {
    @ObservedObject var store: MonitorStore
    @State private var dark = false
    @State private var empty = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("深色", isOn: $dark)
                Toggle("空数据", isOn: $empty)
            }
            .toggleStyle(.checkbox)
            .padding(12)
            Text("隔离样本：0.3／1／2.4 亿及模型跨格")
                .font(.caption)
                .padding(.bottom, 8)
            Divider()
            TokenUsageQAContent(store: store, empty: empty)
                .id(empty)
            Spacer(minLength: 0)
        }
        .frame(width: 420)
        .preferredColorScheme(dark ? .dark : .light)
    }
}

@MainActor
private struct TokenUsageQAContent: View {
    let store: MonitorStore
    @StateObject private var usageStore: TokenUsageStore

    init(store: MonitorStore, empty: Bool) {
        self.store = store
        _usageStore = StateObject(wrappedValue: TokenUsageStore(reader: TokenUsageQAFixtureReader(empty: empty)))
    }

    var body: some View {
        MenuBarContentView(store: store, tokenUsageStore: usageStore)
    }
}
#endif

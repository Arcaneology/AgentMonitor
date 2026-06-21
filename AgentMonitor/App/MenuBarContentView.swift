import AppKit
import SwiftUI

struct MenuBarContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Agent Monitor 已就绪", systemImage: "checkmark.circle")
                .font(.headline)

            Text("进程与端口监控将在后续阶段实现。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            Button("退出 Agent Monitor") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 320)
    }
}


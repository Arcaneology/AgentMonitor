import SwiftUI

/// Small About popover opened from the panel footer.
struct AboutView: View {
    static let author = "ArcaneStudio"
    static let license = "MIT License"

    var body: some View {
        VStack(spacing: 10) {
            Image("AppMark")
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)

            VStack(spacing: 3) {
                Text(verbatim: "Agent Monitor")
                    .font(.headline)
                Text(versionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    Text(L("作者", "Author"))
                        .foregroundStyle(.secondary)
                    Text(verbatim: Self.author)
                }
                GridRow {
                    Text(L("协议", "License"))
                        .foregroundStyle(.secondary)
                    Text(verbatim: Self.license)
                }
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 220)
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return L("版本 \(version)（\(build)）", "Version \(version) (\(build))")
    }
}

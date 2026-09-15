import Foundation

/// Interface language chosen from the panel footer. Without an explicit choice
/// the app follows the system: Chinese systems start in Chinese, every other
/// system starts in English.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case chinese = "zh"
    case english = "en"

    static let storageKey = "app.language"

    var id: Self { self }

    /// Short label for the footer switch; each option names itself in its own
    /// language so it stays recognizable whichever language is active.
    var switchTitle: String {
        switch self {
        case .chinese: "中文"
        case .english: "EN"
        }
    }

    static var current: AppLanguage {
        // Hosted unit tests share the Debug app's defaults domain. They assert
        // the Chinese copy, so a language picked in the Debug app must not leak
        // into them.
        if isTestHost { return .chinese }
        if let rawValue = UserDefaults.standard.string(forKey: storageKey),
           let language = AppLanguage(rawValue: rawValue) {
            return language
        }
        return systemDefault
    }

    static var systemDefault: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .chinese : .english
    }

    private static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

/// Returns the copy for the current interface language. Strings are kept as
/// inline pairs so each Chinese phrase sits next to its English counterpart.
func L(_ chinese: String, _ english: String) -> String {
    AppLanguage.current == .english ? english : chinese
}

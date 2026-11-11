// Minimal in-app localization: every user-visible string is written as
// tr("English", "Português") and resolved against the Language setting, so
// switching language in the menu takes effect immediately (no relaunch).

import Foundation

enum Language: String, CaseIterable {
    case english = "en"
    case portuguese = "pt"

    /// Shown in its own language so it is always recognizable.
    var title: String {
        switch self {
        case .english: return "English"
        case .portuguese: return "Português"
        }
    }

    static var systemDefault: Language {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("pt") ? .portuguese : .english
    }
}

func tr(_ english: String, _ portuguese: String) -> String {
    Settings.language == .portuguese ? portuguese : english
}

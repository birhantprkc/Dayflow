import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
  case system = ""
  case english = "en"
  case simplifiedChinese = "zh-Hans"
  case korean = "ko"
  case german = "de"
  case russian = "ru"
  case french = "fr"
  case traditionalChinese = "zh-Hant"
  case japanese = "ja"

  var id: String { rawValue }

  // Native names stay readable even if someone chooses an unfamiliar language.
  var title: String {
    switch self {
    case .system: return String(localized: "System default")
    case .english: return "English"
    case .simplifiedChinese: return "简体中文"
    case .korean: return "한국어"
    case .german: return "Deutsch"
    case .russian: return "Русский"
    case .french: return "Français"
    case .traditionalChinese: return "繁體中文"
    case .japanese: return "日本語"
    }
  }
}

enum AppLanguagePreferences {
  private static let key = "AppleLanguages"

  static func selection(in defaults: UserDefaults = .standard) -> AppLanguage {
    // Read only the app domain: the global AppleLanguages array is the system
    // preference, not an explicit override for Dayflow.
    let domain = defaults.persistentDomain(
      forName: Bundle.main.bundleIdentifier ?? "teleportlabs.com.Dayflow")
    guard let languages = domain?[key] as? [String], !languages.isEmpty else { return .system }
    return selection(for: languages)
  }

  static func selection(for languages: [String]) -> AppLanguage {
    guard !languages.isEmpty else { return .system }
    let supported = AppLanguage.allCases.filter { $0 != .system }.map(\.rawValue)
    let match =
      Bundle.preferredLocalizations(from: supported, forPreferences: languages).first ?? "en"
    return AppLanguage(rawValue: match) ?? .english
  }

  static func setSelection(_ language: AppLanguage, in defaults: UserDefaults = .standard) {
    if language == .system {
      defaults.removeObject(forKey: key)
    } else {
      defaults.set([language.rawValue], forKey: key)
    }
  }
}

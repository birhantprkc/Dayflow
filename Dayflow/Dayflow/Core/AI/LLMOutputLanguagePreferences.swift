import Foundation

enum LLMOutputLanguagePreferences {
  private static let overrideKey = "llmOutputLanguageOverride"
  private static let store = UserDefaults.standard

  static var override: String {
    get { store.string(forKey: overrideKey) ?? "" }
    set { store.set(newValue, forKey: overrideKey) }
  }

  static var normalizedOverride: String? {
    let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
    // An explicit choice wins, including English on a non-English interface.
    guard !trimmed.isEmpty else { return defaultOutputLanguage }
    return trimmed
  }

  static var defaultOutputLanguage: String? {
    defaultOutputLanguage(for: Bundle.main.preferredLocalizations.first ?? "en")
  }

  static func defaultOutputLanguage(for localization: String) -> String? {
    switch localization {
    case "zh-Hans": return "Simplified Chinese"
    case "zh-Hant": return "Traditional Chinese"
    case "ko": return "Korean"
    case "de": return "German"
    case "ru": return "Russian"
    case "fr": return "French"
    case "ja": return "Japanese"
    default: return nil
    }
  }

  static func languageInstruction(forJSON: Bool) -> String? {
    guard let lang = normalizedOverride else { return nil }
    let verbatimClause =
      "If any rule requires an exact English phrase (e.g., \"Scattered apps and sites\"), keep it verbatim."
    if forJSON {
      return
        "The user only speaks \(lang). Respond in \(lang), but keep JSON keys in English exactly as specified. \(verbatimClause)"
    }
    return "The user only speaks \(lang). Respond in \(lang). \(verbatimClause)"
  }
}

import XCTest

@testable import Dayflow

final class LocalizationTests: XCTestCase {
  func testLanguagePickerPersistsOnlyAnAppOverrideAndCanRemoveIt() throws {
    let suiteName = "Dayflow.LocalizationTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    AppLanguagePreferences.setSelection(.japanese, in: defaults)
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["ja"])
    AppLanguagePreferences.setSelection(.system, in: defaults)
    XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"])
  }

  func testRegionalLanguagePreferencesResolveToSupportedTranslations() {
    XCTAssertEqual(AppLanguagePreferences.selection(for: ["de-DE"]), .german)
    XCTAssertEqual(AppLanguagePreferences.selection(for: ["zh-Hant-TW"]), .traditionalChinese)
    XCTAssertEqual(AppLanguagePreferences.selection(for: ["zh-Hans-CN"]), .simplifiedChinese)
    XCTAssertEqual(AppLanguagePreferences.selection(for: []), .system)
  }

  func testEverySupportedLanguageHasBundledInterfaceAndPermissionStrings() throws {
    let languages = ["zh-Hans", "ko", "de", "ru", "fr", "zh-Hant", "ja"]
    for language in languages {
      let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
      let bundle = try XCTUnwrap(Bundle(path: path))
      let settings = bundle.localizedString(forKey: "Settings", value: nil, table: "Localizable")
      XCTAssertFalse(settings.isEmpty)
      XCTAssertNotEqual(settings, "Settings", language)
      let permission = bundle.localizedString(
        forKey: "NSScreenCaptureUsageDescription", value: nil, table: "InfoPlist")
      XCTAssertNotEqual(permission, "NSScreenCaptureUsageDescription", language)
    }
  }

  func testOutputLanguageFollowsSupportedInterfaceLanguages() {
    XCTAssertEqual(
      LLMOutputLanguagePreferences.defaultOutputLanguage(for: "zh-Hans"), "Simplified Chinese")
    XCTAssertEqual(
      LLMOutputLanguagePreferences.defaultOutputLanguage(for: "zh-Hant"), "Traditional Chinese")
    XCTAssertEqual(LLMOutputLanguagePreferences.defaultOutputLanguage(for: "ja"), "Japanese")
    XCTAssertEqual(LLMOutputLanguagePreferences.defaultOutputLanguage(for: "ko"), "Korean")
    XCTAssertEqual(LLMOutputLanguagePreferences.defaultOutputLanguage(for: "de"), "German")
    XCTAssertEqual(LLMOutputLanguagePreferences.defaultOutputLanguage(for: "ru"), "Russian")
    XCTAssertEqual(LLMOutputLanguagePreferences.defaultOutputLanguage(for: "fr"), "French")
    XCTAssertNil(LLMOutputLanguagePreferences.defaultOutputLanguage(for: "en"))
    XCTAssertNil(LLMOutputLanguagePreferences.defaultOutputLanguage(for: "unsupported"))
  }

  func testExplicitEnglishOutputIsNotMistakenForFollowingTheInterface() {
    let previous = LLMOutputLanguagePreferences.override
    defer { LLMOutputLanguagePreferences.override = previous }
    LLMOutputLanguagePreferences.override = " English "
    XCTAssertEqual(LLMOutputLanguagePreferences.normalizedOverride, "English")
    XCTAssertTrue(
      LLMOutputLanguagePreferences.languageInstruction(forJSON: true)?.contains(
        "Respond in English") == true)
  }

  func testStorageNumbersDoNotParseTranslatedUnitLabels() {
    XCTAssertEqual(
      StorageLimitOption(id: 0, label: "1 ГБ", bytes: 1_000_000_000).shortLabel, 1.formatted())
    XCTAssertEqual(
      StorageLimitOption(id: 1, label: "2 Go", bytes: 2_000_000_000).shortLabel, 2.formatted())
  }

  func testInternalLabelsRemainStableAcrossInterfaceLanguages() {
    XCTAssertEqual(LLMProviderID.local.providerLabel, "local")
    XCTAssertEqual(DashboardChatProvider.gemini.runtimeLabel, "gemini_function_calling")
    XCTAssertEqual(DashboardChatTurnRole.user.promptLabel, "User")
    XCTAssertEqual(DashboardChatTurnRole.assistant.promptLabel, "Assistant")
  }

  func testLocalizedInterfaceDoesNotChangeWireTimeParsing() {
    XCTAssertEqual(parseTimeHMMA(timeString: "9:30 AM"), 570)
    XCTAssertEqual(parseTimeHMMA(timeString: "11:59 PM"), 1439)
  }

  /// The onboarding sentence takes the CLI tool first and the subscription brand second.
  /// Languages that name the brand first must address the arguments by index.
  func testOnboardingProviderSentenceKeepsToolAndSubscriptionApart() throws {
    let key =
      "Dayflow uses %@ through your existing %@ subscription. Install it and sign in on this Mac, then we'll verify the connection."
    let subscriptionPhrase = [
      "de": "ChatGPT-Abo", "fr": "abonnement ChatGPT", "ja": "ChatGPTサブスクリプション",
      "ko": "ChatGPT 구독", "ru": "подписку ChatGPT", "zh-Hans": "ChatGPT 订阅",
      "zh-Hant": "ChatGPT 訂閱",
    ]
    for (language, phrase) in subscriptionPhrase {
      let bundle = try languageBundle(language)
      let format = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
      XCTAssertNotEqual(format, key, language)
      let sentence = String(format: format, "Codex CLI", "ChatGPT")
      XCTAssertTrue(sentence.contains("Codex CLI"), "\(language): \(sentence)")
      XCTAssertTrue(sentence.contains(phrase), "\(language): \(sentence)")
      XCTAssertFalse(
        sentence.contains("Codex CLI-Abo") || sentence.contains("Codex CLI 订阅"),
        "\(language): \(sentence)")
    }
  }

  /// Plural keys must pick the grammatical form from each language's CLDR rules, not
  /// from an English one/other test.
  func testPluralUnitsFollowEachLanguagesRules() throws {
    let russian = try languageBundle("ru")
    let russianLocale = Locale(identifier: "ru")
    XCTAssertEqual(
      pluralized("%lld hours", count: 1, bundle: russian, locale: russianLocale), "1 час")
    XCTAssertEqual(
      pluralized("%lld hours", count: 2, bundle: russian, locale: russianLocale), "2 часа")
    XCTAssertEqual(
      pluralized("%lld hours", count: 5, bundle: russian, locale: russianLocale), "5 часов")
    XCTAssertEqual(
      pluralized("%lld minutes", count: 1, bundle: russian, locale: russianLocale), "1 минута")
    XCTAssertEqual(
      pluralized("%lld minutes", count: 3, bundle: russian, locale: russianLocale), "3 минуты")
    XCTAssertEqual(
      pluralized("%lld minutes", count: 11, bundle: russian, locale: russianLocale), "11 минут")

    let german = try languageBundle("de")
    let germanLocale = Locale(identifier: "de")
    XCTAssertEqual(
      pluralized("%lld minutes", count: 1, bundle: german, locale: germanLocale), "1 Minute")
    XCTAssertEqual(
      pluralized("%lld minutes", count: 2, bundle: german, locale: germanLocale), "2 Minuten")

    let japanese = try languageBundle("ja")
    XCTAssertEqual(
      pluralized("%lld hours", count: 1, bundle: japanese, locale: Locale(identifier: "ja")), "1時間")
  }

  private func languageBundle(_ language: String) throws -> Bundle {
    let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), language)
    return try XCTUnwrap(Bundle(path: path), language)
  }

  private func pluralized(_ key: String, count: Int, bundle: Bundle, locale: Locale) -> String {
    let format = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    return String(format: format, locale: locale, count)
  }
}

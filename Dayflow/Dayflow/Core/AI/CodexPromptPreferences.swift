import Foundation

enum CodexPromptPreferences {
  private static let overridesKey = "chatGPTPromptOverrides"

  static func hasStoredOverrides(
    in defaults: UserDefaults = .standard
  ) -> Bool {
    defaults.object(forKey: overridesKey) != nil
  }

  static func load(
    from defaults: UserDefaults = .standard
  ) -> ActivityCardPromptOverrides {
    guard let data = defaults.data(forKey: overridesKey) else {
      return ActivityCardPromptOverrides()
    }
    guard let overrides = try? JSONDecoder().decode(ActivityCardPromptOverrides.self, from: data)
    else {
      return ActivityCardPromptOverrides()
    }
    return overrides
  }

  static func save(
    _ overrides: ActivityCardPromptOverrides,
    to defaults: UserDefaults = .standard
  ) {
    try? saveVerified(overrides, to: defaults)
  }

  static func reset(
    in defaults: UserDefaults = .standard
  ) {
    defaults.removeObject(forKey: overridesKey)
  }

  static func saveVerified(
    _ overrides: ActivityCardPromptOverrides,
    to defaults: UserDefaults
  ) throws {
    let previousValue = defaults.object(forKey: overridesKey)
    let data: Data
    do {
      data = try JSONEncoder().encode(overrides)
    } catch {
      throw ProviderPromptPreferencesError.encodingFailed
    }

    defaults.set(data, forKey: overridesKey)
    guard load(from: defaults) == overrides else {
      restore(previousValue, forKey: overridesKey, in: defaults)
      throw ProviderPromptPreferencesError.writeVerificationFailed
    }
  }

  private static func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
    if let value {
      defaults.set(value, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }

}

enum CodexPromptDefaults {
  // Selection evidence is generation-only; ActivityCardData ignores this intermediate field.
  static let titleBlock = """
    Write each title as the natural answer to “What did I spend this time doing?” Use a short phrase in sentence case, usually beginning with an activity verb. Name the main activity and its familiar subject. Add a method, person, comparison, creative treatment, or version only when it meaningfully distinguishes this episode. Specificity is optional: keep a title simple when the activity already identifies it. Prefer a recognizable approach over a list of implementation terms or the platform where work ran. The title should be understandable on its own tomorrow, accurate to the observed activity, and consistent with neighboring titles.

    <examples>
    Invented examples of the desired level of abstraction:
    <example>Evidence: investigated failed OAuth callbacks and Redis sessions for a product named Cedar. Title: Fixing Cedar sign-in.</example>
    <example>Evidence: tested whether combining radar and satellite readings improved Rainbird forecasts. Title: Testing radar and satellite fusion for Rainbird forecasts.</example>
    <example>Evidence: revised the aims and budget of a grant application through an editor and assistant. Title: Revising the grant proposal.</example>
    <example>Evidence: watched basketball clips for twenty minutes and briefly checked a parcel. Title: Watching basketball highlights.</example>
    <example>Evidence: read advice on insulating an attic; no installation observed. Title: Researching attic insulation.</example>
    </examples>

    For EVERY card, after its detailedSummary and before its title, output a titleEvidence object with activities (an array of {activity, minutes}), selectedActivity, and familiarSubject. Account for the entire interval, with approximate minutes summing to the card duration. Combine recurring visits to the same actual task; different subjects remain separate even when they share an assistant, browser, or broad project. Count foreground interaction, not background windows. Select the activity with the most supported time. Name that activity alone when it represents at least half of the interval. Put side activities only in the summaries. Name the selected activity and familiar subject; preserve a central approach or comparison when it helps distinguish the work. Omit incidental tools and brief detours.

    Invented example: titleEvidence: {"activities":[{"activity":"Reading about attic insulation","minutes":18},{"activity":"Checking a parcel","minutes":2}],"selectedActivity":"Reading about attic insulation","familiarSubject":"attic insulation"}; title: "Researching attic insulation".

    Only assign a topic to an activity when the foreground evidence establishes it. A browser article behind a messaging window does not establish what the messages discuss. Preserve an unknown topic as unknown rather than borrowing nearby content.

    A unique largest activity is not necessarily representative. If it occupies less than half the card, revisit whether a supported boundary can separate activities. If the duration rules require a mixed card, use a short honest description of the mixture or two substantial activities; do not name a tiny plurality as though it fills the interval. Group tasks under a shared purpose only when that purpose is supported, rather than assuming everything in the same project serves one goal.

    Use an everyday description of what the project does when an internal dataset name or technical method would make the title hard to recognize. Keep familiar product names and central methods when useful. If comparing named models is the task itself, their names can be the useful detail; if models are merely tools, leave them in the summary.

    Match the verb to the evidence: drafting is not sending, testing is not a proven improvement, and a static page without interaction is not active browsing. Read neighboring titles together: preserve meaningful differences between planning, editing, and reviewing, without inventing distinctions or forcing every title to carry a qualifier.

    titleEvidence is intermediate working data; the title is the short user-facing label. Return all required card fields, including title, distractions, and appSites, in the final JSON array.
    """

  static let summaryBlock = """
    SUMMARIES
    Write 2–3 factual sentences in first person without "I". State the main activity and meaningful secondary details. Preserve what happened without adding claims of completion.
    """

  static let detailedSummaryBlock = """
    DETAILED SUMMARIES
    Write a chronological log of timestamped activity lines. Each line states the concrete action, subject, and relevant application or site. Include substantive secondary activities and specific details here that the title omits. Encode line breaks with valid JSON escapes.
    """
}

struct CodexPromptSections {
  let title: String
  let summary: String
  let detailedSummary: String

  init(overrides: ActivityCardPromptOverrides) {
    self.title = CodexPromptSections.compose(
      defaultBlock: CodexPromptDefaults.titleBlock, custom: overrides.titleBlock)
    self.summary = CodexPromptSections.compose(
      defaultBlock: CodexPromptDefaults.summaryBlock, custom: overrides.summaryBlock)
    self.detailedSummary = CodexPromptSections.compose(
      defaultBlock: CodexPromptDefaults.detailedSummaryBlock, custom: overrides.detailedBlock)
  }

  private static func compose(defaultBlock: String, custom: String?) -> String {
    let trimmed = custom?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? defaultBlock : trimmed
  }
}

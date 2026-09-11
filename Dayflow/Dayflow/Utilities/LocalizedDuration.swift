import Foundation

enum LocalizedDuration {
  /// Display only. Stored timeline timestamps keep their fixed wire format.
  static func string(_ seconds: TimeInterval, style: DateComponentsFormatter.UnitsStyle = .full)
    -> String
  {
    let formatter = DateComponentsFormatter()
    var calendar = Calendar.current
    calendar.locale = .current
    formatter.calendar = calendar
    formatter.allowedUnits = [.hour, .minute]
    formatter.unitsStyle = style
    formatter.zeroFormattingBehavior = .dropAll
    let rounded = max(0, floor(seconds / 60) * 60)
    return formatter.string(from: rounded) ?? String(localized: "0 minutes")
  }
}

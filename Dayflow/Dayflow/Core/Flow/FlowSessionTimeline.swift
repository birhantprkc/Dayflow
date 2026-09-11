//
//  FlowSessionTimeline.swift
//  Dayflow
//
//  The session's activity timeline, built live by the distraction agent: on
//  every tick the model names what the user is doing ("Address feedback on
//  PR", "Scrolling on X") and native folds that into a list of contiguous
//  entries, merging consecutive ticks that describe the same thing. Breaks
//  are logged while the agent is paused. Every change is written to a JSON
//  file so the summary screen can pull the finished timeline the moment the
//  session ends (through the web bridge's `getTimeline`), and so a relaunch
//  mid-session keeps what was logged so far.
//

import AppKit
import Foundation

@MainActor
final class FlowSessionTimeline: ObservableObject {
  static let shared = FlowSessionTimeline()

  enum Kind: String, Codable {
    case focused
    case distracted
    case `break`
  }

  struct Entry: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var kind: Kind
    var startedAt: Date
    var endedAt: Date
    /// Frontmost app's icon as a data: URL (32px PNG), when we had one.
    var iconURL: String?
    /// Frontmost app's bundle identifier, for merging same-app ticks.
    var bundleId: String?
  }

  private struct File: Codable {
    var sessionStartedAt: Date
    var updatedAt: Date
    var entries: [Entry]
  }

  @Published private(set) var entries: [Entry] = []
  private(set) var sessionStartedAt = Date()
  private(set) var updatedAt: Date?

  /// Where the timeline lives on disk (Application Support/Dayflow/).
  let fileURL: URL = {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let directory = base.appendingPathComponent("Dayflow", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("flow-session-timeline.json")
  }()

  private init() {}

  // MARK: - Session lifecycle

  /// Called when the agent starts watching a session. Keeps the entries on
  /// disk if they belong to this same session (a relaunch or re-brief);
  /// otherwise starts empty.
  func begin(sessionStartedAt started: Date) {
    if let file = load(), abs(file.sessionStartedAt.timeIntervalSince(started)) < 5 {
      sessionStartedAt = file.sessionStartedAt
      entries = file.entries
      updatedAt = file.updatedAt
      return
    }
    sessionStartedAt = started
    entries = []
    updatedAt = nil
    save()
  }

  /// A tick's read of the screen. Consecutive ticks describing the same thing
  /// extend the open entry; anything new starts a fresh one right where the
  /// last ended, so the bars stay contiguous.
  func record(
    title rawTitle: String, kind: Kind, bundleId: String?, iconURL: String?, at now: Date = Date()
  ) {
    let title = Self.tidy(rawTitle)
    guard !title.isEmpty else {
      extendOpenEntry(to: now)
      return
    }
    if var last = entries.last, last.kind == kind, Self.same(last.title, title),
      last.bundleId == nil || bundleId == nil || last.bundleId == bundleId
    {
      last.endedAt = now
      if last.iconURL == nil { last.iconURL = iconURL }
      if last.bundleId == nil { last.bundleId = bundleId }
      entries[entries.count - 1] = last
    } else {
      entries.append(
        Entry(
          id: UUID().uuidString, title: title, kind: kind, startedAt: openingTime(for: now),
          endedAt: now, iconURL: iconURL, bundleId: bundleId))
    }
    save()
  }

  /// Nothing new to say this tick (the model's reply was unparseable): the
  /// current activity simply continues.
  func extendOpenEntry(to now: Date = Date()) {
    guard var last = entries.last, last.endedAt < now else { return }
    last.endedAt = now
    entries[entries.count - 1] = last
    save()
  }

  func beginBreak(at now: Date = Date()) {
    if let last = entries.last, last.kind == .break { return }
    entries.append(
      Entry(
        id: UUID().uuidString, title: "Break", kind: .break, startedAt: openingTime(for: now),
        endedAt: now, iconURL: nil, bundleId: nil))
    save()
  }

  func endBreak(at now: Date = Date()) {
    guard var last = entries.last, last.kind == .break else { return }
    last.endedAt = now
    entries[entries.count - 1] = last
    save()
  }

  /// The session is over: the open entry runs to the end so the last bar
  /// doesn't stop a tick short.
  func finish(at now: Date = Date()) {
    extendOpenEntry(to: now)
  }

  func clear() {
    entries = []
    updatedAt = nil
    try? FileManager.default.removeItem(at: fileURL)
  }

  // MARK: - Bridge

  /// Entries in the shape the web summary's `FlowActivity` expects.
  var bridgePayload: [[String: Any]] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return entries.map { entry in
      var payload: [String: Any] = [
        "id": entry.id,
        "title": entry.title,
        "kind": entry.kind.rawValue,
        "started_at": formatter.string(from: entry.startedAt),
        "ended_at": formatter.string(from: entry.endedAt),
      ]
      if let icon = entry.iconURL { payload["icon_url"] = icon }
      return payload
    }
  }

  // MARK: - App icons

  /// The frontmost app right now, with its icon as a small PNG data URL.
  nonisolated static func frontmostApp() -> (bundleId: String?, iconURL: String?) {
    guard let app = NSWorkspace.shared.frontmostApplication else { return (nil, nil) }
    // Dayflow's own overlay/window in front tells us nothing about the work.
    if app.bundleIdentifier == Bundle.main.bundleIdentifier { return (nil, nil) }
    return (app.bundleIdentifier, iconDataURL(for: app))
  }

  private nonisolated(unsafe) static var iconCache: [String: String] = [:]
  private nonisolated static let iconCacheLock = NSLock()

  private nonisolated static func iconDataURL(for app: NSRunningApplication) -> String? {
    let key = app.bundleIdentifier ?? app.localizedName ?? ""
    iconCacheLock.lock()
    if let cached = iconCache[key] {
      iconCacheLock.unlock()
      return cached
    }
    iconCacheLock.unlock()
    guard let icon = app.icon else { return nil }
    let size = NSSize(width: 32, height: 32)
    let small = NSImage(size: size)
    small.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    icon.draw(
      in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
    small.unlockFocus()
    guard let tiff = small.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { return nil }
    let url = "data:image/png;base64," + png.base64EncodedString()
    iconCacheLock.lock()
    iconCache[key] = url
    iconCacheLock.unlock()
    return url
  }

  // MARK: - Helpers

  /// A new entry starts where the previous one ended so the timeline has no
  /// gaps, unless the previous one ended long ago (agent was down), in
  /// which case it starts one tick back.
  private func openingTime(for now: Date) -> Date {
    let tick = FlowAgentSettings.shared.tickSeconds
    guard let last = entries.last else {
      return max(sessionStartedAt, now.addingTimeInterval(-tick))
    }
    if now.timeIntervalSince(last.endedAt) > tick * 3 {
      return now.addingTimeInterval(-tick)
    }
    return last.endedAt
  }

  private static func tidy(_ title: String) -> String {
    var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
    while text.hasSuffix(".") { text.removeLast() }
    if text.count > 60 { text = String(text.prefix(57)) + "…" }
    guard let first = text.first else { return "" }
    return first.uppercased() + text.dropFirst()
  }

  private static func same(_ a: String, _ b: String) -> Bool {
    let normalize = { (value: String) in
      value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }
    return normalize(a) == normalize(b)
  }

  private func save() {
    updatedAt = Date()
    let file = File(sessionStartedAt: sessionStartedAt, updatedAt: updatedAt!, entries: entries)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(file) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }

  private func load() -> File? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(File.self, from: data)
  }
}

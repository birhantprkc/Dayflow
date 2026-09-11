//
//  FlowDistractionAgent.swift
//  Dayflow
//
//  Real distraction detection for Flow sessions. Each session gets one
//  continuous Codex CLI conversation: an initial briefing with the user's
//  goals, session length, and alert style, then a screenshot every ~15 seconds
//  with the current time and time remaining. The model replies with a strict
//  one-object JSON verdict; nudges/praise drive the desktop overlay and
//  on-task/off-task flips drive the session's distraction log (via
//  FlowSessionMirror → web UI → backend).
//
//  Runs entirely through the user's own `codex` CLI at low reasoning effort,
//  reusing ChatCLIProcessRunner (streaming for the first turn to capture the
//  thread id, then `codex exec resume <id> --image <shot>` per tick).
//

import AppKit
import Combine
import Foundation
import ScreenCaptureKit

@MainActor
final class FlowDistractionAgent: ObservableObject {
  static let shared = FlowDistractionAgent()

  /// One line of the debug transcript: what the model said on a turn.
  struct TranscriptEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let text: String
  }

  /// Model replies (and turn failures) for the DEBUG log panel in FlowView.
  @Published private(set) var transcript: [TranscriptEntry] = []
  /// One-line state for the debug panel ("Watching · tick 12s ago").
  @Published private(set) var statusLine = "Not running"
  @Published private(set) var lastTickAt: Date?
  @Published private(set) var lastTickSeconds: Double?

  /// The model's per-turn reply. Anything unparseable is treated as
  /// on-task/no-action so a flaky turn can never fire a bogus nudge.
  private struct Verdict: Decodable {
    let status: String?
    let action: String?
    let message: String?
    let reason: String?
    /// Short goal ids ("g2") the model saw finished on screen this turn.
    let completed_goals: [String]?
  }

  /// The optional second object in a reply: the model's revised timeline.
  private struct TimelineReply: Decodable {
    let timeline: [FlowSessionTimeline.ModelItem]?
  }

  private let runner = ChatCLIProcessRunner()

  private var codexSessionId: String?
  private var tickTimer: Timer?
  private var tickInFlight = false
  private var paused = false
  /// Bumped on every start/stop so results from a superseded session's
  /// in-flight process are ignored when they land.
  private var generation = 0
  private var consecutiveFailures = 0
  /// One-shot context lines (snooze, back-to-work, break) folded into the
  /// next tick's message.
  private var pendingNotes: [String] = []
  private var lastReportedOffTask = false

  private var goals: [String] = []
  /// Open tasks with ids; the briefing labels them g1, g2… and the model
  /// reports those short ids back in `completed_goals`.
  private var goalTasks: [FlowGoalTask] = []
  private var reportedGoalIds: Set<String> = []
  private var alertStyle: FlowAlertStyle = .friendly
  private var sessionStartedAt = Date()
  private var sessionEndsAt: Date?
  private var workDirectory: URL?
  /// The snapshot the current conversation was briefed with, so a lost Codex
  /// thread (or a settings change) can re-brief without the mirror's help.
  private var lastSnapshot: FlowNativeSnapshot?
  /// Number of re-briefs this session, so a broken Codex install can't loop.
  private var rebriefs = 0
  private var timeline: FlowSessionTimeline { FlowSessionTimeline.shared }
  /// Debug panel: make the next tick ask for a timeline update.
  private var forceTimelineUpdate = false

  /// Model, reasoning, cadence, prompt… all live in FlowAgentSettings so the
  /// debug panel can change them while a session runs.
  private var settings: FlowAgentSettings { FlowAgentSettings.shared }
  private var cancellables: Set<AnyCancellable> = []

  /// Some models reject reasoning summaries (a user's global config.toml may
  /// set model_reasoning_summary = "detailed"), and the agent never wants
  /// them anyway — ticks should produce nothing but the JSON verdict.
  /// workspace-write lets the model edit the session timeline file that
  /// native drops into its working directory (nothing else is in there).
  private static let codexConfigOverrides = [
    "model_reasoning_summary=none", "sandbox_mode=workspace-write",
  ]

  /// The model-facing timeline file, inside the Codex working directory.
  private var timelineFileURL: URL? {
    workDirectory?.appendingPathComponent("timeline.json")
  }

  private init() {
    // A new cadence applies to the running session immediately.
    FlowAgentSettings.shared.$tickSeconds
      .dropFirst()
      .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self, self.codexSessionId != nil else { return }
        self.scheduleTimer()
      }
      .store(in: &cancellables)
  }

  var isRunning: Bool { generationIsLive && codexSessionId != nil }
  private var generationIsLive: Bool { tickTimer != nil || tickInFlight }

  // MARK: - Lifecycle (driven by FlowSessionMirror phase transitions)

  func start(with snapshot: FlowNativeSnapshot) {
    start(with: snapshot, rebrief: false)
  }

  /// `rebrief` keeps the transcript and counts toward the re-brief cap; used
  /// when the Codex thread is lost mid-session or the debug panel restarts
  /// the agent with new settings.
  private func start(with snapshot: FlowNativeSnapshot, rebrief: Bool) {
    stop()
    lastSnapshot = snapshot
    guard settings.agentEnabled else {
      statusLine = "Disabled"
      return
    }
    if !rebrief {
      rebriefs = 0
      transcript = []
    }

    goals = snapshot.goals ?? []
    goalTasks =
      snapshot.goalTasks
      ?? goals.enumerated().map { FlowGoalTask(id: "goal-\($0.offset)", title: $0.element) }
    if !rebrief { reportedGoalIds = [] }
    alertStyle = snapshot.alertStyle
    sessionStartedAt =
      snapshot.sessionStartedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
    sessionEndsAt = snapshot.sessionEndsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    lastReportedOffTask = false
    pendingNotes = []
    consecutiveFailures = 0
    paused = false
    // Same session on a re-brief or relaunch keeps what's been logged so far.
    timeline.begin(sessionStartedAt: sessionStartedAt)

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("DayflowFlowAgent-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    workDirectory = directory

    generation += 1
    let gen = generation
    let prompt = initialPrompt()
    let runner = self.runner

    print("[FlowAgent] Starting Codex conversation (style: \(alertStyle.rawValue))")
    statusLine = rebrief ? "Re-briefing \(settings.model)…" : "Briefing \(settings.model)…"
    tickInFlight = true
    let model = settings.model
    let effort = settings.reasoningEffort
    Task.detached(priority: .utility) {
      var sessionId: String?
      var replyText = ""
      var errorText: String?
      do {
        let stream = runner.runStreaming(
          tool: .codex,
          prompt: prompt,
          workingDirectory: directory,
          model: model,
          reasoningEffort: effort,
          codexConfigOverrides: Self.codexConfigOverrides
        )
        for try await event in stream {
          switch event {
          case .sessionStarted(let id): sessionId = id
          case .textDelta(let text): replyText += text
          case .complete(let text): replyText = text
          case .error(let message): errorText = message
          default: break
          }
        }
      } catch {
        errorText = error.localizedDescription
      }

      await MainActor.run {
        FlowDistractionAgent.shared.finishStart(
          generation: gen, sessionId: sessionId, reply: replyText, error: errorText)
      }
    }
  }

  private func finishStart(generation gen: Int, sessionId: String?, reply: String, error: String?) {
    guard gen == generation else { return }
    tickInFlight = false

    guard let sessionId else {
      print("[FlowAgent] Could not start Codex session: \(error ?? "no thread id in output")")
      appendTranscript("Couldn't start the agent: \(error ?? "no thread id in output")")
      statusLine = "Failed to start"
      AnalyticsService.shared.capture("flow_agent_start_failed")
      cleanupWorkDirectory()
      return
    }
    statusLine = "Watching (\(settings.model), \(settings.reasoningEffort))"

    print("[FlowAgent] Codex session started: \(sessionId), first reply: \(reply.prefix(200))")
    appendTranscript(reply)
    AnalyticsService.shared.capture("flow_agent_started")
    codexSessionId = sessionId
    scheduleTimer()
  }

  func pause() {
    guard generationIsLive || codexSessionId != nil else { return }
    paused = true
    timeline.beginBreak()
    noteUserEvent("The user is taking a break; screenshots were paused while it lasted.")
  }

  func resume() {
    guard codexSessionId != nil else { return }
    paused = false
    timeline.endBreak()
    noteUserEvent("The user just came back from their break.")
  }

  func stop() {
    generation += 1
    tickTimer?.invalidate()
    tickTimer = nil
    tickInFlight = false
    codexSessionId = nil
    paused = false
    pendingNotes = []
    lastReportedOffTask = false
    cleanupWorkDirectory()
    statusLine = "Not running"
  }

  // MARK: - Debug panel controls

  /// Starts a fresh Codex conversation for the current session with whatever
  /// the settings say now (model, prompt, cadence…).
  func restart() {
    let mirror = FlowSessionMirror.shared
    guard mirror.snapshot.phase == .active || mirror.snapshot.phase == .onBreak else {
      appendTranscript("No active session to watch.")
      return
    }
    appendTranscript("Restarting the agent with the current settings.")
    start(with: mirror.snapshot, rebrief: true)
    if mirror.snapshot.phase == .onBreak { paused = true }
  }

  /// Take a screenshot and ask the model right now, off the timer.
  func tickNow() {
    guard codexSessionId != nil else {
      appendTranscript("Agent isn't running.")
      return
    }
    let wasPaused = paused
    paused = false
    tick()
    paused = wasPaused
  }

  func clearTranscript() {
    transcript = []
  }

  /// Debug panel: tick right now and ask for the timeline in the same turn.
  func requestTimelineNow() {
    forceTimelineUpdate = true
    tickNow()
  }

  /// The briefing exactly as it would be sent now (for the debug panel).
  var currentBriefing: String { initialPrompt() }

  /// The open task list changed mid-session (voice additions, manual
  /// check-offs): tell the model on its next tick, with fresh short ids.
  func goalsChanged(to snapshot: FlowNativeSnapshot) {
    guard codexSessionId != nil else { return }
    let next = snapshot.goalTasks ?? []
    guard next != goalTasks else { return }
    let finished = goalTasks.filter { old in !next.contains(where: { $0.id == old.id }) }
    let added = next.filter { new in !goalTasks.contains(where: { $0.id == new.id }) }
    goalTasks = next
    goals = next.map(\.title)
    lastSnapshot = snapshot
    var note = "GOALS UPDATED. Open goals are now:\n" + goalsList()
    if !finished.isEmpty {
      note += "\nNo longer open (done or removed): " + finished.map(\.title).joined(separator: "; ")
    }
    if !added.isEmpty {
      note += "\nNewly added: " + added.map(\.title).joined(separator: "; ")
    }
    pendingNotes.append(note)
  }

  /// "- [g1] title" lines; the short id is the position in the current list.
  private func goalsList() -> String {
    goalTasks.enumerated().map { "- [g\($0.offset + 1)] \($0.element.title)" }
      .joined(separator: "\n")
  }

  /// Queue a line of context (snooze, back-to-work…) for the next tick.
  /// `markRefocused` also resets the off-task flag so a later distraction
  /// opens a fresh interval in the session log.
  func noteUserEvent(_ note: String, markRefocused: Bool = false) {
    guard codexSessionId != nil else { return }
    pendingNotes.append(note)
    if markRefocused { lastReportedOffTask = false }
  }

  // MARK: - Ticks

  private func scheduleTimer() {
    tickTimer?.invalidate()
    tickTimer = Timer.scheduledTimer(
      withTimeInterval: max(5, settings.tickSeconds), repeats: true
    ) { _ in
      MainActor.assumeIsolated {
        FlowDistractionAgent.shared.tick()
      }
    }
  }

  private func tick() {
    guard let sessionId = codexSessionId, let directory = workDirectory else { return }
    guard !paused, !tickInFlight else { return }

    tickInFlight = true
    let gen = generation
    let askTimeline =
      forceTimelineUpdate || timeline.wantsUpdate(every: settings.timelineEverySeconds)
    forceTimelineUpdate = false
    if askTimeline, let file = timelineFileURL {
      // The model reads and edits this file during the turn.
      try? timeline.promptTimelineJSON().write(to: file, atomically: true, encoding: .utf8)
    }
    let message = tickMessage(askTimeline: askTimeline)
    pendingNotes = []
    let runner = self.runner
    let shotURL = directory.appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970)).jpg")
    let model = settings.model
    let effort = settings.reasoningEffort
    let textOnly = settings.textOnly
    let shotHeight = settings.screenshotHeight
    let quality = settings.jpegQuality
    let timeout = settings.tickTimeoutSeconds
    let startedAt = Date()
    // Which app is in front goes on the timeline entry (icon + merge key).
    let front = FlowSessionTimeline.frontmostApp()

    Task.detached(priority: .utility) {
      var replyText: String?
      var errorText: String?
      do {
        try await Self.captureScreenshotJPEG(to: shotURL, height: shotHeight, quality: quality)
        // OCR text instead of the image for text-only models.
        var prompt = message
        var imagePaths = [shotURL.path]
        if textOnly {
          let screenText = Self.recognizeScreenText(at: shotURL)
          prompt +=
            "\nScreen text (Apple OCR of the current screenshot):\n\(screenText)\nReply with the JSON object only."
          imagePaths = []
        } else {
          prompt += "\nScreenshot attached. Reply with the JSON object only."
        }
        let result = try runner.run(
          tool: .codex,
          prompt: prompt,
          workingDirectory: directory,
          imagePaths: imagePaths,
          model: model,
          reasoningEffort: effort,
          codexResumeSessionId: sessionId,
          codexConfigOverrides: Self.codexConfigOverrides,
          timeoutSeconds: timeout
        )
        if result.exitCode == 0 {
          replyText = result.stdout
        } else {
          errorText = result.stderr.isEmpty ? "exit \(result.exitCode)" : result.stderr
        }
      } catch {
        errorText = error.localizedDescription
      }
      try? FileManager.default.removeItem(at: shotURL)

      let elapsed = Date().timeIntervalSince(startedAt)
      await MainActor.run {
        FlowDistractionAgent.shared.finishTick(
          generation: gen, reply: replyText, error: errorText, seconds: elapsed,
          front: front, askedTimeline: askTimeline)
      }
    }
  }

  private func finishTick(
    generation gen: Int, reply: String?, error: String?, seconds: Double,
    front: FlowSessionTimeline.FrontApp, askedTimeline: Bool
  ) {
    guard gen == generation else { return }
    tickInFlight = false
    lastTickAt = Date()
    lastTickSeconds = seconds

    guard let reply else {
      consecutiveFailures += 1
      print("[FlowAgent] Tick failed (\(consecutiveFailures)): \(error ?? "unknown")")
      appendTranscript("Turn failed: \(error ?? "unknown")")
      // Codex lost the conversation (its rollout file is gone, e.g. a full
      // disk or a pruned sessions dir). Resuming will never work again, so
      // start a fresh thread instead of burning through the failure budget.
      if let error, error.contains("no rollout found") || error.contains("thread/resume"),
        let snapshot = lastSnapshot, rebriefs < 3
      {
        rebriefs += 1
        appendTranscript("Codex thread was lost; re-briefing on a new one (\(rebriefs)/3).")
        start(with: snapshot, rebrief: true)
        pendingNotes.append("(Re-briefed mid-session after the previous conversation was lost.)")
        return
      }
      if consecutiveFailures >= settings.maxFailures {
        print("[FlowAgent] Stopping after \(consecutiveFailures) consecutive failures")
        appendTranscript("Agent stopped after \(consecutiveFailures) consecutive failures.")
        AnalyticsService.shared.capture("flow_agent_gave_up")
        stop()
        statusLine = "Stopped after \(consecutiveFailures) failures"
      }
      return
    }
    consecutiveFailures = 0
    appendTranscript(reply)

    let objects = Self.jsonObjects(in: reply)
    guard let first = objects.first,
      let verdict = try? JSONDecoder().decode(Verdict.self, from: Data(first.utf8))
    else {
      print("[FlowAgent] Unparseable reply, treating as on-task: \(reply.prefix(200))")
      return
    }
    // The verdict comes first and is acted on first; the timeline (when the
    // tick asked for one) rides behind it in a second object.
    handle(verdict: verdict)
    timeline.observe(offTask: verdict.status == "off_task", front: front, reason: verdict.reason)
    if askedTimeline { readBackTimeline(fallback: Array(objects.dropFirst())) }
  }

  /// After a timeline turn: take the file the model edited (or, if it
  /// answered inline instead, a {"timeline": [...]} object in its reply).
  private func readBackTimeline(fallback objects: [String]) {
    if let file = timelineFileURL, let data = try? Data(contentsOf: file),
      let items = Self.decodeTimelineItems(data), !items.isEmpty
    {
      timeline.apply(modelItems: items)
      return
    }
    for object in objects {
      if let parsed = try? JSONDecoder().decode(TimelineReply.self, from: Data(object.utf8)),
        let items = parsed.timeline
      {
        timeline.apply(modelItems: items)
        return
      }
    }
    appendTranscript("Timeline update: the model didn't leave a usable timeline.json.")
  }

  /// The file may be a bare array or wrapped in {"timeline": [...]}.
  private static func decodeTimelineItems(_ data: Data) -> [FlowSessionTimeline.ModelItem]? {
    let decoder = JSONDecoder()
    if let items = try? decoder.decode([FlowSessionTimeline.ModelItem].self, from: data) {
      return items
    }
    return (try? decoder.decode(TimelineReply.self, from: data))?.timeline
  }

  private func handle(verdict: Verdict) {
    let offTask = verdict.status == "off_task"
    if offTask != lastReportedOffTask {
      lastReportedOffTask = offTask
      FlowSessionMirror.shared.agentReportedFocusChange(isDistracted: offTask)
      if offTask {
        print("[FlowAgent] Off task: \(verdict.reason ?? "no reason given")")
      }
    }

    // Goals the model saw finished: resolve g-ids, relay once each.
    let finished = (verdict.completed_goals ?? []).compactMap { short -> FlowGoalTask? in
      let digits = short.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "g[] "))
      guard let index = Int(digits), index >= 1, index <= goalTasks.count else { return nil }
      let task = goalTasks[index - 1]
      guard !reportedGoalIds.contains(task.id) else { return nil }
      return task
    }
    if !finished.isEmpty {
      reportedGoalIds.formUnion(finished.map(\.id))
      print("[FlowAgent] Goals completed: \(finished.map(\.title))")
      FlowSessionMirror.shared.agentCompletedGoals(finished)
    }

    switch verdict.action {
    case "nudge":
      let message =
        verdict.message ?? String(localized: "Psst... I think you're getting distracted!")
      FlowSessionMirror.shared.agentNudge(message: message)
    case "praise":
      if let message = verdict.message, !message.isEmpty {
        FlowSessionMirror.shared.agentPraise(message: message)
      }
    default:
      break
    }
  }

  // MARK: - Prompts

  private func initialPrompt() -> String {
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "h:mm a"
    let started = timeFormatter.string(from: sessionStartedAt)

    let lengthLine: String
    if let endsAt = sessionEndsAt {
      let minutes = max(1, Int(endsAt.timeIntervalSince(sessionStartedAt) / 60))
      lengthLine =
        "Planned length: \(minutes) minutes (ends around \(timeFormatter.string(from: endsAt)))."
    } else {
      lengthLine = "Open-ended: no timer, the user works until they choose to stop."
    }

    let goalsBlock: String
    if goals.isEmpty {
      goalsBlock = """
        The user didn't list specific goals. Judge by continuity instead: sustained work in \
        one arena (coding, writing, design, research...) is on task; entertainment, social \
        feeds, and aimless browsing are off task.
        """
    } else {
      goalsBlock = goalsList()
    }

    let styleBlock: String
    switch alertStyle {
    case .quiet:
      styleBlock = """
        Quiet. The user asked for zero interruptions. NEVER use "nudge" or "praise" — keep \
        action "none" on every turn. Your status field still matters: distractions are \
        logged silently for their session summary.
        """
    case .friendly:
      styleBlock = """
        Friendly. Give them slack: don't nudge until they've clearly been off task for a \
        few minutes straight (many consecutive off-task checks — a quick detour that \
        ends on its own never earns a nudge). One nudge per incident; if they're still \
        distracted several minutes later, one firmer follow-up is okay. Tone: warm and \
        encouraging, like a supportive friend. Never guilt-trippy.
        """
    case .feisty:
      styleBlock = """
        Feisty. Quick and stern. Nudge as soon as you're confident they're off task — one \
        clearly off-task check is enough. Persistent reminders until they're back on \
        track: if they stay distracted, nudge again every minute or two, each one more \
        direct than the last. Tone: stern and no-nonsense, a coach who won't let it slide. \
        Blunt is fine; insulting is not.
        """
    }

    // The evidence wording flips between screenshots and OCR text.
    let evidenceIntro: String
    let evidenceJudging: String
    if settings.textOnly {
      evidenceIntro =
        "text extracted from a screenshot of their screen (Apple's OCR), the current time, "
        + "and the time left"
      evidenceJudging = """
        - The OCR text is your only evidence, and it's imperfect: expect garbled fragments, \
        menu bars, timestamps, and UI chrome mixed together. Anchor on the strong signals — \
        app names, window and tab titles, site names, video or post titles.
        """
    } else {
      evidenceIntro = "a screenshot of their screen, the current time, and the time left"
      evidenceJudging = "- The screenshot is your only evidence."
    }

    let template = settings.briefingTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
    var prompt = template.isEmpty ? Self.briefingTemplate : template
    let values: [String: String] = [
      "{{started}}": started,
      "{{length}}": lengthLine,
      "{{style}}": alertStyle.rawValue,
      "{{goals}}": goalsBlock,
      "{{style_rules}}": styleBlock,
      "{{evidence_intro}}": evidenceIntro,
      "{{evidence_rules}}": evidenceJudging,
      "{{tick_seconds}}": String(Int(settings.tickSeconds)),
    ]
    for (key, value) in values {
      prompt = prompt.replacingOccurrences(of: key, with: value)
    }
    let extra = settings.extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    if !extra.isEmpty {
      prompt += "\n\nADDITIONAL INSTRUCTIONS\n" + extra
    }
    return prompt
  }

  /// The built-in briefing. Placeholders: {{started}}, {{length}}, {{style}},
  /// {{goals}}, {{style_rules}}, {{evidence_intro}}, {{evidence_rules}},
  /// {{tick_seconds}}. The debug panel can replace the whole thing.
  static let briefingTemplate = """
    You are the focus companion inside Dayflow, a Mac time-tracking app. The user just \
    started a Flow focus session and you're watching over it. Roughly every {{tick_seconds}} seconds \
    you'll get a message with {{evidence_intro}}. Your job: judge whether they're on task, \
    and decide whether their focus buddy (a small pixel creature that peeks in from the \
    screen edge) should say something.

    SESSION
    - Started at {{started}}.
    - {{length}}
    - Alert style: {{style}}.

    THE USER'S STATED FOCUS
    {{goals}}

    HOW TO JUDGE
    - Be generous. Docs, searches, terminal work, Slack or email replies, and quick \
    utility checks all plausibly serve the goals — count them as on task.
    - One glance at something unrelated is not a distraction; a pattern across \
    consecutive checks is (social feeds, YouTube, shopping, news rabbit holes).
    {{evidence_rules}}
    - If you're unsure, assume on task.

    HOW TO REPLY
    Reply to every message with exactly one JSON object and nothing else — no prose, no \
    code fences, no explanation:
    {"status": "on_task" | "off_task", "action": "none" | "nudge" | "praise", "message": "...", "reason": "..."}
    - status: your read of the current check.
    - action "nudge" makes the creature appear with your message. Write it yourself in \
    the alert style's tone, but keep it SHORT: one sentence, 10 words max — it renders \
    in a tiny speech bubble ("Twitter can wait — 12 minutes left!").
    - action "praise" shows a brief encouragement, same 10-word cap. Use it sparingly — \
    at most once every ten minutes or so, e.g. after a long on-task stretch or right \
    after they recover from a distraction.
    - message is required whenever action isn't "none". reason: a few words of evidence \
    whenever status is "off_task".
    - completed_goals: optional. Each goal above has a short id in brackets. When the \
    screen shows a goal has been FINISHED — the PR is merged, the email is in Sent, the \
    doc is published, the ticket is closed, they typed "done" — include its id, e.g. \
    "completed_goals": ["g2"], in that turn's verdict. Working on a goal is not finishing \
    it: only report on clear evidence of completion, and report each goal once. Dayflow \
    checks the task off for them, so a false positive is worse than a miss.

    ALERT STYLE
    {{style_rules}}

    THE SESSION TIMELINE
    You also keep the user's session log, the way Dayflow's timeline does. It lives in a \
    file, timeline.json, in your working directory: a JSON array of entries \
    {"start": "HH:mm", "end": "HH:mm", "kind": "focused" | "distracted" | "break", "title": "..."}. \
    About once a minute a message will end with "TIMELINE UPDATE" and give you the file's \
    path plus the check log since your last edit. On those turns, read the file and edit \
    it in place as you see fit — usually extend the last entry or add one for what they've \
    moved on to, and now and then condense: merge a stretch of work on one thing into a \
    single entry even if they bounced between docs, terminal, and editor for it, and rename \
    earlier entries once you understand what they were really doing. Keep genuine splits: \
    a detour to X or YouTube (kind "distracted"), even a one-minute one, and every break \
    stay as their own entries. Entries must stay contiguous (each starts where the previous \
    ended, 24h HH:mm), the first at the session start, the last ending at the current time. \
    Titles are concrete, 3–7 words, like "Address feedback on PR", "Scrolling on X", \
    "Reviewing checkout flow mockups in Figma". After editing the file, reply with the \
    verdict object as usual — the file is the timeline, don't repeat it in your reply.

    Don't overthink the ticks: no analysis, no chain of reasoning in your reply. Most \
    turns the correct answer is exactly {"status":"on_task","action":"none"}. Acknowledge \
    this briefing now with that same JSON object.
    """

  private func tickMessage(askTimeline: Bool) -> String {
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "h:mm a"
    let now = Date()

    var line = "Current time: \(timeFormatter.string(from: now))."
    if let endsAt = sessionEndsAt {
      let remaining = max(0, Int(endsAt.timeIntervalSince(now) / 60))
      line += " Time remaining: \(Self.formatMinutes(remaining))."
    } else {
      let elapsed = max(0, Int(now.timeIntervalSince(sessionStartedAt) / 60))
      line += " Elapsed: \(Self.formatMinutes(elapsed)) (open-ended session)."
    }

    var parts = [line]
    parts.append(contentsOf: pendingNotes)
    if askTimeline {
      let since = timeline.lastModelUpdateAt
      parts.append(
        """
        TIMELINE UPDATE — read \(timelineFileURL?.path ?? "timeline.json") and edit it in \
        place so it covers the whole session (started \
        \(FlowSessionTimeline.clock(sessionStartedAt))) up to now, then reply with the \
        verdict object.
        Check log since your last edit (time · verdict · frontmost app · reason):
        \(timeline.promptObservations(since: since))
        Breaks (exact, from the app): \(timeline.promptBreaks())
        """)
    }
    // The evidence line (screenshot vs OCR text) is appended in tick(), where
    // the capture happens.
    return parts.joined(separator: "\n")
  }

  private static func formatMinutes(_ minutes: Int) -> String {
    minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
  }

  private func appendTranscript(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    transcript.append(TranscriptEntry(date: Date(), text: trimmed))
    if transcript.count > 200 {
      transcript.removeFirst(transcript.count - 200)
    }
  }

  // MARK: - Verdict parsing

  /// Every top-level {...} in the reply, in order, tolerating fences and
  /// stray prose around them. Strings are skipped so braces inside a title
  /// don't confuse the depth count.
  private static func jsonObjects(in reply: String) -> [String] {
    var objects: [String] = []
    var depth = 0
    var start: String.Index?
    var inString = false
    var escaped = false
    var index = reply.startIndex
    while index < reply.endIndex {
      let character = reply[index]
      if inString {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
      } else if character == "\"" {
        inString = true
      } else if character == "{" {
        if depth == 0 { start = index }
        depth += 1
      } else if character == "}" {
        depth -= 1
        if depth == 0, let begin = start {
          objects.append(String(reply[begin...index]))
          start = nil
        }
        if depth < 0 { depth = 0 }
      }
      index = reply.index(after: index)
    }
    return objects
  }

  // MARK: - Screenshot capture

  /// One-shot capture of the main display, scaled to ~720p JPEG. Independent
  /// of the timeline recorder so Flow works even when recording is paused.
  private nonisolated static func captureScreenshotJPEG(
    to url: URL, height: Int, quality: Double
  ) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true)
    guard let display = content.displays.first else {
      throw NSError(
        domain: "FlowAgent", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
    }

    let configuration = SCStreamConfiguration()
    let aspectRatio = Double(display.width) / Double(max(1, display.height))
    configuration.height = height
    configuration.width = Int(Double(height) * aspectRatio)
    configuration.scalesToFit = true
    configuration.showsCursor = true

    let image = try await SCScreenshotManager.captureImage(
      contentFilter: SCContentFilter(display: display, excludingWindows: []),
      configuration: configuration
    )

    let bitmap = NSBitmapImageRep(cgImage: image)
    guard
      let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
    else {
      throw NSError(
        domain: "FlowAgent", code: -2,
        userInfo: [NSLocalizedDescriptionKey: "JPEG conversion failed"])
    }
    try jpegData.write(to: url)
  }

  // Full-screen OCR via the same Apple Vision recognizer the Claude
  // transcription path uses (text-only mode).
  private nonisolated static func recognizeScreenText(at url: URL) -> String {
    let blocks = (try? AppleVisionClaudeFrameTextRecognizer().recognizeText(in: url)) ?? []
    let lines = blocks.filter { $0.confidence >= 0.3 }.map(\.text)
    var text = lines.joined(separator: "\n")
    if text.count > 4000 {
      text = String(text.prefix(4000)) + "\n[truncated]"
    }
    return text.isEmpty ? String(localized: "[no text detected on screen]") : text
  }

  // MARK: - Cleanup

  private func cleanupWorkDirectory() {
    if let directory = workDirectory {
      try? FileManager.default.removeItem(at: directory)
    }
    workDirectory = nil
  }
}

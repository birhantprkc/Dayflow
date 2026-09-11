//
//  FlowOverlayView.swift
//  Dayflow
//
//  SwiftUI content for the Flow desktop overlay panel. The creature is a
//  video (HEVC with alpha, see FlowCreatureView) whose 1280×768 canvas bakes
//  in the screen position: it peeks in over the right edge to wave or breathe
//  fire, and drags out a tub for breaks. The speech bubble and action pills
//  are laid over the video; the panel window sits flush against the screen's
//  bottom-right corner so the offscreen half of the creature clips naturally.
//

import SwiftUI

struct FlowOverlayView: View {
  @ObservedObject private var mirror = FlowSessionMirror.shared
  @State private var showSnoozeOptions = false
  /// Nudges start as just the creature; the bubble and replies appear once
  /// the user hovers over it (and then stay until the overlay changes).
  @State private var revealed = false

  /// The 1280×768 clip canvas rendered at half size, plus a little headroom
  /// so bubbles can float above it.
  private static let videoSize = CGSize(width: 640, height: 384)
  private static let rootSize = CGSize(width: 680, height: 440)

  var body: some View {
    ZStack(alignment: .topLeading) {
      // Always mounted: exit clips play while the overlay state is already
      // .hidden, just before the panel fades out.
      FlowCreatureVideoView(variant: mirror.overlayVariant)
        .frame(width: Self.videoSize.width, height: Self.videoSize.height)
        .offset(
          x: Self.rootSize.width - Self.videoSize.width,
          y: mirror.overlayVariant.anchorsToTop ? 0 : Self.rootSize.height - Self.videoSize.height)

      // Invisible hotspot over the creature's body: hovering reveals the
      // bubble and replies, dragging moves where the creature comes from.
      if mirror.overlay != .hidden {
        FlowCreatureHotspot(
          onHover: { hovering in
            if hovering { withAnimation(.spring(duration: 0.3)) { revealed = true } }
          }
        )
        .frame(width: hotspotRect.width, height: hotspotRect.height)
        .offset(x: hotspotRect.minX, y: hotspotRect.minY)
      }

      switch mirror.overlay {
      case .hidden:
        EmptyView()
      case .toast(let message):
        speechBubble(message, layout: .edge)
      case .nudge(let message, let escalated):
        if revealed {
          speechBubble(
            message, layout: escalated && mirror.overlayVariant == .side ? .scene : .edge
          )
          .transition(.opacity.combined(with: .scale(scale: 0.9)))
          nudgePills
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      case .onBreak:
        breakBubble
      case .sessionEnded:
        if revealed {
          speechBubble(String(localized: "Time's up! Great work."), layout: .edge)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
          sessionEndedPills
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      }
    }
    .frame(width: Self.rootSize.width, height: Self.rootSize.height, alignment: .topLeading)
    .animation(.spring(duration: 0.3), value: mirror.overlay)
    .onChange(of: mirror.overlay) { oldValue, newValue in
      showSnoozeOptions = false
      revealed = false
      updateCreature(from: oldValue, to: newValue)
    }
    .onAppear {
      updateCreature(from: .hidden, to: mirror.overlay)
    }
  }

  /// Where the creature's body sits in the panel for each layout (root
  /// coordinates, top-left origin), generous enough to catch a hover.
  private var hotspotRect: CGRect {
    switch mirror.overlayVariant {
    case .side: return CGRect(x: 470, y: 150, width: 210, height: 290)
    case .top: return CGRect(x: 250, y: 40, width: 260, height: 220)
    case .peek: return CGRect(x: 260, y: 0, width: 200, height: 150)
    }
  }

  // MARK: - Creature clip selection

  private func updateCreature(from old: FlowOverlayPresentation, to new: FlowOverlayPresentation) {
    let player = FlowCreaturePlayer.shared
    let variant = mirror.overlayVariant
    switch new {
    case .hidden:
      break  // Exit clips are driven by FlowOverlayController before hiding.
    case .nudge(_, true):
      player.play(.fireBegin, thenLoop: .fireLoop)
    case .toast, .sessionEnded, .nudge:
      switch variant {
      case .side:
        if old == .hidden {
          player.play(.entrance, thenLoop: .waveLoop)
        } else {
          player.ensureLoop(.waveLoop)
        }
      case .top:
        if old == .hidden {
          player.play(.dropFromTop, thenLoop: .randomListen)
        } else if player.currentClip != .listen1 && player.currentClip != .listen2 {
          player.ensureLoop(.randomListen)
        }
      case .peek:
        if old == .hidden {
          player.play(.peekEnter, thenLoop: .peekWaveLoop)
        } else {
          player.ensureLoop(.peekWaveLoop)
        }
      }
    case .onBreak:
      player.play(.bathBegin, thenLoop: .bathLoop)
    }
  }

  // MARK: - Speech bubble

  /// Where the bubble sits: `edge` next to the creature, `scene` higher up
  /// and further left, clear of the fire/tub clips. The from-above variants
  /// put the creature mid-panel, so the bubble moves left of it.
  private enum BubbleLayout {
    case edge, scene

    func offset(in variant: FlowNudgeVariant) -> CGPoint {
      switch (variant, self) {
      case (.side, .edge): return CGPoint(x: 430, y: 190)
      case (.side, .scene): return CGPoint(x: 310, y: 84)
      case (.top, _): return CGPoint(x: 104, y: 80)
      case (.peek, _): return CGPoint(x: 140, y: 18)
      }
    }
  }

  /// Reply pills sit under the bubble; in the from-above variants they also
  /// have to clear the creature's body.
  private var pillsOffset: CGPoint {
    switch mirror.overlayVariant {
    case .side: return CGPoint(x: 388, y: 262)
    case .top: return CGPoint(x: 104, y: 238)
    case .peek: return CGPoint(x: 140, y: 92)
    }
  }

  private func speechBubble(_ text: String, layout: BubbleLayout) -> some View {
    bubbleShell(layout: layout) {
      Text(text)
        .font(.custom("Figtree", size: 14))
        .foregroundColor(.black)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var breakBubble: some View {
    bubbleShell(layout: .scene) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Break time!")
          .font(.custom("Figtree", size: 14))
          .foregroundColor(.black)
        if let endsAt = mirror.snapshot.breakEndsAt {
          CountdownText(until: Date(timeIntervalSince1970: TimeInterval(endsAt)))
            .font(.custom("Figtree", size: 13).monospacedDigit())
            .foregroundColor(.black.opacity(0.6))
        }
      }
    }
  }

  private func bubbleShell<Content: View>(
    layout: BubbleLayout, @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .padding(.horizontal, 11)
      .padding(.vertical, 8)
      .frame(width: 147, alignment: .leading)
      .frame(minHeight: 49)
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(Color(hex: "D9D9D9"))
      )
      .background(alignment: .trailing) {
        // Tail pointing right, toward the creature.
        BubbleTail()
          .fill(Color(hex: "D9D9D9"))
          .frame(width: 30, height: 16)
          .offset(x: 19)
      }
      .offset(
        x: layout.offset(in: mirror.overlayVariant).x, y: layout.offset(in: mirror.overlayVariant).y
      )
  }

  // MARK: - Nudge pills

  private var nudgePills: some View {
    VStack(alignment: .leading, spacing: 7) {
      pill(background: .white.opacity(0.5)) {
        showSnoozeOptions = false
        mirror.respondBackToWork()
      } label: {
        HStack(spacing: 4) {
          pillText(String(localized: "Whoops! I'll get back to work."))
          Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.black.opacity(0.7))
        }
      }

      pill(background: .white.opacity(showSnoozeOptions ? 0.8 : 0.5)) {
        showSnoozeOptions.toggle()
      } label: {
        pillText(String(localized: "Just a few more minutes!"))
      }

      if showSnoozeOptions {
        HStack(spacing: 5) {
          ForEach([5, 10, 15], id: \.self) { minutes in
            pill(background: .white.opacity(0.75)) {
              showSnoozeOptions = false
              mirror.snooze(minutes: minutes)
            } label: {
              pillText(String(localized: "\(minutes) min"))
            }
          }
        }
      }

      pill(background: .white.opacity(0.5)) {
        showSnoozeOptions = false
        mirror.correctMistake()
      } label: {
        pillText(String(localized: "Correct Flow's mistake"))
      }
    }
    .offset(x: pillsOffset.x, y: pillsOffset.y)
  }

  private var sessionEndedPills: some View {
    VStack(alignment: .leading, spacing: 7) {
      pill(background: .white.opacity(0.5)) {
        mirror.openFlowTab()
      } label: {
        pillText(String(localized: "Start a new session"))
      }
      pill(background: .white.opacity(0.5)) {
        mirror.dismissOverlay()
      } label: {
        pillText(String(localized: "Done"))
      }
    }
    .offset(x: pillsOffset.x, y: pillsOffset.y)
  }

  private func pillText(_ title: String) -> some View {
    Text(title)
      .font(.custom("Figtree", size: 14))
      .foregroundColor(.black)
  }

  private func pill<Label: View>(
    background: Color,
    action: @escaping () -> Void,
    @ViewBuilder label: () -> Label
  ) -> some View {
    Button(action: action) {
      label()
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 10).fill(background))
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }
  }
}

/// Transparent view over the creature. Tracks the mouse even though the
/// panel never activates, and turns a drag into a panel move along the
/// layout's free axis (see FlowOverlayController.drag).
private struct FlowCreatureHotspot: NSViewRepresentable {
  let onHover: (Bool) -> Void

  func makeNSView(context: Context) -> HotspotView {
    let view = HotspotView()
    view.onHover = onHover
    return view
  }

  func updateNSView(_ nsView: HotspotView, context: Context) {
    nsView.onHover = onHover
  }

  final class HotspotView: NSView {
    var onHover: ((Bool) -> Void)?
    private var dragStart: NSPoint?
    private var dragged = false

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      addTrackingArea(
        NSTrackingArea(
          rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
          owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
      onHover?(true)
      NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
      onHover?(false)
      if dragStart == nil { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
      dragStart = NSEvent.mouseLocation
      dragged = false
      NSCursor.closedHand.set()
      FlowOverlayController.shared.beginDrag()
    }

    override func mouseDragged(with event: NSEvent) {
      guard let dragStart else { return }
      let now = NSEvent.mouseLocation
      let delta = NSPoint(x: now.x - dragStart.x, y: now.y - dragStart.y)
      if abs(delta.x) > 3 || abs(delta.y) > 3 { dragged = true }
      if dragged { FlowOverlayController.shared.drag(by: delta) }
    }

    override func mouseUp(with event: NSEvent) {
      if dragged { FlowOverlayController.shared.endDrag() }
      dragStart = nil
      dragged = false
      NSCursor.openHand.set()
    }
  }
}

/// The speech bubble's tail: a small curved point aimed right at the creature.
private struct BubbleTail: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.midY),
      control: CGPoint(x: rect.maxX * 0.7, y: rect.minY)
    )
    path.addQuadCurve(
      to: CGPoint(x: rect.minX, y: rect.maxY),
      control: CGPoint(x: rect.maxX * 0.7, y: rect.maxY)
    )
    path.closeSubpath()
    return path
  }
}

/// Self-updating "mm:ss" countdown to a fixed deadline.
private struct CountdownText: View {
  let until: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      Text(formatted(remaining: until.timeIntervalSince(context.date)))
    }
  }

  private func formatted(remaining: TimeInterval) -> String {
    let total = max(0, Int(remaining))
    let clock = String(format: "%d:%02d", total / 60, total % 60)
    return String(
      localized: "\(clock) left",
      comment: "Break countdown; the argument is a m:ss clock such as 4:59.")
  }
}

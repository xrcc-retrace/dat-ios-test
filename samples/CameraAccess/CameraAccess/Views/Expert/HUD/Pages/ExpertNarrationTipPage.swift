import SwiftUI

/// Expert lens page — narration tip carousel + tap-to-stop pill +
/// auto-confirm stop overlay.
///
/// Layout (top → bottom inside the lens):
///   1. Centered recording chip (timer + audio meter + pulsing dot)
///   2. Tip card carousel (peek prev + current + next; fixed height)
///   3. Full-width stop pill
///
/// When the user triggers stop (tap or pinch-select on the pill) the
/// overlay layers on top of the page using the recede-and-arrive
/// pattern — page content recedes via the canonical
/// `.rayBanHUDRecede(active:)` modifier (numbers live in
/// `RayBanHUDLayoutTokens.recede*`) and the overlay arrives with a
/// scale-in/opacity transition. The overlay shows a 3-second
/// countdown; tap X (or pinch-back / pinch-select the X) before the
/// timer expires to cancel; otherwise stop auto-fires.
///
/// Carousel mechanics:
///   • Touch DragGesture binds `dragOffset` to live translation.
///     Adjacent card peeks in. Release past `stepSwipeCommitThreshold`
///     runs the commit animation; below, snap-back.
///   • Pinch-drag-release (terminal `.left` / `.right`) runs the same
///     commit animation programmatically. Highlights mid-pinch are
///     ignored — the user's release is the commit signal.
///
/// The page only renders while `recordingManager.isRecording` (gated
/// at `IPhoneRecordingView`'s `hud:` slot), so its `.onAppear` is a
/// safe place to install the `HandGestureService.shared.onEvent`
/// terminal-event hook.
struct ExpertNarrationTipPage: RayBanHUDView {
  @ObservedObject var recordingManager: ExpertRecordingManager
  @ObservedObject var hud: ExpertRecordingHUDViewModel
  let onStop: () -> Void

  @EnvironmentObject private var hoverCoordinator: HUDHoverCoordinator

  /// Set when the stop overlay is showing. Drives the recede-and-arrive
  /// transition + the countdown progress bar's start time.
  @State private var countdownStartedAt: Date?
  /// The auto-confirm Task. Sleeps `stopCountdownDuration` then fires
  /// `onStop` if not cancelled.
  @State private var commitTask: Task<Void, Never>?

  /// Live drag offset used by the carousel. 0 = current card centered;
  /// negative = dragged left (next card peeking in from right);
  /// positive = dragged right (prev card peeking in from left).
  @State private var dragOffset: CGFloat = 0
  /// Re-entry guard so a second swipe mid-animation can't double-commit.
  @State private var isCommitting: Bool = false
  /// Cached card width set by the GeometryReader on layout. Read by
  /// the terminal-event closure so its programmatic slide uses the
  /// same metric as the touch drag.
  @State private var cachedCardWidth: CGFloat = 0

  var body: some View {
    ZStack {
      primaryContent
        // Recede the page hard so the overlay reads as foreground.
        // Combined with the overlay's heavier weight, the eye locks
        // onto the overlay without any ambiguity. Recessed page also
        // can't catch carousel swipes / pill taps — those would land
        // on stale affordances mid-countdown. Numbers live in
        // `RayBanHUDLayoutTokens.recede*`.
        .rayBanHUDRecede(active: countdownStartedAt != nil)

      if let started = countdownStartedAt {
        ExpertHUDStopOverlay(
          startedAt: started,
          duration: RayBanHUDLayoutTokens.stopCountdownDuration,
          onCancel: cancelStopFlow
        )
        .transition(.scale(scale: 0.88).combined(with: .opacity))
        .padding(.horizontal, 24)
        .hudInputHandler { coord in
          ExpertStopOverlayHandler(coordinator: coord, onCancel: cancelStopFlow)
        }
      }
    }
    .animation(
      .spring(response: 0.32, dampingFraction: 0.85),
      value: countdownStartedAt != nil
    )
    .onAppear {
      // Pinch-drag-release → tip cycle, BUT only when the cursor is on
      // the narration card. The stop pill has no left/right neighbors
      // in the focus graph, so a pinch-drag-release while parked on
      // it should be a no-op — not silently cycle the carousel
      // underneath. Mirrors the focus-engine principle: page actions
      // belong to the focused element, not the page globally.
      //
      // Highlights are also ignored (the page handler returns false
      // for `.directional`); only terminal events fire here.
      let coord = hoverCoordinator
      HandGestureService.shared.onEvent = { event in
        Task { @MainActor in
          guard coord.hovered == .expertTipCard else { return }
          switch event {
          case .right: commitDirection(.right)
          case .left:  commitDirection(.left)
          default: break
          }
        }
      }
    }
    .onDisappear {
      HandGestureService.shared.onEvent = nil
      commitTask?.cancel()
      commitTask = nil
    }
    .hudInputHandler { coord in
      ExpertTipPageHandler(coordinator: coord)
    }
  }

  // MARK: - Primary content

  private var primaryContent: some View {
    // Outer padding gives the timer pill its breathing room at the top
    // and the stop pill its breathing room at the bottom. The card
    // fills everything between the two pills with `.frame(maxHeight:
    // .infinity)`. Inter-element spacing is the same on both sides of
    // the card so the gaps timer→card and card→stop match.
    VStack(spacing: 14) {
      statusRow
      carousel
      stopPill
    }
    .padding(RayBanHUDLayoutTokens.contentPadding)
  }

  /// Centered recording chip (timer + audio meter) + ambient hand-
  /// tracking status indicator. The mic-source badge that used to live
  /// here moved out — at this point in the flow the expert already
  /// picked their transport; surfacing the mic source again inside the
  /// lens is just visual noise.
  ///
  /// The hand indicator hangs off the right of the chip; both stay
  /// centered as a unit thanks to the flanking `Spacer`s. When the
  /// user has hand tracking disabled in Server Settings → Debug, the
  /// indicator returns `EmptyView()` and the chip re-centers naturally
  /// without any geometry change.
  private var statusRow: some View {
    HStack(spacing: 8) {
      Spacer(minLength: 0)
      ExpertHUDRecordingStatusChip(
        duration: recordingManager.recordingDuration,
        audioPeak: hud.smoothedAudioPeak,
        isRecording: recordingManager.isRecording
      )
      HandTrackingStatusIndicator()
      Spacer(minLength: 0)
    }
  }

  /// Three adjacent cards (prev | current | next), HStack-offset so
  /// the current is centered when dragOffset == 0. Adjacent cards
  /// peek into view as the user drags.
  private var carousel: some View {
    GeometryReader { geo in
      let cardWidth = geo.size.width
      HStack(spacing: 0) {
        ExpertHUDNarrationTipCard(tip: tip(at: hud.tipIndex - 1))
          .frame(width: cardWidth)
        ExpertHUDNarrationTipCard(tip: tip(at: hud.tipIndex))
          .frame(width: cardWidth)
          .hoverSelectable(
            .expertTipCard,
            shape: .rounded(RayBanHUDLayoutTokens.cardRadius),
            behavior: .selectOnly
          ) {}
        ExpertHUDNarrationTipCard(tip: tip(at: hud.tipIndex + 1))
          .frame(width: cardWidth)
      }
      .frame(width: cardWidth * 3, alignment: .leading)
      .offset(x: -cardWidth + dragOffset)
      // `.simultaneousGesture` so the middle card's hoverSelectable
      // tap can coexist with the carousel's horizontal drag.
      .simultaneousGesture(touchSwipeGesture(cardWidth: cardWidth))
      .onAppear { cachedCardWidth = cardWidth }
      .onChange(of: cardWidth) { _, newWidth in cachedCardWidth = newWidth }
    }
    .frame(maxHeight: .infinity)
    .clipped()
  }

  private var stopPill: some View {
    ExpertHUDStopPill { startStopFlow() }
  }

  // MARK: - Carousel gesture

  private func touchSwipeGesture(cardWidth: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: RayBanHUDLayoutTokens.stepSwipeMinimumDistance)
      .onChanged { value in
        guard !isCommitting else { return }
        // Reject vertical-dominant drags so the user can scroll the
        // surrounding chrome without the carousel hijacking.
        guard abs(value.translation.width) > abs(value.translation.height) else { return }
        dragOffset = value.translation.width
      }
      .onEnded { value in
        guard !isCommitting else { return }
        guard abs(value.translation.width) > abs(value.translation.height) else {
          snapBack()
          return
        }
        let translation = value.translation.width
        let threshold = RayBanHUDLayoutTokens.stepSwipeCommitThreshold
        if translation <= -threshold {
          // Dragged left far enough → advance to next tip.
          commitDirection(.right, cardWidth: cardWidth)
        } else if translation >= threshold {
          // Dragged right far enough → retreat to previous tip.
          commitDirection(.left, cardWidth: cardWidth)
        } else {
          snapBack()
        }
      }
  }

  /// Unified animator for both touch-release-with-threshold and
  /// terminal pinch events.
  ///
  /// `.right` direction = "advance" (next tip; card slides off LEFT).
  /// `.left` direction = "retreat" (prev tip; card slides off RIGHT).
  private func commitDirection(_ direction: Direction, cardWidth: CGFloat? = nil) {
    let width = cardWidth ?? cachedCardWidth
    guard width > 0, !isCommitting else { return }
    isCommitting = true

    let target: CGFloat = direction == .right ? -width : width
    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
      dragOffset = target
    }
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 360_000_000)
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        if direction == .right {
          hud.advanceTip()
        } else {
          hud.retreatTip()
        }
        dragOffset = 0
      }
      isCommitting = false
    }
  }

  private func snapBack() {
    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
      dragOffset = 0
    }
  }

  // MARK: - Stop flow

  /// Open the stop confirmation overlay. Schedules the auto-confirm
  /// Task; the overlay's countdown drives the visual progress bar.
  /// Idempotent — re-triggering while already counting down is a
  /// no-op.
  private func startStopFlow() {
    guard countdownStartedAt == nil else { return }
    countdownStartedAt = Date()
    let nanos = UInt64(RayBanHUDLayoutTokens.stopCountdownDuration * 1_000_000_000)
    commitTask?.cancel()
    commitTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: nanos)
      guard !Task.isCancelled else { return }
      countdownStartedAt = nil
      commitTask = nil
      hoverCoordinator.cancel()
      onStop()
    }
  }

  /// Cancel the pending stop. Cancels the Task so `onStop` doesn't
  /// fire, clears the overlay, restores the cursor.
  private func cancelStopFlow() {
    commitTask?.cancel()
    commitTask = nil
    countdownStartedAt = nil
    hoverCoordinator.cancel()
  }

  // MARK: - Helpers

  private func tip(at index: Int) -> ExpertNarrationTip {
    let count = ExpertCoachingTips.pool.count
    let wrapped = ((index % count) + count) % count
    return ExpertCoachingTips.pool[wrapped]
  }
}

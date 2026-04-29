import SwiftUI

/// Slow auto-scrolling container for overflowing lens content (today: the
/// expanded step card on the Coaching page, where web-search-generated
/// procedures often have descriptions longer than the lens can show).
///
/// When `content` overflows the available viewport height, the inner
/// content drifts upward at `pointsPerSecond` until it reaches the
/// content bottom, then ping-pongs back to the top, then back down,
/// indefinitely. When content fits the viewport, the offset stays at 0
/// and `isOverflowing` reads `false` so the host page can branch its
/// pinch-select semantic accordingly.
///
/// **Architecture:**
///
/// - Outer `GeometryReader` reads the parent's allocated size for the
///   container. The inner `TimelineView` is explicitly sized to that
///   viewport via `.frame(width:height:)`, so the container occupies
///   exactly what its parent gives it — no `.frame(maxHeight: .infinity)`
///   on the timeline view itself, which would let it grow to whatever
///   the lens allows and break sibling layout.
/// - `TimelineView(.animation)` always ticks at the display refresh
///   rate. Pausing the timeline would prevent the body from running,
///   which would prevent the content from rendering, which would
///   prevent overflow detection. Chicken-and-egg. Motion is gated by
///   `currentElapsed()` returning a frozen accumulator while
///   hard-paused.
/// - Content is laid out at natural height inside the timeline (the
///   inner `VStack`'s children already use `.fixedSize(vertical: true)`
///   on their `Text`s). The TimelineView's `.clipped()` clips the
///   overflow visually; the content's natural frame is measurable.
/// - Measurement uses `.onGeometryChange` (iOS 17) — simpler than
///   `PreferenceKey` bubbling out of nested geometry readers.
/// - Pause / resume bookkeeping uses an elapsed-time accumulator so
///   the scroll picks up exactly where it left off when the user
///   resumes.
///
/// Two suspend inputs:
/// - `isUserPaused` (Binding) — user's explicit toggle (pinch-select on
///   the step card). Owned by the host page so the page can branch
///   pinch-select based on this state.
/// - `isExternallySuspended` (Bool) — driven by the host page when an
///   overlay (exit confirmation, identification confirm, end-diagnostic
///   alert) recedes the page.
///
/// On `resetKey` change (e.g. step index advanced, expansion left
/// `.stepExpanded`), the elapsed accumulator resets to 0 and
/// `isUserPaused` is cleared.
struct AutoScrollingContainer<Content: View>: View {
  let pointsPerSecond: Double
  @Binding var isUserPaused: Bool
  let isExternallySuspended: Bool
  /// Reports back whether the content currently overflows the viewport.
  /// The host reads this to decide pinch-select semantics.
  @Binding var isOverflowing: Bool
  /// Hashable trigger; when this changes, scroll position resets to top
  /// and `isUserPaused` clears.
  let resetKey: AnyHashable
  @ViewBuilder let content: () -> Content

  // MARK: - Internal state

  @State private var contentHeight: CGFloat = 0
  @State private var viewportHeight: CGFloat = 0
  @State private var accumulatedElapsed: TimeInterval = 0
  @State private var lastResumeAt: Date = Date()

  private var overflow: CGFloat {
    max(0, contentHeight - viewportHeight)
  }

  private var isHardPaused: Bool {
    isUserPaused || isExternallySuspended
  }

  /// Time to scroll one direction (top → bottom). Cycle duration is
  /// 2× this (down then back up).
  private var halfCycleDuration: TimeInterval {
    guard pointsPerSecond > 0 else { return .infinity }
    return TimeInterval(overflow) / pointsPerSecond
  }

  /// Reads elapsed time, accounting for paused intervals.
  private func currentElapsed() -> TimeInterval {
    if isHardPaused {
      return accumulatedElapsed
    }
    return accumulatedElapsed + Date().timeIntervalSince(lastResumeAt)
  }

  /// Map elapsed seconds to a `0…1` ping-pong phase.
  /// 0 = top of content, 1 = bottom of content.
  ///
  /// Cycle has four segments so the eye can anchor at each endpoint:
  ///   1. dwell at top    (`phase = 0`,   length = `dwellDuration`)
  ///   2. scroll down     (`phase 0→1`,   length = `halfCycleDuration`)
  ///   3. dwell at bottom (`phase = 1`,   length = `dwellDuration`)
  ///   4. scroll up       (`phase 1→0`,   length = `halfCycleDuration`)
  private func phase(at elapsed: TimeInterval) -> CGFloat {
    guard halfCycleDuration > 0, halfCycleDuration.isFinite else { return 0 }
    let dwell = RayBanHUDLayoutTokens.autoScrollEdgeDwellDuration
    let scroll = halfCycleDuration
    let cycle = 2 * (dwell + scroll)
    let t = elapsed.truncatingRemainder(dividingBy: cycle)

    if t < dwell {
      // Segment 1 — pinned at top.
      return 0
    }
    if t < dwell + scroll {
      // Segment 2 — scrolling down.
      return CGFloat((t - dwell) / scroll)
    }
    if t < 2 * dwell + scroll {
      // Segment 3 — pinned at bottom.
      return 1
    }
    // Segment 4 — scrolling back up.
    return CGFloat(1 - (t - 2 * dwell - scroll) / scroll)
  }

  // MARK: - Body

  var body: some View {
    GeometryReader { viewportProxy in
      TimelineView(.animation) { _ in
        let p = phase(at: currentElapsed())
        content()
          .frame(maxWidth: .infinity, alignment: .leading)
          .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
          } action: { newHeight in
            contentHeight = newHeight
            recomputeOverflowSignal()
          }
          .offset(y: -p * overflow)
      }
      .frame(width: viewportProxy.size.width, height: viewportProxy.size.height, alignment: .top)
      .clipped()
      .onAppear {
        viewportHeight = viewportProxy.size.height
        recomputeOverflowSignal()
      }
      .onChange(of: viewportProxy.size.height) { _, newValue in
        viewportHeight = newValue
        recomputeOverflowSignal()
      }
    }
    .onChange(of: resetKey) { _, _ in
      reset()
    }
    .onChange(of: isUserPaused) { oldValue, newValue in
      let wasHardPaused = oldValue || isExternallySuspended
      let nowHardPaused = newValue || isExternallySuspended
      handlePauseTransition(wasPaused: wasHardPaused, isPausedNow: nowHardPaused)
    }
    .onChange(of: isExternallySuspended) { oldValue, newValue in
      let wasHardPaused = isUserPaused || oldValue
      let nowHardPaused = isUserPaused || newValue
      handlePauseTransition(wasPaused: wasHardPaused, isPausedNow: nowHardPaused)
    }
  }

  // MARK: - Bookkeeping

  /// On run→pause: bank the elapsed time we'd accumulated since the
  /// last resume. On pause→run: snapshot the new resume timestamp so
  /// future reads start from "now" relative to the banked elapsed.
  private func handlePauseTransition(wasPaused: Bool, isPausedNow: Bool) {
    guard wasPaused != isPausedNow else { return }
    if isPausedNow {
      accumulatedElapsed += Date().timeIntervalSince(lastResumeAt)
    } else {
      lastResumeAt = Date()
    }
  }

  private func reset() {
    accumulatedElapsed = 0
    lastResumeAt = Date()
    isUserPaused = false
  }

  private func recomputeOverflowSignal() {
    let nowOverflowing = contentHeight > viewportHeight
    if nowOverflowing != isOverflowing {
      isOverflowing = nowOverflowing
    }
  }
}

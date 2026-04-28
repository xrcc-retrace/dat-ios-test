import Foundation

/// Focus-engine handler for the Expert narration tip page.
///
/// Default focus = `.expertStopRecording`. The stop pill is the only
/// `.hoverSelectable` element on the page, so the cursor lives there
/// while recording is active. Pinch-select on the stop pill is a
/// **deliberate no-op** (the pill registers an empty `onConfirm`
/// closure) — stop is destructive enough to require a 2-second hold,
/// not a single confirm gesture. The hold lives on the pill's own
/// `simultaneousGesture(DragGesture)`, separate from the focus engine.
///
/// Tip cycling lives **outside** this handler. We want commit-on-release
/// semantics: pinch-drag-left mid-flight should NOT cycle, only the
/// terminal `.left` event on release should. Highlights fire mid-pinch
/// and translate into `.directional(...)` dispatches; if we consumed
/// them here, the cycle would happen the moment the thumb crossed a
/// quadrant — too eager. So `handle(direction:)` returns `false` for
/// left/right, and `ExpertNarrationTipPage` listens for terminal
/// `.left`/`.right` directly via `HandGestureService.shared.onEvent`.
/// Touch-swipe-release goes through the same animator, so both paths
/// converge on identical visual behavior.
///
/// What this handler does own:
/// - Default focus = `.expertStopRecording` (cursor parks on the stop
///   pill while recording).
/// - `.select` → fires the focused element's registered `onConfirm`.
///   For the default-focused stop pill that's the empty closure on
///   the `.hoverSelectable` (intentional — stop is destructive enough
///   to demand the 2-second hold, not a single pinch-select).
/// - `.dismiss` → not consumed; the emulator runs with
///   `enableDismissGesture: false` so this never fires from touch, and
///   we also don't want pinch-back to ambush a recording.
@MainActor
final class ExpertTipPageHandler: HUDInputHandler {
  unowned let coordinator: HUDHoverCoordinator

  init(coordinator: HUDHoverCoordinator) {
    self.coordinator = coordinator
  }

  var defaultFocus: HUDControl? { .expertStopRecording }

  /// Two reachable controls: stop pill (default) and tip card.
  /// Pinch-up moves the cursor onto the card (so the user can see the
  /// hover ring on it before swiping); pinch-down returns to the stop
  /// pill. Left/right are NOT in the graph — those events drive the
  /// carousel via the legacy onEvent path on terminal release, NOT
  /// directional focus traversal.
  var focusGraph: FocusGraph {
    [
      .expertStopRecording: FocusNeighbors(up: .expertTipCard),
      .expertTipCard:       FocusNeighbors(down: .expertStopRecording),
    ]
  }

  /// Up/down traverse the graph (stop ↔ card). Left/right are not
  /// consumed — see class comment.
  func handle(direction: Direction) -> Bool {
    switch direction {
    case .up, .down:
      return defaultFocusTraversal(
        coordinator: coordinator,
        graph: focusGraph,
        direction: direction
      )
    case .left, .right:
      return false
    }
  }

  func handleSelect() -> Bool {
    guard let id = coordinator.hovered else { return false }
    coordinator.fireConfirm(for: id)
    return true
  }

  func handleDismiss() -> Bool { false }

  var voiceCommands: [String: () -> Void] { [:] }
}

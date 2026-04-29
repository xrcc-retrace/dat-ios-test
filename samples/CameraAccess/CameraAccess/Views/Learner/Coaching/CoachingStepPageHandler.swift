import Foundation

/// Focus-engine handler for the Coaching step page (collapsed state).
///
/// Default focus = `.stepCard`. Page-level semantics:
///
/// - **Left/right** while focused on the step card → step nav, but
///   **commit-on-release**, not commit-on-highlight. Highlights fire
///   mid-pinch as the thumb crosses a quadrant; consuming them here
///   would advance / retreat the step the moment the user starts
///   dragging — too eager, and accumulates accidental skips when the
///   learner just shifts their hand. Terminal `.left` / `.right` events
///   fire step nav via the page's `HandGestureService.shared.onEvent`
///   listener instead. Mirrors Expert's narration tip carousel
///   (`ExpertTipPageHandler` / `ExpertNarrationTipPage`).
/// - **Up** from the step card → cursor moves to the leftmost top button
///   (Reference if present, else Insights, else no-op). Encoded directly
///   in the focus graph via the leftmost-first rule.
/// - **Up/right** while focused on the top buttons → graph traversal
///   (Reference ↔ Insights via the row).
/// - **Down** from the top buttons → return to step card.
/// - **Select** anywhere → fire the focused element's `onConfirm` (toggle
///   reference / insights expansion, etc.).
/// - **Dismiss** → trigger the exit confirmation overlay via the
///   `onShowExitConfirmation` callback (the parent view owns the
///   overlay's presentation state).
///
/// Voice commands lined up for Phase 4 — the handler declares them now;
/// the voice adapter consumes them later.
@MainActor
final class CoachingStepPageHandler: HUDInputHandler {
  unowned let coordinator: HUDHoverCoordinator
  let onAdvanceStep: () -> Void
  let onRetreatStep: () -> Void
  let hasReference: () -> Bool
  let hasInsights: () -> Bool
  /// True while the step page's reference panel is expanded. When
  /// true, the focus graph slots `.referenceClip` between the top
  /// affordances and the (compact) step card so the user can pinch-
  /// down from `.toggleReference` onto the clip and pinch-select to
  /// toggle playback. When false, the graph stays in collapsed shape
  /// (no `.referenceClip` entry).
  let isReferenceExpanded: () -> Bool
  let onSetMuted: (Bool) -> Void
  let onShowExitConfirmation: () -> Void

  init(
    coordinator: HUDHoverCoordinator,
    onAdvanceStep: @escaping () -> Void,
    onRetreatStep: @escaping () -> Void,
    hasReference: @escaping () -> Bool,
    hasInsights: @escaping () -> Bool,
    isReferenceExpanded: @escaping () -> Bool,
    onSetMuted: @escaping (Bool) -> Void,
    onShowExitConfirmation: @escaping () -> Void
  ) {
    self.coordinator = coordinator
    self.onAdvanceStep = onAdvanceStep
    self.onRetreatStep = onRetreatStep
    self.hasReference = hasReference
    self.hasInsights = hasInsights
    self.isReferenceExpanded = isReferenceExpanded
    self.onSetMuted = onSetMuted
    self.onShowExitConfirmation = onShowExitConfirmation
  }

  var defaultFocus: HUDControl? { .stepCard }

  /// Both top-row pills are always rendered — even when the step has
  /// no reference clip or no insights, the pills stay visible (with a
  /// gray status dot) so the user can navigate to them and see the
  /// empty state on tap. The focus graph mirrors that: Reference and
  /// Insights are always reachable from the step card via `.up`, and
  /// they chain to each other via left/right regardless of content
  /// presence.
  ///
  /// In `.referenceExpanded` state the clip panel sits in the middle
  /// of the lens; up/down chain becomes:
  /// `top affordances ↔ .referenceClip ↔ .stepCard ↔ bottom actions`.
  ///
  /// `hasReference` / `hasInsights` callbacks are kept for the
  /// expansion branching below and for future per-content behavior.
  var focusGraph: FocusGraph {
    var graph: FocusGraph = [:]

    let referenceExpanded = isReferenceExpanded() && hasReference()

    graph[.stepCard] = FocusNeighbors(
      up: referenceExpanded ? .referenceClip : .toggleReference,
      down: .toggleMute
    )

    graph[.toggleReference] = FocusNeighbors(
      down: referenceExpanded ? .referenceClip : .stepCard,
      right: .toggleInsights
    )
    graph[.toggleInsights] = FocusNeighbors(
      down: referenceExpanded ? .referenceClip : .stepCard,
      left: .toggleReference
    )
    graph[.toggleMute] = FocusNeighbors(
      up: .stepCard,
      right: .exitWorkflowButton
    )
    graph[.exitWorkflowButton] = FocusNeighbors(
      up: .stepCard,
      left: .toggleMute
    )

    if referenceExpanded {
      // Clip panel — only in the graph while actually visible. No
      // left/right neighbors per the input rule (directional input on
      // the focused element does nothing unless the graph or a page-
      // level override defines it).
      graph[.referenceClip] = FocusNeighbors(
        up: .toggleReference,
        down: .stepCard
      )
    }

    return graph
  }

  /// Up/down on step card = focus-graph traversal (top affordances /
  /// bottom audio row / reference clip when expanded). Left/right on
  /// the step card are NOT consumed here — step nav uses a
  /// commit-on-release model and runs from the page's
  /// `HandGestureService.shared.onEvent` listener instead. See class
  /// comment.
  ///
  /// Once focus is on a top button or the bottom row, all directions
  /// traverse the graph (no page-level override applies there).
  func handle(direction: Direction) -> Bool {
    if coordinator.hovered == .stepCard {
      switch direction {
      case .left, .right:
        // Returning false drops the highlight-fired (mid-pinch)
        // directional and the lens emulator's release-fired touch
        // swipe directional. The terminal pinch path on
        // `HandGestureService.shared.onEvent` is what now fires step
        // nav. Mirrors Expert's narration carousel exactly.
        return false
      case .up, .down:
        return defaultFocusTraversal(
          coordinator: coordinator,
          graph: focusGraph,
          direction: direction
        )
      }
    }
    return defaultFocusTraversal(
      coordinator: coordinator,
      graph: focusGraph,
      direction: direction
    )
  }

  func handleSelect() -> Bool {
    guard let id = coordinator.hovered else { return false }
    coordinator.fireConfirm(for: id)
    return true
  }

  func handleDismiss() -> Bool {
    onShowExitConfirmation()
    return true
  }

  var voiceCommands: [String: () -> Void] {
    [
      "next step":      { [weak self] in self?.onAdvanceStep() },
      "previous step":  { [weak self] in self?.onRetreatStep() },
      "go back":        { [weak self] in self?.onRetreatStep() },
      "show reference": { [weak self] in self?.coordinator.fireConfirm(for: .toggleReference) },
      "hide reference": { [weak self] in self?.coordinator.fireConfirm(for: .toggleReference) },
      "show insights":  { [weak self] in self?.coordinator.fireConfirm(for: .toggleInsights) },
      "hide insights":  { [weak self] in self?.coordinator.fireConfirm(for: .toggleInsights) },
      "mute":           { [weak self] in self?.onSetMuted(true) },
      "unmute":         { [weak self] in self?.onSetMuted(false) },
      "exit":           { [weak self] in self?.onShowExitConfirmation() },
      "exit workflow":  { [weak self] in self?.onShowExitConfirmation() },
    ]
  }
}

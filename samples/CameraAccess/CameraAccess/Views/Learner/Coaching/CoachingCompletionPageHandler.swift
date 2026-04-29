import Foundation

/// Focus-engine handler for the Coaching completion page.
///
/// Single focusable node: `.completionSavedWorkflows` (the "Return to
/// workflows" pill). The summary card above it is decorative — not
/// hover-selectable, so up/down has nowhere to traverse.
///
/// Default focus = `.completionSavedWorkflows`.
///
/// - **Up/down/left/right** → no-op (single-node graph).
/// - **Select** → fire the focused pill's `onConfirm` (exits the session).
/// - **Dismiss** → no-op; the page handler doesn't claim dismiss because
///   the procedure is already complete and exit is the intended outcome
///   anyway. `coordinator.dispatch(.dismiss)` returns false; the lens
///   double-tap caller is free to do nothing further.
@MainActor
final class CoachingCompletionPageHandler: HUDInputHandler {
  unowned let coordinator: HUDHoverCoordinator

  init(coordinator: HUDHoverCoordinator) {
    self.coordinator = coordinator
  }

  var defaultFocus: HUDControl? { .completionSavedWorkflows }

  var focusGraph: FocusGraph {
    [
      .completionSavedWorkflows: FocusNeighbors(),
    ]
  }

  func handle(direction: Direction) -> Bool {
    defaultFocusTraversal(
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

  func handleDismiss() -> Bool { false }

  var voiceCommands: [String: () -> Void] {
    [
      "return to workflows":  { [weak self] in self?.coordinator.fireConfirm(for: .completionSavedWorkflows) },
      "workflows":            { [weak self] in self?.coordinator.fireConfirm(for: .completionSavedWorkflows) },
      "library":              { [weak self] in self?.coordinator.fireConfirm(for: .completionSavedWorkflows) },
      "done":                 { [weak self] in self?.coordinator.fireConfirm(for: .completionSavedWorkflows) },
    ]
  }
}

import Foundation

/// Focus-engine handler for the Coaching completion page.
///
/// Vertical chain through three action cards:
///   `.completionOk` → `.completionSavedWorkflows` → `.completionTroubleshoot`
///
/// Default focus = `.completionOk` (the natural starting position; user
/// most often confirms-and-leaves on completion).
///
/// - **Up/down** → traverse the chain.
/// - **Left/right** → no-op (vertical layout, no horizontal neighbors).
/// - **Select** → fire focused action card's `onConfirm`.
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

  var defaultFocus: HUDControl? { .completionOk }

  var focusGraph: FocusGraph {
    [
      .completionOk: FocusNeighbors(
        down: .completionSavedWorkflows
      ),
      .completionSavedWorkflows: FocusNeighbors(
        up: .completionOk,
        down: .completionTroubleshoot
      ),
      .completionTroubleshoot: FocusNeighbors(
        up: .completionSavedWorkflows
      ),
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
      "done":             { [weak self] in self?.coordinator.fireConfirm(for: .completionOk) },
      "saved workflows":  { [weak self] in self?.coordinator.fireConfirm(for: .completionSavedWorkflows) },
      "library":          { [weak self] in self?.coordinator.fireConfirm(for: .completionSavedWorkflows) },
      "troubleshoot":     { [weak self] in self?.coordinator.fireConfirm(for: .completionTroubleshoot) },
    ]
  }
}

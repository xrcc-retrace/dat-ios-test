import Foundation

/// Focus-engine handler for the exit confirmation overlay.
///
/// Default focus = `.exitConfirmCancel` (the safe option). An accidental
/// `.select` cannot trigger exit by itself — the user has to deliberately
/// move the cursor to Confirm before selecting, which is the protection
/// the layered focus model provides.
///
/// - **Up/down** → traverses Cancel ↔ Confirm. Mirrors the visual layout
///   (Cancel sits above Confirm in the overlay).
/// - **Left/right** → no-op (no horizontal neighbors).
/// - **Select** → fires the focused button's `onConfirm`.
/// - **Dismiss** → equivalent to Cancel (the user wants out).
///
/// The handler doesn't own the dismiss UI itself — it's pushed onto the
/// stack by `CoachingExitConfirmationOverlay`'s `.hudInputHandler`
/// modifier on appear, popped on disappear. Cancel / Confirm closures
/// are registered with the coordinator via the buttons'
/// `.hoverSelectable(...)` modifier; this handler just routes events.
@MainActor
final class CoachingExitConfirmHandler: HUDInputHandler {
  unowned let coordinator: HUDHoverCoordinator

  init(coordinator: HUDHoverCoordinator) {
    self.coordinator = coordinator
  }

  var defaultFocus: HUDControl? { .exitConfirmCancel }

  var focusGraph: FocusGraph {
    [
      .exitConfirmCancel: FocusNeighbors(down: .exitConfirmExit),
      .exitConfirmExit:   FocusNeighbors(up: .exitConfirmCancel),
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

  /// Dismiss = Cancel. Fires the Cancel button's registered `onConfirm`,
  /// which dismisses the overlay (the parent's `showDismissConfirmation`
  /// flips false; this handler pops on disappear; underlying step page
  /// handler resumes).
  func handleDismiss() -> Bool {
    coordinator.fireConfirm(for: .exitConfirmCancel)
    return true
  }

  var voiceCommands: [String: () -> Void] {
    [
      "yes":     { [weak self] in self?.coordinator.fireConfirm(for: .exitConfirmExit) },
      "exit":    { [weak self] in self?.coordinator.fireConfirm(for: .exitConfirmExit) },
      "confirm": { [weak self] in self?.coordinator.fireConfirm(for: .exitConfirmExit) },
      "no":      { [weak self] in self?.coordinator.fireConfirm(for: .exitConfirmCancel) },
      "cancel":  { [weak self] in self?.coordinator.fireConfirm(for: .exitConfirmCancel) },
      "go back": { [weak self] in self?.coordinator.fireConfirm(for: .exitConfirmCancel) },
    ]
  }
}

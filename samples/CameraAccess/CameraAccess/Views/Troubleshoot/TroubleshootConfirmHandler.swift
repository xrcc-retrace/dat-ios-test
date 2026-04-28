import Foundation

/// Focus-engine handler for the Troubleshoot identification-confirmation
/// overlay ("That's it" / "Try again").
///
/// Default focus = `.confirmIdentification` (the forward path). Neither
/// option is destructive — re-identifying just resets local state and
/// nudges Gemini to try again — so the cursor lands on the most likely
/// user intent rather than the safer-back-out option (cf. the exit
/// confirmation overlay where Cancel is the safe default).
///
/// - **Down/right** from Confirm -> Re-identify.
/// - **Up/left** from Re-identify -> Confirm.
/// - **Select** → fires the focused button's `onConfirm`.
/// - **Dismiss** → equivalent to Re-identify (the user wants out of the
///   "is this the right product?" question; rejecting the guess and
///   trying again is the natural escape hatch).
@MainActor
final class TroubleshootConfirmHandler: HUDInputHandler {
  unowned let coordinator: HUDHoverCoordinator

  init(coordinator: HUDHoverCoordinator) {
    self.coordinator = coordinator
  }

  var defaultFocus: HUDControl? { .confirmIdentification }

  var focusGraph: FocusGraph {
    [
      .confirmIdentification: FocusNeighbors(down: .reIdentify, right: .reIdentify),
      .reIdentify:            FocusNeighbors(up: .confirmIdentification, left: .confirmIdentification),
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

  /// Dismiss = Re-identify. Fires the reject button's registered
  /// `onConfirm`, which closes the overlay (parent's
  /// `pendingConfirmation` flips false; the page handler underneath
  /// resumes).
  func handleDismiss() -> Bool {
    coordinator.fireConfirm(for: .reIdentify)
    return true
  }

  var voiceCommands: [String: () -> Void] {
    [
      "yes":          { [weak self] in self?.coordinator.fireConfirm(for: .confirmIdentification) },
      "that's it":    { [weak self] in self?.coordinator.fireConfirm(for: .confirmIdentification) },
      "confirm":      { [weak self] in self?.coordinator.fireConfirm(for: .confirmIdentification) },
      "no":           { [weak self] in self?.coordinator.fireConfirm(for: .reIdentify) },
      "try again":    { [weak self] in self?.coordinator.fireConfirm(for: .reIdentify) },
      "wrong":        { [weak self] in self?.coordinator.fireConfirm(for: .reIdentify) },
    ]
  }
}

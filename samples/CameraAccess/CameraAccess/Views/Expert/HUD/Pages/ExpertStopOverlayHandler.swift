import Foundation

/// Focus-engine handler for the Expert stop-recording confirmation
/// overlay. Pushed onto the coordinator stack when the overlay opens
/// (via `.hudInputHandler` on the overlay view), popped when it closes.
///
/// The overlay has one interactive element — the X (cancel) button.
/// Default focus lands there so a pinch-select cancels the pending
/// stop instead of waiting for the timer. Lens double-tap (pinch-back)
/// also cancels, via `handleDismiss`. The auto-confirm path is the
/// timer expiring — owned by the page, not this handler.
@MainActor
final class ExpertStopOverlayHandler: HUDInputHandler {
  unowned let coordinator: HUDHoverCoordinator
  let onCancel: () -> Void

  init(coordinator: HUDHoverCoordinator, onCancel: @escaping () -> Void) {
    self.coordinator = coordinator
    self.onCancel = onCancel
  }

  var defaultFocus: HUDControl? { .expertStopCancel }

  var focusGraph: FocusGraph { [:] }

  func handle(direction: Direction) -> Bool { false }

  func handleSelect() -> Bool {
    guard let id = coordinator.hovered else { return false }
    coordinator.fireConfirm(for: id)
    return true
  }

  func handleDismiss() -> Bool {
    onCancel()
    return true
  }

  var voiceCommands: [String: () -> Void] {
    [
      "cancel":  { [weak self] in self?.onCancel() },
      "no":      { [weak self] in self?.onCancel() },
      "go back": { [weak self] in self?.onCancel() },
    ]
  }
}

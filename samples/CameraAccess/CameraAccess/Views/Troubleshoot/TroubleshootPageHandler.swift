import Foundation

/// Generic focus-engine handler for Troubleshoot lens pages.
///
/// All five Troubleshoot pages (Identify / Diagnose / Searching / Resolved
/// / NoSolution) share the same shape: at most one interactive control
/// per page, and the page-level meaning of `.dismiss` is "end the
/// diagnostic session" (i.e. open the same confirmation alert the
/// top-bar close button opens). One handler class with a couple of
/// parameters covers all five rather than five near-identical classes.
///
/// Layout:
///
/// - `focusedControl: nil` — passive page (Identify / Diagnose / Searching).
///   No focus, no select, but `.dismiss` is still consumed.
/// - `focusedControl: .someControl` — active page (Resolved / NoSolution).
///   Default focus lands on the single button; pinch-select fires it via
///   the registered `onConfirm`.
///
/// Direction handling is a no-op everywhere (single-element pages have
/// no traversal). If a future page needs neighbor-based traversal, swap
/// in a dedicated handler subclass — this one stays single-purpose.
@MainActor
final class TroubleshootPageHandler: HUDInputHandler {
  unowned let coordinator: HUDHoverCoordinator
  let focusedControl: HUDControl?
  let onDismiss: () -> Void
  let onSetMuted: (Bool) -> Void
  /// Voice phrase that fires the focused control's confirm closure.
  /// Layered on top of the always-available exit phrases. Ignored when
  /// `focusedControl == nil`.
  let voiceCommandLabel: String?

  init(
    coordinator: HUDHoverCoordinator,
    focusedControl: HUDControl? = nil,
    voiceCommandLabel: String? = nil,
    onSetMuted: @escaping (Bool) -> Void,
    onDismiss: @escaping () -> Void
  ) {
    self.coordinator = coordinator
    self.focusedControl = focusedControl
    self.voiceCommandLabel = voiceCommandLabel
    self.onSetMuted = onSetMuted
    self.onDismiss = onDismiss
  }

  var defaultFocus: HUDControl? { focusedControl ?? .diagnosticToggleMute }

  var focusGraph: FocusGraph {
    var graph: FocusGraph = [
      .diagnosticToggleMute: FocusNeighbors(right: .diagnosticExit),
      .diagnosticExit: FocusNeighbors(left: .diagnosticToggleMute),
    ]

    if let focusedControl {
      graph[focusedControl] = FocusNeighbors(down: .diagnosticToggleMute)
      graph[.diagnosticToggleMute] = FocusNeighbors(up: focusedControl, right: .diagnosticExit)
      graph[.diagnosticExit] = FocusNeighbors(up: focusedControl, left: .diagnosticToggleMute)
    }

    return graph
  }

  func handle(direction: Direction) -> Bool {
    defaultFocusTraversal(coordinator: coordinator, graph: focusGraph, direction: direction)
  }

  func handleSelect() -> Bool {
    guard let id = coordinator.hovered else { return false }
    coordinator.fireConfirm(for: id)
    return true
  }

  /// Dismiss = end-diagnostic confirmation alert. Consumed at this
  /// layer so the focus-engine pipeline behaves identically to the
  /// double-pinch back gesture (which currently routes through the
  /// legacy `viewModel.onBackGesture` callback to the same destination).
  func handleDismiss() -> Bool {
    onDismiss()
    return true
  }

  var voiceCommands: [String: () -> Void] {
    var commands: [String: () -> Void] = [
      "exit":           { [weak self] in self?.onDismiss() },
      "end diagnostic": { [weak self] in self?.onDismiss() },
      "cancel":         { [weak self] in self?.onDismiss() },
      "mute":           { [weak self] in self?.onSetMuted(true) },
      "unmute":         { [weak self] in self?.onSetMuted(false) },
    ]
    if let id = focusedControl, let label = voiceCommandLabel {
      commands[label] = { [weak self] in self?.coordinator.fireConfirm(for: id) }
    }
    return commands
  }
}

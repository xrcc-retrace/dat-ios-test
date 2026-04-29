import SwiftUI

/// Discrete input event dispatched into the focus engine. All input
/// modalities — touch (`DragGesture` on `RayBanHUDEmulator`), MediaPipe
/// pinch-drag (Phase 3 adapter), future voice (Phase 4) — funnel into
/// `HUDHoverCoordinator.dispatch(_:)`. The topmost active handler decides
/// what each event *means* in its context (e.g. `.directional(.left)` is
/// "previous step" on the step page, "move cursor to Cancel" on the exit
/// overlay).
enum HUDInputEvent: Equatable {
  case directional(Direction)
  case select
  /// Back gesture. Step page → trigger exit confirmation overlay.
  /// Overlay → equivalent to Cancel.
  case dismiss
}

enum Direction: Equatable {
  case up
  case down
  case left
  case right
}

/// Per-element neighbor map. `nil` in any direction means "no neighbor"
/// — the handler may consume the event silently or fall through to
/// other behavior.
struct FocusNeighbors: Equatable {
  var up: HUDControl?
  var down: HUDControl?
  var left: HUDControl?
  var right: HUDControl?

  init(
    up: HUDControl? = nil,
    down: HUDControl? = nil,
    left: HUDControl? = nil,
    right: HUDControl? = nil
  ) {
    self.up = up
    self.down = down
    self.left = left
    self.right = right
  }
}

typealias FocusGraph = [HUDControl: FocusNeighbors]

/// One handler is "active" per stack layer. Pages install their handler
/// at the bottom of the stack on appear; overlays push on top. The
/// topmost handler eats events. When an overlay pops, the page handler
/// underneath automatically becomes active again.
///
/// Conformers are typically classes living for the lifetime of the
/// page/overlay. Use the `.hudInputHandler { coord in MyHandler(…) }`
/// view modifier to register one — the modifier handles push/pop on
/// view lifecycle.
@MainActor
protocol HUDInputHandler: AnyObject {
  /// Neighbor graph for directional traversal. Empty if the handler
  /// interprets directional input page-locally without a graph (e.g.
  /// the step page does step nav on left/right when cursor is on the
  /// step card).
  var focusGraph: FocusGraph { get }

  /// Cursor lands here when this handler activates (push). `nil` =
  /// leave focus wherever it is (or cleared).
  var defaultFocus: HUDControl? { get }

  /// Direction handler. Return `true` if consumed. Default impl runs
  /// `defaultFocusTraversal`. Handlers override to add page-level
  /// semantics for specific directions.
  func handle(direction: Direction) -> Bool

  /// Select handler. Default impl fires the focused element's
  /// registered `onConfirm` via `coordinator.fireConfirm(for:)`.
  func handleSelect() -> Bool

  /// Dismiss handler. Default returns `false` (not consumed; the
  /// emulator falls back to the legacy `onLensBackGesture` callback).
  /// Overlays override to consume `.dismiss` as Cancel.
  func handleDismiss() -> Bool

  /// Voice phrase → action mapping. Empty by default. The Phase 4
  /// voice adapter matches transcripts against the topmost handler's
  /// voiceCommands.
  var voiceCommands: [String: () -> Void] { get }
}

extension HUDInputHandler {
  var voiceCommands: [String: () -> Void] { [:] }
}

/// Default focus-graph traversal. Handlers call this from their
/// `handle(direction:)` for the directions where no page-level override
/// applies.
///
/// **Leftmost-first** is encoded by graph authors at declaration time —
/// when a focused element has multiple candidates for a direction, the
/// page declares `up: hasReference ? .toggleReference : (hasInsights ?
/// .toggleInsights : nil)`. This helper just walks the declared graph;
/// the rule lives in the `FocusGraph` itself.
///
/// Mutates `coordinator.hovered` inside the canonical lens-motion spring
/// so the cursor's transition between elements matches the rest of the
/// HUD's motion vocabulary (see DESIGN.md → Animation System).
@MainActor
@discardableResult
func defaultFocusTraversal(
  coordinator: HUDHoverCoordinator,
  graph: FocusGraph,
  direction: Direction
) -> Bool {
  guard let current = coordinator.hovered,
        let neighbors = graph[current] else { return false }
  let next: HUDControl?
  switch direction {
  case .up: next = neighbors.up
  case .down: next = neighbors.down
  case .left: next = neighbors.left
  case .right: next = neighbors.right
  }
  guard let next else { return false }
  withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
    coordinator.hovered = next
  }
  return true
}

// MARK: - MediaPipe pinch-drag translation

/// Translates a `PinchDragEvent` from the MediaPipe recognizer into a
/// `HUDInputEvent` dispatched on the coordinator. Lets touch swipes and
/// hand gestures share one focus-engine pipeline.
///
/// Mapping (designed so cursor moves once per gesture, not twice):
///
/// - `.highlightLeft/Right/Up/Down` → `.directional(...)`. **Highlights
///   drive the cursor.** They fire mid-pinch as the thumb enters a
///   quadrant; the cursor moves to the highlighted neighbor in real
///   time. When the user releases their pinch, the cursor stays where
///   it last highlighted — matches the "release leaves cursor put"
///   intent.
/// - `.left/.right/.up/.down` (terminal, on release) → ignored. The
///   highlight already moved the cursor; dispatching again would move
///   it past the intended target.
/// - `.select` → `.select`. A pinch-release-without-drag fires the
///   focused button's action (the registered `onConfirm`).
/// - `.back` (double-pinch) → `.dismiss`. The handler decides — step
///   page → trigger exit overlay; overlay → cancel.
/// - `.cancel` → ignored. (Future: restore cursor to its pre-pinch
///   position when the user drifts then aborts.)
@MainActor
func dispatchPinchDragEvent(
  _ event: PinchDragEvent,
  into coordinator: HUDHoverCoordinator
) {
  switch event {
  case .highlightLeft:  coordinator.dispatch(.directional(.left))
  case .highlightRight: coordinator.dispatch(.directional(.right))
  case .highlightUp:    coordinator.dispatch(.directional(.up))
  case .highlightDown:  coordinator.dispatch(.directional(.down))
  case .select:         coordinator.dispatch(.select)
  case .back:           coordinator.dispatch(.dismiss)
  case .left, .right, .up, .down, .cancel: break
  }
}

// MARK: - View modifier for handler registration

extension View {
  /// Pages and overlays use this to install their `HUDInputHandler` —
  /// pushed onto the coordinator stack on appear, popped on disappear.
  /// The factory closure receives the resolved coordinator so handlers
  /// can capture it at init.
  func hudInputHandler(
    _ make: @escaping (HUDHoverCoordinator) -> HUDInputHandler
  ) -> some View {
    modifier(HUDInputHandlerModifier(make: make))
  }
}

private struct HUDInputHandlerModifier: ViewModifier {
  let make: (HUDHoverCoordinator) -> HUDInputHandler
  @EnvironmentObject private var coordinator: HUDHoverCoordinator
  @State private var pushToken: UUID?

  func body(content: Content) -> some View {
    content
      .onAppear {
        let h = make(coordinator)
        pushToken = coordinator.push(h)
      }
      .onDisappear {
        if let token = pushToken {
          coordinator.pop(token: token)
        }
        pushToken = nil
      }
  }
}

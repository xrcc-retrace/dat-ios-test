import SwiftUI

/// Stable id for every HUD element that participates in the Ray-Ban-style
/// hover → confirm interaction. A tap on an element moves the hover to it;
/// a second tap while hovered fires the confirm closure. Tapping the
/// surrounding scrim clears the hover without firing.
enum HUDControl: Hashable {
  case stepCard
  /// The expanded reference-clip panel on the Coaching step page.
  /// Focusable when reference is expanded; pinch-select / tap toggles
  /// playback (play ↔ pause). No-op when the reference is a still
  /// (non-video) asset.
  case referenceClip
  case exitWorkflow
  case completionSavedWorkflows
  case completionTroubleshoot
  case completionOk
  case insightsTab(InsightCategory)
  case expertStopRecording
  case expertTipCard
  /// "X" cancel button on the Expert stop-recording confirmation
  /// overlay. Default-focused on overlay appear so a stray pinch-select
  /// during the 3-second countdown cancels the stop instead of waiting
  /// for the timer to expire.
  case expertStopCancel
  /// Top-left affordance on the Coaching step page — toggles the in-page
  /// reference clip expansion.
  case toggleReference
  /// Top-right affordance on the Coaching step page — toggles the in-page
  /// insights (tips / warnings / red flags) expansion.
  case toggleInsights
  /// Bottom-left mic mute/unmute capsule on the Coaching step page.
  case toggleMute
  /// Bottom-right Exit capsule on the Coaching step page.
  case exitWorkflowButton
  /// Cancel button on the in-lens "Are you sure you want to exit?" overlay.
  /// Default-focused on the overlay's appearance so an accidental select
  /// gesture cannot trigger exit by itself.
  case exitConfirmCancel
  /// Confirm button on the in-lens "Are you sure you want to exit?" overlay.
  case exitConfirmExit
  /// "That's it" pill on the Troubleshoot identification-confirmation overlay.
  /// Default-focused on appear so a stray select gesture confirms (the safer
  /// option here is the forward path — re-identifying would lose the AI's
  /// guess).
  case confirmIdentification
  /// "Try again" pill on the Troubleshoot identification-confirmation overlay.
  case reIdentify
  /// "Start" pill on the Troubleshoot resolved page — kicks off handoff to
  /// the learner session.
  case startProcedure
  /// "Upload a manual" pill on the Troubleshoot no-solution page — opens the
  /// PDF upload sheet.
  case uploadManual
}

enum HUDInteractionBehavior: Equatable {
  /// Tap moves the cursor to this element AND fires its `onConfirm` in
  /// one action. Default for benign buttons. Touch users expect this —
  /// tap = fire. The focus engine (pinch-drag, swipe) uses a separate
  /// `.select` dispatch path that also fires via the registered confirm
  /// closure on the coordinator. So tap and pinch-select converge on
  /// the same action, just from different modalities.
  case tapToFire

  /// First tap moves the cursor (no fire); a SECOND tap while already
  /// hovered fires `onConfirm`. The destructive-action safety pattern.
  /// Use for elements where an accidental single touch shouldn't
  /// commit anything — e.g. the Expert stop-recording pill, where
  /// even opening the cancel-window overlay is too much for a stray
  /// finger. Pinch users already get parity for free: a pinch-drag
  /// lands the cursor first, then a pinch-select fires — same two-
  /// stage commit.
  case confirmOnSecondTap

  /// Tap only moves the cursor; the action is triggered by an external
  /// gesture (e.g. a `.simultaneousGesture` hold). Reserve for cases
  /// where the action is intrinsically a hold or drag — not for
  /// "destructive button" safety (use `.confirmOnSecondTap` instead).
  case selectOnly
}

/// The single hovered control lives on the coordinator and is injected into
/// the HUD subtree via `.environmentObject`. Only one element can be hovered
/// at a time — selecting another moves the hover; selecting the same one
/// commits.
@MainActor
final class HUDHoverCoordinator: ObservableObject {
  @Published var hovered: HUDControl?

  // MARK: - Tap-driven (existing)

  func tap(_ id: HUDControl, behavior: HUDInteractionBehavior, onConfirm: () -> Void) {
    switch behavior {
    case .tapToFire:
      // Tap = fire. Cursor lands on this element AND its action runs in
      // one motion. Matches normal iOS button expectations and stays
      // consistent with the pinch-drag focus engine (which separates
      // "move cursor" from "select" but converges on the same onConfirm).
      hovered = id
      onConfirm()
    case .confirmOnSecondTap:
      // First tap on an unhovered element: just land the cursor (no
      // fire). Subsequent tap while already hovered: fire. Two-stage
      // safety for destructive actions; mirrors the pinch flow where
      // the user must drag-to-target before the select fires.
      if hovered == id {
        onConfirm()
      } else {
        hovered = id
      }
    case .selectOnly:
      // Tap moves cursor only. External gesture (typically a hold via
      // `.simultaneousGesture`) drives the action.
      hovered = id
    }
  }

  func cancel() {
    hovered = nil
  }

  // MARK: - Focus engine: handler stack
  //
  // Pages and overlays push handlers on appear, pop on disappear. The
  // topmost handler receives every dispatched `HUDInputEvent`. When an
  // overlay pops, the page handler beneath it automatically becomes
  // active again — no manual restoration needed.
  //
  // See `HUDInputEngine.swift` for `HUDInputHandler` + `HUDInputEvent`.

  private var stack: [HUDInputHandler] = []

  func push(_ handler: HUDInputHandler) {
    stack.append(handler)
    if let id = handler.defaultFocus {
      withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
        hovered = id
      }
    }
  }

  func pop(_ handler: HUDInputHandler) {
    stack.removeAll { $0 === handler }
    let next = stack.last?.defaultFocus
    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
      hovered = next
    }
  }

  /// Dispatch an event to the topmost handler. Returns whether a handler
  /// consumed it — callers (notably the emulator's lens double-tap) can
  /// fall back to legacy behavior when no handler claimed the event.
  @discardableResult
  func dispatch(_ event: HUDInputEvent) -> Bool {
    guard let top = stack.last else { return false }
    switch event {
    case .directional(let direction):
      return top.handle(direction: direction)
    case .select:
      return top.handleSelect()
    case .dismiss:
      return top.handleDismiss()
    }
  }

  // MARK: - Confirm registry
  //
  // Every `.hoverSelectable` registers its `onConfirm` here on appear so
  // a non-touch select path (`HUDInputHandler.handleSelect()` →
  // `fireConfirm(for: hovered)`) can activate the focused element
  // without needing a tap to land on it. Touch behavior is unchanged —
  // `.onTapGesture` still drives the existing `tap(_:behavior:onConfirm:)`
  // flow; the registry is purely additive for non-touch paths.

  private var confirms: [HUDControl: () -> Void] = [:]

  func registerConfirm(_ id: HUDControl, _ block: @escaping () -> Void) {
    confirms[id] = block
  }

  func unregisterConfirm(_ id: HUDControl) {
    confirms.removeValue(forKey: id)
  }

  func fireConfirm(for id: HUDControl) {
    confirms[id]?()
  }
}

/// Shape-aware hover overlay + tap handling that implements the
/// hover → confirm pattern. Apply via `.hoverSelectable(_:onConfirm:)`.
struct HoverSelectable: ViewModifier {
  let id: HUDControl
  let shape: HUDSurfaceShape
  let behavior: HUDInteractionBehavior
  let onConfirm: () -> Void
  @EnvironmentObject private var coordinator: HUDHoverCoordinator

  func body(content: Content) -> some View {
    content
      .overlay(HUDHoverHighlight(shape: shape, isVisible: coordinator.hovered == id))
      .contentShape(Rectangle())
      .onTapGesture {
        coordinator.tap(id, behavior: behavior, onConfirm: onConfirm)
      }
      .animation(.easeInOut(duration: 0.15), value: coordinator.hovered)
      // Register the confirm closure with the coordinator so non-touch
      // select paths (focus engine: `HUDInputHandler.handleSelect()` →
      // `coordinator.fireConfirm(for: hovered)`) can activate this
      // element without a tap landing. Touch behavior is unchanged.
      .onAppear {
        coordinator.registerConfirm(id, onConfirm)
      }
      .onDisappear {
        coordinator.unregisterConfirm(id)
      }
  }
}

extension View {
  func hoverSelectable(
    _ id: HUDControl,
    shape: HUDSurfaceShape,
    behavior: HUDInteractionBehavior = .tapToFire,
    onConfirm: @escaping () -> Void
  ) -> some View {
    modifier(HoverSelectable(id: id, shape: shape, behavior: behavior, onConfirm: onConfirm))
  }
}

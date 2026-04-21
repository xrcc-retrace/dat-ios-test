import SwiftUI

/// Stable id for every HUD element that participates in the Ray-Ban-style
/// hover → confirm interaction. A tap on an element moves the hover to it;
/// a second tap while hovered fires the confirm closure. Tapping the
/// surrounding scrim clears the hover without firing.
enum HUDControl: Hashable {
  case stepCard
  case detailCollapse
  case exitWorkflow
  case completionSavedWorkflows
  case completionTroubleshoot
  case completionOk
  case insightsTab(InsightCategory)
  case expertStopRecording
  case expertTipCard
}

enum HUDInteractionBehavior: Equatable {
  case confirmOnSecondTap
  case selectOnly
}

/// The single hovered control lives on the coordinator and is injected into
/// the HUD subtree via `.environmentObject`. Only one element can be hovered
/// at a time — selecting another moves the hover; selecting the same one
/// commits.
@MainActor
final class HUDHoverCoordinator: ObservableObject {
  @Published var hovered: HUDControl?

  func tap(_ id: HUDControl, behavior: HUDInteractionBehavior, onConfirm: () -> Void) {
    if behavior == .confirmOnSecondTap, hovered == id {
      hovered = nil
      onConfirm()
    } else {
      hovered = id
    }
  }

  func cancel() {
    hovered = nil
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
  }
}

extension View {
  func hoverSelectable(
    _ id: HUDControl,
    shape: HUDSurfaceShape,
    behavior: HUDInteractionBehavior = .confirmOnSecondTap,
    onConfirm: @escaping () -> Void
  ) -> some View {
    modifier(HoverSelectable(id: id, shape: shape, behavior: behavior, onConfirm: onConfirm))
  }
}

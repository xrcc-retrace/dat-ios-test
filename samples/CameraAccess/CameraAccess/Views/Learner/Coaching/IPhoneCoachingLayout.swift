import SwiftUI

/// Camera-first container used by Gemini Live sessions on iPhone transport
/// (Learner Coaching + Troubleshoot).
///
/// Z-order (bottom → top):
///   [0] Black fallback — prevents a white flash before the capture
///       session's first frame lands.
///   [1] `IPhoneCameraPreview` — full-bleed live camera feed. Attaches
///       to the existing `AVCaptureSession` owned by `IPhoneCameraCapture`;
///       hardware-composited, runs async from the sample-buffer delivery
///       path, and introduces zero latency on the JPEG → Gemini send
///       pipeline (which still drops late frames via
///       `alwaysDiscardsLateVideoFrames`).
///   [2] Ray-Ban HUD surface — injected per flow (`CoachingRayBanHUD` for
///       learner coaching, `TroubleshootRayBanHUD` for diagnostic). The
///       layout enforces two invariants on whatever the caller passes:
///         • Full-screen bounds (matches the camera's frame exactly).
///         • Transparent container (no background fills applied here).
///       The HUD is hit-testable — interactive controls (step card,
///       exit pill, completion pills) accept taps directly. Because HUD
///       interactive surfaces are small and specifically placed inside
///       a square work-area, the rest of the HUD frame is `Color.clear`
///       and taps pass through to the drawer handle beneath it.
///   [3] `BottomDrawer` — handle-only at rest, pull up to expand to ~90%
///       height. All the mode's existing session UI (activity feed, step
///       instructions, controls, reconnect banner, progress bar) lives
///       inside the drawer body.
struct IPhoneCoachingLayout<HUD: View, Drawer: View>: View {
  @ObservedObject var viewModel: GeminiLiveSessionBase
  @Binding var drawerExpanded: Bool
  let hud: () -> HUD
  let drawer: () -> Drawer
  let showDrawer: Bool

  init(
    viewModel: GeminiLiveSessionBase,
    drawerExpanded: Binding<Bool>,
    showDrawer: Bool = true,
    @ViewBuilder hud: @escaping () -> HUD,
    @ViewBuilder drawer: @escaping () -> Drawer
  ) {
    self.viewModel = viewModel
    self._drawerExpanded = drawerExpanded
    self.showDrawer = showDrawer
    self.hud = hud
    self.drawer = drawer
  }

  var body: some View {
    ZStack {
      // [0] Fallback
      Color.black
        .ignoresSafeArea()

      // [1] Live camera preview
      if let previewLayer = viewModel.iPhonePreviewLayer {
        IPhoneCameraPreview(previewLayer: previewLayer)
          .ignoresSafeArea()
      }

      // [2] Ray-Ban HUD surface — injected per flow. Wrapped here with
      // the full-bleed sizing + safe-area ignoring invariants. Crucially:
      // no `.background(...)` call is ever applied, so the HUD stays fully
      // transparent above the camera. Hit-testing is on; the HUD body
      // itself is responsible for placing `Color.clear` wherever taps
      // should fall through to the drawer handle.
      hud()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()

      // [3] Draggable bottom drawer (portrait only; landscape hides the
      // drawer so the HUD simulates the Ray-Ban lens uninterrupted).
      if showDrawer {
        BottomDrawer(isExpanded: $drawerExpanded) {
          drawer()
        }
      }
    }
  }
}

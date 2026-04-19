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
///       layout enforces three invariants on whatever the caller passes:
///         • Full-screen bounds (matches the camera's frame exactly).
///         • Transparent container (no background fills applied here).
///         • Pass-through hit testing (so drawer drags / future camera
///           taps aren't swallowed). Individual HUD subviews can opt
///           back into hit testing on themselves.
///       Owning the invariants at the layout means the frontend designer
///       editing a HUD file can't accidentally break the camera-first UX.
///   [3] `BottomDrawer` — handle-only at rest, pull up to expand to ~90%
///       height. All the mode's existing session UI (activity feed, step
///       instructions, controls, reconnect banner, progress bar) lives
///       inside the drawer body.
struct IPhoneCoachingLayout<HUD: View, Drawer: View>: View {
  @ObservedObject var viewModel: GeminiLiveSessionBase
  @Binding var drawerExpanded: Bool
  let hud: () -> HUD
  let drawer: () -> Drawer

  init(
    viewModel: GeminiLiveSessionBase,
    drawerExpanded: Binding<Bool>,
    @ViewBuilder hud: @escaping () -> HUD,
    @ViewBuilder drawer: @escaping () -> Drawer
  ) {
    self.viewModel = viewModel
    self._drawerExpanded = drawerExpanded
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
      // the three invariants (full-bleed sizing, safe-area ignoring,
      // hit-test pass-through). Crucially: no `.background(...)` call is
      // ever applied, so the HUD stays fully transparent above the
      // camera.
      hud()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)

      // [3] Draggable bottom drawer
      BottomDrawer(isExpanded: $drawerExpanded) {
        drawer()
      }
    }
  }
}

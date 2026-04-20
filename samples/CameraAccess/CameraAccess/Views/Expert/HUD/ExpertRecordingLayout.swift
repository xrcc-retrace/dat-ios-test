import SwiftUI

/// Camera-first container for the Expert recording screen. Mirrors
/// `IPhoneCoachingLayout` so the Expert HUD has the same Z-stack structure,
/// same transparency + hit-testing rules, and the same "no background ever
/// set on the HUD" invariant. No bottom drawer — the expert's HUD is
/// self-contained in the top + cluster regions.
///
/// Z-order (bottom → top):
///   [0] Black fallback — prevents white flash before the first frame.
///   [1] Live camera preview (injected via `content`).
///   [2] Expert HUD surface (injected via `hud`).
///   [3] Pre-recording chrome (close button, start-recording button) —
///       the caller injects this via `chrome`. During recording, callers
///       should hide chrome they want replaced by the HUD's stop pill.
struct ExpertRecordingLayout<Content: View, HUD: View, Chrome: View>: View {
  @ViewBuilder let content: () -> Content
  @ViewBuilder let hud: () -> HUD
  @ViewBuilder let chrome: () -> Chrome

  var body: some View {
    ZStack {
      // [0] Fallback
      Color.black
        .ignoresSafeArea()

      // [1] Live camera preview
      content()
        .ignoresSafeArea()

      // [2] HUD surface — full-bleed, transparent, hit-test-only-where-needed.
      hud()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()

      // [3] Non-HUD chrome (close, progress spinner, start-recording button).
      chrome()
    }
  }
}

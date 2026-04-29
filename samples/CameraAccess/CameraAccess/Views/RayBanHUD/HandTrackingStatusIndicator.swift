import SwiftUI

/// Tiny ambient indicator that lives next to the audio meter on every
/// mode's lens base UI (Coaching, Troubleshoot via the shared
/// `RayBanHUDBottomAudioActionRow`; Expert via
/// `ExpertNarrationTipPage.statusRow`).
///
/// Three visual states:
/// - **Hand tracking globally disabled** (`@AppStorage("disableHandTracking")`
///   on): renders nothing. The indicator is purely opt-in feedback;
///   when the user has chosen to silence the pipeline entirely, we
///   don't surface a glyph that would suggest otherwise.
/// - **Enabled, pose not gated**: dim glyph (`white @ 0.30`). The
///   pipeline is alive but the recognizer FSM isn't armed — the user's
///   hand isn't visible, isn't large enough, or the palm angle isn't
///   in the canonical edge-on-and-up grasp posture.
/// - **Enabled, pose gated**: bright glyph (`white @ 0.96`). The
///   recognizer's gates are passing for the latest frame; a pinch-
///   drag-release would be recognized.
///
/// Pure status, not a control. Never `.hoverSelectable`, never
/// reachable from the focus engine. No backdrop — sits beside the
/// audio meter without competing for the user's attention.
///
/// Crossfades on the canonical short ease so the brightness change
/// reads as a smooth signal rather than a hard flash. Subscribes to
/// `HandGestureService.shared.objectWillChange` via `@ObservedObject`,
/// so the indicator redraws whenever `latestHandFrame` updates and
/// the computed `isPoseGated` re-evaluates.
struct HandTrackingStatusIndicator: View {
  @ObservedObject private var service = HandGestureService.shared
  @AppStorage("disableHandTracking") private var disableHandTracking: Bool = false

  var body: some View {
    if !disableHandTracking {
      Image(systemName: "hand.raised.fill")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Color.white.opacity(service.isPoseGated ? 0.96 : 0.30))
        .frame(width: 22, height: 22)
        .animation(.easeInOut(duration: 0.18), value: service.isPoseGated)
        .accessibilityHidden(true)
    }
  }
}

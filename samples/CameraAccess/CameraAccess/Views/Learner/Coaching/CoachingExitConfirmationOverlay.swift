import SwiftUI

/// "Are you sure you want to exit?" overlay rendered on top of the lens
/// when the user double-taps to leave the coaching session. Replaces the
/// previous in-lens exit pill + the SwiftUI `.alert` system dialog with
/// a single Ray-Ban-styled card.
///
/// Hosted by `CoachingSessionView` inside the lens emulator's overlay
/// area. Default focus lands on `Cancel` so an accidental select gesture
/// can't trigger exit by itself.
struct CoachingExitConfirmationOverlay: View {
  let onCancel: () -> Void
  let onConfirm: () -> Void

  @EnvironmentObject private var hoverCoordinator: HUDHoverCoordinator

  var body: some View {
    VStack(spacing: 14) {
      Text("Are you sure you want to exit?")
        .font(.inter(.bold, size: 15))
        .foregroundStyle(Color.white.opacity(0.98))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: 8) {
        cancelButton
        confirmButton
      }
    }
    .padding(.horizontal, RayBanHUDLayoutTokens.contentPadding)
    .padding(.vertical, 18)
    .frame(maxWidth: 240)
    // Standard panel surface — the recede recipe on the underlying
    // page (scale 0.92, opacity 0.32, blur 6) is what makes the
    // overlay read as foreground; a heavier panel weight stacks too
    // much contrast against the hover ring on the inner pills.
    .rayBanHUDPanel(shape: .rounded(RayBanHUDLayoutTokens.cardRadius))
    // Focus engine: push the overlay's handler on appear, pop on disappear.
    // The handler's `defaultFocus = .exitConfirmCancel` lands the cursor
    // on Cancel automatically when the overlay opens — replaces the manual
    // `.onAppear { hovered = ... }` we used to hand-roll. On pop, the
    // coordinator restores the underlying step page handler's default
    // focus (.stepCard) so dismissing the overlay leaves the user back
    // where they were.
    .hudInputHandler { coord in
      CoachingExitConfirmHandler(coordinator: coord)
    }
  }

  private var cancelButton: some View {
    HStack(spacing: 6) {
      Image(systemName: "arrow.uturn.backward")
        .font(.system(size: 12, weight: .semibold))
      Text("Cancel")
        .font(.inter(.medium, size: 13))
    }
    .foregroundStyle(Color.black.opacity(0.92))
    .frame(maxWidth: .infinity)
    .padding(.vertical, 9)
    .background(Capsule().fill(Color.white.opacity(0.95)))
    .rayBanHUDPanel(shape: .capsule)
    .hoverSelectable(.exitConfirmCancel, shape: .capsule, onConfirm: onCancel)
  }

  private var confirmButton: some View {
    HStack(spacing: 6) {
      Image(systemName: "rectangle.portrait.and.arrow.forward")
        .font(.system(size: 12, weight: .semibold))
      Text("Confirm exit")
        .font(.inter(.medium, size: 13))
    }
    .foregroundStyle(Color.white.opacity(0.96))
    .frame(maxWidth: .infinity)
    .padding(.vertical, 9)
    .background(
      Capsule().fill(Color(red: 0.96, green: 0.26, blue: 0.21).opacity(0.32))
    )
    .rayBanHUDPanel(shape: .capsule)
    .hoverSelectable(.exitConfirmExit, shape: .capsule, onConfirm: onConfirm)
  }
}

import SwiftUI

/// Staged celebration overlay for a successfully-completed coaching step.
///
/// Plays inside the lens HUD when a forward `advance_step` advances the
/// learner. Driven by a single `Bool` from the view model — the overlay
/// manages its own staged opacity/scale animations so the durations stay
/// declarative and don't depend on Timer / @State polling.
///
/// Sequence (matches the plan):
///   - 0.00 → 0.20s : green fill fades in (opacity 0 → 0.35)
///   - 0.20 → 0.40s : checkmark + "Step completed" arrive (fade + scale)
///   - 0.40 → 0.70s : hold (overlay stays at full intensity)
///   - the 0.30s slide afterwards is owned by the parent's `.transition`
///
/// The view model keeps `celebratingStepIndex == fromIndex` for the full
/// timeline window so the OLD card carries the overlay off-screen during
/// the slide; once the slide completes, `celebratingStepIndex` clears and
/// the overlay reverses (briefly) on whatever card view is still mounted.
/// In practice the OLD card is gone by then so the reversal is invisible.
struct StepCompletionOverlay: View {
  let isCelebrating: Bool

  var body: some View {
    // The shape's `.fill` accepts whatever size it's proposed and never
    // contributes an intrinsic size of its own — perfect for a passive
    // overlay. The checkmark + label are layered with `.overlay(...)`
    // so they CANNOT propose a size to the host card. Earlier versions
    // used a ZStack with the VStack as a sibling, which (under certain
    // SwiftUI renders) caused a one-frame layout pass on the host that
    // briefly enlarged the step card before settling.
    RoundedRectangle(
      cornerRadius: RayBanHUDLayoutTokens.cardRadius,
      style: .continuous
    )
    .fill(Color.green.opacity(isCelebrating ? 0.35 : 0))
    // Phase 1 — green tint comes first. easeInOut keeps the leading edge
    // soft so it doesn't read as a flashbulb pop.
    .animation(.easeInOut(duration: 0.20), value: isCelebrating)
    .overlay(
      VStack(spacing: 8) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 38, weight: .semibold))
          .foregroundStyle(Color.white)
        Text("Step completed")
          .font(.inter(.bold, size: 14))
          .tracking(0.6)
          .foregroundStyle(Color.white)
      }
      .opacity(isCelebrating ? 1 : 0)
      .scaleEffect(isCelebrating ? 1.0 : 0.88)
      // Phase 2 — checkmark + label arrive on the standard HUD spring,
      // delayed 0.20s so the green has fully faded in first. Same spring
      // token as every other HUD enter/exit so the new pattern matches
      // the rest of the design language.
      .animation(
        .spring(response: 0.32, dampingFraction: 0.85).delay(0.20),
        value: isCelebrating
      )
    )
    .allowsHitTesting(false)
  }
}

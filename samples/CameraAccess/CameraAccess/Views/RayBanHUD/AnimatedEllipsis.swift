import SwiftUI

/// Three-dot animated ellipsis. Cascading opacity wave driven by
/// `TimelineView(.animation)` reading real elapsed time off the OS
/// animation timeline — same canonical pattern as `RetraceAudioMeter`.
/// Per `Views/RayBanHUD/DESIGN.md` → "Continuous animations: never
/// poll", and an upgrade from the previous `withAnimation(.linear(…)
/// .repeatForever)` driver, which sometimes wedged inside the lens
/// emulator's compositing-group / additive-blend context and on
/// `.id(...)`-driven view replacements (e.g. the search-narration
/// transitions in `TroubleshootSearchStatusView`). The TimelineView
/// path ticks regardless of containing animation context, so the
/// ellipsis stays alive across compositing modes and id swaps.
///
/// Drop-in "thinking / in flight" indicator for any HUD surface.
struct AnimatedEllipsis: View {
  var size: CGFloat = 6
  var spacing: CGFloat = 4
  var color: Color = .white.opacity(0.85)

  /// One full traversal of the cascading wave across the three dots.
  private let cycleDuration: TimeInterval = 1.2

  var body: some View {
    TimelineView(.animation) { context in
      // Phase ∈ [0, 1) computed from wall-clock time so the wave is
      // always advancing, regardless of SwiftUI animation context or
      // .id-triggered view replacements.
      let elapsed = context.date.timeIntervalSinceReferenceDate
      let phase = (elapsed / cycleDuration).truncatingRemainder(dividingBy: 1.0)

      HStack(spacing: spacing) {
        ForEach(0..<3, id: \.self) { i in
          Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(opacity(forIndex: i, phase: phase))
        }
      }
    }
  }

  private func opacity(forIndex index: Int, phase: Double) -> Double {
    let offset = Double(index) / 3.0
    let local = (phase + offset).truncatingRemainder(dividingBy: 1.0)
    let wave = abs(local - 0.5) * 2
    return 0.25 + (1.0 - wave) * 0.75
  }
}

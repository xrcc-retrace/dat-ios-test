import SwiftUI

/// Four-quadrant cross shown in the Ray-Ban HUD above the gesture event
/// log. While the user is pinching and has drifted out of the center
/// dead zone, the box matching the current thumb quadrant lights up so
/// the user can see exactly which button would commit if they released
/// right now.
///
/// Layout is a classic D-pad plus: UP on top, DOWN on bottom,
/// LEFT / RIGHT flanking a CENTER spacer box. The center is visually
/// inert (no gesture fires from the center directly; a release there is
/// either `.select` or `.cancel` depending on whether the user ever
/// left the dead zone — that state surfaces via the overlay chip and
/// the event log, not this cross).
///
/// Shared across all three HUDs (Expert / Coaching / Troubleshoot) by
/// `HandGestureDebugStack`. Do not mount this directly.
struct PinchDragCrossUI: View {
  /// Quadrant the recognizer reports the thumb is currently occupying,
  /// or nil when idle / in the center dead zone.
  let currentHighlightQuadrant: PinchDragQuadrant?

  /// Outer footprint. Tuned so UP/DOWN/LEFT/RIGHT each read at a glance
  /// without dominating the HUD. Same width as `MicroGestureDebugLog`
  /// (220 pt) so the stack column is visually aligned.
  private let size: CGFloat = 120
  private let boxSize: CGFloat = 38
  private let spacing: CGFloat = 4

  var body: some View {
    ZStack {
      // Center box — visually present so the cross reads as a unified
      // shape, but never highlighted.
      quadrantBox(direction: nil, label: "·", isCenter: true)
        .position(x: size / 2, y: size / 2)

      quadrantBox(direction: .up, label: "▲")
        .position(x: size / 2, y: size / 2 - (boxSize + spacing))

      quadrantBox(direction: .down, label: "▼")
        .position(x: size / 2, y: size / 2 + (boxSize + spacing))

      quadrantBox(direction: .left, label: "◀")
        .position(x: size / 2 - (boxSize + spacing), y: size / 2)

      quadrantBox(direction: .right, label: "▶")
        .position(x: size / 2 + (boxSize + spacing), y: size / 2)
    }
    .frame(width: size, height: size)
    .allowsHitTesting(false)
  }

  private func quadrantBox(
    direction: PinchDragQuadrant?,
    label: String,
    isCenter: Bool = false
  ) -> some View {
    let isLit = !isCenter && direction != nil && direction == currentHighlightQuadrant
    return ZStack {
      RoundedRectangle(cornerRadius: 6)
        .fill(
          isLit
            ? Color.green.opacity(0.7)
            : Color.black.opacity(isCenter ? 0.35 : 0.45)
        )
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(
          isLit ? Color.green : Color.white.opacity(isCenter ? 0.12 : 0.22),
          lineWidth: isLit ? 1.5 : 0.75
        )
      Text(label)
        .font(.system(size: isCenter ? 10 : 14, weight: .bold, design: .monospaced))
        .foregroundStyle(
          isLit
            ? Color.white
            : Color.white.opacity(isCenter ? 0.35 : 0.75)
        )
    }
    .frame(width: boxSize, height: boxSize)
  }
}

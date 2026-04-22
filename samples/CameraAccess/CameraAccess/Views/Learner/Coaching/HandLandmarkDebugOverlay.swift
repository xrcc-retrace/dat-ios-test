import SwiftUI

/// Temporary debug overlay that visualizes `PinchDragRecognizer`'s state.
///
/// Shows two landmarks — `thumbTip`, `indexTip` — plus a live distance
/// line connecting them. The line flips green when the pinch-contact
/// gate passes (2D distance under `indexContactThreshold`); red / thin
/// otherwise.
///
/// Persistent START / END markers show where the thumb was at the most
/// recent pinch begin / release, with a dashed line between them so the
/// user can see the classifier's drag trajectory.
///
/// Coordinate mapping is linear over the overlay's bounds — there's no
/// aspect-fill correction for the camera preview beneath, so dots may
/// sit slightly offset from the physical hand. Relative geometry (which
/// direction the drag went, whether the pinch fired) is preserved, which
/// is what matters for debugging.
///
/// Remove once gesture → action wiring lands.
struct HandLandmarkDebugOverlay: View {
  let frame: HandLandmarkFrame?
  let indexContactThreshold: Float
  /// Orientation start-gate bounds. The overlay uses these to render a
  /// POSE OK / POSE OFF chip — matches the gate the recognizer itself
  /// applies at IDLE → pinching transitions. Both palm-facing-Z AND
  /// hand-size conditions must pass.
  let gatePalmFacingZMin: Float
  let gatePalmFacingZMax: Float
  let gateHandSizeMin: Float
  /// True while the recognizer is holding a deferred `.select` waiting
  /// for a possible second tap. Renders a TAP 1/2 chip so users can see
  /// the double-tap window is open.
  let pendingSelectActive: Bool
  let contactStartNormalized: CGPoint?
  let contactEndNormalized: CGPoint?

  var body: some View {
    GeometryReader { geo in
      let size = geo.size
      ZStack {
        if let frame = frame,
           let thumbTip = frame.thumbTip,
           let indexTip = frame.indexTip {

          let thumbPt = point(x: thumbTip.x, y: thumbTip.y, in: size)
          let indexPt = point(x: indexTip.x, y: indexTip.y, in: size)

          // Pinch detection is 2D only — z is too noisy from MediaPipe
          // to be useful, so we skip computing it entirely.
          let indexDist2D = distance2D(thumbTip, indexTip)
          let indexPinched = indexDist2D < indexContactThreshold

          // Thumb ↔ indexTip line.
          Path { path in
            path.move(to: thumbPt)
            path.addLine(to: indexPt)
          }
          .stroke(
            indexPinched ? Color.green : Color.red.opacity(0.4),
            style: StrokeStyle(lineWidth: indexPinched ? 3 : 1.5, lineCap: .round)
          )

          // Persistent contact-start marker (yellow).
          if let startN = contactStartNormalized {
            let s = point(x: Float(startN.x), y: Float(startN.y), in: size)
            persistentMarker(at: s, color: .yellow, label: "START")
          }

          // Persistent contact-end marker (purple).
          if let endN = contactEndNormalized {
            let e = point(x: Float(endN.x), y: Float(endN.y), in: size)
            persistentMarker(at: e, color: .purple, label: "END")
          }

          // Trajectory line if both markers exist.
          if let startN = contactStartNormalized,
             let endN = contactEndNormalized {
            let s = point(x: Float(startN.x), y: Float(startN.y), in: size)
            let e = point(x: Float(endN.x), y: Float(endN.y), in: size)
            Path { path in
              path.move(to: s)
              path.addLine(to: e)
            }
            .stroke(Color.white.opacity(0.7),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
          }

          // Landmark dots + labels.
          landmarkDot(at: indexPt, color: .cyan, label: "INDEX")
          liveThumbDot(at: thumbPt, pinched: indexPinched)
            .shadow(
              color: indexPinched ? .green.opacity(0.8) : .red.opacity(0.8),
              radius: 6
            )

          // Status badge — pinch engagement + pose gate + optional TAP 1/2.
          let activeLabel: String = indexPinched ? "INDEX PINCH" : "IDLE"
          let activeColor: Color = indexPinched ? .green : .gray

          // Orientation gate evaluation — mirrors the check inside
          // PinchDragRecognizer. Used for the POSE OK / POSE OFF chip.
          // Both palm-facing-Z AND hand-size conditions must pass.
          let poseOK: Bool = {
            guard let orient = frame.orientation else { return false }
            return orient.palmFacingZ >= gatePalmFacingZMin
              && orient.palmFacingZ <= gatePalmFacingZMax
              && orient.handSize >= gateHandSizeMin
          }()

          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
              // Pinch engagement chip.
              HStack(spacing: 6) {
                Circle().fill(activeColor).frame(width: 10, height: 10)
                Text(activeLabel)
                  .font(.system(size: 12, weight: .bold, design: .monospaced))
                  .foregroundStyle(.white)
              }
              // Pose-gate chip — same visual style, separate pill so the
              // two signals read independently. Green = gate passing,
              // gray = blocking IDLE → pinching transitions.
              HStack(spacing: 6) {
                Circle()
                  .fill(poseOK ? Color.green : Color.gray)
                  .frame(width: 10, height: 10)
                Text(poseOK ? "POSE OK" : "POSE OFF")
                  .font(.system(size: 12, weight: .bold, design: .monospaced))
                  .foregroundStyle(.white)
              }
              // Double-tap window chip — only visible while a deferred
              // `.select` is still waiting.
              if pendingSelectActive {
                HStack(spacing: 6) {
                  Circle()
                    .fill(Color.orange)
                    .frame(width: 10, height: 10)
                  Text("TAP 1/2")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                }
              }
            }
            HStack(spacing: 10) {
              HStack(spacing: 4) {
                Circle()
                  .fill(indexDist2D < indexContactThreshold ? Color.green : Color.red)
                  .frame(width: 5, height: 5)
                Text(String(format: "IDX %.2f", indexDist2D))
                  .font(.system(size: 9, design: .monospaced))
                  .foregroundStyle(.white.opacity(0.85))
              }
            }
            Text(String(format: "th IDX<%.2f", indexContactThreshold))
              .font(.system(size: 8, design: .monospaced))
              .foregroundStyle(.white.opacity(0.5))
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
          .padding(12)
        } else {
          Text("no hand")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.4))
            .padding(8)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(12)
        }
      }
    }
    .allowsHitTesting(false)
  }

  // MARK: - Dots

  private func landmarkDot(at pt: CGPoint, color: Color, label: String) -> some View {
    ZStack {
      Circle()
        .fill(color)
        .frame(width: 10, height: 10)
      Circle()
        .stroke(Color.white, lineWidth: 1)
        .frame(width: 10, height: 10)
      Text(label)
        .font(.system(size: 9, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
        .offset(x: 0, y: -14)
    }
    .position(pt)
  }

  private func persistentMarker(at pt: CGPoint, color: Color, label: String) -> some View {
    ZStack {
      Circle()
        .stroke(color, lineWidth: 2)
        .frame(width: 14, height: 14)
      Circle()
        .fill(color.opacity(0.35))
        .frame(width: 14, height: 14)
      Text(label)
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundStyle(color)
        .offset(x: 0, y: 14)
    }
    .position(pt)
  }

  private func liveThumbDot(at pt: CGPoint, pinched: Bool) -> some View {
    let color = pinched ? Color.green : Color.red
    return ZStack {
      Circle()
        .fill(color.opacity(0.85))
        .frame(width: 16, height: 16)
      Circle()
        .stroke(Color.white, lineWidth: 1.5)
        .frame(width: 16, height: 16)
      Text("THUMB")
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundStyle(.white)
        .offset(x: 0, y: -18)
    }
    .position(pt)
  }

  // MARK: - Math

  private func distance2D(_ a: HandLandmark2D, _ b: HandLandmark2D) -> Float {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return (dx * dx + dy * dy).squareRoot()
  }

  private func point(x: Float, y: Float, in size: CGSize) -> CGPoint {
    CGPoint(x: CGFloat(x) * size.width, y: CGFloat(y) * size.height)
  }
}

import CoreGraphics
import Foundation

/// A single MediaPipe hand landmark. Coordinates are normalized: x/y in
/// [0.0, 1.0] relative to the input image (origin top-left, y-down), z in
/// image-space units with the wrist as the origin (negative = closer to the
/// camera). Kept as `Float` to match MediaPipe's native precision.
struct HandLandmark2D: Equatable {
  var x: Float
  var y: Float
  var z: Float
}

/// Compact description of the hand's orientation in the image. Used as
/// a start-gate on `PinchDragRecognizer` so the recognizer only enters
/// TRACKING when the hand is held in the specific posture the user
/// intends for gesture input (vs. e.g. resting at the side or performing
/// unrelated task motion).
///
/// Three signals:
///   - pointing direction in the image (2D palmAngle),
///   - roll about the hand's long axis (palmFacingZ),
///   - apparent size in the image (handSize).
struct HandOrientation: Equatable {
  /// 2D angle of `wrist → middleMCP` in the image, in degrees. Image
  /// coords are y-down so:
  ///   0°     → palm pointing right in image
  ///   −90°   → palm pointing up
  ///   ±180°  → palm pointing left
  ///   90°    → palm pointing down
  let palmAngleDegrees: Float

  /// Z-component of the normalized 3D palm normal (cross of
  /// `wrist→indexMCP` × `wrist→pinkyMCP`, then normalized). Range
  /// [−1, +1]. Captures rotation about the hand's long axis (roll):
  ///
  ///   −1.0 → palm directly faces the camera (palmar surface visible)
  ///    0.0 → palm edge-on to the camera (Meta XR-style grasp pose —
  ///          thumb side visible, palm pointing sideways)
  ///   +1.0 → back of hand directly faces the camera (knuckles visible)
  ///
  /// Uses MediaPipe z (smaller = closer to camera), so the sign is
  /// consistent regardless of handedness: `-1` always means palm-toward-
  /// camera for both hands. Combine with `HandLandmarkFrame.handedness`
  /// to disambiguate thumb-up-vs-thumb-down if needed.
  let palmFacingZ: Float

  /// `|wrist → middleMCP|` in normalized image units. Proxy for apparent
  /// hand size — close to camera = large, far = small. Useful to reject
  /// frames where the hand is too small to resolve thumb tips reliably.
  let handSize: Float
}

/// Measurement bundle describing the thumb's spatial relationship to the
/// index finger's proximal phalanx (segment indexMCP ↔ indexPIP).
///
/// `distance2D` is the shortest 2D distance from the thumb tip to the
/// segment in image coords (x,y). `zDelta` is the absolute difference
/// between the thumb's z and the segment's interpolated z at the
/// 2D-closest point — a "are they at the same depth" signal. `closestT`
/// is the segment parameter (0 at MCP, 1 at PIP) locating the point the
/// thumb is hovering above.
///
/// Used by `MicroGestureRecognizer` to gate contact on BOTH axes.
struct ThumbSegmentContactMeasurement: Equatable {
  let distance2D: Float
  let zDelta: Float
  let closestT: Float
}

/// A point-in-time snapshot of one detected hand. Produced by
/// `HandLandmarkerService`; consumed by `PinchGestureRecognizer` and anyone
/// else that wants hand geometry without pulling MediaPipe into their module.
///
/// `landmarks` uses MediaPipe's 21-joint index convention:
///   0: wrist
///   1-4: thumb (CMC, MCP, IP, tip)
///   5-8: index (MCP, PIP, DIP, tip)
///   9-12: middle
///   13-16: ring
///   17-20: little
///
/// An empty `landmarks` array indicates "no hand in this frame". Consumers
/// should treat that as a pinch-exit signal rather than a hold.
struct HandLandmarkFrame: Equatable {
  var landmarks: [HandLandmark2D]
  var handedness: String?        // "Left" | "Right" | nil
  var timestampMs: Int

  static let empty = HandLandmarkFrame(landmarks: [], handedness: nil, timestampMs: 0)

  var isEmpty: Bool { landmarks.isEmpty }

  /// Thumb tip (index 4). Nil when no hand was detected.
  var thumbTip: HandLandmark2D? {
    landmarks.count > 4 ? landmarks[4] : nil
  }

  /// Index fingertip (index 8). Nil when no hand was detected.
  var indexTip: HandLandmark2D? {
    landmarks.count > 8 ? landmarks[8] : nil
  }

  /// Middle fingertip (index 12). Used by `PinchDragRecognizer` as the
  /// second pinch target (thumb + middle fingertip = `.back`).
  var middleTip: HandLandmark2D? {
    landmarks.count > 12 ? landmarks[12] : nil
  }

  /// Index MCP — the knuckle at the base of the index finger (joint 5).
  /// The proximal anchor of the `indexMCP → indexPIP` segment used by
  /// `MicroGestureRecognizer` for thumb-contact detection + Axis A.
  var indexMCP: HandLandmark2D? {
    landmarks.count > 5 ? landmarks[5] : nil
  }

  /// Index PIP — the middle joint of the index finger (joint 6).
  /// The distal anchor of the proximal-phalanx segment on which the thumb
  /// rests for Meta XR micro gestures.
  var indexPIP: HandLandmark2D? {
    landmarks.count > 6 ? landmarks[6] : nil
  }

  /// Shortest 2D distance from `thumbTip` to the line segment
  /// `indexMCP ↔ indexPIP`. Convenience passthrough to
  /// `thumbProximalSegmentContact`; prefer that property when you also
  /// need the z delta.
  var thumbToIndexProximalSegmentDistance: Float? {
    thumbProximalSegmentContact?.distance2D
  }

  /// Snapshot of the hand's 2D orientation and apparent size — the
  /// inputs `PinchDragRecognizer` uses as its start-gate when deciding
  /// whether to arm a pinch. Nil if any of wrist / indexMCP /
  /// middleMCP (9) / pinkyMCP (17) are missing from the frame.
  var orientation: HandOrientation? {
    guard landmarks.count > 17 else { return nil }
    let w = landmarks[0]         // wrist
    let imc = landmarks[5]       // indexMCP
    let mmc = landmarks[9]       // middleMCP
    let pmc = landmarks[17]      // pinkyMCP

    // Palm direction vector in image plane: wrist → middleMCP.
    let dx = mmc.x - w.x
    let dy = mmc.y - w.y
    let size = (dx * dx + dy * dy).squareRoot()
    guard size > 0.001 else { return nil }
    let angleDegrees = atan2(dy, dx) * 180.0 / Float.pi

    // Full 3D palm normal = (wrist→indexMCP) × (wrist→pinkyMCP), using
    // x, y, AND z components. Normalize to unit length so the z
    // component is the cosine of the angle between palm normal and the
    // camera-forward axis — a clean roll signal in [-1, +1].
    let v1x = imc.x - w.x
    let v1y = imc.y - w.y
    let v1z = imc.z - w.z
    let v2x = pmc.x - w.x
    let v2y = pmc.y - w.y
    let v2z = pmc.z - w.z
    let nx = v1y * v2z - v1z * v2y
    let ny = v1z * v2x - v1x * v2z
    let nz = v1x * v2y - v1y * v2x
    let nmag = (nx * nx + ny * ny + nz * nz).squareRoot()
    let palmFacingZ: Float = nmag > 1e-6 ? nz / nmag : 0

    return HandOrientation(
      palmAngleDegrees: angleDegrees,
      palmFacingZ: palmFacingZ,
      handSize: size
    )
  }

  /// Full contact measurement for the thumb-on-proximal-phalanx check —
  /// both the 2D image-plane distance and the z-axis delta between the
  /// thumb and the interpolated point on the segment. The recognizer
  /// requires BOTH axes to be below their respective thresholds before
  /// declaring contact; releasing either pulls us out of contact.
  ///
  /// `closestT` is the segment parameter at the 2D-closest point
  /// (0 = indexMCP, 1 = indexPIP). Exposed so the debug overlay can
  /// visualize where on the finger the thumb is hovering.
  ///
  /// Returns nil when any of thumbTip / indexMCP / indexPIP is missing
  /// from the frame.
  var thumbProximalSegmentContact: ThumbSegmentContactMeasurement? {
    guard let t = thumbTip, let a = indexMCP, let b = indexPIP else { return nil }
    let abx = b.x - a.x
    let aby = b.y - a.y
    let lenSq = abx * abx + aby * aby

    if lenSq < 1e-8 {
      // Degenerate segment (a ≈ b). Fall back to point distance to a.
      let dx = t.x - a.x
      let dy = t.y - a.y
      let dz = t.z - a.z
      return ThumbSegmentContactMeasurement(
        distance2D: (dx * dx + dy * dy).squareRoot(),
        zDelta: abs(dz),
        closestT: 0
      )
    }

    let apx = t.x - a.x
    let apy = t.y - a.y
    let tRaw = (apx * abx + apy * aby) / lenSq
    let tClamped = max(0, min(1, tRaw))

    // Closest 2D point on segment.
    let cx = a.x + tClamped * abx
    let cy = a.y + tClamped * aby
    // Interpolate z at the same segment parameter — gives us "what depth
    // does the finger have here?" for comparison with the thumb's depth.
    let cz = a.z + tClamped * (b.z - a.z)

    let dx = t.x - cx
    let dy = t.y - cy
    let dz = t.z - cz
    return ThumbSegmentContactMeasurement(
      distance2D: (dx * dx + dy * dy).squareRoot(),
      zDelta: abs(dz),
      closestT: tClamped
    )
  }

  /// Mean of all 21 joints, in normalized image coordinates. Use as the
  /// "hand position" for drag-direction classification — more stable than a
  /// single joint because it averages out per-finger jitter.
  var centroid: CGPoint? {
    guard !landmarks.isEmpty else { return nil }
    var sx: Float = 0
    var sy: Float = 0
    for p in landmarks {
      sx += p.x
      sy += p.y
    }
    let n = Float(landmarks.count)
    return CGPoint(x: CGFloat(sx / n), y: CGFloat(sy / n))
  }

  /// Normalized 2D distance between thumb tip and index tip. Returns `.infinity`
  /// if either joint is missing — that way a missing hand never looks like a
  /// pinch.
  var thumbIndexDistance: Float {
    guard let t = thumbTip, let i = indexTip else { return .infinity }
    let dx = t.x - i.x
    let dy = t.y - i.y
    return (dx * dx + dy * dy).squareRoot()
  }
}

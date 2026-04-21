import CoreGraphics
import Foundation

/// Discrete events emitted by `PinchDragRecognizer`. Six cases covering
/// quick pinch (select), four directional drags, and a back gesture.
enum PinchDragEvent: Equatable {
  case select   // quick thumb+index pinch, released with minimal drag
  case left     // thumb+index pinch, dragged left in image, released
  case right    // ... drag right
  case up       // ... drag up (image y-down convention → negative Δy)
  case down     // ... drag down (positive Δy)
  case back     // quick thumb+middle pinch, released briefly
}

/// One entry in the recent-gesture log. Each emit carries a fresh UUID so
/// rapid consecutive identical events still animate in the debug log.
struct PinchDragLogEntry: Equatable, Identifiable {
  let id: UUID
  let event: PinchDragEvent
  let firedAt: Date

  init(event: PinchDragEvent, firedAt: Date = Date(), id: UUID = UUID()) {
    self.id = id
    self.event = event
    self.firedAt = firedAt
  }
}

/// State machine that converts a `HandLandmarkFrame` stream into discrete
/// `PinchDragEvent` values using a pinch-drag-release model:
///
///   IDLE → (thumb+index pinch detected) → INDEX_PINCHING → (release)
///     → classify delta in image plane:
///       - |delta| < selectRadius → .select
///       - else 4-quadrant by |Δx| vs |Δy|, sign gives L/R/U/D
///
///   IDLE → (thumb+middle pinch detected) → MIDDLE_PINCHING → (release)
///     → .back (only if duration ≤ tapMaxDurationMs; otherwise drop)
///
/// Contact detection uses 3D Euclidean distance (x, y, z) so that thumb
/// and fingertip passing in front of each other without touching doesn't
/// false-positive. Per-target hysteresis thresholds on both 2D and z.
///
/// Pure value type. No MediaPipe / AVFoundation / SwiftUI imports. Drive
/// from any queue. Injectable clock for deterministic tests.
struct PinchDragRecognizer {
  struct Config {
    // Pinch detection is 2D-only. MediaPipe's z estimate for fingertips
    // is too noisy to use as a contact gate without false negatives
    // (esp. middle, where the finger extends past a curled index and
    // depth diverges). Orientation still gates on `palmFacingZ` — that
    // signal comes from wrist/MCP landmarks which are more stable.

    // Index pinch — select + 4 directional drags.
    // 0.04 ≈ 29 px on a 720-wide frame. Release at 0.05 gives a small
    // hysteresis gap (0.01 ≈ 7 px) that's still above the ~0.002 jitter
    // floor, so pinches don't flicker but release feels responsive.
    var indexContactThreshold: Float = 0.04
    var indexReleaseThreshold: Float = 0.05

    // Middle pinch — back. 2D thresholds identical to index; the winner
    // between index and middle is picked by whichever finger pair is
    // physically closer at the moment of contact.
    var middleContactThreshold: Float = 0.04
    var middleReleaseThreshold: Float = 0.05

    /// On index-pinch release, if |drag| is below this, emit `.select`
    /// instead of a directional event. Normalized image units (0.05 ≈
    /// 36 px on a 720-wide frame, roughly 4 mm of thumb travel at arm's
    /// length — larger than typical camera shake / hand tremor, smaller
    /// than a deliberate swipe).
    ///
    /// Higher → more tolerance for accidental drift during a quick pinch;
    /// small thumb wobble while releasing still emits `.select`.
    /// Lower → strict select; any drift gets classified as a direction.
    var selectRadius: Float = 0.05

    /// On middle-pinch release, drag magnitude must be at or below this
    /// to emit `.back`. Same units as `selectRadius`. Beyond this the
    /// release is treated as unintentional (the user didn't mean a crisp
    /// back tap) and silently dropped. Mirrors `selectRadius` so both
    /// tap-style gestures share the same drift tolerance.
    var backDragTolerance: Float = 0.05

    /// On middle-pinch release, emit `.back` only if the pinch duration
    /// was at or below this. Longer contacts are treated as accidental
    /// grabs and silently dropped.
    var tapMaxDurationMs: Int = 400

    /// Post-emit lockout — suppresses event storms during physical
    /// settle-time between gestures. Lowered from 350 ms so rapid
    /// intentional double-swipes (e.g. two fast rights to jump two
    /// cards) both fire.
    var postEmitCooldownMs: Int = 250

    // MARK: - Orientation start-gate
    //
    // The recognizer only enters a pinch state when the hand is in a
    // deliberate "ready pose" — this rejects accidental pinches that
    // happen while the user is doing unrelated hands-on work. The gate
    // applies ONLY at IDLE → pinching transitions; once tracking is
    // active, the hand can rotate / resize freely without losing the
    // gesture.
    //
    // Gate is an AND of two conditions: the palm must be roughly
    // edge-on to the camera (Meta XR-style grasp pose, thumb side
    // visible) AND the hand must be close enough to produce reliable
    // landmarks.

    /// Minimum `HandOrientation.palmFacingZ` for gate pass. `palmFacingZ`
    /// is the z-component of the unit palm normal, in [-1, +1]:
    ///   -1 → palm toward camera, 0 → edge-on, +1 → back toward camera.
    /// Default range [-0.5, +0.5] accepts the ~edge-on poses while
    /// rejecting palm-fully-facing and back-fully-facing.
    var gatePalmFacingZMin: Float = -0.5

    /// Upper bound on `HandOrientation.palmFacingZ` for gate pass.
    var gatePalmFacingZMax: Float = 0.5

    /// Minimum `HandOrientation.handSize` for gate pass — rejects frames
    /// where MediaPipe has lost the hand (common when it shrinks to the
    /// edge of frame, often accompanied by a handedness misflip).
    var gateHandSizeMin: Float = 0.10

    /// Test / debug escape hatch. When true, the IDLE case skips the
    /// gate entirely and any frame with a close-enough pinch qualifies.
    var gateDisabled: Bool = false

    /// Missing-frame tolerance during tracking. Brief (≤ this many)
    /// frames with no hand are absorbed; longer drops reset to IDLE.
    var maxMissingFramesDuringPinching: Int = 4

    /// Abandoned-hold timeout — a pinch held longer than this is
    /// discarded without emit.
    var maxPinchDurationMs: Int = 4000
  }

  /// Read-only snapshot for debug overlays.
  struct DebugSnapshot: Equatable {
    enum FSM: Equatable { case idle, indexPinching, middlePinching }
    let fsm: FSM
    let inCooldown: Bool
    let trackingDurationMs: Int
    let latestIndexDistance: Float?
    let latestMiddleDistance: Float?
  }

  // MARK: - State

  private enum FSMState {
    case idle
    case indexPinching(TrackingContext)
    case middlePinching(TrackingContext)
  }

  private struct TrackingContext {
    let startTimestampMs: Int
    let startThumbPosition: CGPoint
    var latestThumbPosition: CGPoint
    var latestTimestampMs: Int
    var missingFrameRun: Int
    var latestContactDistance2D: Float
  }

  private struct PinchMeasurement {
    let distance2D: Float
  }

  private let config: Config
  private let now: () -> Date
  private var state: FSMState = .idle
  private var lastEmitAt: Date?

  /// Thumb position recorded on the most recent IDLE → *Pinching
  /// transition. Persists across IDLE so the debug overlay can show
  /// "here's where the pinch started."
  private(set) var lastContactStartPosition: CGPoint?

  /// Thumb position recorded on the most recent *Pinching → IDLE
  /// transition (release, abort, or timeout). Persists until the next
  /// contact begins.
  private(set) var lastContactReleasePosition: CGPoint?

  // MARK: - Init

  init(config: Config = .init(), now: @escaping () -> Date = Date.init) {
    self.config = config
    self.now = now
  }

  // MARK: - Public API

  /// Consume one frame. Returns a non-nil event when the FSM fires on
  /// release; nil for every intermediate frame and for cooldown-suppressed
  /// emits.
  mutating func ingest(_ frame: HandLandmarkFrame) -> PinchDragEvent? {
    // Global post-emit cooldown — all state transitions frozen.
    if let lastEmitAt {
      let elapsedMs = Int(now().timeIntervalSince(lastEmitAt) * 1000)
      if elapsedMs < config.postEmitCooldownMs {
        return nil
      }
    }

    let indexM = pinchMeasurement(frame: frame, finger: .index)
    let middleM = pinchMeasurement(frame: frame, finger: .middle)

    switch state {
    case .idle:
      // Orientation start-gate. Only applied at IDLE → pinching; once
      // tracking is active, rotation doesn't matter per design spec.
      // AND of two conditions: palm edge-on AND hand big enough.
      if !config.gateDisabled {
        guard let orient = frame.orientation else { return nil }
        if orient.palmFacingZ < config.gatePalmFacingZMin ||
           orient.palmFacingZ > config.gatePalmFacingZMax ||
           orient.handSize < config.gateHandSizeMin {
          return nil
        }
      }

      // Pick the closer of the two pinches when both qualify. When the
      // user deliberately pinches middle, their index tip is often
      // anatomically close to the thumb too — a hardcoded "index wins"
      // priority would always steal the gesture. Smallest 2D distance
      // wins; if both are equidistant, index wins as tiebreaker.
      let indexPasses = indexM.map {
        $0.distance2D < config.indexContactThreshold
      } ?? false
      let middlePasses = middleM.map {
        $0.distance2D < config.middleContactThreshold
      } ?? false

      enum Winner { case index, middle }
      let winner: Winner? = {
        switch (indexPasses, middlePasses) {
        case (true, true):
          return indexM!.distance2D <= middleM!.distance2D ? .index : .middle
        case (true, false): return .index
        case (false, true): return .middle
        case (false, false): return nil
        }
      }()

      guard let winner, let thumb = frame.thumbTip else { return nil }
      let startPt = CGPoint(x: CGFloat(thumb.x), y: CGFloat(thumb.y))
      let ctxM = (winner == .index) ? indexM! : middleM!
      let ctx = TrackingContext(
        startTimestampMs: frame.timestampMs,
        startThumbPosition: startPt,
        latestThumbPosition: startPt,
        latestTimestampMs: frame.timestampMs,
        missingFrameRun: 0,
        latestContactDistance2D: ctxM.distance2D
      )
      state = (winner == .index) ? .indexPinching(ctx) : .middlePinching(ctx)
      lastContactStartPosition = startPt
      lastContactReleasePosition = nil
      return nil

    case .indexPinching(var ctx):
      // Abandoned-hold timeout.
      if frame.timestampMs - ctx.startTimestampMs > config.maxPinchDurationMs {
        lastContactReleasePosition = ctx.latestThumbPosition
        state = .idle
        return nil
      }

      // Hand lost — tolerate brief gaps.
      if frame.isEmpty {
        ctx.missingFrameRun += 1
        if ctx.missingFrameRun > config.maxMissingFramesDuringPinching {
          lastContactReleasePosition = ctx.latestThumbPosition
          state = .idle
          return nil
        }
        state = .indexPinching(ctx)
        return nil
      }
      ctx.missingFrameRun = 0

      // Contact still closed? 2D only — z gating removed (too noisy).
      let m = indexM
      let stillIn2D = (m?.distance2D ?? .infinity) <= config.indexReleaseThreshold
      if stillIn2D, let m {
        if let thumb = frame.thumbTip {
          ctx.latestThumbPosition = CGPoint(x: CGFloat(thumb.x), y: CGFloat(thumb.y))
        }
        ctx.latestTimestampMs = frame.timestampMs
        ctx.latestContactDistance2D = m.distance2D
        state = .indexPinching(ctx)
        return nil
      }

      // Release — classify drag → .select / .left / .right / .up / .down.
      lastContactReleasePosition = ctx.latestThumbPosition
      let event = classifyIndexRelease(ctx: ctx)
      state = .idle
      lastEmitAt = now()
      return event

    case .middlePinching(var ctx):
      // Abandoned-hold timeout.
      if frame.timestampMs - ctx.startTimestampMs > config.maxPinchDurationMs {
        lastContactReleasePosition = ctx.latestThumbPosition
        state = .idle
        return nil
      }

      if frame.isEmpty {
        ctx.missingFrameRun += 1
        if ctx.missingFrameRun > config.maxMissingFramesDuringPinching {
          lastContactReleasePosition = ctx.latestThumbPosition
          state = .idle
          return nil
        }
        state = .middlePinching(ctx)
        return nil
      }
      ctx.missingFrameRun = 0

      let m = middleM
      let stillIn2D = (m?.distance2D ?? .infinity) <= config.middleReleaseThreshold
      if stillIn2D, let m {
        if let thumb = frame.thumbTip {
          ctx.latestThumbPosition = CGPoint(x: CGFloat(thumb.x), y: CGFloat(thumb.y))
        }
        ctx.latestTimestampMs = frame.timestampMs
        ctx.latestContactDistance2D = m.distance2D
        state = .middlePinching(ctx)
        return nil
      }

      // Release — emit .back only when BOTH gates pass:
      //   1. Duration is a quick tap (not an accidental grab).
      //   2. Drag magnitude is within backDragTolerance — small tremor
      //      from camera/hand motion is absorbed; a deliberate sweep
      //      during middle pinch is treated as unintentional and dropped.
      lastContactReleasePosition = ctx.latestThumbPosition
      let duration = ctx.latestTimestampMs - ctx.startTimestampMs
      let dxBack = Float(ctx.latestThumbPosition.x - ctx.startThumbPosition.x)
      let dyBack = Float(ctx.latestThumbPosition.y - ctx.startThumbPosition.y)
      let dragBack = (dxBack * dxBack + dyBack * dyBack).squareRoot()
      state = .idle
      if duration <= config.tapMaxDurationMs && dragBack <= config.backDragTolerance {
        lastEmitAt = now()
        return .back
      }
      return nil
    }
  }

  var debugState: DebugSnapshot {
    let cooldown: Bool = {
      guard let lastEmitAt else { return false }
      return Int(now().timeIntervalSince(lastEmitAt) * 1000) < config.postEmitCooldownMs
    }()
    switch state {
    case .idle:
      return DebugSnapshot(
        fsm: .idle,
        inCooldown: cooldown,
        trackingDurationMs: 0,
        latestIndexDistance: nil,
        latestMiddleDistance: nil
      )
    case .indexPinching(let ctx):
      return DebugSnapshot(
        fsm: .indexPinching,
        inCooldown: false,
        trackingDurationMs: ctx.latestTimestampMs - ctx.startTimestampMs,
        latestIndexDistance: ctx.latestContactDistance2D,
        latestMiddleDistance: nil
      )
    case .middlePinching(let ctx):
      return DebugSnapshot(
        fsm: .middlePinching,
        inCooldown: false,
        trackingDurationMs: ctx.latestTimestampMs - ctx.startTimestampMs,
        latestIndexDistance: nil,
        latestMiddleDistance: ctx.latestContactDistance2D
      )
    }
  }

  // MARK: - Private helpers

  private enum PinchTarget { case index, middle }

  private func pinchMeasurement(frame: HandLandmarkFrame, finger: PinchTarget) -> PinchMeasurement? {
    guard let thumb = frame.thumbTip else { return nil }
    let other: HandLandmark2D?
    switch finger {
    case .index: other = frame.indexTip
    case .middle: other = frame.middleTip
    }
    guard let other else { return nil }
    let dx = thumb.x - other.x
    let dy = thumb.y - other.y
    let dist2D = (dx * dx + dy * dy).squareRoot()
    return PinchMeasurement(distance2D: dist2D)
  }

  private func classifyIndexRelease(ctx: TrackingContext) -> PinchDragEvent {
    let dx = Float(ctx.latestThumbPosition.x - ctx.startThumbPosition.x)
    let dy = Float(ctx.latestThumbPosition.y - ctx.startThumbPosition.y)
    let magnitude = (dx * dx + dy * dy).squareRoot()

    if magnitude < config.selectRadius {
      return .select
    }
    // Diagonal decision boundary. Horizontal wins on exact tie.
    if abs(dx) >= abs(dy) {
      return dx > 0 ? .right : .left
    } else {
      // Image y-down: positive dy = thumb moved down on screen.
      return dy > 0 ? .down : .up
    }
  }
}

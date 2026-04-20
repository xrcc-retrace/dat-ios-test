import CoreGraphics
import Foundation

/// Discrete Meta XR micro-gesture events emitted by `MicroGestureRecognizer`.
/// Names match Meta's canonical vocabulary so the mapping from Meta docs →
/// our code reads 1:1. Directions are user-relative (handedness corrected).
enum HandGestureEvent: Equatable {
  case tap
  case swipeLeft
  case swipeRight
  case swipeForward   // thumb slides toward fingertip (distal)
  case swipeBackward  // thumb slides toward knuckle (proximal)
}

/// One entry in the recent-gesture log shown on the Ray-Ban HUD debug
/// overlay. Each emit from the recognizer appends one of these to the
/// session VM's published list. `id` is fresh per emission so identical
/// consecutive events still animate independently.
struct MicroGestureLogEntry: Equatable, Identifiable {
  let id: UUID
  let event: HandGestureEvent
  let firedAt: Date

  init(event: HandGestureEvent, firedAt: Date = Date(), id: UUID = UUID()) {
    self.id = id
    self.event = event
    self.firedAt = firedAt
  }
}

/// State machine that converts a `HandLandmarkFrame` stream into discrete
/// `HandGestureEvent` values, modeled on the STMG (CHI 2024) algorithm
/// adapted to 2D MediaPipe landmarks.
///
/// Pure value type. No AVFoundation / SwiftUI / MediaPipe imports. Callers
/// on any queue drive it; the recognizer itself is deterministic given a
/// frame sequence + an injected clock.
///
/// Contact is detected by 2D distance from `thumbTip` to the line segment
/// `indexMCP ↔ indexPIP` (the Meta XR "proximal phalanx" contact zone).
/// Direction is classified in a local coordinate frame constructed from
/// the index-finger segment:
///
///   Axis A (along finger) = normalize(indexPIP − indexMCP)
///   Axis B (across finger) = perpendicular to A in image plane,
///                            sign-flipped for left hand
///
/// Per-axis magnitude thresholds reflect the physical asymmetry of the
/// finger: along-finger swipes have more room (~2–3 cm) than across-finger
/// swipes (~1–1.5 cm).
struct MicroGestureRecognizer {
  struct Config {
    /// Enter TRACKING when thumb-to-segment 2D distance falls below this
    /// AND `zContactThreshold` is also met. Widened slightly from 0.06 →
    /// 0.10 so natural thumb positions near (but not perfectly overlapping)
    /// the finger in the image count as contact; z now enforces the
    /// "physically close" requirement that 2D distance alone doesn't.
    var contactThreshold: Float = 0.10
    /// Exit TRACKING when 2D distance exceeds this. Hysteresis gap of
    /// 0.04 is >> the ~0.002 filtered jitter floor.
    var releaseThreshold: Float = 0.14

    /// Enter TRACKING when |thumbTip.z − segment_interpolated_z| is below
    /// this. MediaPipe z is in same normalized units as x/y and is
    /// documented as noisy, so this is generous — tight enough to reject
    /// "thumb is passing in front of the finger at different depth" but
    /// loose enough to absorb ~0.02-0.05 z jitter.
    var zContactThreshold: Float = 0.08
    /// Exit TRACKING when z delta exceeds this. Hysteresis.
    var zReleaseThreshold: Float = 0.12

    /// Minimum |along|-axis magnitude to classify Forward/Backward.
    /// Finger is ~3 cm long; a clean 2 cm swipe is ~0.025 normalized.
    var alongMin: Float = 0.020
    /// Minimum |across|-axis magnitude to classify Left/Right.
    /// Finger is ~1.5 cm wide; a clean 1 cm swipe is ~0.012 normalized.
    var acrossMin: Float = 0.010
    /// Overall magnitude ceiling for tap classification — motion below
    /// this AND short duration → tap.
    var tapOverallMax: Float = 0.008

    /// One projected axis must dominate the other by this factor to
    /// classify. Otherwise we drop the frame as "ambiguous diagonal"
    /// rather than misroute to the wrong direction.
    var dominantAxisRatio: Float = 1.3

    /// Maximum contact duration for tap classification. Longer contact
    /// with zero drift is treated as a cancelled gesture, not a tap.
    var tapMaxDurationMs: Int = 200

    /// Post-emit lockout. Suppresses runaway double-fires and gives the
    /// user's physical hand motion time to settle between gestures.
    var postEmitCooldownMs: Int = 350

    /// Tolerate brief hand dropouts (single missed MediaPipe frame) by
    /// not resetting TRACKING immediately. Beyond this frame count with
    /// no hand, we reset.
    var maxMissingFramesDuringTracking: Int = 4

    /// Abandoned-hold timeout. TRACKING for longer than this → reset
    /// without emit. Catches "user forgot the pose" and thermal stalls
    /// that deliver a backlog burst.
    var maxTrackingDurationMs: Int = 2000

    /// Skip any frame where |indexPIP − indexMCP| < this normalized
    /// length — the local frame would be degenerate and projections
    /// meaningless. Practical value at iPhone arm's length.
    var minFingerAxisLength: Float = 0.02

    /// MediaPipe occasionally flips handedness for a single frame under
    /// motion. Only reset TRACKING when the mismatch persists this many
    /// consecutive frames.
    var maxHandednessMismatchFrames: Int = 3
  }

  /// Read-only snapshot of internal state, exposed for on-device debug
  /// overlays. Not part of the event contract; subject to change.
  struct DebugSnapshot: Equatable {
    enum FSM: Equatable { case idle, tracking }
    let fsm: FSM
    let inCooldown: Bool
    let trackingDurationMs: Int
    let latestContactDistance: Float?
  }

  // MARK: - Private state

  private enum FSMState {
    case idle
    case tracking(TrackingContext)
  }

  private struct TrackingContext {
    let startTimestampMs: Int
    let startHandedness: String?
    let startThumbPosition: CGPoint
    var latestThumbPosition: CGPoint
    var latestTimestampMs: Int
    var latestContactDistance: Float
    var missingFrameRun: Int
    var handednessMismatchRun: Int
    /// Axes captured at release time. We derive them from the release
    /// frame rather than the start frame because if the hand rotated
    /// slightly during the gesture, the release-frame axes reflect the
    /// final intended direction.
  }

  private let config: Config
  private let now: () -> Date
  private var state: FSMState = .idle
  private var lastEmitAt: Date?

  /// Thumb position captured on the most recent IDLE → TRACKING transition.
  /// Persists after release so debug overlays can show "here's where
  /// contact started." Cleared and re-set each time TRACKING begins.
  private(set) var lastContactStartPosition: CGPoint?

  /// Thumb position captured on the most recent TRACKING → IDLE transition,
  /// regardless of whether the transition emitted an event (i.e. includes
  /// aborts: hand-lost, abandoned-hold, handedness-flip, and normal release).
  /// Persists until the next contact begins.
  private(set) var lastContactReleasePosition: CGPoint?

  // MARK: - Init

  init(config: Config = .init(), now: @escaping () -> Date = Date.init) {
    self.config = config
    self.now = now
  }

  // MARK: - Public API

  /// Consume one frame, advancing the FSM. Returns a non-nil event when
  /// the FSM fires on thumb release; nil for every intermediate frame and
  /// for frames suppressed by cooldown.
  mutating func ingest(_ frame: HandLandmarkFrame) -> HandGestureEvent? {
    // Hard cooldown. Any ingest within the lockout window is ignored —
    // state stays whatever it was (typically .idle after a successful emit).
    if let lastEmitAt {
      let elapsedMs = Int(now().timeIntervalSince(lastEmitAt) * 1000)
      if elapsedMs < config.postEmitCooldownMs {
        return nil
      }
    }

    let contact = frame.thumbProximalSegmentContact
    let fingerAxisLen = fingerAxisLength(frame)

    switch state {
    case .idle:
      // Need hand + contact on BOTH axes + non-degenerate finger axis.
      guard let contact else { return nil }
      guard contact.distance2D < config.contactThreshold else { return nil }
      guard contact.zDelta < config.zContactThreshold else { return nil }
      guard fingerAxisLen >= config.minFingerAxisLength else { return nil }
      guard let thumb = frame.thumbTip else { return nil }

      let startPt = CGPoint(x: CGFloat(thumb.x), y: CGFloat(thumb.y))
      state = .tracking(TrackingContext(
        startTimestampMs: frame.timestampMs,
        startHandedness: frame.handedness,
        startThumbPosition: startPt,
        latestThumbPosition: startPt,
        latestTimestampMs: frame.timestampMs,
        latestContactDistance: contact.distance2D,
        missingFrameRun: 0,
        handednessMismatchRun: 0
      ))
      // Record start for debug overlay; clear any stale release marker
      // so the overlay doesn't show the previous gesture's end position.
      lastContactStartPosition = startPt
      lastContactReleasePosition = nil
      return nil

    case .tracking(var ctx):
      // Abandoned-hold timeout.
      let elapsedMs = frame.timestampMs - ctx.startTimestampMs
      if elapsedMs > config.maxTrackingDurationMs {
        lastContactReleasePosition = ctx.latestThumbPosition
        state = .idle
        return nil
      }

      // Hand lost — count missing frames; reset if too many.
      if frame.isEmpty {
        ctx.missingFrameRun += 1
        if ctx.missingFrameRun > config.maxMissingFramesDuringTracking {
          lastContactReleasePosition = ctx.latestThumbPosition
          state = .idle
          return nil
        }
        state = .tracking(ctx)
        return nil
      }
      ctx.missingFrameRun = 0

      // Handedness mid-sequence flip tolerance.
      if frame.handedness != ctx.startHandedness {
        ctx.handednessMismatchRun += 1
        if ctx.handednessMismatchRun >= config.maxHandednessMismatchFrames {
          lastContactReleasePosition = ctx.latestThumbPosition
          state = .idle
          return nil
        }
      } else {
        ctx.handednessMismatchRun = 0
      }

      // No reliable contact signal → treat as release-in-progress.
      let effective2D = contact?.distance2D ?? .infinity
      let effectiveZ = contact?.zDelta ?? .infinity

      // Still in contact when BOTH axes are within their respective
      // release thresholds. Either axis going out triggers release —
      // mirrors the "AND to enter" contract.
      let still2D = effective2D <= config.releaseThreshold
      let stillZ = effectiveZ <= config.zReleaseThreshold
      if still2D && stillZ {
        if let thumb = frame.thumbTip {
          ctx.latestThumbPosition = CGPoint(x: CGFloat(thumb.x), y: CGFloat(thumb.y))
        }
        ctx.latestTimestampMs = frame.timestampMs
        ctx.latestContactDistance = effective2D
        state = .tracking(ctx)
        return nil
      }

      // Release — either 2D or z (or both) exceeded. Classify using the
      // release-frame axes when possible.
      lastContactReleasePosition = ctx.latestThumbPosition
      let event = classify(ctx: ctx, releaseFrame: frame)
      state = .idle
      if event != nil {
        lastEmitAt = now()
      }
      return event
    }
  }

  /// Read-only debug snapshot for overlays / tuning tools.
  var debugState: DebugSnapshot {
    switch state {
    case .idle:
      return DebugSnapshot(
        fsm: .idle,
        inCooldown: lastEmitAt.map {
          Int(now().timeIntervalSince($0) * 1000) < config.postEmitCooldownMs
        } ?? false,
        trackingDurationMs: 0,
        latestContactDistance: nil
      )
    case .tracking(let ctx):
      return DebugSnapshot(
        fsm: .tracking,
        inCooldown: false,
        trackingDurationMs: ctx.latestTimestampMs - ctx.startTimestampMs,
        latestContactDistance: ctx.latestContactDistance
      )
    }
  }

  // MARK: - Classification

  private func classify(ctx: TrackingContext, releaseFrame: HandLandmarkFrame) -> HandGestureEvent? {
    // Prefer axes from the release frame (captures hand rotation during
    // gesture); fall back to start-frame axes if release-frame axes are
    // degenerate.
    let axes = localAxes(releaseFrame)
      ?? LocalAxes(ax: 0, ay: 1, bx: 1, by: 0)  // sensible default; rarely reached

    let dx = Float(ctx.latestThumbPosition.x - ctx.startThumbPosition.x)
    let dy = Float(ctx.latestThumbPosition.y - ctx.startThumbPosition.y)
    let along = dx * axes.ax + dy * axes.ay
    let across = dx * axes.bx + dy * axes.by
    let magnitude = (along * along + across * across).squareRoot()
    let duration = ctx.latestTimestampMs - ctx.startTimestampMs

    // Tap: near-zero motion + short duration.
    if magnitude < config.tapOverallMax && duration < config.tapMaxDurationMs {
      return .tap
    }

    let absAlong = abs(along)
    let absAcross = abs(across)

    // Along-finger dominant.
    if absAlong >= config.alongMin && absAlong >= absAcross * config.dominantAxisRatio {
      return along > 0 ? .swipeForward : .swipeBackward
    }

    // Across-finger dominant.
    if absAcross >= config.acrossMin && absAcross >= absAlong * config.dominantAxisRatio {
      return across > 0 ? .swipeRight : .swipeLeft
    }

    // Ambiguous (diagonal, or below per-axis minimums). Drop — better
    // than misrouting.
    return nil
  }

  // MARK: - Local frame math

  private struct LocalAxes {
    let ax: Float
    let ay: Float
    let bx: Float
    let by: Float
  }

  private func localAxes(_ frame: HandLandmarkFrame) -> LocalAxes? {
    guard let mcp = frame.indexMCP, let pip = frame.indexPIP else { return nil }
    let dx = pip.x - mcp.x
    let dy = pip.y - mcp.y
    let len = (dx * dx + dy * dy).squareRoot()
    guard len >= config.minFingerAxisLength else { return nil }
    let ax = dx / len
    let ay = dy / len
    // Perpendicular in image coords (y-down): rotate (ax, ay) → (-ay, ax).
    // Flip for left hand so "positive B" remains the user's right.
    var bx = -ay
    var by = ax
    if frame.handedness == "Left" {
      bx = -bx
      by = -by
    }
    return LocalAxes(ax: ax, ay: ay, bx: bx, by: by)
  }

  private func fingerAxisLength(_ frame: HandLandmarkFrame) -> Float {
    guard let mcp = frame.indexMCP, let pip = frame.indexPIP else { return 0 }
    let dx = pip.x - mcp.x
    let dy = pip.y - mcp.y
    return (dx * dx + dy * dy).squareRoot()
  }
}

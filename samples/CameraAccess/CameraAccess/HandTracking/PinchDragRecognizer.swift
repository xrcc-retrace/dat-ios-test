import CoreGraphics
import Foundation

/// The four directional quadrants used by `PinchDragRecognizer`. Each is
/// chosen by the classic diagonal split — `|Δx| ≥ |Δy|` selects a
/// horizontal quadrant, otherwise vertical, and sign picks the direction.
/// A thumb inside `selectRadius` of its start position is in no quadrant
/// (center dead zone).
enum PinchDragQuadrant: Equatable {
  case left, right, up, down
}

/// Discrete events emitted by `PinchDragRecognizer`. Two families:
///
///   - **Terminal**: fire on release (or double-tap emission) and commit
///     a gesture. `.select`, `.cancel`, `.left`, `.right`, `.up`, `.down`,
///     `.back`.
///   - **Highlight**: fire mid-pinch as the thumb enters a new quadrant,
///     giving the UI a chance to pre-light the button the user is about
///     to select. One emit per quadrant entry, not per frame.
enum PinchDragEvent: Equatable {
  case select   // pinch released inside selectRadius, never drifted out
  case cancel   // pinch drifted out of selectRadius then back in — an abort
  case left     // pinch dragged left in image, released in the left quadrant
  case right    // ... drag right
  case up       // ... drag up (image y-down → negative Δy)
  case down     // ... drag down (positive Δy)
  case back     // two quick taps near the same spot

  case highlightLeft
  case highlightRight
  case highlightUp
  case highlightDown

  /// The quadrant this event represents, if any. Nil for `.select`,
  /// `.cancel`, `.back`.
  var quadrant: PinchDragQuadrant? {
    switch self {
    case .left, .highlightLeft:   return .left
    case .right, .highlightRight: return .right
    case .up, .highlightUp:       return .up
    case .down, .highlightDown:   return .down
    case .select, .cancel, .back: return nil
    }
  }

  /// True for events that commit a gesture (cause state transitions in
  /// the consumer). False for mid-pinch highlights.
  var isTerminal: Bool {
    switch self {
    case .select, .cancel, .left, .right, .up, .down, .back: return true
    case .highlightLeft, .highlightRight, .highlightUp, .highlightDown:
      return false
    }
  }
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
/// `PinchDragEvent` values using a single pinch pair (thumb + index):
///
///   IDLE → (contact detected, gate pass, not in cooldown) → PINCHING
///     ├─ (still pinched, thumb enters new quadrant) → emit `.highlight*`
///     └─ (released) → classify:
///       - magnitude < selectRadius, never drifted out → defer `.select`
///         (or emit `.back` on double-tap candidate)
///       - magnitude < selectRadius, has drifted out → `.cancel`
///       - else → direction event (`.left/.right/.up/.down`)
///
/// Highlights fire exactly once per quadrant entry, giving the cross-UI
/// a chance to light the corresponding button before commit. Returning
/// to the center dead zone does not fire an event, but it does allow a
/// later re-entry into the same quadrant to fire again.
///
/// `.back` fires when two `.select`-sized pinches happen within
/// `doubleTapMaxGapMs` and within `doubleTapMaxDrift` of each other. If
/// the second tap drifts out and back, it becomes `.cancel` instead of
/// `.back` — the double-tap gesture is aborted by any drift.
///
/// Pure value type. No MediaPipe / AVFoundation / SwiftUI imports. Drive
/// from any queue. Injectable clock for deterministic tests.
struct PinchDragRecognizer {
  struct Config {
    // Pinch detection is 2D-only. MediaPipe's z estimate for fingertips
    // is too noisy to use as a contact gate without false negatives.
    // Orientation still gates on `palmFacingZ` — that signal comes from
    // wrist/MCP landmarks which are more stable.
    var indexContactThreshold: Float = 0.04
    var indexReleaseThreshold: Float = 0.05

    /// Center "dead zone" radius, in normalized image units. Drift
    /// below this is treated as zero (no quadrant highlights, release
    /// commits as `.select` or `.cancel` depending on whether the pinch
    /// ever left this zone). 0.05 ≈ 36 px on a 720-wide frame.
    var selectRadius: Float = 0.05

    /// Max gap between the first tap's release and the second tap's
    /// contact start for the pair to qualify as a double-tap. Beyond
    /// this, the first tap commits as a plain `.select`.
    var doubleTapMaxGapMs: Int = 300

    /// Max thumb-position drift between first tap's release and second
    /// tap's start for the pair to qualify as double-tap.
    var doubleTapMaxDrift: Float = 0.06

    /// Post-emit lockout — suppresses event storms during physical
    /// settle-time between gestures. Applies only at IDLE → pinching
    /// transitions; highlights mid-gesture are never cooldown-gated.
    var postEmitCooldownMs: Int = 250

    // MARK: - Orientation start-gate

    var gatePalmFacingZMin: Float = -0.5
    var gatePalmFacingZMax: Float = 0.5
    var gateHandSizeMin: Float = 0.10
    var gateDisabled: Bool = false

    var maxMissingFramesDuringPinching: Int = 4
    var maxPinchDurationMs: Int = 4000
  }

  /// Read-only snapshot for debug overlays.
  struct DebugSnapshot: Equatable {
    enum FSM: Equatable { case idle, indexPinching }
    let fsm: FSM
    let inCooldown: Bool
    let trackingDurationMs: Int
    let latestIndexDistance: Float?
    let pendingSelectActive: Bool
    /// Quadrant the thumb is currently occupying (nil while idle, in the
    /// center dead zone, or not tracking). Drives the cross-UI's lit box.
    let currentHighlightQuadrant: PinchDragQuadrant?
    /// True once the thumb has drifted out of `selectRadius` during the
    /// current pinch — the release will commit `.cancel` rather than
    /// `.select` if the user returns to center.
    let hasDriftedOutDuringPinch: Bool
  }

  // MARK: - State

  private enum FSMState {
    case idle
    case indexPinching(TrackingContext)
  }

  private struct TrackingContext {
    let startTimestampMs: Int
    let startThumbPosition: CGPoint
    var latestThumbPosition: CGPoint
    var latestTimestampMs: Int
    var missingFrameRun: Int
    var latestContactDistance2D: Float
    let isDoubleTapCandidate: Bool
    /// Last quadrant for which a `.highlight*` was emitted (nil means the
    /// thumb is in the center dead zone or no highlight has fired yet).
    /// A transition to a different value triggers the next emit.
    var lastHighlightedQuadrant: PinchDragQuadrant?
    /// Sticky flag — true once the thumb has ever crossed outside
    /// `selectRadius` during this pinch. Drives the `.cancel` vs
    /// `.select` decision on release.
    var hasEverExitedSelectRadius: Bool
  }

  private struct PinchMeasurement {
    let distance2D: Float
  }

  private struct PendingSelect {
    let releaseTime: Date
    let position: CGPoint
  }

  private let config: Config
  private let now: () -> Date
  private var state: FSMState = .idle
  private var lastEmitAt: Date?
  private var pendingSelect: PendingSelect?

  private(set) var lastContactStartPosition: CGPoint?
  private(set) var lastContactReleasePosition: CGPoint?

  // MARK: - Init

  init(config: Config = .init(), now: @escaping () -> Date = Date.init) {
    self.config = config
    self.now = now
  }

  // MARK: - Public API

  /// Consume one frame. Returns a non-nil event when:
  ///   - the FSM fires on release,
  ///   - a deferred `.select` commits because its double-tap window
  ///     expired, or
  ///   - the thumb enters a new quadrant mid-pinch.
  /// Returns nil for intermediate frames and for cooldown-suppressed emits.
  mutating func ingest(_ frame: HandLandmarkFrame) -> PinchDragEvent? {
    // 1. Deferred `.select` fire. Runs OUTSIDE cooldown — we already
    //    held this one for the full `doubleTapMaxGapMs`, committing now.
    if let ps = pendingSelect {
      let elapsedMs = Int(now().timeIntervalSince(ps.releaseTime) * 1000)
      if elapsedMs >= config.doubleTapMaxGapMs {
        pendingSelect = nil
        lastEmitAt = now()
        return .select
      }
    }

    let indexM = pinchMeasurement(frame: frame)

    switch state {
    case .idle:
      // Cooldown gates only IDLE → pinching transitions. Mid-gesture
      // highlights must not be blocked by a previous emit's cooldown.
      if let lastEmitAt {
        let elapsedMs = Int(now().timeIntervalSince(lastEmitAt) * 1000)
        if elapsedMs < config.postEmitCooldownMs {
          return nil
        }
      }

      if !config.gateDisabled {
        guard let orient = frame.orientation else { return nil }
        if orient.palmFacingZ < config.gatePalmFacingZMin ||
           orient.palmFacingZ > config.gatePalmFacingZMax ||
           orient.handSize < config.gateHandSizeMin {
          return nil
        }
      }

      let indexPasses = indexM.map {
        $0.distance2D < config.indexContactThreshold
      } ?? false
      guard indexPasses, let m = indexM, let thumb = frame.thumbTip else {
        return nil
      }
      let startPt = CGPoint(x: CGFloat(thumb.x), y: CGFloat(thumb.y))

      var isDoubleTap = false
      if let ps = pendingSelect {
        let elapsedMs = Int(now().timeIntervalSince(ps.releaseTime) * 1000)
        if elapsedMs <= config.doubleTapMaxGapMs {
          let dx = Float(startPt.x - ps.position.x)
          let dy = Float(startPt.y - ps.position.y)
          let drift = (dx * dx + dy * dy).squareRoot()
          if drift <= config.doubleTapMaxDrift {
            isDoubleTap = true
          }
        }
        pendingSelect = nil
      }

      let ctx = TrackingContext(
        startTimestampMs: frame.timestampMs,
        startThumbPosition: startPt,
        latestThumbPosition: startPt,
        latestTimestampMs: frame.timestampMs,
        missingFrameRun: 0,
        latestContactDistance2D: m.distance2D,
        isDoubleTapCandidate: isDoubleTap,
        lastHighlightedQuadrant: nil,
        hasEverExitedSelectRadius: false
      )
      state = .indexPinching(ctx)
      lastContactStartPosition = startPt
      lastContactReleasePosition = nil
      return nil

    case .indexPinching(var ctx):
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
        state = .indexPinching(ctx)
        return nil
      }
      ctx.missingFrameRun = 0

      let stillIn2D = (indexM?.distance2D ?? .infinity) <= config.indexReleaseThreshold
      if stillIn2D, let m = indexM {
        if let thumb = frame.thumbTip {
          ctx.latestThumbPosition = CGPoint(x: CGFloat(thumb.x), y: CGFloat(thumb.y))
        }
        ctx.latestTimestampMs = frame.timestampMs
        ctx.latestContactDistance2D = m.distance2D

        // Quadrant highlight emission.
        let currentQuadrant = quadrant(for: ctx)
        if currentQuadrant != nil {
          ctx.hasEverExitedSelectRadius = true
        }
        var highlight: PinchDragEvent? = nil
        if currentQuadrant != ctx.lastHighlightedQuadrant {
          ctx.lastHighlightedQuadrant = currentQuadrant
          if let q = currentQuadrant {
            highlight = highlightEvent(for: q)
          }
          // Center re-entry emits nothing — the cross-UI reads the
          // quadrant directly from `debugState.currentHighlightQuadrant`
          // for that transition.
        }

        state = .indexPinching(ctx)
        return highlight
      }

      // Release — classify and route.
      lastContactReleasePosition = ctx.latestThumbPosition
      let classified = classifyRelease(ctx: ctx)
      state = .idle

      switch classified {
      case .select:
        if ctx.isDoubleTapCandidate {
          // Clean double-tap → .back
          lastEmitAt = now()
          return .back
        } else {
          // First tap — defer for possible double-tap
          pendingSelect = PendingSelect(
            releaseTime: now(),
            position: ctx.latestThumbPosition
          )
          return nil
        }
      case .cancel:
        // Cancel always emits immediately, even inside a double-tap
        // window. Drifting out aborts the double-tap attempt too.
        lastEmitAt = now()
        return .cancel
      case .left, .right, .up, .down:
        // Direction — if this was a double-tap candidate, the pending
        // first select is swallowed (not emitted alongside the direction).
        lastEmitAt = now()
        return classified
      default:
        // Unreachable; classifyRelease only returns the above.
        return nil
      }
    }
  }

  var debugState: DebugSnapshot {
    let cooldown: Bool = {
      guard let lastEmitAt else { return false }
      return Int(now().timeIntervalSince(lastEmitAt) * 1000) < config.postEmitCooldownMs
    }()
    let pendingActive: Bool = {
      guard let ps = pendingSelect else { return false }
      let elapsedMs = Int(now().timeIntervalSince(ps.releaseTime) * 1000)
      return elapsedMs < config.doubleTapMaxGapMs
    }()
    switch state {
    case .idle:
      return DebugSnapshot(
        fsm: .idle,
        inCooldown: cooldown,
        trackingDurationMs: 0,
        latestIndexDistance: nil,
        pendingSelectActive: pendingActive,
        currentHighlightQuadrant: nil,
        hasDriftedOutDuringPinch: false
      )
    case .indexPinching(let ctx):
      return DebugSnapshot(
        fsm: .indexPinching,
        inCooldown: false,
        trackingDurationMs: ctx.latestTimestampMs - ctx.startTimestampMs,
        latestIndexDistance: ctx.latestContactDistance2D,
        pendingSelectActive: pendingActive,
        currentHighlightQuadrant: ctx.lastHighlightedQuadrant,
        hasDriftedOutDuringPinch: ctx.hasEverExitedSelectRadius
      )
    }
  }

  // MARK: - Private helpers

  private func pinchMeasurement(frame: HandLandmarkFrame) -> PinchMeasurement? {
    guard let thumb = frame.thumbTip, let index = frame.indexTip else {
      return nil
    }
    let dx = thumb.x - index.x
    let dy = thumb.y - index.y
    let dist2D = (dx * dx + dy * dy).squareRoot()
    return PinchMeasurement(distance2D: dist2D)
  }

  /// Quadrant the thumb currently occupies relative to the pinch-start
  /// position, or nil if inside `selectRadius`. Horizontal wins on an
  /// exact diagonal tie, same rule as the release classifier.
  private func quadrant(for ctx: TrackingContext) -> PinchDragQuadrant? {
    let dx = Float(ctx.latestThumbPosition.x - ctx.startThumbPosition.x)
    let dy = Float(ctx.latestThumbPosition.y - ctx.startThumbPosition.y)
    let magnitude = (dx * dx + dy * dy).squareRoot()
    if magnitude < config.selectRadius { return nil }
    if abs(dx) >= abs(dy) {
      return dx > 0 ? .right : .left
    } else {
      return dy > 0 ? .down : .up
    }
  }

  private func highlightEvent(for q: PinchDragQuadrant) -> PinchDragEvent {
    switch q {
    case .left: return .highlightLeft
    case .right: return .highlightRight
    case .up: return .highlightUp
    case .down: return .highlightDown
    }
  }

  private func classifyRelease(ctx: TrackingContext) -> PinchDragEvent {
    let dx = Float(ctx.latestThumbPosition.x - ctx.startThumbPosition.x)
    let dy = Float(ctx.latestThumbPosition.y - ctx.startThumbPosition.y)
    let magnitude = (dx * dx + dy * dy).squareRoot()

    if magnitude < config.selectRadius {
      // Inside the center dead zone on release. Did the thumb ever leave
      // it during this pinch? If yes → user aborted, emit `.cancel`.
      // If no → clean tap, emit `.select`.
      return ctx.hasEverExitedSelectRadius ? .cancel : .select
    }
    if abs(dx) >= abs(dy) {
      return dx > 0 ? .right : .left
    } else {
      return dy > 0 ? .down : .up
    }
  }
}

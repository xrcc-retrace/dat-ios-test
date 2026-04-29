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
    //
    // Both thresholds are scale-invariant ratios — `thumb-tip ↔ index-tip`
    // distance divided by `wrist ↔ middleMCP` distance (the same handSize
    // proxy used by the orientation gate). A ratio of 0.22 means "thumb
    // and index are within ~22 % of one palm-length of each other." This
    // stays stable as the user moves nearer / farther from the camera —
    // image-unit thresholds tighten when the hand is close (handSize
    // grows), making sustained pinches release on jitter.
    var indexContactRatio: Float = 0.22
    var indexReleaseRatio: Float = 0.24

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

    var gatePalmFacingZMin: Float = -0.4
    var gatePalmFacingZMax: Float = 0.4
    var gateHandSizeMin: Float = 0.15

    /// 2D palm-angle gate (top-to-bottom rotation of the hand in the
    /// image; `wrist → middleMCP` direction). Image coords are y-down so
    /// `−90°` = pointing up, `0°` = pointing right, `+90°` = pointing
    /// down, `±180°` = pointing left. Defaults span the full circle so
    /// the recognizer's unit tests (which use `Config()`) are unaffected;
    /// `productionConfig()` narrows this to the canonical "hand-up"
    /// posture. Wrap-around (a range that crosses `±180°`) is not
    /// handled — keep min ≤ max within `[-180, 180]`.
    var gatePalmAngleMin: Float = -180.0
    var gatePalmAngleMax: Float = 180.0

    var gateDisabled: Bool = false

    var maxMissingFramesDuringPinching: Int = 4

    /// Release debounce — number of consecutive frames the index pinch
    /// must stay above `indexReleaseRatio` (or have missing
    /// thumb/index landmarks) before the FSM commits to a real release.
    /// 1 = no debounce (single bad frame ends the pinch — convenient for
    /// deterministic unit tests but jittery on-device).
    /// 3 ≈ 100 ms at 30 fps — absorbs MediaPipe distance jitter and brief
    /// landmark dropouts without delaying intentional releases noticeably.
    /// Production call sites should override to 3; default stays at 1 so
    /// the test suite's single-frame release pattern keeps working.
    var releaseDebounceFrames: Int = 1
  }

  /// Read-only snapshot for debug overlays.
  struct DebugSnapshot: Equatable {
    enum FSM: Equatable { case idle, indexPinching }
    let fsm: FSM
    let inCooldown: Bool
    let trackingDurationMs: Int
    /// Most recent pinch ratio (thumb-index distance ÷ handSize). Nil
    /// while idle or when the frame lacked the landmarks to compute it.
    let latestIndexRatio: Float?
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
    var latestContactRatio: Float
    let isDoubleTapCandidate: Bool
    /// Last quadrant for which a `.highlight*` was emitted (nil means the
    /// thumb is in the center dead zone or no highlight has fired yet).
    /// A transition to a different value triggers the next emit.
    var lastHighlightedQuadrant: PinchDragQuadrant?
    /// Sticky flag — true once the thumb has ever crossed outside
    /// `selectRadius` during this pinch. Drives the `.cancel` vs
    /// `.select` decision on release.
    var hasEverExitedSelectRadius: Bool
    /// Consecutive frames the pinch has registered as "released" (ratio
    /// above `indexReleaseRatio`, or no thumb/index landmark). Reset
    /// to 0 every time the pinch tests as still in contact. Commits to a
    /// real release once it reaches `releaseDebounceFrames`.
    var releaseRunFrames: Int
  }

  private struct PinchMeasurement {
    /// Thumb-tip ↔ index-tip distance divided by `handSize`
    /// (`|wrist → middleMCP|`). Scale-invariant, so a single threshold
    /// works regardless of how close the hand is to the camera.
    let ratio: Float
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
           orient.handSize < config.gateHandSizeMin ||
           orient.palmAngleDegrees < config.gatePalmAngleMin ||
           orient.palmAngleDegrees > config.gatePalmAngleMax {
          return nil
        }
      }

      let indexPasses = indexM.map {
        $0.ratio < config.indexContactRatio
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
        latestContactRatio: m.ratio,
        isDoubleTapCandidate: isDoubleTap,
        lastHighlightedQuadrant: nil,
        hasEverExitedSelectRadius: false,
        releaseRunFrames: 0
      )
      state = .indexPinching(ctx)
      lastContactStartPosition = startPt
      lastContactReleasePosition = nil
      return nil

    case .indexPinching(var ctx):
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

      let stillIn = (indexM?.ratio ?? .infinity) <= config.indexReleaseRatio
      if stillIn, let m = indexM {
        // Pinch is still engaged this frame. Reset the release-debounce
        // counter so a stale "almost released" run doesn't persist.
        ctx.releaseRunFrames = 0
        if let thumb = frame.thumbTip {
          ctx.latestThumbPosition = CGPoint(x: CGFloat(thumb.x), y: CGFloat(thumb.y))
        }
        ctx.latestTimestampMs = frame.timestampMs
        ctx.latestContactRatio = m.ratio

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

      // Frame looks released — accumulate the debounce counter. Don't
      // commit the release until we've seen `releaseDebounceFrames` in a
      // row, which absorbs single-frame distance jitter and brief
      // landmark dropouts without re-anchoring the start position.
      ctx.releaseRunFrames += 1
      if ctx.releaseRunFrames < max(1, config.releaseDebounceFrames) {
        state = .indexPinching(ctx)
        return nil
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
        latestIndexRatio: nil,
        pendingSelectActive: pendingActive,
        currentHighlightQuadrant: nil,
        hasDriftedOutDuringPinch: false
      )
    case .indexPinching(let ctx):
      return DebugSnapshot(
        fsm: .indexPinching,
        inCooldown: false,
        trackingDurationMs: ctx.latestTimestampMs - ctx.startTimestampMs,
        latestIndexRatio: ctx.latestContactRatio,
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
    // handSize comes from `wrist → middleMCP` (HandOrientation already
    // computes it). If the orientation landmarks are missing the frame
    // is too degenerate to do scale-invariant pinch detection on, so
    // bail and let the caller treat it as "no measurement."
    guard let hand = frame.orientation, hand.handSize > 1e-4 else {
      return nil
    }
    let dx = thumb.x - index.x
    let dy = thumb.y - index.y
    let dist2D = (dx * dx + dy * dy).squareRoot()
    return PinchMeasurement(ratio: dist2D / hand.handSize)
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

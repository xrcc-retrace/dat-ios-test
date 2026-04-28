import Combine
import CoreGraphics
import Foundation

/// Single-instance owner of the hand-tracking recognizer and its plumbing.
///
/// Before this service existed, every VM that ran a camera pipeline (the
/// Gemini Live shared base for Coaching + Troubleshoot, plus the Expert
/// recording HUD VM) held its own `PinchDragRecognizer` instance and
/// duplicated the same ~30-line frame-ingest closure: append to the log,
/// throttle the orientation log, fire `.back` callbacks, etc. Adding a
/// new mode meant copy-pasting the plumbing.
///
/// Now: the `PinchDragRecognizer` lives here once. Camera pipelines call
/// `ingest(_:)` from their existing frame closures; views read state for
/// the debug overlay through the singleton; mode-specific reactions
/// (Expert's tip cycling, Coaching's `.back` → exit confirmation) attach
/// closures via `onEvent` / `onBackGesture` and clear them on teardown.
///
/// The `[Orient]` 1-Hz log, the 50-entry log cap, and the
/// `releaseDebounceFrames = 3` config all live here — same numbers as
/// before, just centralized.
@MainActor
final class HandGestureService: ObservableObject {

  // MARK: - Singleton

  static let shared = HandGestureService()

  private init() {}

  // MARK: - Published state

  @Published private(set) var latestHandFrame: HandLandmarkFrame?
  @Published private(set) var recentPinchDragEvents: [PinchDragLogEntry] = []

  /// Hard cap on retained log entries. Oldest are dropped when exceeded.
  let logMaxHistory: Int = 50

  // MARK: - Per-mode hooks

  /// Fires for every recognizer event AFTER it's appended to the log.
  /// Set per-mode to react to events outside `.back` — e.g. Expert maps
  /// `.right` / `.left` to tip cycling. Both `onEvent` and `onBackGesture`
  /// fire if both are set. Always clear on mode teardown to avoid
  /// leaking the closure into the next mode.
  var onEvent: ((PinchDragEvent) -> Void)?

  /// Fires specifically on `.back` (double index-finger pinch). The
  /// canonical "back / dismiss" hook used by Coaching + Troubleshoot, and
  /// by any future mode that wants the same intent. Clear on teardown.
  var onBackGesture: (() -> Void)?

  /// Fires for every recognizer event AFTER it's appended to the log.
  /// Owned by the focus engine — `RayBanHUDEmulator` sets this on appear
  /// to translate pinch-drag events into `HUDInputEvent` dispatches.
  /// Independent of `onEvent` and `onBackGesture` so mode-local hooks
  /// (Expert tip cycling) and the focus engine can coexist without
  /// fighting over the same callback slot.
  var onFocusEngineEvent: ((PinchDragEvent) -> Void)?

  // MARK: - Recognizer (single source of truth)

  /// Same config the per-VM recognizers used before this refactor —
  /// `releaseDebounceFrames = 3`. If we ever need different configs per
  /// mode, add a `setConfig(_:)` method instead of multiplying instances.
  static func productionConfig() -> PinchDragRecognizer.Config {
    var c = PinchDragRecognizer.Config()
    c.releaseDebounceFrames = 3
    return c
  }

  private var pinchDragRecognizer = PinchDragRecognizer(
    config: HandGestureService.productionConfig()
  )

  /// 1-Hz throttle for the `[Orient]` console log. Same throttle as the
  /// previous per-VM implementations.
  private var lastOrientationLogAt: Date?

  // MARK: - Public ingest API

  /// Camera pipelines call this from their existing frame closures.
  /// Updates `latestHandFrame`, emits the throttled orientation log,
  /// runs the recognizer, appends to the log, and dispatches event +
  /// back-gesture callbacks.
  func ingest(_ frame: HandLandmarkFrame) {
    latestHandFrame = frame

    if let orient = frame.orientation {
      let now = Date()
      if lastOrientationLogAt == nil ||
         now.timeIntervalSince(lastOrientationLogAt!) >= 1.0 {
        lastOrientationLogAt = now
        print(String(
          format: "[Orient] palmAngle=%+7.1f°  palmFacingZ=%+.3f  handSize=%.3f  handedness=%@",
          orient.palmAngleDegrees,
          orient.palmFacingZ,
          orient.handSize,
          frame.handedness ?? "?"
        ))
      }
    }

    guard let event = pinchDragRecognizer.ingest(frame) else { return }
    print("[PinchDrag] \(event) ts=\(frame.timestampMs)")
    recentPinchDragEvents.append(PinchDragLogEntry(event: event))
    let overflow = recentPinchDragEvents.count - logMaxHistory
    if overflow > 0 {
      recentPinchDragEvents.removeFirst(overflow)
    }

    onEvent?(event)
    if event == .back {
      onBackGesture?()
    }
    onFocusEngineEvent?(event)
  }

  /// Reset recognizer FSM + log + cached frame. Called when a session
  /// starts so stale state from a prior mode doesn't bleed in.
  func reset() {
    pinchDragRecognizer = PinchDragRecognizer(config: Self.productionConfig())
    latestHandFrame = nil
    recentPinchDragEvents.removeAll()
    lastOrientationLogAt = nil
  }
}

// MARK: - HandGestureDebugProvider conformance

/// Forwards every required property to the recognizer / state above.
/// Bodies are identical to what the per-VM computed properties did before
/// this refactor.
extension HandGestureService: HandGestureDebugProvider {

  /// Pinch-contact ratio threshold, surfaced so the debug overlay renders
  /// the same gate the recognizer applies. Scale-invariant against camera
  /// distance.
  var indexPinchContactRatio: Float {
    PinchDragRecognizer.Config().indexContactRatio
  }

  var gatePalmFacingZMin: Float {
    PinchDragRecognizer.Config().gatePalmFacingZMin
  }

  var gatePalmFacingZMax: Float {
    PinchDragRecognizer.Config().gatePalmFacingZMax
  }

  var gateHandSizeMin: Float {
    PinchDragRecognizer.Config().gateHandSizeMin
  }

  /// True while a deferred `.select` is still inside its double-tap
  /// window. Drives the overlay's "TAP 1/2" chip.
  var pendingSelectActive: Bool {
    pinchDragRecognizer.debugState.pendingSelectActive
  }

  /// Quadrant the thumb is currently occupying relative to the pinch
  /// start, or nil while idle / in the center dead zone. Drives the
  /// cross-UI's lit box.
  var currentHighlightQuadrant: PinchDragQuadrant? {
    pinchDragRecognizer.debugState.currentHighlightQuadrant
  }

  /// Thumb position at the most recent pinch start. Read-through from
  /// the active recognizer. Nil until first contact; persists across
  /// frames.
  var lastContactStartPosition: CGPoint? {
    pinchDragRecognizer.lastContactStartPosition
  }

  /// Thumb position at the most recent release / abort. Read-through
  /// from the active recognizer. Nil until first release; persists until
  /// next contact begins.
  var lastContactReleasePosition: CGPoint? {
    pinchDragRecognizer.lastContactReleasePosition
  }
}

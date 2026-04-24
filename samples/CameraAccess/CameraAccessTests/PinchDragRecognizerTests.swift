import XCTest
@testable import CameraAccess

final class PinchDragRecognizerTests: XCTestCase {

  // MARK: - Clock fixture

  private var clock: Date = Date(timeIntervalSince1970: 1_000_000)
  private var clockSource: () -> Date { { self.clock } }

  private func advance(ms: Int) {
    clock = clock.addingTimeInterval(TimeInterval(ms) / 1000.0)
  }

  // MARK: - Frame builder
  //
  // Place indexTip at (0.5, 0.5), thumbTip wherever the test wants. When
  // thumbTip is close to indexTip → pinch qualifies. Wrist + indexMCP +
  // pinkyMCP are chosen so the orientation gate lands palmFacingZ near 0.4
  // (canonical edge-on pose) with handSize ~0.18. Tests that want to
  // exercise the gate itself pass explicit overrides.

  private func frame(
    thumbX: Float, thumbY: Float, thumbZ: Float = 0,
    indexX: Float = 0.5, indexY: Float = 0.5, indexZ: Float = 0,
    wristX: Float = 0.55, wristY: Float = 0.80, wristZ: Float = 0,
    indexMCPX: Float = 0.50, indexMCPY: Float = 0.55, indexMCPZ: Float = -0.10,
    middleMCPX: Float = 0.45, middleMCPY: Float = 0.65, middleMCPZ: Float = 0,
    pinkyMCPX: Float = 0.60, pinkyMCPY: Float = 0.60, pinkyMCPZ: Float = 0.10,
    timestampMs: Int,
    handPresent: Bool = true
  ) -> HandLandmarkFrame {
    guard handPresent else {
      return HandLandmarkFrame(landmarks: [], handedness: nil, timestampMs: timestampMs)
    }
    var pts = Array(repeating: HandLandmark2D(x: 0.5, y: 0.5, z: 0), count: 21)
    pts[0] = HandLandmark2D(x: wristX, y: wristY, z: wristZ)                 // wrist
    pts[4] = HandLandmark2D(x: thumbX, y: thumbY, z: thumbZ)                 // thumbTip
    pts[5] = HandLandmark2D(x: indexMCPX, y: indexMCPY, z: indexMCPZ)        // indexMCP
    pts[6] = HandLandmark2D(x: 0.5, y: 0.52, z: 0)                           // indexPIP
    pts[8] = HandLandmark2D(x: indexX, y: indexY, z: indexZ)                 // indexTip
    pts[9] = HandLandmark2D(x: middleMCPX, y: middleMCPY, z: middleMCPZ)     // middleMCP
    pts[17] = HandLandmark2D(x: pinkyMCPX, y: pinkyMCPY, z: pinkyMCPZ)       // pinkyMCP
    return HandLandmarkFrame(landmarks: pts, handedness: "Right", timestampMs: timestampMs)
  }

  /// Thumb exactly on indexTip → minimum pinch distance (0).
  private func indexPinchFrame(
    thumbOffset: CGPoint = .zero,
    timestampMs: Int
  ) -> HandLandmarkFrame {
    frame(
      thumbX: 0.5 + Float(thumbOffset.x),
      thumbY: 0.5 + Float(thumbOffset.y),
      timestampMs: timestampMs
    )
  }

  /// Thumb far from indexTip → released.
  private func releasedFrame(timestampMs: Int) -> HandLandmarkFrame {
    frame(thumbX: 0.85, thumbY: 0.5, timestampMs: timestampMs)
  }

  // MARK: - Single tap (.select with deferred commit)

  func test_singleTap_deferredSelectFires_afterWindow() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0

    // Pinch begin + hold + release. Release itself returns nil because
    // the .select is being held for a possible double-tap.
    XCTAssertNil(r.ingest(indexPinchFrame(timestampMs: ts)))
    ts = 80; advance(ms: 80)
    XCTAssertNil(r.ingest(indexPinchFrame(timestampMs: ts)))
    ts = 120; advance(ms: 40)
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)),
                 "Release should defer, not emit .select immediately")

    // Just past the window — next ingest should commit the deferred .select.
    advance(ms: 301)
    ts += 301
    XCTAssertEqual(r.ingest(releasedFrame(timestampMs: ts)), .select)
  }

  func test_singleTap_selectDoesNotFire_insideWindow() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 100; advance(ms: 100)
    _ = r.ingest(releasedFrame(timestampMs: ts))

    // Within the 300 ms window, no subsequent ingest should fire .select.
    advance(ms: 150); ts += 150
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)))

    // pendingSelect should still be live per the debug snapshot.
    XCTAssertTrue(r.debugState.pendingSelectActive)
  }

  // MARK: - Directional drags (emit immediately, not deferred)

  func test_indexPinchDragRight_emitsRight() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 100; advance(ms: 100)
    // Thumb + indexTip both move to (0.58, 0.5) so the pinch stays closed.
    let held = frame(thumbX: 0.58, thumbY: 0.5, indexX: 0.58, indexY: 0.5, timestampMs: ts)
    _ = r.ingest(held)
    ts = 200; advance(ms: 100)
    let release = frame(thumbX: 0.58, thumbY: 0.5, indexX: 0.9, indexY: 0.5, timestampMs: ts)
    XCTAssertEqual(r.ingest(release), .right)
  }

  func test_indexPinchDragLeft_emitsLeft() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 100; advance(ms: 100)
    _ = r.ingest(frame(thumbX: 0.42, thumbY: 0.5, indexX: 0.42, indexY: 0.5, timestampMs: ts))
    ts = 200; advance(ms: 100)
    let release = frame(thumbX: 0.42, thumbY: 0.5, indexX: 0.9, indexY: 0.5, timestampMs: ts)
    XCTAssertEqual(r.ingest(release), .left)
  }

  func test_indexPinchDragUp_emitsUp() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 100; advance(ms: 100)
    _ = r.ingest(frame(thumbX: 0.5, thumbY: 0.42, indexX: 0.5, indexY: 0.42, timestampMs: ts))
    ts = 200; advance(ms: 100)
    let release = frame(thumbX: 0.5, thumbY: 0.42, indexX: 0.9, indexY: 0.42, timestampMs: ts)
    XCTAssertEqual(r.ingest(release), .up)
  }

  func test_indexPinchDragDown_emitsDown() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 100; advance(ms: 100)
    _ = r.ingest(frame(thumbX: 0.5, thumbY: 0.58, indexX: 0.5, indexY: 0.58, timestampMs: ts))
    ts = 200; advance(ms: 100)
    let release = frame(thumbX: 0.5, thumbY: 0.58, indexX: 0.9, indexY: 0.58, timestampMs: ts)
    XCTAssertEqual(r.ingest(release), .down)
  }

  func test_ambiguousDiagonal_horizontalWins() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 100; advance(ms: 100)
    _ = r.ingest(frame(thumbX: 0.55, thumbY: 0.55, indexX: 0.55, indexY: 0.55, timestampMs: ts))
    ts = 200; advance(ms: 100)
    let release = frame(thumbX: 0.55, thumbY: 0.55, indexX: 0.9, indexY: 0.55, timestampMs: ts)
    // delta = (0.05, 0.05). |dx| == |dy| → horizontal wins → .right.
    XCTAssertEqual(r.ingest(release), .right)
  }

  // MARK: - Double-tap → .back

  func test_doubleTap_emitsBack_notTwoSelects() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0

    // Tap 1: begin + release. Deferred .select, no emit yet.
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 80; advance(ms: 80)
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)))

    // Tap 2: begin within the 300 ms window at the same spot → double-tap
    // candidate. Release with minimal drag → .back.
    ts = 180; advance(ms: 100)
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 230; advance(ms: 50)
    XCTAssertEqual(r.ingest(releasedFrame(timestampMs: ts)), .back)

    // pendingSelect must be cleared — no stray .select leaking out later.
    advance(ms: 500); ts += 500
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)))
  }

  func test_doubleTap_windowExpired_emitsTwoSelects() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0

    // Tap 1.
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 80; advance(ms: 80)
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)))

    // Wait past the window — deferred .select commits on the next ingest.
    advance(ms: 400); ts += 400
    XCTAssertEqual(r.ingest(releasedFrame(timestampMs: ts)), .select,
                   "Deferred .select should commit once the double-tap window closes")

    // Wait past the post-emit cooldown before the next attempt.
    advance(ms: 260); ts += 260

    // Tap 2 — independent gesture, own deferred .select.
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    advance(ms: 80); ts += 80
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)))
    advance(ms: 310); ts += 310
    XCTAssertEqual(r.ingest(releasedFrame(timestampMs: ts)), .select)
  }

  func test_doubleTap_driftTooLarge_suppressesFirstSelect() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0

    // Tap 1 at (0.5, 0.5).
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 80; advance(ms: 80)
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)))

    // Tap 2 at (0.7, 0.5) — 0.2 away, well over doubleTapMaxDrift (0.06).
    // Within the 300 ms window, so pendingSelect is consumed (second pinch
    // starting cancels it), but isDoubleTapCandidate = false. The first
    // .select is silently dropped; the second tap starts fresh.
    ts = 180; advance(ms: 100)
    let secondTap = frame(thumbX: 0.7, thumbY: 0.5, indexX: 0.7, indexY: 0.5, timestampMs: ts)
    _ = r.ingest(secondTap)
    ts = 220; advance(ms: 40)
    let secondRelease = frame(thumbX: 0.7, thumbY: 0.5, indexX: 0.95, indexY: 0.5, timestampMs: ts)
    XCTAssertNil(r.ingest(secondRelease),
                 "Second tap releases as deferred .select — no immediate emit")

    // Second tap's deferred .select commits after its own window.
    advance(ms: 310); ts += 310
    XCTAssertEqual(r.ingest(releasedFrame(timestampMs: ts)), .select)
  }

  func test_doubleTap_secondPinchIsDrag_emitsOnlyDirection() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0

    // Tap 1.
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 80; advance(ms: 80)
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)))

    // Tap 2 starts nearby but the user drags right before releasing →
    // emit .right, suppress the pending .select.
    ts = 180; advance(ms: 100)
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 230; advance(ms: 50)
    _ = r.ingest(frame(thumbX: 0.6, thumbY: 0.5, indexX: 0.6, indexY: 0.5, timestampMs: ts))
    ts = 280; advance(ms: 50)
    let release = frame(thumbX: 0.6, thumbY: 0.5, indexX: 0.95, indexY: 0.5, timestampMs: ts)
    XCTAssertEqual(r.ingest(release), .right)

    // No stray .select after — the suppressed first tap shouldn't leak.
    advance(ms: 500); ts += 500
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)))
  }

  // MARK: - Cooldown

  func test_cooldown_suppressesPinchAfterDirection() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0

    // First gesture: drag right (immediate emit).
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 100; advance(ms: 100)
    _ = r.ingest(frame(thumbX: 0.58, thumbY: 0.5, indexX: 0.58, indexY: 0.5, timestampMs: ts))
    ts = 200; advance(ms: 100)
    let release = frame(thumbX: 0.58, thumbY: 0.5, indexX: 0.9, indexY: 0.5, timestampMs: ts)
    XCTAssertEqual(r.ingest(release), .right)

    // Within cooldown (250 ms). Attempt another pinch — should be ignored.
    ts = 300; advance(ms: 100)
    XCTAssertNil(r.ingest(indexPinchFrame(timestampMs: ts)))
    XCTAssertEqual(r.debugState.fsm, .idle, "Cooldown should block new pinch transitions")

    // After cooldown, fresh gesture fires.
    advance(ms: 300); ts += 300
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    advance(ms: 100); ts += 100
    _ = r.ingest(frame(thumbX: 0.58, thumbY: 0.5, indexX: 0.58, indexY: 0.5, timestampMs: ts))
    advance(ms: 100); ts += 100
    let release2 = frame(thumbX: 0.58, thumbY: 0.5, indexX: 0.9, indexY: 0.5, timestampMs: ts)
    XCTAssertEqual(r.ingest(release2), .right)
  }

  // MARK: - Error paths

  func test_handLostMidPinch_resetsToIdle() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))

    // 6 consecutive empty frames — exceeds maxMissingFramesDuringPinching (4).
    for _ in 0..<6 {
      ts += 33; advance(ms: 33)
      _ = r.ingest(frame(thumbX: 0, thumbY: 0, timestampMs: ts, handPresent: false))
    }

    ts += 100; advance(ms: 100)
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)))
    XCTAssertEqual(r.debugState.fsm, .idle)
  }

  // The 4 s pinch-duration cap was removed — a sustained highlight now
  // stays in `.indexPinching` indefinitely. This block intentionally has
  // no test for an "abandoned hold reset"; the FSM only exits the
  // pinching state on real release, missing-frame timeout, or debounced
  // release jitter (covered by `test_releaseDebounce_*` below).

  // MARK: - Release debounce

  /// Single-frame release jitter mid-pinch is absorbed when the recognizer
  /// is configured with `releaseDebounceFrames > 1`. The pinch survives,
  /// `startThumbPosition` does NOT shift, and the FSM stays in
  /// `.indexPinching`.
  func test_releaseDebounce_singleFrameJitter_doesNotEndPinch() {
    var cfg = PinchDragRecognizer.Config()
    cfg.releaseDebounceFrames = 3
    var r = PinchDragRecognizer(config: cfg, now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    XCTAssertEqual(r.debugState.fsm, .indexPinching)

    // One bad frame — distance jumps above the release threshold.
    ts += 33; advance(ms: 33)
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)))
    XCTAssertEqual(r.debugState.fsm, .indexPinching,
                   "Debounce should keep the FSM in pinching after one stray release frame")

    // Pinch comes back next frame — debounce counter resets.
    ts += 33; advance(ms: 33)
    XCTAssertNil(r.ingest(indexPinchFrame(timestampMs: ts)))
    XCTAssertEqual(r.debugState.fsm, .indexPinching)
  }

  /// Three consecutive release frames commit the release at the default
  /// `releaseDebounceFrames = 3`. Only the third frame fires (or defers)
  /// the classified event.
  func test_releaseDebounce_threeFramesCommitsRelease() {
    var cfg = PinchDragRecognizer.Config()
    cfg.releaseDebounceFrames = 3
    var r = PinchDragRecognizer(config: cfg, now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))

    // Frames 1 and 2 of release — both absorbed, no commit.
    ts += 33; advance(ms: 33)
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)))
    XCTAssertEqual(r.debugState.fsm, .indexPinching)
    ts += 33; advance(ms: 33)
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)))
    XCTAssertEqual(r.debugState.fsm, .indexPinching)

    // Frame 3 — debounce satisfied, classifies as .select, defers.
    ts += 33; advance(ms: 33)
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)),
                 "Third release frame should defer .select for double-tap window")
    XCTAssertEqual(r.debugState.fsm, .idle)
    XCTAssertTrue(r.debugState.pendingSelectActive)
  }

  // MARK: - Orientation gate

  func test_orientationGate_rejectsPinchWithPalmFacingCamera() {
    var r = PinchDragRecognizer(now: clockSource)
    // Flat-palm-facing-camera pose: indexMCP and pinkyMCP at the same z as
    // the wrist. 3D palm normal collapses to pure ±z → palmFacingZ ≈ ±1,
    // far outside the default [-0.5, +0.5] gate.
    let f = frame(
      thumbX: 0.5, thumbY: 0.5,
      indexMCPX: 0.50, indexMCPY: 0.55, indexMCPZ: 0,
      pinkyMCPX: 0.60, pinkyMCPY: 0.60, pinkyMCPZ: 0,
      timestampMs: 0
    )
    XCTAssertNil(r.ingest(f))
    XCTAssertEqual(r.debugState.fsm, .idle,
                   "Gate should block pinch when palm fully faces camera (palmFacingZ ≈ ±1)")
  }

  func test_orientationGate_rejectsPinchWithTooSmallHand() {
    var r = PinchDragRecognizer(now: clockSource)
    let f = frame(
      thumbX: 0.5, thumbY: 0.5,
      wristX: 0.505, wristY: 0.805,
      indexMCPX: 0.495, indexMCPY: 0.795, indexMCPZ: -0.10,
      middleMCPX: 0.495, middleMCPY: 0.795,  // deltas ~0.01, size ~0.014
      pinkyMCPX: 0.505, pinkyMCPY: 0.79, pinkyMCPZ: 0.10,
      timestampMs: 0
    )
    XCTAssertNil(r.ingest(f))
    XCTAssertEqual(r.debugState.fsm, .idle, "Gate should block when handSize < 0.10")
  }

  func test_orientationGate_mayBeDisabledViaConfig() {
    var cfg = PinchDragRecognizer.Config()
    cfg.gateDisabled = true
    var r = PinchDragRecognizer(config: cfg, now: clockSource)
    let f = frame(
      thumbX: 0.5, thumbY: 0.5,
      indexMCPX: 0.50, indexMCPY: 0.55, indexMCPZ: 0,
      pinkyMCPX: 0.60, pinkyMCPY: 0.60, pinkyMCPZ: 0,
      timestampMs: 0
    )
    _ = r.ingest(f)
    XCTAssertEqual(r.debugState.fsm, .indexPinching, "Gate override should let pinch engage")
  }

  func test_orientationGate_allowsReleaseRegardlessOfPose() {
    // Gate is IDLE→pinching only. Once engaged, changing pose during the
    // drag must NOT kill the gesture.
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0

    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    XCTAssertEqual(r.debugState.fsm, .indexPinching)

    ts = 100; advance(ms: 100)
    let midFrame = frame(
      thumbX: 0.58, thumbY: 0.5, indexX: 0.58, indexY: 0.5,
      indexMCPX: 0.50, indexMCPY: 0.55, indexMCPZ: 0,    // pose now OUT of gate
      pinkyMCPX: 0.60, pinkyMCPY: 0.60, pinkyMCPZ: 0,
      timestampMs: ts
    )
    _ = r.ingest(midFrame)
    XCTAssertEqual(r.debugState.fsm, .indexPinching, "Mid-drag pose change must not reset tracking")

    ts = 200; advance(ms: 100)
    let release = frame(
      thumbX: 0.58, thumbY: 0.5, indexX: 0.9, indexY: 0.5,
      indexMCPX: 0.50, indexMCPY: 0.55, indexMCPZ: 0,
      pinkyMCPX: 0.60, pinkyMCPY: 0.60, pinkyMCPZ: 0,
      timestampMs: ts
    )
    XCTAssertEqual(r.ingest(release), .right,
                   "Release classifier ignores orientation; direction still fires")
  }

  // MARK: - Debug exposure

  func test_contactStartEndPositions_persistAcrossRelease() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    XCTAssertNotNil(r.lastContactStartPosition)
    XCTAssertNil(r.lastContactReleasePosition)

    ts = 100; advance(ms: 100)
    _ = r.ingest(frame(thumbX: 0.55, thumbY: 0.5, indexX: 0.55, indexY: 0.5, timestampMs: ts))

    ts = 200; advance(ms: 100)
    _ = r.ingest(releasedFrame(timestampMs: ts))

    XCTAssertNotNil(r.lastContactStartPosition)
    XCTAssertNotNil(r.lastContactReleasePosition)
    XCTAssertNotEqual(r.lastContactStartPosition, r.lastContactReleasePosition)
  }

  // MARK: - Highlights (mid-pinch quadrant pre-fire)

  func test_highlight_firesOnQuadrantEntry() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0

    // Pinch engages — thumb at center.
    XCTAssertNil(r.ingest(indexPinchFrame(timestampMs: ts)))

    // Drag thumb into the right quadrant while keeping contact. dx=0.08
    // is well over selectRadius (0.05).
    ts = 50; advance(ms: 50)
    let right = frame(thumbX: 0.58, thumbY: 0.5, indexX: 0.58, indexY: 0.5, timestampMs: ts)
    XCTAssertEqual(r.ingest(right), .highlightRight)
  }

  func test_highlight_noRepeatsInSameQuadrant() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))

    ts = 50; advance(ms: 50)
    _ = r.ingest(frame(thumbX: 0.58, thumbY: 0.5, indexX: 0.58, indexY: 0.5, timestampMs: ts))

    // Still in the right quadrant — no second highlight.
    ts = 100; advance(ms: 50)
    XCTAssertNil(r.ingest(frame(thumbX: 0.60, thumbY: 0.5, indexX: 0.60, indexY: 0.5, timestampMs: ts)))

    ts = 150; advance(ms: 50)
    XCTAssertNil(r.ingest(frame(thumbX: 0.62, thumbY: 0.5, indexX: 0.62, indexY: 0.5, timestampMs: ts)))
  }

  func test_highlight_firesOnQuadrantChange() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))

    // Right quadrant first.
    ts = 50; advance(ms: 50)
    XCTAssertEqual(
      r.ingest(frame(thumbX: 0.58, thumbY: 0.5, indexX: 0.58, indexY: 0.5, timestampMs: ts)),
      .highlightRight
    )

    // Cross to down (|dy|=0.08 > |dx|=0).
    ts = 100; advance(ms: 50)
    XCTAssertEqual(
      r.ingest(frame(thumbX: 0.5, thumbY: 0.58, indexX: 0.5, indexY: 0.58, timestampMs: ts)),
      .highlightDown
    )

    // Cross to left.
    ts = 150; advance(ms: 50)
    XCTAssertEqual(
      r.ingest(frame(thumbX: 0.42, thumbY: 0.5, indexX: 0.42, indexY: 0.5, timestampMs: ts)),
      .highlightLeft
    )

    // Cross to up.
    ts = 200; advance(ms: 50)
    XCTAssertEqual(
      r.ingest(frame(thumbX: 0.5, thumbY: 0.42, indexX: 0.5, indexY: 0.42, timestampMs: ts)),
      .highlightUp
    )
  }

  func test_highlight_firesAgainWhenRevisitingQuadrant() {
    // Enter right, come back to center (no emit), re-enter right → emit again.
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))

    ts = 50; advance(ms: 50)
    XCTAssertEqual(
      r.ingest(frame(thumbX: 0.58, thumbY: 0.5, indexX: 0.58, indexY: 0.5, timestampMs: ts)),
      .highlightRight
    )

    // Return to center — within selectRadius — no emit, but re-primes.
    ts = 100; advance(ms: 50)
    XCTAssertNil(
      r.ingest(frame(thumbX: 0.5, thumbY: 0.5, indexX: 0.5, indexY: 0.5, timestampMs: ts))
    )

    // Re-enter right — emit again.
    ts = 150; advance(ms: 50)
    XCTAssertEqual(
      r.ingest(frame(thumbX: 0.58, thumbY: 0.5, indexX: 0.58, indexY: 0.5, timestampMs: ts)),
      .highlightRight
    )
  }

  func test_debugState_reflectsCurrentQuadrant() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    XCTAssertNil(r.debugState.currentHighlightQuadrant, "Center → nil")

    ts = 50; advance(ms: 50)
    _ = r.ingest(frame(thumbX: 0.5, thumbY: 0.58, indexX: 0.5, indexY: 0.58, timestampMs: ts))
    XCTAssertEqual(r.debugState.currentHighlightQuadrant, .down)
  }

  // MARK: - Cancel (drift out and back)

  func test_cancel_emittedAfterDriftOutAndBack() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))

    // Drift into right quadrant.
    ts = 50; advance(ms: 50)
    _ = r.ingest(frame(thumbX: 0.58, thumbY: 0.5, indexX: 0.58, indexY: 0.5, timestampMs: ts))

    // Return to center.
    ts = 100; advance(ms: 50)
    _ = r.ingest(frame(thumbX: 0.5, thumbY: 0.5, indexX: 0.5, indexY: 0.5, timestampMs: ts))

    // Release at center — should be .cancel, not .select (not deferred).
    ts = 150; advance(ms: 50)
    XCTAssertEqual(r.ingest(releasedFrame(timestampMs: ts)), .cancel)
  }

  func test_cancel_firesImmediately_notDeferred() {
    // Unlike .select, .cancel does not pay the double-tap latency penalty.
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 50; advance(ms: 50)
    _ = r.ingest(frame(thumbX: 0.58, thumbY: 0.5, indexX: 0.58, indexY: 0.5, timestampMs: ts))
    ts = 100; advance(ms: 50)
    _ = r.ingest(frame(thumbX: 0.5, thumbY: 0.5, indexX: 0.5, indexY: 0.5, timestampMs: ts))
    ts = 150; advance(ms: 50)
    XCTAssertEqual(r.ingest(releasedFrame(timestampMs: ts)), .cancel)
    XCTAssertFalse(r.debugState.pendingSelectActive,
                   "Cancel must not set a pendingSelect; it's not a tap")
  }

  func test_cancel_overridesBackOnDoubleTapDrift() {
    // Tap 1: clean select inside dead zone.
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 80; advance(ms: 80)
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)))

    // Tap 2: starts near same spot — would normally be double-tap candidate.
    // But user drifts out and back → release-classifier returns .cancel, not
    // .select, so FSM emits .cancel instead of .back.
    ts = 180; advance(ms: 100)
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 220; advance(ms: 40)
    _ = r.ingest(frame(thumbX: 0.58, thumbY: 0.5, indexX: 0.58, indexY: 0.5, timestampMs: ts))
    ts = 260; advance(ms: 40)
    _ = r.ingest(frame(thumbX: 0.5, thumbY: 0.5, indexX: 0.5, indexY: 0.5, timestampMs: ts))
    ts = 300; advance(ms: 40)
    XCTAssertEqual(r.ingest(releasedFrame(timestampMs: ts)), .cancel)
  }

  func test_select_stillEmits_whenNoDriftEverHappened() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))

    // Multiple held frames, all within selectRadius — hasEverExitedSelectRadius
    // stays false.
    ts = 50; advance(ms: 50)
    _ = r.ingest(indexPinchFrame(thumbOffset: CGPoint(x: 0.02, y: 0), timestampMs: ts))
    ts = 100; advance(ms: 50)
    _ = r.ingest(indexPinchFrame(thumbOffset: CGPoint(x: -0.02, y: 0.01), timestampMs: ts))

    // Release inside dead zone → deferred .select.
    ts = 150; advance(ms: 50)
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)))

    // After window — fires as .select (not .cancel).
    advance(ms: 310); ts += 310
    XCTAssertEqual(r.ingest(releasedFrame(timestampMs: ts)), .select)
  }

  // MARK: - Debug exposure (double-tap window)

  func test_pendingSelectActive_flipsFalseAfterCommit() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 100; advance(ms: 100)
    _ = r.ingest(releasedFrame(timestampMs: ts))

    XCTAssertTrue(r.debugState.pendingSelectActive, "Should be live inside window")

    advance(ms: 310); ts += 310
    _ = r.ingest(releasedFrame(timestampMs: ts))  // commits the deferred .select
    XCTAssertFalse(r.debugState.pendingSelectActive,
                   "Should clear once the deferred .select has committed")
  }
}

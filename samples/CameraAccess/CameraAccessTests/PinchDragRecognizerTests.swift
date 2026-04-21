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
  // Place indexTip at (0.5, 0.5), middleTip at (0.55, 0.5), thumbTip
  // wherever the test wants. When thumbTip is close to indexTip → index
  // pinch. Close to middleTip → middle pinch. Keep z = 0 everywhere so
  // the z-gate is trivially satisfied in tests (it's exercised separately).

  private func frame(
    thumbX: Float, thumbY: Float, thumbZ: Float = 0,
    indexX: Float = 0.5, indexY: Float = 0.5, indexZ: Float = 0,
    middleX: Float = 0.55, middleY: Float = 0.5, middleZ: Float = 0,
    // Wrist + indexMCP + middleMCP + pinkyMCP positions are chosen so
    // the `HandOrientation` computes handSize ~0.18 AND palmFacingZ in
    // the [-0.5, +0.5] gate range. The trick: indexMCP and pinkyMCP are
    // offset in z (opposite signs) so the 3D palm normal has large x/y
    // components and a small z, landing palmFacingZ near 0.4 — the
    // canonical Meta XR-style edge-on pose. Tests that want to exercise
    // the gate itself pass explicit override values.
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
    pts[12] = HandLandmark2D(x: middleX, y: middleY, z: middleZ)             // middleTip
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

  /// Thumb on middleTip → middle pinch.
  private func middlePinchFrame(timestampMs: Int) -> HandLandmarkFrame {
    frame(thumbX: 0.55, thumbY: 0.5, timestampMs: timestampMs)
  }

  /// Thumb far from both fingers → released.
  private func releasedFrame(timestampMs: Int) -> HandLandmarkFrame {
    frame(thumbX: 0.85, thumbY: 0.5, timestampMs: timestampMs)
  }

  // MARK: - Tests

  func test_indexPinchNoDrag_emitsSelect() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    XCTAssertNil(r.ingest(indexPinchFrame(timestampMs: ts)))
    ts = 80; advance(ms: 80)
    XCTAssertNil(r.ingest(indexPinchFrame(timestampMs: ts)))
    ts = 120; advance(ms: 40)
    XCTAssertEqual(r.ingest(releasedFrame(timestampMs: ts)), .select)
  }

  func test_indexPinchDragRight_emitsRight() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 100; advance(ms: 100)
    // Thumb moves +x by 0.08 while still pinched (indexTip moves with it
    // to keep distance small).
    var f = indexPinchFrame(thumbOffset: CGPoint(x: 0.08, y: 0), timestampMs: ts)
    // Move indexTip along with thumb so pinch distance stays < release threshold.
    f = frame(thumbX: 0.58, thumbY: 0.5, indexX: 0.58, indexY: 0.5, timestampMs: ts)
    _ = r.ingest(f)
    ts = 200; advance(ms: 100)
    // Release — thumb stays at 0.58, fingers spread away.
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
    // Thumb moves up (negative y in image coords).
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

  func test_middlePinchBrief_emitsBack() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(middlePinchFrame(timestampMs: ts))
    ts = 100; advance(ms: 100)
    _ = r.ingest(middlePinchFrame(timestampMs: ts))
    ts = 150; advance(ms: 50)
    let release = releasedFrame(timestampMs: ts)
    XCTAssertEqual(r.ingest(release), .back)
  }

  func test_middlePinchLongHold_noEmit() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(middlePinchFrame(timestampMs: ts))
    // Hold for 500 ms — longer than tapMaxDurationMs (400).
    ts = 500; advance(ms: 500)
    _ = r.ingest(middlePinchFrame(timestampMs: ts))
    ts = 520; advance(ms: 20)
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)))
  }

  func test_indexPriorityWhenBothQualify() {
    // Construct a frame where thumb is close to BOTH fingers. Index
    // should win.
    var r = PinchDragRecognizer(now: clockSource)
    // thumb at (0.52, 0.5); indexTip at (0.50, 0.5), middleTip at (0.53, 0.5).
    // distance to index = 0.02, distance to middle = 0.01 — both under threshold.
    // Index priority means we enter .indexPinching.
    let f = frame(thumbX: 0.52, thumbY: 0.5, indexX: 0.50, indexY: 0.5,
                  middleX: 0.53, middleY: 0.5, timestampMs: 0)
    _ = r.ingest(f)
    XCTAssertEqual(r.debugState.fsm, .indexPinching)
  }

  func test_ambiguousDiagonal_horizontalWins() {
    // Equal |dx| = |dy|. Horizontal wins the tie per config.
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

  func test_cooldown_suppressesSecondEvent() {
    var r = PinchDragRecognizer(now: clockSource)

    // First gesture: quick select.
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 100; advance(ms: 100)
    XCTAssertEqual(r.ingest(releasedFrame(timestampMs: ts)), .select)

    // Second attempted within cooldown (350 ms).
    ts = 200; advance(ms: 100)
    XCTAssertNil(r.ingest(indexPinchFrame(timestampMs: ts)))
    ts = 300; advance(ms: 100)
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)))

    // After cooldown — fresh gesture fires.
    advance(ms: 300); ts = 600
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    ts = 700; advance(ms: 100)
    XCTAssertEqual(r.ingest(releasedFrame(timestampMs: ts)), .select)
  }

  func test_handLostMidPinch_resetsToIdle() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))

    // 6 consecutive empty frames — exceeds maxMissingFramesDuringPinching (4).
    for _ in 0..<6 {
      ts += 33; advance(ms: 33)
      _ = r.ingest(frame(thumbX: 0, thumbY: 0, timestampMs: ts, handPresent: false))
    }

    // Release should not emit — we've already reset.
    ts += 100; advance(ms: 100)
    XCTAssertNil(r.ingest(releasedFrame(timestampMs: ts)))
    XCTAssertEqual(r.debugState.fsm, .idle)
  }

  func test_abandonedHold_exceedsMaxDuration_resets() {
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    // Hold for 5s — exceeds maxPinchDurationMs (4000).
    ts = 5000; advance(ms: 5000)
    XCTAssertNil(r.ingest(indexPinchFrame(timestampMs: ts)))
    XCTAssertEqual(r.debugState.fsm, .idle)
  }

  func test_orientationGate_rejectsPinchWithPalmFacingCamera() {
    var r = PinchDragRecognizer(now: clockSource)
    // Flat-palm-facing-camera pose: indexMCP and pinkyMCP at the same
    // z as the wrist. 3D palm normal collapses to pure ±z → palmFacingZ
    // ≈ ±1, far outside the default [-0.5, +0.5] gate.
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
    // Hand way too small (hand far from camera / MediaPipe losing the hand).
    // Use the edge-on z offsets so palmFacingZ passes, but shrink the
    // wrist→middleMCP distance so handSize falls below 0.10.
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
    // Same palm-facing-camera frame as above; with gate off, pinch
    // should engage.
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
    // Gate is IDLE→pinching only. Once engaged, changing pose during
    // the drag must NOT kill the gesture.
    var r = PinchDragRecognizer(now: clockSource)
    var ts = 0

    // Start in valid pose → pinch engages.
    _ = r.ingest(indexPinchFrame(timestampMs: ts))
    XCTAssertEqual(r.debugState.fsm, .indexPinching)

    // Mid-drag, rotate palm to face camera (palmFacingZ ≈ ±1, out of gate).
    ts = 100; advance(ms: 100)
    let midFrame = frame(
      thumbX: 0.58, thumbY: 0.5, indexX: 0.58, indexY: 0.5,
      indexMCPX: 0.50, indexMCPY: 0.55, indexMCPZ: 0,    // pose now OUT of gate
      pinkyMCPX: 0.60, pinkyMCPY: 0.60, pinkyMCPZ: 0,
      timestampMs: ts
    )
    _ = r.ingest(midFrame)
    XCTAssertEqual(r.debugState.fsm, .indexPinching, "Mid-drag pose change must not reset tracking")

    // Release still classifies normally — no gate applied at release.
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
    // End should have moved from start.
    XCTAssertNotEqual(r.lastContactStartPosition, r.lastContactReleasePosition)
  }
}

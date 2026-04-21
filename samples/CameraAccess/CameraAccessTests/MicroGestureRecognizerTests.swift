import XCTest
@testable import CameraAccess

final class MicroGestureRecognizerTests: XCTestCase {

  // MARK: - Clock fixture

  /// Mutable wall clock fed into the recognizer. Advance in tests by
  /// writing `clock = Date(timeIntervalSince1970: newValue)`.
  private var clock: Date = Date(timeIntervalSince1970: 1_000_000)
  private var clockSource: () -> Date { { self.clock } }

  private func advance(ms: Int) {
    clock = clock.addingTimeInterval(TimeInterval(ms) / 1000.0)
  }

  // MARK: - Frame builder
  //
  // Index finger is laid out along +y at x=0.5, running from indexMCP at
  // (0.5, 0.5) to indexPIP at (0.5, 0.6). This makes:
  //   Axis A = (0, +1)  (along finger, +y)
  //   Axis B for right hand = (-1, 0)  (across finger; rotate (0,1) → (-1,0))
  //
  // Therefore for a RIGHT hand:
  //   Swipe Forward  = thumb moves +y   (positive along A)
  //   Swipe Backward = thumb moves -y   (negative along A)
  //   Swipe Right    = thumb moves -x   (positive B, since B = (-1,0))
  //   Swipe Left     = thumb moves +x   (negative B)
  //
  // For a LEFT hand, B flips sign so Swipe Right = thumb moves +x.

  private func frame(
    thumbX: Float, thumbY: Float,
    handedness: String? = "Right",
    timestampMs: Int,
    handPresent: Bool = true
  ) -> HandLandmarkFrame {
    guard handPresent else {
      return HandLandmarkFrame(landmarks: [], handedness: nil, timestampMs: timestampMs)
    }
    var pts = Array(repeating: HandLandmark2D(x: 0.5, y: 0.5, z: 0), count: 21)
    pts[4] = HandLandmark2D(x: thumbX, y: thumbY, z: 0)  // thumbTip
    pts[5] = HandLandmark2D(x: 0.5, y: 0.5, z: 0)         // indexMCP
    pts[6] = HandLandmark2D(x: 0.5, y: 0.6, z: 0)         // indexPIP (finger length 0.10)
    pts[8] = HandLandmark2D(x: 0.5, y: 0.8, z: 0)         // indexTip (unused by recognizer but sane)
    pts[0] = HandLandmark2D(x: 0.5, y: 0.4, z: 0)         // wrist
    pts[9] = HandLandmark2D(x: 0.55, y: 0.5, z: 0)        // middleMCP
    return HandLandmarkFrame(landmarks: pts, handedness: handedness, timestampMs: timestampMs)
  }

  /// Convenience: a frame where the thumb is in contact with indexMCP-PIP
  /// (distance ≈ 0, well below contactThreshold). Position lands on the
  /// segment itself.
  private func contactFrame(
    thumbX: Float = 0.5,
    thumbY: Float = 0.55,
    handedness: String? = "Right",
    timestampMs: Int
  ) -> HandLandmarkFrame {
    frame(thumbX: thumbX, thumbY: thumbY, handedness: handedness, timestampMs: timestampMs)
  }

  /// Convenience: thumb well clear of the finger (distance > releaseThreshold).
  private func releasedFrame(
    handedness: String? = "Right",
    timestampMs: Int
  ) -> HandLandmarkFrame {
    // 0.3 away from the segment on the +x side — way above the 0.09 release threshold.
    frame(thumbX: 0.8, thumbY: 0.55, handedness: handedness, timestampMs: timestampMs)
  }

  // MARK: - Tests

  func test_swipeForward_cleanTrajectory_emitsForward() {
    var recognizer = MicroGestureRecognizer(now: clockSource)

    // Enter contact at (0.5, 0.55) — on the segment.
    var ts = 0
    XCTAssertNil(recognizer.ingest(contactFrame(timestampMs: ts)))

    // Thumb slides along +y (forward, toward fingertip) — 0.03 normalized.
    ts = 100
    advance(ms: 100)
    XCTAssertNil(recognizer.ingest(contactFrame(thumbY: 0.58, timestampMs: ts)))

    // Release: thumb jumps clear (distance > 0.09 release threshold).
    ts = 200
    advance(ms: 100)
    let event = recognizer.ingest(releasedFrame(timestampMs: ts))
    // Note: classifier uses latestThumbPosition which was 0.58 in the prior
    // in-contact frame, not the release-frame's 0.8. So along = 0.58 - 0.55 = 0.03.
    XCTAssertEqual(event, .swipeForward)
  }

  func test_swipeBackward_negativeAlong_emitsBackward() {
    var recognizer = MicroGestureRecognizer(now: clockSource)
    var ts = 0
    _ = recognizer.ingest(contactFrame(timestampMs: ts))
    ts = 100; advance(ms: 100)
    _ = recognizer.ingest(contactFrame(thumbY: 0.52, timestampMs: ts))
    ts = 200; advance(ms: 100)
    let event = recognizer.ingest(releasedFrame(timestampMs: ts))
    XCTAssertEqual(event, .swipeBackward)
  }

  func test_swipeRight_rightHand_thumbMovesNegativeX_emitsRight() {
    var recognizer = MicroGestureRecognizer(now: clockSource)
    var ts = 0
    _ = recognizer.ingest(contactFrame(timestampMs: ts))
    // For a right hand with our finger layout, Axis B = (-1, 0).
    // Positive B (swipeRight) = thumb moves in -x direction.
    ts = 100; advance(ms: 100)
    _ = recognizer.ingest(contactFrame(thumbX: 0.48, thumbY: 0.55, timestampMs: ts))
    ts = 200; advance(ms: 100)
    let event = recognizer.ingest(releasedFrame(timestampMs: ts))
    XCTAssertEqual(event, .swipeRight)
  }

  func test_swipeLeft_rightHand_thumbMovesPositiveX_emitsLeft() {
    var recognizer = MicroGestureRecognizer(now: clockSource)
    var ts = 0
    _ = recognizer.ingest(contactFrame(timestampMs: ts))
    ts = 100; advance(ms: 100)
    _ = recognizer.ingest(contactFrame(thumbX: 0.52, thumbY: 0.55, timestampMs: ts))
    ts = 200; advance(ms: 100)
    let event = recognizer.ingest(releasedFrame(timestampMs: ts))
    XCTAssertEqual(event, .swipeLeft)
  }

  func test_tap_briefContactZeroMotion_emitsTap() {
    var recognizer = MicroGestureRecognizer(now: clockSource)
    var ts = 0
    _ = recognizer.ingest(contactFrame(timestampMs: ts))
    // Hold briefly with no motion.
    ts = 80; advance(ms: 80)
    _ = recognizer.ingest(contactFrame(timestampMs: ts))
    // Release.
    ts = 120; advance(ms: 40)
    let event = recognizer.ingest(releasedFrame(timestampMs: ts))
    XCTAssertEqual(event, .tap)
  }

  func test_longContactNoMotion_doesNotEmitTap() {
    var recognizer = MicroGestureRecognizer(now: clockSource)
    var ts = 0
    _ = recognizer.ingest(contactFrame(timestampMs: ts))
    // Hold for 500 ms — exceeds tapMaxDurationMs (200).
    ts = 500; advance(ms: 500)
    _ = recognizer.ingest(contactFrame(timestampMs: ts))
    ts = 520; advance(ms: 20)
    let event = recognizer.ingest(releasedFrame(timestampMs: ts))
    XCTAssertNil(event)
  }

  func test_ambiguousDiagonal_noEmit() {
    var recognizer = MicroGestureRecognizer(now: clockSource)
    var ts = 0
    _ = recognizer.ingest(contactFrame(timestampMs: ts))
    // Thumb moves equally along both axes — dominantAxisRatio test fails both ways.
    ts = 100; advance(ms: 100)
    _ = recognizer.ingest(contactFrame(thumbX: 0.47, thumbY: 0.58, timestampMs: ts))
    ts = 200; advance(ms: 100)
    let event = recognizer.ingest(releasedFrame(timestampMs: ts))
    XCTAssertNil(event)
  }

  func test_cooldown_suppressesSecondGestureWithinWindow() {
    var recognizer = MicroGestureRecognizer(now: clockSource)

    // First gesture: clean forward swipe.
    var ts = 0
    _ = recognizer.ingest(contactFrame(timestampMs: ts))
    ts = 100; advance(ms: 100)
    _ = recognizer.ingest(contactFrame(thumbY: 0.58, timestampMs: ts))
    ts = 200; advance(ms: 100)
    let first = recognizer.ingest(releasedFrame(timestampMs: ts))
    XCTAssertEqual(first, .swipeForward)

    // Second gesture attempted 100 ms later — well within the 350 ms cooldown.
    ts = 300; advance(ms: 100)
    XCTAssertNil(recognizer.ingest(contactFrame(timestampMs: ts)))
    ts = 350; advance(ms: 50)
    XCTAssertNil(recognizer.ingest(contactFrame(thumbY: 0.58, timestampMs: ts)))
    ts = 400; advance(ms: 50)
    let second = recognizer.ingest(releasedFrame(timestampMs: ts))
    XCTAssertNil(second, "Second gesture should be suppressed by cooldown")
  }

  func test_cooldown_allowsGestureAfterWindowExpires() {
    var recognizer = MicroGestureRecognizer(now: clockSource)

    var ts = 0
    _ = recognizer.ingest(contactFrame(timestampMs: ts))
    ts = 100; advance(ms: 100)
    _ = recognizer.ingest(contactFrame(thumbY: 0.58, timestampMs: ts))
    ts = 200; advance(ms: 100)
    XCTAssertEqual(recognizer.ingest(releasedFrame(timestampMs: ts)), .swipeForward)

    // Wait out the 350 ms cooldown.
    advance(ms: 400)
    ts = 600

    // Second clean forward swipe — should fire.
    _ = recognizer.ingest(contactFrame(timestampMs: ts))
    ts = 700; advance(ms: 100)
    _ = recognizer.ingest(contactFrame(thumbY: 0.58, timestampMs: ts))
    ts = 800; advance(ms: 100)
    XCTAssertEqual(recognizer.ingest(releasedFrame(timestampMs: ts)), .swipeForward)
  }

  func test_handLostMidTracking_resetsToIdle_noEmit() {
    var recognizer = MicroGestureRecognizer(now: clockSource)
    var ts = 0
    _ = recognizer.ingest(contactFrame(timestampMs: ts))
    ts = 100; advance(ms: 100)
    _ = recognizer.ingest(contactFrame(thumbY: 0.58, timestampMs: ts))

    // Hand drops out for 5 consecutive frames — exceeds maxMissingFramesDuringTracking (4).
    for i in 1...6 {
      ts += 33; advance(ms: 33)
      _ = recognizer.ingest(frame(thumbX: 0, thumbY: 0, timestampMs: ts, handPresent: false))
      _ = i
    }

    // Attempt release — recognizer should already be IDLE and not emit.
    ts += 100; advance(ms: 100)
    let event = recognizer.ingest(releasedFrame(timestampMs: ts))
    XCTAssertNil(event)
    XCTAssertEqual(recognizer.debugState.fsm, .idle)
  }

  func test_abandonedHold_exceedsMaxDuration_resetsToIdle() {
    var recognizer = MicroGestureRecognizer(now: clockSource)
    var ts = 0
    _ = recognizer.ingest(contactFrame(timestampMs: ts))

    // Hold contact for 2500 ms — exceeds maxTrackingDurationMs (2000).
    ts = 2500; advance(ms: 2500)
    XCTAssertNil(recognizer.ingest(contactFrame(thumbY: 0.58, timestampMs: ts)))
    XCTAssertEqual(recognizer.debugState.fsm, .idle)
  }

  func test_handednessFlipPersists_resetsToIdle_noEmit() {
    var recognizer = MicroGestureRecognizer(now: clockSource)
    var ts = 0
    _ = recognizer.ingest(contactFrame(handedness: "Right", timestampMs: ts))
    ts = 33; advance(ms: 33)
    _ = recognizer.ingest(contactFrame(thumbY: 0.56, handedness: "Right", timestampMs: ts))

    // Three consecutive Left frames → reset.
    for _ in 0..<3 {
      ts += 33; advance(ms: 33)
      _ = recognizer.ingest(contactFrame(thumbY: 0.56, handedness: "Left", timestampMs: ts))
    }
    XCTAssertEqual(recognizer.debugState.fsm, .idle)
  }

  func test_handednessLeftHand_swipeLeftIsMirrored() {
    var recognizer = MicroGestureRecognizer(now: clockSource)
    var ts = 0
    _ = recognizer.ingest(contactFrame(handedness: "Left", timestampMs: ts))
    // For LEFT hand, B is flipped → swipeLeft (negative B) means thumb moves in -x.
    ts = 100; advance(ms: 100)
    _ = recognizer.ingest(contactFrame(thumbX: 0.48, thumbY: 0.55, handedness: "Left", timestampMs: ts))
    ts = 200; advance(ms: 100)
    let event = recognizer.ingest(releasedFrame(handedness: "Left", timestampMs: ts))
    XCTAssertEqual(event, .swipeLeft)
  }

  func test_degenerateFingerAxis_noTransitionToTracking() {
    var recognizer = MicroGestureRecognizer(now: clockSource)

    // Collapse indexMCP and indexPIP onto the same point → finger axis = 0.
    var pts = Array(repeating: HandLandmark2D(x: 0.5, y: 0.5, z: 0), count: 21)
    pts[4] = HandLandmark2D(x: 0.5, y: 0.5, z: 0)  // thumb ON the knuckle
    pts[5] = HandLandmark2D(x: 0.5, y: 0.5, z: 0)  // MCP
    pts[6] = HandLandmark2D(x: 0.5, y: 0.5, z: 0)  // PIP collapsed onto MCP
    let bad = HandLandmarkFrame(landmarks: pts, handedness: "Right", timestampMs: 0)

    XCTAssertNil(recognizer.ingest(bad))
    XCTAssertEqual(recognizer.debugState.fsm, .idle,
                   "Degenerate finger axis must not trigger TRACKING")
  }
}

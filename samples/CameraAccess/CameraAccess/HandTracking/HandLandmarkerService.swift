import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MediaPipeTasksVision
import UIKit

/// Wraps the MediaPipe Hand Landmarker (live-stream mode) for the Retrace
/// pipeline. Only file in the app that imports `MediaPipeTasksVision` — every
/// other consumer reads the `HandLandmarkFrame` value type produced here so
/// MediaPipe symbols never leak into view models / views.
///
/// Thread model: `submit(...)` is cheap and safe to call from any thread
/// (typically the AVCapture delivery queue). MediaPipe invokes
/// `handLandmarker(_:didFinishDetection:...)` on its own internal queue;
/// results are synthesized into `HandLandmarkFrame` and delivered via
/// `onResult` on that same queue. Consumers hop to MainActor themselves.
final class HandLandmarkerService: NSObject, @unchecked Sendable {
  enum StartError: Error, LocalizedError {
    case modelMissing
    case mediaPipeInit(Error)

    var errorDescription: String? {
      switch self {
      case .modelMissing:
        return "hand_landmarker.task not bundled in the app."
      case .mediaPipeInit(let underlying):
        return "MediaPipe HandLandmarker init failed: \(underlying.localizedDescription)"
      }
    }
  }

  struct Options {
    var numHands: Int = 1
    var minHandDetectionConfidence: Float = 0.5
    var minHandPresenceConfidence: Float = 0.5
    var minTrackingConfidence: Float = 0.5
  }

  /// Fired on MediaPipe's internal delivery queue after each detection.
  /// Consumers must hop to their own actor/queue before touching UI state.
  var onResult: (@Sendable (HandLandmarkFrame) -> Void)?

  private let options: Options
  private let lock = NSLock()
  private var landmarker: HandLandmarker?
  private var lastSubmittedTimestampMs: Int = -1

  init(options: Options = .init()) {
    self.options = options
    super.init()
  }

  /// Load the model and spin up the live-stream landmarker. Call once per
  /// session lifecycle. Throws `.modelMissing` when the `.task` resource isn't
  /// in the bundle (expected in previews / tests — caller should treat as a
  /// disabled-feature signal, not a crash).
  func start() throws {
    lock.lock()
    defer { lock.unlock() }
    guard landmarker == nil else { return }

    guard let modelPath = HandTrackingConfig.modelBundlePath() else {
      throw StartError.modelMissing
    }

    let mpOptions = HandLandmarkerOptions()
    mpOptions.baseOptions.modelAssetPath = modelPath
    mpOptions.runningMode = .liveStream
    mpOptions.numHands = options.numHands
    mpOptions.minHandDetectionConfidence = options.minHandDetectionConfidence
    mpOptions.minHandPresenceConfidence = options.minHandPresenceConfidence
    mpOptions.minTrackingConfidence = options.minTrackingConfidence
    mpOptions.handLandmarkerLiveStreamDelegate = self

    do {
      landmarker = try HandLandmarker(options: mpOptions)
    } catch {
      throw StartError.mediaPipeInit(error)
    }
    lastSubmittedTimestampMs = -1
  }

  /// Release the MediaPipe graph. Safe to call repeatedly.
  func stop() {
    lock.lock()
    defer { lock.unlock() }
    landmarker = nil
    lastSubmittedTimestampMs = -1
  }

  /// Feed a sample buffer into the landmarker. Safe to call from the AVCapture
  /// delivery queue. No-op if `start()` hasn't been called (or if it threw),
  /// so callers don't need a separate availability gate.
  func submit(sampleBuffer: CMSampleBuffer) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let timestampMs = Int(CMTimeGetSeconds(pts) * 1000.0)
    submit(pixelBuffer: pixelBuffer, timestampMs: timestampMs)
  }

  /// Variant that takes an already-extracted pixel buffer and explicit
  /// millisecond timestamp. Useful when the timestamp comes from a host clock
  /// rather than the buffer's own PTS.
  func submit(pixelBuffer: CVPixelBuffer, timestampMs: Int) {
    // MediaPipe requires strictly increasing timestamps per live-stream invocation.
    // Drop duplicates / backwards frames defensively rather than letting MediaPipe
    // throw — the capture queue can occasionally deliver out-of-order PTSs under
    // load, and a thrown error here would tear down the whole service.
    let landmarkerRef: HandLandmarker?
    let accepted: Bool = lock.withLock {
      if timestampMs <= lastSubmittedTimestampMs {
        return false
      }
      lastSubmittedTimestampMs = timestampMs
      return true
    }
    guard accepted else { return }
    landmarkerRef = lock.withLock { landmarker }
    guard let landmarker = landmarkerRef else { return }

    // Capture buffer is already rotated to portrait by `IPhoneCameraCapture`'s
    // connection.videoRotationAngle = 90, so MediaPipe receives an upright image.
    let image: MPImage
    do {
      image = try MPImage(pixelBuffer: pixelBuffer, orientation: .up)
    } catch {
      return
    }

    do {
      try landmarker.detectAsync(image: image, timestampInMilliseconds: timestampMs)
    } catch {
      // Don't spam; MediaPipe throws transient errors on first few frames while
      // the graph warms up. Silently drop — it'll recover on the next frame.
    }
  }
}

extension HandLandmarkerService: HandLandmarkerLiveStreamDelegate {
  func handLandmarker(
    _ handLandmarker: HandLandmarker,
    didFinishDetection result: HandLandmarkerResult?,
    timestampInMilliseconds: Int,
    error: Error?
  ) {
    let frame = Self.makeFrame(result: result, timestampMs: timestampInMilliseconds)
    onResult?(frame)
  }

  /// Convert MediaPipe's result into our value type. Extracted + `static` so
  /// this conversion is trivially unit-testable (and keeps the delegate method
  /// tiny).
  private static func makeFrame(
    result: HandLandmarkerResult?,
    timestampMs: Int
  ) -> HandLandmarkFrame {
    guard let result,
          let hand = result.landmarks.first
    else {
      return HandLandmarkFrame(landmarks: [], handedness: nil, timestampMs: timestampMs)
    }
    let points = hand.map { lm in
      HandLandmark2D(x: lm.x, y: lm.y, z: lm.z)
    }
    let handedness = result.handedness.first?.first?.categoryName
    return HandLandmarkFrame(
      landmarks: points,
      handedness: handedness,
      timestampMs: timestampMs
    )
  }
}

import Foundation

/// Single source of truth for whether the hand-tracking pipeline is available
/// on this build + device. Kept tiny so other modules can consult it without
/// pulling MediaPipe symbols into their compile graph.
enum HandTrackingConfig {
  static let modelResourceName = "hand_landmarker"
  static let modelResourceExtension = "task"

  /// Minimum interval between frames fed into MediaPipe. AVCaptureSession runs
  /// at ~30 fps on an iPhone 15 rear camera; the hand-landmarker's MediaPipe
  /// graph is cheap on Metal but still ~4-7% sustained CPU. Throttling to
  /// ~15 fps halves the cost while keeping pinch transitions (100-200 ms)
  /// smooth.
  static let ingestMinInterval: TimeInterval = 1.0 / 15.0

  /// Path to the bundled `.task` model. Nil when the resource is missing.
  /// Resolved lazily because `Bundle.main` isn't fully populated at static-init
  /// time for SwiftUI previews and unit tests.
  static func modelBundlePath() -> String? {
    Bundle.main.path(
      forResource: modelResourceName,
      ofType: modelResourceExtension
    )
  }

  /// True iff the `.task` file is bundled. Call this before attaching the
  /// second video output or creating `HandGestureViewModel`. Returns false
  /// for previews / unit tests so nothing tries to load MediaPipe in those
  /// contexts.
  static var isAvailable: Bool {
    modelBundlePath() != nil
  }
}

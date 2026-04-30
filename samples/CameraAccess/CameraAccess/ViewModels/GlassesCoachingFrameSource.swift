import CoreImage
import CoreMedia
import Foundation
import MWDATCamera
import UIKit

/// Off-MainActor fan-out for `VideoFrame`s arriving on the DAT SDK
/// `videoFramePublisher` delivery queue. Mirrors `IPhoneCoachingCameraSource`'s
/// throttle + JPEG-encode-inline + async-send pattern, with two extra outputs:
/// a 10 Hz preview bridge and a hand-tracking handoff. Holds no MainActor state
/// and is `@unchecked Sendable` so the publisher closure can call `submit(_:)`
/// directly without hopping queues.
///
/// All frame processing — UIImage decode for the preview, JPEG encode for
/// Gemini, and MediaPipe `submit` — happens on whatever queue invoked
/// `submit(_:)` (typically DAT's frame delivery queue). The only MainActor
/// hops are a single `@Published` assignment for the preview UIImage and the
/// existing three-gate check inside `sendJpeg`. This matches the iPhone
/// pipeline so glasses sessions don't backpressure the SwiftUI render loop
/// the way the prior MainActor-bound `forwardFrameToGemini(_:)` did.
final class GlassesCoachingFrameSource: @unchecked Sendable {
  private let minInterval: TimeInterval
  private let previewMinInterval: TimeInterval
  private let jpegQuality: CGFloat
  private let ciContext = CIContext()

  private let lock = NSLock()
  private var lastSendAt: Date?
  private var lastPreviewAt: Date?
  private var isEncodingFrame = false

  private let submitHand: (@Sendable (CMSampleBuffer) -> Void)?
  private let sendJpeg: @Sendable (Data) async -> Void
  private let sendPreview: @Sendable (UIImage) async -> Void

  init(
    minInterval: TimeInterval,
    previewMinInterval: TimeInterval = 0.1,
    jpegQuality: CGFloat,
    submitHand: (@Sendable (CMSampleBuffer) -> Void)?,
    sendJpeg: @escaping @Sendable (Data) async -> Void,
    sendPreview: @escaping @Sendable (UIImage) async -> Void
  ) {
    self.minInterval = minInterval
    self.previewMinInterval = previewMinInterval
    self.jpegQuality = jpegQuality
    self.submitHand = submitHand
    self.sendJpeg = sendJpeg
    self.sendPreview = sendPreview
  }

  /// Called from the DAT SDK `videoFramePublisher` delivery queue (off-main).
  /// Three independent paths:
  ///   1. Hand tracking — direct off-main call into `HandLandmarkerService.submit`,
  ///      which is documented Sendable-safe (`@unchecked Sendable`).
  ///   2. Preview — 10 Hz throttled. Decode `videoFrame.makeUIImage()` here on
  ///      the caller's queue; the bridge closure hops the `@Published` preview
  ///      assignment onto MainActor.
  ///   3. Gemini JPEG — 0.5 fps throttled (`minInterval`) plus an
  ///      `isEncodingFrame` re-entry guard so a slow WebSocket send can't pile
  ///      up encodes. JPEG bytes go straight from CVPixelBuffer through
  ///      `CIContext.jpegRepresentation(...)` — no UIImage round-trip, matching
  ///      `IPhoneCoachingCameraSource.makeJpeg(from:)`.
  func submit(_ videoFrame: VideoFrame) {
    let sampleBuffer = videoFrame.sampleBuffer

    submitHand?(sampleBuffer)

    let now = Date()

    let shouldSendPreview: Bool = lock.withLock {
      if let last = lastPreviewAt, now.timeIntervalSince(last) < previewMinInterval {
        return false
      }
      lastPreviewAt = now
      return true
    }
    if shouldSendPreview, let image = videoFrame.makeUIImage() {
      Task { [sendPreview] in
        await sendPreview(image)
      }
    }

    let shouldEncodeJpeg: Bool = lock.withLock {
      if isEncodingFrame { return false }
      if let last = lastSendAt, now.timeIntervalSince(last) < minInterval { return false }
      isEncodingFrame = true
      lastSendAt = now
      return true
    }
    guard shouldEncodeJpeg else { return }

    guard let jpeg = makeJpeg(from: sampleBuffer) else {
      lock.withLock { isEncodingFrame = false }
      return
    }

    Task { [sendJpeg, weak self] in
      await sendJpeg(jpeg)
      self?.lock.withLock { self?.isEncodingFrame = false }
    }
  }

  private func makeJpeg(from sampleBuffer: CMSampleBuffer) -> Data? {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return nil
    }
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let options: [CIImageRepresentationOption: Any] = [
      kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:
        jpegQuality,
    ]
    return ciContext.jpegRepresentation(
      of: ciImage,
      colorSpace: colorSpace,
      options: options
    )
  }
}

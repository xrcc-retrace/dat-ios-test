import AVFoundation
import CoreImage
import CoreMedia
import Foundation

/// Throttles `CMSampleBuffer` frames from `IPhoneCameraCapture` and forwards
/// them to Gemini Live as JPEG bytes at the same rate the glasses path uses
/// (≈0.5 fps by default — `videoMinInterval` 2.0s).
///
/// All frame processing happens on the AVCapture delegate queue that delivered
/// the sample buffer; no hop to MainActor. Lock-protected state for the
/// throttle timestamps keeps this Sendable-safe when `CoachingSessionViewModel`
/// swaps the `sendJpeg` closure from MainActor.
final class IPhoneCoachingCameraSource: @unchecked Sendable {
  private let minInterval: TimeInterval
  private let jpegQuality: CGFloat
  private let ciContext = CIContext()
  private let lock = NSLock()
  private var lastSendAt: Date?
  private var isEncodingFrame = false
  private let sendJpeg: @Sendable (Data) async -> Void

  init(
    minInterval: TimeInterval,
    jpegQuality: CGFloat,
    sendJpeg: @escaping @Sendable (Data) async -> Void
  ) {
    self.minInterval = minInterval
    self.jpegQuality = jpegQuality
    self.sendJpeg = sendJpeg
  }

  /// Called from the AVCaptureVideoDataOutput delegate queue.
  /// Skips the frame if (a) we sent another within `minInterval`, or
  /// (b) a prior JPEG encode is still in flight (avoids piling up Gemini sends
  /// under back-pressure).
  func submit(_ sampleBuffer: CMSampleBuffer) {
    let now = Date()
    lock.lock()
    if isEncodingFrame {
      lock.unlock()
      return
    }
    if let last = lastSendAt, now.timeIntervalSince(last) < minInterval {
      lock.unlock()
      return
    }
    isEncodingFrame = true
    lastSendAt = now
    lock.unlock()

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

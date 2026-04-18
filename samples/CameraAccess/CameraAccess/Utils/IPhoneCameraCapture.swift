import AVFoundation
import Foundation
import UIKit

/// Wraps `AVCaptureSession` for the iPhone-native capture path.
///
/// Delivers `CMSampleBuffer`s off-main so downstream consumers (the recording writer,
/// or the coaching JPEG throttler) can ingest them on their own queues without
/// bouncing through MainActor. Matches the portrait output geometry of the DAT
/// SDK glasses stream (720 × 1280) so the existing `ExpertRecordingManager`
/// writer settings work unchanged.
@MainActor
final class IPhoneCameraCapture: NSObject, ObservableObject {
  enum CaptureError: Error, LocalizedError {
    case permissionDenied
    case noCameraAvailable
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
      switch self {
      case .permissionDenied: return "Camera permission denied."
      case .noCameraAvailable: return "No back camera available on this device."
      case .cannotAddInput: return "Could not attach camera input to the capture session."
      case .cannotAddOutput: return "Could not attach video output to the capture session."
      }
    }
  }

  @Published private(set) var isRunning: Bool = false

  /// Preview layer bound to the session. Install into a `UIView` via
  /// `IPhoneCameraPreview` (UIViewRepresentable).
  let previewLayer: AVCaptureVideoPreviewLayer

  /// Called on the capture delegate queue (serial, off-main) for every decoded
  /// frame. Downstream consumers should be cheap here — enqueue work onto their
  /// own queues; don't block. Setting this value flows through the Sendable
  /// FrameDelegate to avoid main-actor isolation leaking into the AVCapture
  /// delivery path.
  var onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)? {
    get { frameDelegate.handler }
    set { frameDelegate.handler = newValue }
  }

  private let session = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let delegateQueue = DispatchQueue(
    label: "com.retrace.iphone.camera",
    qos: .userInitiated
  )
  private let frameDelegate = FrameDelegate()
  private var isConfigured = false

  override init() {
    self.previewLayer = AVCaptureVideoPreviewLayer(session: session)
    self.previewLayer.videoGravity = .resizeAspectFill
    super.init()
  }

  /// Ask iOS for camera permission. Safe to call repeatedly.
  func requestPermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .video)
    case .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }

  /// Configure (once) and start the capture session.
  /// Must be called after `requestPermission()` returns true.
  func start() async throws {
    try configureIfNeeded()
    if !session.isRunning {
      // `AVCaptureSession.startRunning` blocks briefly; move off MainActor.
      await Task.detached(priority: .userInitiated) { [session] in
        session.startRunning()
      }.value
      let running = session.isRunning
      print("[IPhoneCamera] session.startRunning() → isRunning=\(running)")
      isRunning = running
    }
  }

  func stop() {
    guard session.isRunning else {
      isRunning = false
      return
    }
    // `stopRunning` also blocks; keep it off MainActor.
    let s = session
    Task.detached(priority: .userInitiated) {
      s.stopRunning()
    }
    isRunning = false
  }

  // MARK: - Internals

  private func configureIfNeeded() throws {
    guard !isConfigured else { return }

    session.beginConfiguration()
    defer { session.commitConfiguration() }

    // Do NOT let AVCaptureSession reconfigure AVAudioSession. Our
    // AudioSessionManager (.coachingPhoneOnly / .recordingPhoneOnly) already
    // owns category, mode, mic preference, and speaker override — letting the
    // capture session override those causes FigCaptureSourceRemote -12710 /
    // -17281 XPC races on physical iPhone during coaching startup.
    session.automaticallyConfiguresApplicationAudioSession = false
    // Keep capture sharing our managed audio session rather than spinning up
    // its own (default is `true`; stated explicitly for clarity).
    session.usesApplicationAudioSession = true

    // Match the glasses stream: 1280x720 source at portrait-90° orientation
    // → 720x1280 decoded buffers, which is what ExpertRecordingManager's
    // AVAssetWriter output settings expect.
    if session.canSetSessionPreset(.hd1280x720) {
      session.sessionPreset = .hd1280x720
    }

    // Back camera (wide-angle). Back is right for both expert demonstration
    // and learner task performance with the phone propped up.
    guard
      let camera = AVCaptureDevice.default(
        .builtInWideAngleCamera,
        for: .video,
        position: .back
      )
    else {
      throw CaptureError.noCameraAvailable
    }

    let input: AVCaptureDeviceInput
    do {
      input = try AVCaptureDeviceInput(device: camera)
    } catch {
      throw CaptureError.cannotAddInput
    }
    guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
    session.addInput(input)

    videoOutput.setSampleBufferDelegate(frameDelegate, queue: delegateQueue)
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String:
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    ]
    guard session.canAddOutput(videoOutput) else { throw CaptureError.cannotAddOutput }
    session.addOutput(videoOutput)

    // Portrait output. 90° = portrait on back camera. `videoRotationAngle` is the
    // modern replacement for the deprecated `.portrait` on iOS 17+.
    if let connection = videoOutput.connection(with: .video) {
      if connection.isVideoRotationAngleSupported(90) {
        connection.videoRotationAngle = 90
      }
    }

    // Preview layer should also render portrait.
    if let previewConnection = previewLayer.connection,
       previewConnection.isVideoRotationAngleSupported(90) {
      previewConnection.videoRotationAngle = 90
    }

    isConfigured = true
  }

  /// Sample-buffer delegate — non-MainActor so AVCaptureVideoDataOutput can call
  /// it from its delivery queue. Holds the frame handler under a lock so the
  /// owning VM can reassign it from MainActor without data racing with delivery.
  private final class FrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _handler: (@Sendable (CMSampleBuffer) -> Void)?

    var handler: (@Sendable (CMSampleBuffer) -> Void)? {
      get { lock.withLock { _handler } }
      set { lock.withLock { _handler = newValue } }
    }

    func captureOutput(
      _ output: AVCaptureOutput,
      didOutput sampleBuffer: CMSampleBuffer,
      from connection: AVCaptureConnection
    ) {
      handler?(sampleBuffer)
    }
  }
}

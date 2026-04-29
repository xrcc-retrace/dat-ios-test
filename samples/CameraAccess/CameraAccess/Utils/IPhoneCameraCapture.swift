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

  /// Called on a *separate* capture delegate queue (serial, off-main) for every
  /// decoded frame on the hand-tracking output. Runs at the full capture rate
  /// (~30 fps, BGRA) so MediaPipe can consume without re-converting YUV. The
  /// Gemini coaching path keeps its own throttled YUV output on `videoOutput`.
  /// Only wired when `HandTrackingConfig.isAvailable`.
  var onHandSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)? {
    get { handFrameDelegate.handler }
    set { handFrameDelegate.handler = newValue }
  }

  private let session = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let delegateQueue = DispatchQueue(
    label: "com.retrace.iphone.camera",
    qos: .userInitiated
  )
  private let frameDelegate = FrameDelegate()
  private let handVideoOutput = AVCaptureVideoDataOutput()
  private let handDelegateQueue = DispatchQueue(
    label: "com.retrace.iphone.handtracking",
    qos: .userInitiated
  )
  private let handFrameDelegate = FrameDelegate()
  private var isConfigured = false
  private var prefersLandscapeOutput = false

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

  func stop() async {
    guard session.isRunning else {
      isRunning = false
      return
    }
    // `stopRunning` blocks; keep it off MainActor and `await` it so callers
    // can serialize a fast restart against the prior stop completing.
    let s = session
    await Task.detached(priority: .userInitiated) {
      s.stopRunning()
    }.value
    isRunning = false
  }

  /// Rotate the on-screen preview to match the current interface orientation.
  /// The main capture output's connection stays pinned at 90° — JPEG frames
  /// sent to Gemini keep their portrait-normalized geometry regardless of
  /// which way the phone is held.
  ///
  /// The hand-tracking output, however, follows the preview: MediaPipe
  /// landmarks are normalized to the buffer it processed, and the debug
  /// overlay maps those coords linearly into the on-screen preview rect.
  /// If the buffer were portrait while the preview was landscape (or
  /// vice-versa), markers would land in the wrong place, so the hand
  /// connection rotates with the preview.
  func setPreviewInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
    let angle: CGFloat
    switch orientation {
    case .portrait: angle = 90
    case .landscapeRight: angle = 0
    case .landscapeLeft: angle = 180
    case .portraitUpsideDown: angle = 270
    case .unknown: angle = 90
    @unknown default: angle = 90
    }
    if let connection = previewLayer.connection,
       connection.isVideoRotationAngleSupported(angle) {
      connection.videoRotationAngle = angle
    }
    if let handConnection = handVideoOutput.connection(with: .video),
       handConnection.isVideoRotationAngleSupported(angle) {
      handConnection.videoRotationAngle = angle
    }
  }

  /// Lock both the capture output and the preview to landscape-right (0°) or
  /// portrait (90°). Drives the iPhone expert "Landscape output" toggle —
  /// flipping this before `ExpertRecordingManager.startRecording(width:height:)`
  /// is how we produce 1280×720 landscape MP4s instead of the 720×1280 portrait
  /// default. Preview rotation also locks, so the user sees exactly the framing
  /// that will be written.
  ///
  /// Intentional behavior: when enabled, we pin to `landscapeRight` regardless
  /// of which way the phone is physically held — the recording doesn't follow
  /// device rotation. When disabled, the caller is responsible for restoring
  /// the preview to the current device orientation via
  /// `setPreviewInterfaceOrientation(_:)`.
  func setCaptureLandscapeOutput(_ enabled: Bool) {
    prefersLandscapeOutput = enabled
    applyCaptureRotation(enabled: enabled)
  }

  private func applyCaptureRotation(enabled: Bool) {
    let angle: CGFloat = enabled ? 0 : 90

    if let connection = videoOutput.connection(with: .video),
       connection.isVideoRotationAngleSupported(angle) {
      connection.videoRotationAngle = angle
    }
    if let handConnection = handVideoOutput.connection(with: .video),
       handConnection.isVideoRotationAngleSupported(angle) {
      handConnection.videoRotationAngle = angle
    }
    if enabled,
       let previewConnection = previewLayer.connection,
       previewConnection.isVideoRotationAngleSupported(angle) {
      previewConnection.videoRotationAngle = angle
    }
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

    // Back camera — pick the widest lens this device offers so the preview
    // simulates the Ray-Ban Meta wearable POV (~98° FOV). Priority order:
    //   1. .builtInUltraWideCamera (standalone ultra-wide — available on every
    //                               iPhone that has an ultra-wide module, both
    //                               Pro and non-Pro 11+. Preferred because it
    //                               addresses the lens directly, no zoom
    //                               engagement dance.)
    //   2. .builtInDualWideCamera  (virtual wide+ultra-wide — defensive
    //                               fallback for the rare non-Pro device where
    //                               standalone ultra-wide isn't exposed. Needs
    //                               min-zoom to engage the ultra-wide lens.)
    //   3. .builtInWideAngleCamera (iPhone Air / SE / pre-11 — narrower ~70°
    //                               view, always works. Graceful fallback.)
    //
    // The zoom engagement below is wrapped in try/catch so a failed
    // lockForConfiguration never blocks the session from running.
    let lensPreference: [AVCaptureDevice.DeviceType] = [
      .builtInUltraWideCamera,
      .builtInDualWideCamera,
      .builtInWideAngleCamera,
    ]
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: lensPreference,
      mediaType: .video,
      position: .back
    )
    var selected: AVCaptureDevice?
    for preferred in lensPreference {
      if let match = discovery.devices.first(where: { $0.deviceType == preferred }) {
        selected = match
        break
      }
    }
    guard let camera = selected else {
      throw CaptureError.noCameraAvailable
    }
    print("[IPhoneCamera] Selected lens: \(camera.deviceType.rawValue) — \(camera.localizedName)")

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

    // Second output — hand tracking. Lives on its own serial queue + delegate
    // so MediaPipe inference can never back-pressure the Gemini coaching
    // stream. BGRA pixel format (vs. YUV on the primary output) because
    // MediaPipe's `MPImage(pixelBuffer:)` ingests BGRA cheaper than re-
    // converting the biplanar YUV buffer internally. Attached only when the
    // model file is bundled so non-hand-tracking builds (previews / future
    // trimmed targets) don't pay the per-frame buffer-allocation cost.
    if HandTrackingConfig.isAvailable {
      handVideoOutput.setSampleBufferDelegate(handFrameDelegate, queue: handDelegateQueue)
      handVideoOutput.alwaysDiscardsLateVideoFrames = true
      handVideoOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
      if session.canAddOutput(handVideoOutput) {
        session.addOutput(handVideoOutput)
        if let handConnection = handVideoOutput.connection(with: .video),
           handConnection.isVideoRotationAngleSupported(90) {
          handConnection.videoRotationAngle = 90
        }
      } else {
        print("[IPhoneCamera] Could not add hand-tracking output — continuing without hand tracking")
      }
    }

    // Preview layer should also render portrait.
    if let previewConnection = previewLayer.connection,
       previewConnection.isVideoRotationAngleSupported(90) {
      previewConnection.videoRotationAngle = 90
    }

    // Reapply any output orientation the view requested before async camera
    // configuration finished, so the first recording matches the current UI
    // toggle state.
    applyCaptureRotation(enabled: prefersLandscapeOutput)

    // Standalone .builtInUltraWideCamera is already addressing the ultra-wide
    // lens directly — no zoom change needed. For .builtInDualWideCamera
    // (defensive fallback), setting videoZoomFactor to the device's minimum
    // physically engages the ultra-wide lens (same mechanism as the "0.5x"
    // toggle in the system Camera app). The wide-angle fallback doesn't
    // support sub-1.0x zoom.
    //
    // Wrapped in try/catch so a lockForConfiguration failure (extremely rare
    // during startup, but possible if another process holds the camera) is
    // logged and the session continues at default zoom rather than crashing.
    switch camera.deviceType {
    case .builtInDualWideCamera:
      do {
        try camera.lockForConfiguration()
        let minZoom = camera.minAvailableVideoZoomFactor
        camera.videoZoomFactor = minZoom
        camera.unlockForConfiguration()
        print("[IPhoneCamera] Engaged ultra-wide via zoom=\(minZoom) (range \(camera.minAvailableVideoZoomFactor)…\(camera.maxAvailableVideoZoomFactor))")
      } catch {
        print("[IPhoneCamera] lockForConfiguration failed (\(error)) — keeping default zoom (wide lens)")
      }
    default:
      print("[IPhoneCamera] Using \(camera.deviceType.rawValue) at default zoom — no zoom engagement needed")
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

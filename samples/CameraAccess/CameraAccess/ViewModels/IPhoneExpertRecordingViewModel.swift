import AVFoundation
import Combine
import CoreMedia
import Foundation
import SwiftUI

/// iPhone-native counterpart to `StreamSessionViewModel`. Owns an
/// `AVCaptureSession` (via `IPhoneCameraCapture`), the same `ExpertRecordingManager`
/// the glasses path uses, and an `AudioSessionManager` pinned to the built-in mic.
///
/// Lifecycle:
///   1. User lands on `IPhoneRecordingView` → `prepare()` requests camera + mic
///      permission and starts the capture session (preview goes live).
///   2. User taps record → `startRecording()` fires the existing
///      `ExpertRecordingManager.startRecording()` (writer + audio capture).
///      Sample buffers already flowing from the capture session feed into
///      `recordingManager.appendVideoFrame(_:)` while `isRecording` is true.
///   3. User taps stop → `stopRecording()` finalizes the `.mp4`, sets
///      `showRecordingReview = true` and the existing review sheet takes over.
///   4. On view disappear → `teardown()` stops the capture session + unsets
///      the sample-buffer callback.
@MainActor
final class IPhoneExpertRecordingViewModel: ObservableObject {
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var isPreviewLive: Bool = false

  // Mirror the glasses-path surface so views can reuse ExpertRecordingReviewView.
  @Published var showRecordingReview: Bool = false
  let audioSessionManager = AudioSessionManager(mode: .recordingPhoneOnly)
  lazy var recordingManager = ExpertRecordingManager(audioSessionManager: audioSessionManager)
  let uploadService: UploadService
  let camera = IPhoneCameraCapture()

  /// State layer behind the Expert HUD — tip rotation, audio meter
  /// smoothing, transcript, mic-source. Bound to the audio manager +
  /// transcriber in `init`.
  let hudViewModel = ExpertRecordingHUDViewModel()

  /// On-device speech recognizer for the HUD's rolling transcript card.
  /// Started when recording begins, stopped when it ends.
  let speechTranscriber = SpeechTranscriber()

  /// MediaPipe hand-landmark service. Shares the same `HandTrackingConfig`
  /// gate as the Learner Coaching path — model file bundled → available.
  /// Owned here so the lifecycle matches the camera's. Mirrors
  /// `GeminiLiveSessionBase.handLandmarkerService`.
  private var handLandmarkerService: HandLandmarkerService?

  private var recordingManagerCancellable: AnyCancellable?

  init(uploadService: UploadService) {
    self.uploadService = uploadService
    // SwiftUI doesn't chain observation into nested ObservableObjects, so
    // without this bridge the Start/Stop toggle and timer overlay never
    // redraw when `recordingManager.isRecording` / `recordingDuration` flip.
    // Force the lazy var to materialize, then re-emit its objectWillChange
    // through the outer VM so any subview observing `self` rebuilds.
    let manager = recordingManager
    recordingManagerCancellable = manager.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.objectWillChange.send() }

    hudViewModel.bind(
      audioSessionManager: audioSessionManager,
      speechTranscriber: speechTranscriber
    )
  }

  var previewLayer: AVCaptureVideoPreviewLayer {
    camera.previewLayer
  }

  // MARK: - Session lifecycle

  /// Request permissions and bring up the capture session. Safe to call more
  /// than once — `IPhoneCameraCapture.start()` is idempotent.
  func prepare() async {
    // Defensive reset in case SwiftUI ever caches this @StateObject across
    // presentations. Today a new VM is built on each fullScreenCover, but
    // these resets cost nothing and guard the invariant.
    showError = false
    errorMessage = ""
    showRecordingReview = false

    let cameraGranted = await camera.requestPermission()
    guard cameraGranted else {
      surfaceError("Camera permission denied — open Settings to grant access.")
      return
    }

    let micGranted = await audioSessionManager.requestMicrophonePermission()
    guard micGranted else {
      surfaceError("Microphone permission denied — open Settings to grant access.")
      return
    }

    camera.onSampleBuffer = { [weak self] sampleBuffer in
      guard let self else { return }
      // Hop to MainActor so we can read `recordingManager.isRecording` and call
      // the @MainActor API; `appendVideoFrame` itself dispatches to its serial
      // `recordingQueue`, so the hop only pays for the gate check.
      Task { @MainActor in
        guard self.recordingManager.isRecording else { return }
        self.recordingManager.appendVideoFrame(sampleBuffer)
      }
    }

    startHandTrackingIfAvailable()

    do {
      try await camera.start()
      isPreviewLive = camera.isRunning
    } catch {
      surfaceError("Could not start iPhone camera: \(error.localizedDescription)")
    }
  }

  /// Spin up the MediaPipe hand landmarker and wire the camera's secondary
  /// BGRA output into it. Feeds each detection into the HUD view model,
  /// which handles both the landmark-overlay publish and the gesture
  /// recognizer. No-op when `HandTrackingConfig.isAvailable` is false
  /// (model file not bundled, previews, etc.) so the rest of the pipeline
  /// runs unchanged on devices without the `.task` asset.
  private func startHandTrackingIfAvailable() {
    guard HandTrackingConfig.isAvailable else {
      print("[Expert] Hand tracking unavailable — model not bundled")
      return
    }

    // Fresh recognizer state + cleared debug log per camera session so
    // no stale TRACKING state carries over from a prior recording view.
    // Tip cycling is now installed by the focus engine (see
    // `ExpertTipPageHandler` on `ExpertNarrationTipPage`), not via a
    // service-level `onEvent` hook.
    hudViewModel.resetHandTracking()

    let service = HandLandmarkerService()
    do {
      try service.start()
    } catch {
      print("[Expert] Hand tracking disabled: \(error.localizedDescription)")
      return
    }

    service.onResult = { [weak self] frame in
      Task { @MainActor in
        self?.hudViewModel.ingestHandFrame(frame)
      }
    }
    handLandmarkerService = service

    camera.onHandSampleBuffer = { [weak service] sampleBuffer in
      service?.submit(sampleBuffer: sampleBuffer)
    }
    print("[Expert] Hand tracking started — pinch-drag recognizer armed")
  }

  /// Start the mp4 writer + audio tap. Video frames are already arriving from
  /// the capture session; `ExpertRecordingManager` only forwards them once
  /// `isRecording` is true. The manager's `startRecording()` is `async` so
  /// that the AVAssetWriter + audio session setup can run off the main
  /// thread; we fire-and-forget the Task here — the manager flips
  /// `isStarting` / `isRecording` published flags as it progresses.
  ///
  /// `landscape` picks the writer dimensions (1280×720 landscape vs 720×1280
  /// portrait). The caller must have already flipped
  /// `camera.setCaptureLandscapeOutput(_:)` so frames arrive at the matching
  /// rotation before the writer sees them.
  func startRecording(landscape: Bool) {
    guard isPreviewLive else {
      surfaceError("Camera isn't ready yet.")
      return
    }
    let size = landscape
      ? ExpertRecordingManager.landscapeSize
      : ExpertRecordingManager.portraitSize
    Task { [weak self] in
      guard let self else { return }
      await self.recordingManager.startRecording(width: size.width, height: size.height)
      // Bring up the on-device transcriber AFTER the writer is armed — the
      // mic tap is live at that point. Install it as the *secondary* audio
      // consumer so the writer can never be starved by a slow speech
      // callback.
      await self.speechTranscriber.start()
      self.audioSessionManager.installSecondaryAudioConsumer { [weak self] buffer, _ in
        self?.speechTranscriber.append(buffer)
      }
    }
  }

  /// Finalize the mp4, then trigger the review sheet. Mirrors the glasses path.
  func stopRecording() {
    Task { [weak self] in
      guard let self else { return }
      // Tear down transcription first so late buffers can't land in a
      // recognizer whose session is about to close.
      self.audioSessionManager.removeSecondaryAudioConsumer()
      self.speechTranscriber.stop()
      _ = await self.recordingManager.stopRecording()
      // `recordingManager.recordingURL` is set before `stopRecording` returns.
      if self.recordingManager.recordingURL != nil {
        self.showRecordingReview = true
      } else {
        self.surfaceError("Recording failed — no usable video was captured.")
      }
    }
  }

  /// Stop capture session and drop the sample-buffer callback. Call from
  /// `onDisappear` so the AVCaptureSession doesn't keep running when the
  /// user backs out.
  func teardown() {
    camera.stop()
    camera.onSampleBuffer = nil
    camera.onHandSampleBuffer = nil
    handLandmarkerService?.stop()
    handLandmarkerService = nil
    hudViewModel.resetHandTracking()
    isPreviewLive = false
    audioSessionManager.removeSecondaryAudioConsumer()
    speechTranscriber.stop()
  }

  // MARK: - Error surfacing

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  private func surfaceError(_ message: String) {
    errorMessage = message
    showError = true
  }
}

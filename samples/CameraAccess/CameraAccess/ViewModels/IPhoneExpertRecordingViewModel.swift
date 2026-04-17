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

    do {
      try await camera.start()
      isPreviewLive = camera.isRunning
    } catch {
      surfaceError("Could not start iPhone camera: \(error.localizedDescription)")
    }
  }

  /// Start the mp4 writer + audio tap. Video frames are already arriving from
  /// the capture session; `ExpertRecordingManager` only forwards them once
  /// `isRecording` is true.
  func startRecording() {
    guard isPreviewLive else {
      surfaceError("Camera isn't ready yet.")
      return
    }
    recordingManager.startRecording()
  }

  /// Finalize the mp4, then trigger the review sheet. Mirrors the glasses path.
  func stopRecording() {
    Task { [weak self] in
      guard let self else { return }
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
    isPreviewLive = false
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

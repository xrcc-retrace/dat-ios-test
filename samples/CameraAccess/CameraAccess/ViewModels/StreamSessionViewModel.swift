/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Core view model demonstrating video streaming from Meta wearable devices using the DAT SDK.
// This class showcases the key streaming patterns: device selection, session management,
// video frame handling, photo capture, and error handling.
//

import Combine
import MWDATCamera
import MWDATCore
import SwiftUI

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  /// Preview-source ready signal — surface-parallel with
  /// `IPhoneExpertRecordingViewModel.isPreviewLive` so the unified
  /// `IPhoneRecordingView` chrome (Start CTA enable gate, spinner) can read
  /// the same property regardless of transport. True once the first
  /// glasses frame arrives.
  var isPreviewLive: Bool { hasReceivedFirstFrame }

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false

  // Recording properties
  @Published var showRecordingReview: Bool = false
  let audioSessionManager = AudioSessionManager(mode: .recording)
  lazy var recordingManager = ExpertRecordingManager(audioSessionManager: audioSessionManager)
  let uploadService: UploadService

  /// State layer behind the Expert HUD — tip rotation, audio meter
  /// smoothing, mic-source. Surface-parallel with
  /// `IPhoneExpertRecordingViewModel.hudViewModel` so the same
  /// `ExpertNarrationTipPage` works on glasses transport too.
  let hudViewModel = ExpertRecordingHUDViewModel()

  /// Bridge so SwiftUI subviews observing this VM rebuild when the
  /// recording manager (a nested ObservableObject) emits — same trick
  /// `IPhoneExpertRecordingViewModel` uses.
  private var recordingManagerCancellable: AnyCancellable?

  /// MediaPipe hand-landmark service. Lifecycle matches the streaming
  /// session — started in `prepare()`, stopped in `teardown()`. Mirrors
  /// `IPhoneExpertRecordingViewModel.handLandmarkerService`.
  private var handLandmarkerService: HandLandmarkerService?

  /// Preview is throttled at ~10 Hz so MainActor work doesn't compete with the
  /// writer for CPU — the writer needs every frame at full rate.
  private var lastPreviewUpdateAt: Date = .distantPast

  // The core DAT SDK StreamSession — handles all streaming operations.
  // In 0.6 StreamSession is a Capability attached to a DeviceSession and has no
  // public initializer. We create the session lazily in `startSession()` so a
  // missing eligible device at construction time doesn't kill the VM — instead
  // we can report it when the user actually taps "Start streaming".
  private var deviceSession: DeviceSession?
  private var streamSession: StreamSession?
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceMonitorTask: Task<Void, Never>?

  init(wearables: WearablesInterface, uploadService: UploadService) {
    self.wearables = wearables
    self.uploadService = uploadService
    // Let the SDK auto-select from available devices
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)

    // Mirror IPhoneExpertRecordingViewModel: SwiftUI doesn't chain observation
    // into nested ObservableObjects, so without this bridge the Start/Stop
    // toggle and timer overlay never redraw when `recordingManager.isRecording`
    // / `recordingDuration` flip. Force the lazy var to materialize, then
    // re-emit its `objectWillChange` through this outer VM.
    let manager = recordingManager
    recordingManagerCancellable = manager.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in self?.objectWillChange.send() }

    hudViewModel.bind(audioSessionManager: audioSessionManager)

    // Monitor device availability (independent of any session lifecycle).
    // `[weak self]` breaks the retain cycle: without it, `self` is strongly
    // captured by the long-running for-await loop, and the Task (owned by
    // `deviceMonitorTask`) holds `self` alive past view dismissal — so the
    // VM never deallocates between recordings.
    let selector = deviceSelector
    deviceMonitorTask = Task { [weak self] in
      for await device in selector.activeDeviceStream() {
        guard let self = self else { return }
        await MainActor.run {
          self.hasActiveDevice = device != nil
        }
      }
    }
  }

  deinit {
    deviceMonitorTask?.cancel()
  }

  // MARK: - Surface-parallel API for `IPhoneRecordingView`

  /// Glasses-path counterpart to `IPhoneExpertRecordingViewModel.prepare()`.
  /// Asks for camera permission, brings up the streaming session, and starts
  /// hand tracking so the HUD's pinch-drag / double-pinch back gestures work
  /// during recording.
  func prepare() async {
    showError = false
    errorMessage = ""
    showRecordingReview = false

    await handleStartStreaming()
    startHandTrackingIfAvailable()
  }

  /// Mirror of `IPhoneExpertRecordingViewModel.startRecording(landscape:)` so
  /// the unified recording chrome can call the same method on either VM.
  func startRecording(landscape: Bool) {
    guard isPreviewLive else {
      showError("Glasses preview isn't ready yet.")
      return
    }
    let size = landscape
      ? ExpertRecordingManager.landscapeSize
      : ExpertRecordingManager.portraitSize
    Task { [weak self] in
      guard let self else { return }
      await self.recordingManager.startRecording(width: size.width, height: size.height)
    }
  }

  /// Mirror of `IPhoneExpertRecordingViewModel.stopRecording()`. Finalizes
  /// the mp4 and triggers the review sheet.
  func stopRecording() {
    Task { [weak self] in
      guard let self else { return }
      _ = await self.recordingManager.stopRecording()
      if self.recordingManager.recordingURL != nil {
        self.showRecordingReview = true
      } else {
        self.reportRecordingFailure()
      }
    }
  }

  /// Mirror of `IPhoneExpertRecordingViewModel.teardown()`. Stops streaming,
  /// drops the hand-tracking pipeline, and resets preview state.
  func teardown() {
    Task { [weak self] in
      await self?.stopSession()
    }
    handLandmarkerService?.stop()
    handLandmarkerService = nil
    hudViewModel.resetHandTracking()
  }

  /// Spin up the MediaPipe hand landmarker and pipe glasses video frames
  /// into it via the existing `videoFrameListenerToken` (see
  /// `attachStreamListeners`). Mirrors
  /// `IPhoneExpertRecordingViewModel.startHandTrackingIfAvailable()`.
  private func startHandTrackingIfAvailable() {
    guard HandTrackingConfig.isAvailable else {
      print("[Expert/Glasses] Hand tracking unavailable — model not bundled")
      return
    }
    if HandGestureService.isDisabled {
      print("[Expert/Glasses] Hand tracking suppressed by user setting")
      return
    }

    hudViewModel.resetHandTracking()

    let service = HandLandmarkerService()
    do {
      try service.start()
    } catch {
      print("[Expert/Glasses] Hand tracking disabled: \(error.localizedDescription)")
      return
    }

    service.onResult = { [weak self] frame in
      Task { @MainActor in
        self?.hudViewModel.ingestHandFrame(frame)
      }
    }
    handLandmarkerService = service
    print("[Expert/Glasses] Hand tracking started — pinch-drag recognizer armed")
  }

  func handleStartStreaming() async {
    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      if requestStatus == .granted {
        await startSession()
        return
      }
      showError("Permission denied")
    } catch {
      showError("Permission error: \(error.description)")
    }
  }

  func startSession() async {
    // If a prior session was torn down or never created, build it now (0.6 API).
    if streamSession == nil {
      do {
        let config = StreamSessionConfig(
          videoCodec: .raw,
          resolution: .high,
          frameRate: 30)
        let session = try wearables.createSession(deviceSelector: deviceSelector)
        guard let stream = try session.addStream(config: config) else {
          showError("Could not attach streaming capability to the device session.")
          return
        }
        deviceSession = session
        streamSession = stream
        attachStreamListeners(stream)
        updateStatusFromState(stream.state)
        try session.start()
      } catch let error as DeviceSessionError {
        showError("Failed to start device session: \(error.localizedDescription)")
        deviceSession = nil
        streamSession = nil
        return
      } catch {
        showError("Failed to start device session: \(error.localizedDescription)")
        deviceSession = nil
        streamSession = nil
        return
      }
    }
    await streamSession?.start()
  }

  /// Wire DAT SDK listeners to the freshly-created StreamSession.
  private func attachStreamListeners(_ stream: StreamSession) {
    // Session state changes tell us when streaming starts, stops, or encounters issues.
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.updateStatusFromState(state)
      }
    }

    // Video frames from the device camera.
    // Every frame: pass the CMSampleBuffer straight to the writer (cheap — just an
    // enqueue onto recordingQueue), and forward to the hand landmarker for HUD
    // gesture detection. Preview (`makeUIImage` + SwiftUI rerender) is
    // throttled to ~10 Hz so MainActor isn't burning CPU on display work that
    // competes with the recording path.
    //
    // Per-frame work is hopped onto MainActor — `handLandmarkerService` is
    // a `@MainActor`-isolated property and Swift's data-race checker
    // requires that access happen from MainActor. `submit(sampleBuffer:)`
    // immediately delegates to MediaPipe's async detect path, so doing the
    // hop costs only a queue dispatch.
    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] videoFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }

        self.handLandmarkerService?.submit(sampleBuffer: videoFrame.sampleBuffer)

        if self.recordingManager.isRecording {
          self.recordingManager.appendVideoFrame(videoFrame.sampleBuffer)
        }

        let now = Date()
        guard now.timeIntervalSince(self.lastPreviewUpdateAt) >= 0.1 else { return }
        self.lastPreviewUpdateAt = now
        if let image = videoFrame.makeUIImage() {
          self.currentVideoFrame = image
          if !self.hasReceivedFirstFrame {
            self.hasReceivedFirstFrame = true
          }
        }
      }
    }

    // Streaming errors (device disconnection, streaming failures, etc).
    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let newErrorMessage = formatStreamingError(error)
        if newErrorMessage != self.errorMessage {
          showError(newErrorMessage)
        }
      }
    }

    // Photo capture events. PhotoData contains the image in the requested format.
    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let uiImage = UIImage(data: photoData.data) {
          self.capturedPhoto = uiImage
          self.showPhotoPreview = true
        }
      }
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func stopSession() async {
    // Drop listeners before stopping so trailing frame/state events can't
    // push into a half-torn-down VM.
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil

    await streamSession?.stop()
    deviceSession?.stop()
    streamSession = nil
    deviceSession = nil

    // Reset published UI state so re-entering the view starts from a
    // clean slate instead of flashing the prior session's last frame.
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
    capturedPhoto = nil
    showPhotoPreview = false
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func reportRecordingFailure() {
    showError("Recording failed — no usable video was captured. Please try again.")
  }

  func capturePhoto() {
    streamSession?.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func updateStatusFromState(_ state: StreamSessionState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
    }
  }

  private func formatStreamingError(_ error: StreamSessionError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    case .thermalCritical:
      return "Device is overheating. Streaming has been paused to protect the device."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }
}

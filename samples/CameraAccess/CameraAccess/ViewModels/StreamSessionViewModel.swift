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
      for await deviceId in selector.activeDeviceStream() {
        guard let self = self else { return }
        // Log every device-availability flip so we can correlate
        // glasses pair / hinge events with subsequent stream
        // failures. `activeDeviceStream` yields a `DeviceIdentifier?`
        // (typealias for `String?`), so the optional itself is the
        // "is anything paired" signal.
        print("[Glasses] activeDeviceStream → \(deviceId ?? "<none>")")
        await MainActor.run {
          self.hasActiveDevice = deviceId != nil
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
    print("[Glasses] prepare() begin (hasActiveDevice=\(hasActiveDevice))")
    defer { print("[Glasses] prepare() end") }

    // Glasses path runs DAT BEFORE audio prewarm. Reason:
    // `.recording` mode's prewarm calls `setActive(true)` with
    // `.allowBluetoothHFP`, which makes iOS grab the HFP channel for
    // the mic. The DAT SDK's link to the glasses shares that same BT
    // pipe — flipping the audio session active first destabilizes the
    // device for ~tens of ms, just long enough for `addStream(config:)`
    // to find the device un-eligible and return nil ("Could not attach
    // streaming capability — the glasses dropped before the stream
    // could open"). Bringing the DAT stream up first lets it establish
    // against a quiet BT link; the subsequent audio prewarm then
    // settles the AVAudioSession on top of an already-active stream
    // without disturbing it.
    //
    // The iPhone path inverts this — prewarm is fine first there
    // because `.recordingPhoneOnly` doesn't claim HFP at all.
    print("[Glasses] prepare() → handleStartStreaming")
    await handleStartStreaming()
    print("[Glasses] prepare() → startHandTrackingIfAvailable")
    startHandTrackingIfAvailable()
    print("[Glasses] prepare() → audioSessionManager.prewarm")
    await audioSessionManager.prewarm()
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
      // Surface audio/writer start failures so a wedged audio engine
      // doesn't silently produce a silent mp4. Mirrors the iPhone path.
      if let err = await self.recordingManager.startRecording(width: size.width, height: size.height) {
        self.showError(err.errorDescription ?? "Couldn't start recording.")
      }
    }
  }

  /// Mirror of `IPhoneExpertRecordingViewModel.stopRecording()`. Finalizes
  /// the mp4 and returns the captured `(URL, duration)` tuple so the
  /// caller can dismiss the recording view and route into the review
  /// flow without keeping the glasses stream alive in the background.
  func stopRecording() async -> (URL, TimeInterval)? {
    let duration = recordingManager.recordingDuration
    _ = await recordingManager.stopRecording()
    if let url = recordingManager.recordingURL {
      return (url, duration)
    }
    reportRecordingFailure()
    return nil
  }

  /// Mirror of `IPhoneExpertRecordingViewModel.teardown()`. Stops streaming,
  /// drops the hand-tracking pipeline, and resets preview state. Also
  /// deactivates the AVAudioSession so leaving Expert mode lets other
  /// apps' background audio resume — `stopCapture` only flips the
  /// category for recording modes, it doesn't deactivate.
  func teardown() {
    Task { [weak self] in
      await self?.stopSession()
    }
    handLandmarkerService?.stop()
    handLandmarkerService = nil
    hudViewModel.resetHandTracking()
    audioSessionManager.deactivate()
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
    //
    // Order of operations matches Meta's canonical 0.6 sample:
    //   1. createSession
    //   2. session.start()                ← MUST come before addStream
    //   3. session.addStream(config:)
    //   4. stream.start() (below)
    //
    // Calling addStream while the DeviceSession is still `.idle` makes
    // the SDK return nil (the "Could not attach streaming capability"
    // alert) — addStream's contract requires the session to be at least
    // `.starting` / `.started`. We previously had steps 2 and 3 in
    // reverse order, which is why fresh-launch glasses recordings
    // intermittently failed to attach.
    if streamSession == nil {
      // Pre-gate: if no eligible device is on stream yet, the
      // `.noEligibleDevice` throw further down would tell us the same
      // thing in worse language. Surface a clearer message instead.
      guard hasActiveDevice else {
        print("[Glasses] startSession() → no active device, bailing")
        showError("No glasses available. Make sure they're paired and the hinges are open.")
        return
      }

      do {
        print("[Glasses] startSession() → wearables.createSession(deviceSelector:)")
        let session = try wearables.createSession(deviceSelector: deviceSelector)
        print("[Glasses] createSession ✓ (state=\(session.state))")

        // Start the device session FIRST. Without this, the next
        // addStream call sees a `.idle` session and returns nil.
        do {
          print("[Glasses] session.start() → …")
          try session.start()
          print("[Glasses] session.start() ✓ (state=\(session.state))")
        } catch {
          // Surface the start failure directly and don't proceed —
          // calling addStream on a session that failed to start would
          // throw `.sessionIdle` anyway.
          print("[Glasses] session.start() ✗ \(error)")
          showError("Failed to start device session: \(error.localizedDescription)")
          return
        }

        // CRITICAL: `session.start()` is sync and only transitions the
        // session to `.starting`. The transition to `.started` is
        // asynchronous (BT/WiFi handshake with the glasses). If we call
        // `addStream(config:)` while the session is still `.starting`,
        // the SDK returns nil — the original "Could not attach
        // streaming capability" symptom on a real device. Meta's
        // canonical 0.6 sample verifies `state == .started` first;
        // their Obj-C bridge even exposes a dedicated
        // `startAndWaitUntilReady(completionHandler:)` for this
        // exact wait. Swift only exposes the sync `start()`, so we
        // subscribe to `statePublisher` and await the transition.
        do {
          try await awaitDeviceSessionStarted(session, timeout: 5.0)
          print("[Glasses] device session ready (state=\(session.state))")
        } catch {
          print("[Glasses] device session never reached .started: \(error.localizedDescription)")
          session.stop()
          showError("Glasses didn't finish starting up. Try again.")
          return
        }

        let config = StreamSessionConfig(
          videoCodec: .raw,
          resolution: .high,
          frameRate: 30)
        print("[Glasses] addStream(config: codec=raw, resolution=.high, fps=30) → …")

        guard let stream = try session.addStream(config: config) else {
          // The session started but the SDK declined to attach a stream —
          // most commonly because the eligible device dropped between
          // createSession and addStream. Tear the orphan session back
          // down so the next attempt re-creates from a clean slate.
          print("[Glasses] addStream ✗ returned nil (deviceState=\(session.state)) — stopping orphan session")
          session.stop()
          showError("Could not attach streaming capability — the glasses dropped before the stream could open. Try again.")
          return
        }
        print("[Glasses] addStream ✓ (streamState=\(stream.state))")

        deviceSession = session
        streamSession = stream
        attachStreamListeners(stream)
        updateStatusFromState(stream.state)
      } catch let error as DeviceSessionError {
        print("[Glasses] DeviceSessionError in startSession: \(error)")
        showError("Failed to start device session: \(error.localizedDescription)")
        deviceSession = nil
        streamSession = nil
        return
      } catch {
        print("[Glasses] Unknown error in startSession: \(error)")
        showError("Failed to start device session: \(error.localizedDescription)")
        deviceSession = nil
        streamSession = nil
        return
      }
    } else {
      print("[Glasses] startSession() → reusing existing streamSession")
    }
    print("[Glasses] streamSession.start() → …")
    await streamSession?.start()
    print("[Glasses] streamSession.start() ✓")
  }

  /// Wait for the DAT `DeviceSession` to transition from `.starting`
  /// to `.started` before attempting `addStream(config:)`.
  ///
  /// Background: `DeviceSession.start()` is a sync throws function. It
  /// flips the state machine from `.idle` to `.starting` and returns
  /// immediately — but the BT/WiFi handshake with the glasses takes
  /// hundreds of milliseconds to actually reach `.started`. Calling
  /// `addStream` during that window returns nil. The SDK exposes
  /// `statePublisher` (an `Announcer<DeviceSessionState>`) so we can
  /// subscribe to the transition. Bridging into an `AsyncStream` lets
  /// us await it cleanly with a timeout watchdog.
  ///
  /// Throws on timeout or if the session lands on `.stopped` before
  /// `.started`.
  private func awaitDeviceSessionStarted(
    _ session: DeviceSession,
    timeout: TimeInterval
  ) async throws {
    if session.state == .started { return }

    let (stream, continuation) = AsyncStream<DeviceSessionState>.makeStream()
    let listenerToken = session.statePublisher.listen { state in
      print("[Glasses] DeviceSession.state → \(state)")
      continuation.yield(state)
    }
    defer { _ = listenerToken }  // keep listener alive for the duration

    // Re-check after subscribing to catch a transition that landed
    // between the entry-state check and the listener install.
    if session.state == .started {
      continuation.finish()
      return
    }

    let outcome: Bool = await withTaskGroup(of: Bool?.self, returning: Bool.self) { group in
      group.addTask {
        for await state in stream {
          if state == .started { return true }
          if state == .stopped { return false }
          // .idle / .starting / .paused / .stopping → keep waiting.
        }
        return false
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      continuation.finish()
      return first ?? false
    }

    if !outcome {
      struct DeviceSessionNotReady: LocalizedError {
        var errorDescription: String? { "Device session never reached .started" }
      }
      throw DeviceSessionNotReady()
    }
  }

  /// Wire DAT SDK listeners to the freshly-created StreamSession.
  private func attachStreamListeners(_ stream: StreamSession) {
    // Session state changes tell us when streaming starts, stops, or encounters issues.
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      // Log every transition. Critical for diagnosing "stuck on
      // waitingForDevice" / "starting → stopped" cycles that would
      // otherwise be invisible behind the unchanged UI state.
      print("[Glasses] StreamSession.state → \(state)")
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
            // The single most diagnostic signal — proves frames are
            // actually flowing from glasses → DAT → us, not just that
            // the state machine reported `.streaming`.
            print("[Glasses] ✓ first video frame received")
          }
        }
      }
    }

    // Streaming errors (device disconnection, streaming failures, etc).
    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      print("[Glasses] StreamSession.error → \(error)")
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

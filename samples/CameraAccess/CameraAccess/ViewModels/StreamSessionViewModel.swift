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

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false

  // Recording properties
  @Published var showRecordingReview: Bool = false
  let audioSessionManager = AudioSessionManager(mode: .recording)
  lazy var recordingManager = ExpertRecordingManager(audioSessionManager: audioSessionManager)
  let uploadService: UploadService

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
    // enqueue onto recordingQueue). Preview (`makeUIImage` + SwiftUI rerender) is
    // throttled to ~10 Hz so MainActor isn't burning CPU on display work that
    // competes with the recording path.
    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] videoFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }

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

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
import CoreMedia
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
  /// Cross-instance teardown gate. When the user hits Stop and exits a
  /// recording, `.onDisappear` fires `Task { await teardown() }`
  /// (unstructured) and SwiftUI immediately tears down the view. The
  /// next recording's `.task { await prepare() }` runs before that
  /// teardown Task completes — so `wearables.createSession(...)` sees
  /// the prior DeviceSession still in `.stopping` and throws
  /// `.sessionAlreadyExists`. Stashing the in-flight teardown here
  /// (`prepare()` awaits it before its first SDK call) closes the
  /// race without forcing teardown to be synchronous.
  nonisolated(unsafe) private static var teardownInFlight: Task<Void, Never>?

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

  /// Becomes true after the silent warmup cycle in `prepare()` has
  /// finished. The chrome reads this in addition to `isPreviewLive` to
  /// gate the Start button — preventing a tap during the warmup window.
  ///
  /// Background: the FIRST `AVAssetWriter` started in this app process
  /// against the glasses path always fails with
  /// `AVErrorUnsupportedOutputSettings` (-11861). The SECOND writer
  /// always works. We silently run a throwaway recording cycle once
  /// the stream is up so the user's first tap is iOS's "rec 2." The
  /// Start button stays disabled until that's done.
  @Published var isReadyToRecord: Bool = false

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

  // MARK: - Diagnostic counters
  // Wired in `attachStreamListeners`. Logged every ~2s during recording
  // so we can tell at a glance whether DAT is delivering video to us and
  // whether we're forwarding it to the writer. A "0 forwarded" run that
  // ends in "no usable video was recorded" tells us the listener never
  // saw `recordingManager.isRecording == true` (gate problem). A
  // "forwarded > 0" run that still produces 0 written frames tells us
  // the writer is rejecting the buffer (format / dimensions mismatch).
  private var framesForwardedDuringRecording: Int = 0
  private var framesDroppedNotRecording: Int = 0
  private var lastFrameStatLogAt: Date = .distantPast

  // MARK: - Live frame dimensions (set off-main, read on MainActor)
  // The DAT SDK auto-degrades resolution when BT/WiFi bandwidth is
  // limited (e.g. requested `.high` 720x1280 → delivered `.medium`
  // 504x896). If our `AVAssetWriter` is configured for the requested
  // dimensions, every delivered frame is rejected with "Cannot Encode
  // Media" (writer status 3) and the recording produces 0 video
  // frames despite `forwarded > 0`. We track the latest delivered
  // dimensions off-main and snapshot them when the user taps Start so
  // the writer matches the actual stream.
  private let frameDimsLock = NSLock()
  nonisolated(unsafe) private var _latestFrameDimsW: Int32 = 0
  nonisolated(unsafe) private var _latestFrameDimsH: Int32 = 0

  /// Off-main writer. Called from the video frame listener.
  private nonisolated func storeLatestFrameDims(_ dims: CMVideoDimensions) {
    frameDimsLock.lock()
    _latestFrameDimsW = dims.width
    _latestFrameDimsH = dims.height
    frameDimsLock.unlock()
  }

  // Tracks the last pixel format we logged so we only print on change
  // (otherwise we'd spam every frame at 30 fps).
  private let pixelFormatLogLock = NSLock()
  nonisolated(unsafe) private var _lastLoggedPixelFormat: FourCharCode = 0
  nonisolated(unsafe) private var _lastLoggedPixelFormatDims: (Int32, Int32) = (0, 0)

  /// Off-main pixel-format logger. Prints whenever the FourCC subtype
  /// or dimensions change so we can correlate format / dim changes
  /// with writer rejection. Critical for diagnosing "Cannot Encode
  /// Media": at matching dims, format changes are the next likely
  /// culprit.
  private nonisolated func logPixelFormatIfChanged(
    _ fmt: CMFormatDescription,
    dims: CMVideoDimensions
  ) {
    let subtype = CMFormatDescriptionGetMediaSubType(fmt)
    pixelFormatLogLock.lock()
    let unchanged = (subtype == _lastLoggedPixelFormat)
      && (dims.width == _lastLoggedPixelFormatDims.0)
      && (dims.height == _lastLoggedPixelFormatDims.1)
    if !unchanged {
      _lastLoggedPixelFormat = subtype
      _lastLoggedPixelFormatDims = (dims.width, dims.height)
    }
    pixelFormatLogLock.unlock()
    guard !unchanged else { return }

    // Decode FourCC to a 4-char string for human-readable logging.
    var be = subtype.bigEndian
    let fourCC = withUnsafeBytes(of: &be) { bytes -> String in
      String(bytes: bytes, encoding: .ascii) ?? "?"
    }
    print("[Glasses] pixel format → \(fourCC) (\(subtype)) at \(dims.width)x\(dims.height)")
  }

  // MARK: - Video PTS re-anchoring (glasses-only)
  //
  // We re-stamp glasses video sample buffers onto the host clock so they
  // share a timeline with audio (which is already host-clock-stamped via
  // `time.hostTime` in `ExpertRecordingManager.cmSampleBuffer(from:time:)`).
  // BUT we anchor only ONCE per recording — the first frame's host time
  // becomes the host_anchor, and every subsequent frame's PTS is
  // `host_anchor + (currentDATPTS - firstDATPTS)`. This preserves the
  // DAT SDK's real frame intervals (~33 ms at 30 fps) instead of
  // collapsing them when MainActor backs up and Tasks process in quick
  // succession — that backup was producing PTSs ~1 ms apart with
  // 33 ms-duration each, the resulting PTS+duration overlap is what
  // makes AVAssetWriter return "Cannot Encode Media" after 4 frames.
  private let timingAnchorLock = NSLock()
  nonisolated(unsafe) private var _hostAnchor: CMTime = .invalid
  nonisolated(unsafe) private var _datAnchor: CMTime = .invalid

  /// Reset the timing anchors. Call at the start of each recording so a
  /// new recording doesn't reuse the prior recording's anchors.
  private nonisolated func resetVideoTimingAnchors() {
    timingAnchorLock.lock()
    _hostAnchor = .invalid
    _datAnchor = .invalid
    timingAnchorLock.unlock()
  }

  /// Re-stamp a glasses video sample buffer with the current host-clock
  /// PTS so it lands on the same timeline as the audio buffers (which
  /// already use `time.hostTime` in `ExpertRecordingManager`).
  ///
  /// Background: the DAT SDK's `videoFrame.sampleBuffer` carries a PTS
  /// in the SDK's own clock (small numbers, session-relative). Audio
  /// buffers carry host-clock PTS (huge numbers, since boot).
  /// `AVAssetWriter.startSession(atSourceTime:)` is set by whichever
  /// buffer reaches `recordingQueue` first, then rejects every later
  /// buffer with a PTS before that anchor. So whichever clock "wins"
  /// the race effectively kills the OTHER track:
  ///   - audio first → all video rejected → 0 video frames → "no
  ///     usable video was captured" (the bug)
  ///   - video first → audio's huge PTS is fine, recording works
  /// Re-stamping video to host time eliminates the race entirely —
  /// the writer's session start is always in host clock and both
  /// tracks land cleanly. iPhone doesn't have this bug because its
  /// video PTS is already host-clock (set by AVCaptureSession).
  private nonisolated func restampVideoBufferWithHostClock(
    _ original: CMSampleBuffer
  ) -> CMSampleBuffer? {
    let originalPTS = CMSampleBufferGetPresentationTimeStamp(original)
    guard originalPTS.flags.contains(.valid) else {
      print("[Glasses] restamp: original PTS invalid — skipping")
      return nil
    }

    // Lazy anchor: the first frame after a recording starts captures
    // both the host time AND the DAT-side PTS. All subsequent frames
    // compute new_PTS = host_anchor + (originalPTS - dat_anchor).
    let (hostAnchor, datAnchor): (CMTime, CMTime) = {
      timingAnchorLock.lock()
      defer { timingAnchorLock.unlock() }
      if !_hostAnchor.flags.contains(.valid) {
        _hostAnchor = CMClockGetTime(CMClockGetHostTimeClock())
        _datAnchor = originalPTS
        print("[Glasses] anchored host=\(CMTimeGetSeconds(_hostAnchor))s, dat=\(CMTimeGetSeconds(_datAnchor))s")
      }
      return (_hostAnchor, _datAnchor)
    }()

    // delta = originalPTS - datAnchor → the frame's offset within
    // the DAT clock since recording started. Adding it to the host
    // anchor gives a host-clock PTS that preserves the real
    // inter-frame interval (no overlap when MainActor catches up
    // from a backlog).
    let delta = CMTimeSubtract(originalPTS, datAnchor)
    let newPTS = CMTimeAdd(hostAnchor, delta)

    // Preserve original duration if available so the encoder gets the
    // right inter-frame interval; otherwise default to 30fps.
    var originalTiming = CMSampleTimingInfo()
    let timingStatus = CMSampleBufferGetSampleTimingInfo(
      original,
      at: 0,
      timingInfoOut: &originalTiming
    )
    let duration: CMTime = {
      if timingStatus == noErr,
         originalTiming.duration.flags.contains(.valid),
         originalTiming.duration.value > 0 {
        return originalTiming.duration
      }
      return CMTimeMake(value: 1, timescale: 30)
    }()

    var newTiming = CMSampleTimingInfo(
      duration: duration,
      presentationTimeStamp: newPTS,
      decodeTimeStamp: .invalid
    )

    var copy: CMSampleBuffer?
    let status = CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault,
      sampleBuffer: original,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &newTiming,
      sampleBufferOut: &copy
    )
    guard status == noErr, let buffer = copy else {
      print("[Glasses] restamp failed (status=\(status)) — falling back to original PTS")
      return nil
    }
    return buffer
  }

  /// MainActor-side reader. Returns the most recently observed
  /// frame dimensions, or `nil` if no frame has arrived yet.
  private func readLatestFrameDims() -> (width: Int, height: Int)? {
    frameDimsLock.lock()
    defer { frameDimsLock.unlock() }
    guard _latestFrameDimsW > 0, _latestFrameDimsH > 0 else { return nil }
    return (Int(_latestFrameDimsW), Int(_latestFrameDimsH))
  }

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

    // If a prior recording's teardown is still in flight, wait for it
    // before talking to the SDK. Otherwise we'd race the SDK's session
    // cleanup and hit `.sessionAlreadyExists`.
    if let pending = Self.teardownInFlight {
      print("[Glasses] prepare() awaiting prior teardown to finish…")
      await pending.value
      print("[Glasses] prepare() prior teardown drained")
    }

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
    // Hand tracking BEFORE stream listeners. The listener captures
    // `handLandmarkerService` into a non-self closure (so it can call
    // submit off-main without a MainActor hop), so the service must
    // exist by the time `attachStreamListeners` runs. This is also
    // how the iPhone path is wired (`onHandSampleBuffer` captures the
    // service directly via `[weak service]`).
    print("[Glasses] prepare() → startHandTrackingIfAvailable")
    startHandTrackingIfAvailable()
    print("[Glasses] prepare() → handleStartStreaming")
    await handleStartStreaming()
    print("[Glasses] prepare() → audioSessionManager.prewarm")
    await audioSessionManager.prewarm()

    // Run the silent warmup recording cycle. The first AVAssetWriter
    // started against the glasses path in this process always fails
    // with AVErrorUnsupportedOutputSettings (-11861); the second
    // always works. We sacrifice a throwaway recording here so the
    // user's first tap is iOS's "rec 2." Start button stays disabled
    // (via `isReadyToRecord`) until this completes.
    print("[Glasses] prepare() → runSilentWarmupCycle")
    await runSilentWarmupCycle()
    isReadyToRecord = true
    print("[Glasses] prepare() → isReadyToRecord = true")
  }

  /// Silent warmup cycle that runs in `prepare()` to "use up" iOS's
  /// first-recording failure before the user can see it. Does not
  /// surface any errors and suppresses the recording HUD via
  /// `recordingManager.isWarmingUp`.
  ///
  /// Returns when the cycle is complete OR after a hard timeout. Any
  /// failure inside the cycle is intentionally swallowed.
  private func runSilentWarmupCycle() async {
    // Wait up to ~2s for the first frame so `readLatestFrameDims()`
    // has live dims. Without dims we can't size the writer.
    let dimsWaitStart = Date()
    while readLatestFrameDims() == nil,
          Date().timeIntervalSince(dimsWaitStart) < 2.0 {
      try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms poll
    }
    guard let dims = readLatestFrameDims() else {
      print("[Glasses] warmup → skipped (no first-frame dims after 2s)")
      return
    }

    // Wait up to ~2s for the listener-driven `prepareWriter` to land
    // a writer for those dims. Mirrors the `isWriterPrepared` debounce
    // that the listener uses; if the writer isn't ready in time we
    // still proceed — startRecording's slow-path will build one
    // in-line.
    let prepWaitStart = Date()
    while !recordingManager.isWriterPrepared,
          Date().timeIntervalSince(prepWaitStart) < 2.0 {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }

    print("[Glasses] warmup → starting throwaway recording at \(dims.width)x\(dims.height)")
    recordingManager.isWarmingUp = true
    defer {
      recordingManager.isWarmingUp = false
      // Belt-and-suspenders: clear any error state the warmup might
      // have leaked into. The warmup goes through the manager
      // directly so it shouldn't, but if it ever does we don't want
      // a stale alert greeting the user.
      showError = false
      errorMessage = ""
    }

    // Run the full audio + writer bring-up. We swallow any error —
    // even if the writer fails (which is exactly what we expect on
    // this first attempt), the audio engine still cycles and that's
    // the part that primes iOS for the next attempt.
    let startErr = await recordingManager.startRecording(
      width: dims.width,
      height: dims.height,
      postAudioSettleMs: 100
    )
    if let startErr = startErr {
      print("[Glasses] warmup → startRecording returned error (swallowed): \(startErr.localizedDescription)")
      // No-op — we don't surface this and we don't try to stop a
      // recording that never started.
      return
    }

    // Hold the recording briefly so the writer is exercised. 500ms
    // covers ~15 frames at 30fps — enough for the H.264 encoder to
    // attempt its first append batch (and fail "naturally") before
    // we tear it down.
    try? await Task.sleep(nanoseconds: 500_000_000)

    print("[Glasses] warmup → stopping throwaway recording")
    let url = await recordingManager.stopRecording()
    // stopRecording returns the file URL on success; on failure it
    // already deletes the temp file. Either way, remove anything
    // that survived so we don't leak a warmup mp4 into the user's
    // tmp dir.
    if let url = url {
      try? FileManager.default.removeItem(at: url)
    }
    print("[Glasses] warmup → complete")
  }

  /// Mirror of `IPhoneExpertRecordingViewModel.startRecording(landscape:)` so
  /// the unified recording chrome can call the same method on either VM.
  func startRecording(landscape: Bool) {
    // Belt-and-suspenders: the chrome's button is already disabled
    // until `isReadyToRecord` flips true (warmup cycle done), but
    // gate here too so a programmatic call can't sneak through.
    guard isReadyToRecord else {
      print("[Glasses] startRecording ignored — warmup cycle still running")
      return
    }
    guard isPreviewLive else {
      showError("Glasses preview isn't ready yet.")
      return
    }

    // Source dims from the live frame stream when available — the DAT
    // SDK degrades resolution under bandwidth pressure (we asked for
    // 720x1280 but tend to receive 504x896), and a writer locked to
    // the requested dims rejects every buffer with "Cannot Encode
    // Media". `readLatestFrameDims()` returns whatever the most recent
    // delivered frame's CMVideoFormatDescription said. Falls back to
    // the requested high/landscape size only if no frame has arrived
    // yet — but `isPreviewLive` ensures it has, so the fallback is
    // a defensive belt.
    let liveDims = readLatestFrameDims()
    let size: (width: Int, height: Int) = {
      if let live = liveDims {
        // We now request `.medium` from the SDK so the live dims
        // should be a stable 504×896 from preview through recording.
        // We still source from live dims as a defensive belt — if the
        // SDK ever degrades framerate AND further reduces resolution
        // under extreme pressure, the writer will adapt.
        print("[Glasses] startRecording sizing writer to live dims \(live.width)x\(live.height) (SDK requested .medium 504x896)")
        return live
      }
      print("[Glasses] startRecording falling back to 504x896 (no live frame seen yet)")
      // Fallback matches what we requested from the SDK (.medium).
      return (504, 896)
    }()

    // Reset diagnostic counters per recording so the 2s log windows
    // are scoped to this recording session, not the lifetime of the
    // VM.
    framesForwardedDuringRecording = 0
    framesDroppedNotRecording = 0
    lastFrameStatLogAt = .distantPast
    // Reset the host/DAT timing anchors so the first frame of THIS
    // recording captures fresh anchors. Without this reset the next
    // recording would inherit the prior recording's host_anchor and
    // accumulate stale offsets.
    resetVideoTimingAnchors()
    Task { [weak self] in
      guard let self else { return }
      // Surface audio/writer start failures so a wedged audio engine
      // doesn't silently produce a silent mp4. Mirrors the iPhone path.
      //
      // `postAudioSettleMs: 100` is the glasses-specific HAL-route
      // settle window — after the audio engine has started the BT/HFP
      // route is finalizing, and that finalization fires a
      // `routeChangeNotification` whose XPC HAL reset can invalidate
      // the AVAssetWriter's Video Toolbox session mid-first-batch.
      // Sleeping 100 ms here lets the cascade drain before the writer
      // sees its first sample. Targets the rec-1 "Cannot Encode Media"
      // failure (appendedFrameCount=3 is exactly the in-flight batch
      // before the reset). iPhone uses the default 0 — no HFP route
      // negotiation, no cascade.
      if let err = await self.recordingManager.startRecording(
        width: size.width,
        height: size.height,
        postAudioSettleMs: 100
      ) {
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
    let resultURL = recordingManager.recordingURL

    // Re-prepare a fresh writer for any subsequent recording in this
    // same view session. Done eagerly here (vs. waiting for the next
    // frame to drive it) so the writer is ready immediately whenever
    // the user might tap Start again — same warm-encoder principle as
    // the first prepare.
    if let dims = readLatestFrameDims() {
      print("[Glasses] stopRecording → re-preparing writer for next recording at \(dims.width)x\(dims.height)")
      Task { [weak self] in
        guard let self else { return }
        _ = await self.recordingManager.prepareWriter(
          width: dims.width,
          height: dims.height
        )
      }
    }

    if let url = resultURL {
      return (url, duration)
    }
    reportRecordingFailure()
    return nil
  }

  /// Trigger a `prepareWriter` call against the recordingManager when
  /// dims become known (or change). Debounces internally:
  /// `recordingManager.prepareWriter` short-circuits when a writer
  /// already exists with the requested dims, so calling this on every
  /// frame is safe — but we also avoid spawning a Task per frame by
  /// gating on the manager's published state.
  ///
  /// Glasses-only: this method is never called from the iPhone path.
  /// iPhone keeps its in-line writer creation inside `startRecording`.
  private func prepareWriterIfNeeded(width: Int, height: Int) {
    // Active recording: `prepareWriter` would no-op and we'd churn a
    // Task per frame. Skip.
    guard !recordingManager.isRecording, !recordingManager.isStarting else { return }
    // Already prepared with the right dims? Skip.
    if recordingManager.isWriterPrepared,
       let prepared = recordingManager.preparedDims,
       prepared.width == width, prepared.height == height {
      return
    }
    // Debounce: don't pile up Tasks while one is in flight.
    guard !isPrepareWriterInFlight else { return }
    isPrepareWriterInFlight = true
    Task { [weak self] in
      guard let self else { return }
      defer { self.isPrepareWriterInFlight = false }
      let ok = await self.recordingManager.prepareWriter(width: width, height: height)
      if !ok {
        print("[Glasses] prepareWriter ✗ for \(width)x\(height)")
      }
    }
  }

  /// Debounce flag for `prepareWriterIfNeeded`. Set true while a
  /// `prepareWriter` call is in flight; cleared when it returns. The
  /// listener can fire 30 times per second, so without this we'd
  /// spawn duplicate Tasks while the first is still creating an
  /// AVAssetWriter off-main.
  private var isPrepareWriterInFlight: Bool = false

  /// Mirror of `IPhoneExpertRecordingViewModel.teardown()`. Stops streaming,
  /// drops the hand-tracking pipeline, and resets preview state. Also
  /// deactivates the AVAudioSession so leaving Expert mode lets other
  /// apps' background audio resume — `stopCapture` only flips the
  /// category for recording modes, it doesn't deactivate.
  func teardown() {
    handLandmarkerService?.stop()
    handLandmarkerService = nil
    hudViewModel.resetHandTracking()
    audioSessionManager.deactivate()

    // If a writer was pre-prepared but the user never tapped Start,
    // cancel it and remove the orphan temp mp4. `discardPreparedWriter`
    // is a no-op when a recording is currently active — `stopRecording`
    // is the right path for that case.
    recordingManager.discardPreparedWriter()

    // Drop listener tokens BEFORE we hand the streamSession off to the
    // teardown Task — once nil, the listener closures stop firing, so
    // a trailing frame can't try to read a nil writer or push into a
    // half-torn-down VM.
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil

    // Capture STRONG refs to the SDK objects we need to release. SwiftUI
    // can deallocate this @StateObject between the view dismissal and
    // when the teardown Task actually runs; with `[weak self]` the Task
    // body would see `self == nil` and skip stopSession entirely,
    // leaving the DAT session running on the glasses (LED stays on,
    // WARP frames keep streaming, BT/WiFi battery drains). Capturing
    // the streamSession + deviceSession directly means the SDK objects
    // survive long enough for stop() + .stopped wait to run.
    //
    // The Task ALSO retains self strongly so we can call the
    // awaitDeviceSessionStopped helper. Once stopSession completes,
    // both refs drop and the VM can deallocate.
    let streamToStop = streamSession
    let sessionToStop = deviceSession
    streamSession = nil
    deviceSession = nil

    // Stash the stopSession Task in the cross-instance gate so the
    // next view's `prepare()` can await it (see Self.teardownInFlight).
    // Without this, `.onDisappear` returns immediately and SwiftUI
    // mounts the next recording view; that view's `prepare()` then
    // races our async stopSession and the SDK throws
    // `.sessionAlreadyExists` on the next createSession.
    //
    // Once the Task completes, awaiting it from the next prepare is a
    // no-op — the cached `Void` result returns instantly. So no
    // cleanup needed; subsequent teardowns just overwrite the slot.
    Self.teardownInFlight = Task { [self, streamToStop, sessionToStop] in
      _ = self  // strong capture — keeps awaitDeviceSessionStopped reachable
      print("[Glasses] teardown → stopping streamSession + deviceSession")
      await streamToStop?.stop()
      if let session = sessionToStop {
        session.stop()
        await self.awaitDeviceSessionStopped(session, timeout: 3.0)
        print("[Glasses] teardown → DeviceSession reached \(session.state)")
      }
      print("[Glasses] teardown complete")
    }
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

        // Lock to `.medium` (504×896) instead of `.high` (720×1280).
        //
        // Background: the BT/WiFi link to the glasses can sustain `.high`
        // ONLY while audio isn't competing for bandwidth (i.e. preview-
        // only). The moment recording starts, audio session activation
        // grabs HFP, bandwidth halves, and DAT auto-degrades to `.medium`
        // mid-recording. The AVAssetWriter — already sized at 720×1280
        // from the preview-time dims — then rejects every degraded
        // 504×896 frame with "Cannot Encode Media" and the recording
        // produces 0 video frames.
        //
        // Per SDK docs (camera-streaming.md): "The SDK automatically
        // reduces quality when bandwidth is limited: 1) First lowers
        // resolution (e.g., High → Medium). 2) Then reduces frame rate
        // (e.g., 30 → 24), never below 15 FPS." So requesting `.medium`
        // makes resolution stable from preview through recording — the
        // SDK can only drop framerate from here, which the writer
        // tolerates. Writer is now sized 504×896 the whole time, frames
        // always match, every recording works on the first try.
        //
        // We "give up" the brief `.high` preview moment to gain
        // deterministic recording. The BT pipe wouldn't have delivered
        // `.high` during the actual recording anyway.
        let config = StreamSessionConfig(
          videoCodec: .raw,
          resolution: .medium,
          frameRate: 30)
        print("[Glasses] addStream(config: codec=raw, resolution=.medium, fps=30) → …")

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

    let outcome: Bool = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
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
      return first
    }

    if !outcome {
      struct DeviceSessionNotReady: LocalizedError {
        var errorDescription: String? { "Device session never reached .started" }
      }
      throw DeviceSessionNotReady()
    }
  }

  /// Mirror of `awaitDeviceSessionStarted` for the stop path.
  /// `DeviceSession.stop()` is sync void but the transition to `.stopped`
  /// is async — calling `wearables.createSession(...)` for a fresh
  /// recording before the SDK has actually released the prior session
  /// throws `.sessionAlreadyExists`. We subscribe to `statePublisher`
  /// and await `.stopped` so the next entry into `prepare()` sees a
  /// clean SDK state.
  private func awaitDeviceSessionStopped(
    _ session: DeviceSession,
    timeout: TimeInterval
  ) async {
    if session.state == .stopped { return }

    let (stream, continuation) = AsyncStream<DeviceSessionState>.makeStream()
    let listenerToken = session.statePublisher.listen { state in
      print("[Glasses] DeviceSession.state (stopping) → \(state)")
      continuation.yield(state)
    }
    defer { _ = listenerToken }

    if session.state == .stopped {
      continuation.finish()
      return
    }

    _ = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
      group.addTask {
        for await state in stream {
          if state == .stopped { return true }
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
      return first
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
    // Glasses video pipeline — three independent paths, mirroring the
    // iPhone path's parallelism (where AVCaptureVideoPreviewLayer
    // renders for free, AVCaptureVideoDataOutput delegate queues run
    // off-main, and only the recording gate hops to MainActor).
    //
    // Path 1: hand tracking → direct off-main submit (HandLandmarkerService is
    //         @unchecked Sendable and submits to its own internal queue).
    // Path 2: recording → one MainActor hop for the gate check, then
    //         appendVideoFrame dispatches into recordingQueue.async (encoder).
    // Path 3: preview → makeUIImage() decode on a detached background
    //         Task, MainActor.run only to assign the @Published var.
    //
    // BEFORE: all three were serialized inside a single Task @MainActor
    // per frame. At 30 fps the heavy makeUIImage decode + HUD renders +
    // audio-meter updates fought for the same MainActor; per-frame Tasks
    // queued, sample buffers piled up, and writer.append(...) ran late
    // enough that frames were rejected (the "no usable video" symptom).
    // Snapshot the hand-landmarker service so the @Sendable listener
    // closure can call it off-main without crossing MainActor. Mirrors
    // the iPhone path's `onHandSampleBuffer = { [weak service] … }`
    // pattern. May be nil if hand tracking is unavailable / disabled
    // — the optional-chain in the listener handles that.
    let handService = handLandmarkerService

    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self, weak handService] videoFrame in
      guard let self else { return }

      // Snapshot the actual delivered frame dimensions on every frame
      // so that startRecording can size the AVAssetWriter to match.
      // The DAT SDK auto-degrades resolution when bandwidth is low
      // (we requested .high 720x1280 but the link delivers .medium
      // 504x896), and a writer hardcoded to the requested dims
      // rejects every buffer with "Cannot Encode Media" (status=3,
      // appendedFrames=0). Done off-main, lock-protected.
      if let fmt = videoFrame.sampleBuffer.formatDescription {
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        self.storeLatestFrameDims(dims)

        // Diagnostic: log pixel format ONCE per change. Writer rejects
        // frames with non-trivial format diffs even at matching dims —
        // this tells us whether the SDK is delivering BGRA / 420v /
        // 420f / something exotic that AVAssetWriter's H.264 encoder
        // can't auto-negotiate without a sourceFormatHint. FourCC
        // codes: '420v'=YpCbCr8BiPlanarVideoRange, '420f'=Full,
        // 'BGRA'=32BGRA, 'L010'=10-bit, etc.
        self.logPixelFormatIfChanged(fmt, dims: dims)

        // === Pre-prepare the AVAssetWriter while audio is still idle ===
        // Building the writer concurrently with audio session
        // activation (BT/HFP grab) leaves the H.264 hardware encoder
        // in a "Cannot Encode Media" state on the first recording.
        // Pre-creating it here, in the calm preview phase, avoids
        // that. Debounced to once per dim-set; the helper itself
        // is idempotent + cheap when no rebuild is needed.
        let dimsW = Int(dims.width)
        let dimsH = Int(dims.height)
        Task { @MainActor [weak self] in
          self?.prepareWriterIfNeeded(width: dimsW, height: dimsH)
        }
      }

      // === Path 1 — hand tracking. Direct off-main call. ===
      handService?.submit(sampleBuffer: videoFrame.sampleBuffer)

      // === Path 2 — recording append. MainActor only for the gate. ===
      Task { @MainActor [weak self] in
        guard let self else { return }
        if self.recordingManager.isRecording {
          // Re-stamp PTS to host clock before append — see
          // `restampVideoBufferWithHostClock` for why. Falls back to
          // the original buffer if re-stamping fails (extremely rare).
          let bufferToWrite = self.restampVideoBufferWithHostClock(videoFrame.sampleBuffer)
            ?? videoFrame.sampleBuffer
          self.recordingManager.appendVideoFrame(bufferToWrite)
          self.framesForwardedDuringRecording += 1
        } else {
          self.framesDroppedNotRecording += 1
        }

        // Diagnostic: every ~2 s, log the running counters AND the
        // current recording state. Now fires UNCONDITIONALLY (not
        // gated on isRecording) so a stalled-recording state where
        // the DAT publisher goes silent vs one where it's delivering
        // but the gate is off can be told apart at a glance:
        //   • no `[Glasses] frames recv` lines at all in the window
        //     → DAT publisher silent (BT contention / glasses dropped)
        //   • lines with recording=true, forwarded:0 → frames arriving
        //     but writer never accepting (rare; restamp/format issue)
        //   • lines with recording=false during a "live" recording
        //     → MainActor visibility on the gate (very rare)
        //   • lines with recording=true, forwarded > 0 → working
        let now = Date()
        if now.timeIntervalSince(self.lastFrameStatLogAt) >= 2.0 {
          self.lastFrameStatLogAt = now
          let dims = videoFrame.sampleBuffer.formatDescription.map { fmt -> String in
            let d = CMVideoFormatDescriptionGetDimensions(fmt)
            return "\(d.width)x\(d.height)"
          } ?? "?"
          let total = self.framesForwardedDuringRecording + self.framesDroppedNotRecording
          print("[Glasses] frames recv:\(total) → forwarded:\(self.framesForwardedDuringRecording) (recording=\(self.recordingManager.isRecording)) dims=\(dims)")
        }
      }

      // === Path 3 — preview update. Decode off-main. ===
      // Throttle gate is checked on MainActor (cheap Date comparison).
      // The expensive part — makeUIImage() — runs on a detached
      // background Task. Only the @Published assignment hops back.
      Task.detached(priority: .userInitiated) { [weak self] in
        guard let self else { return }

        let now = Date()
        let shouldUpdate: Bool = await MainActor.run {
          guard now.timeIntervalSince(self.lastPreviewUpdateAt) >= 0.1 else { return false }
          self.lastPreviewUpdateAt = now
          return true
        }
        guard shouldUpdate else { return }

        // CPU-heavy: sample buffer → CGImage → UIImage. This is what
        // was clogging MainActor before; running it here keeps the
        // recording path's MainActor hop fast.
        guard let image = videoFrame.makeUIImage() else { return }

        await MainActor.run {
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
    let entryState: String = deviceSession.map { "\($0.state)" } ?? "nil"
    print("[Glasses] stopSession() begin (deviceState=\(entryState))")
    // Drop listeners before stopping so trailing frame/state events can't
    // push into a half-torn-down VM.
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil

    await streamSession?.stop()
    if let session = deviceSession {
      session.stop()
      // CRITICAL: `stop()` only flips the state machine to `.stopping`
      // and returns; the actual transition to `.stopped` is async. If
      // we nil out the local ref before the SDK has finished tearing
      // the session down, the next `wearables.createSession(...)`
      // throws `.sessionAlreadyExists` because the SDK still sees an
      // active session for that device. Awaiting `.stopped` here
      // guarantees the next `prepare()` enters a clean SDK state.
      await awaitDeviceSessionStopped(session, timeout: 3.0)
      print("[Glasses] DeviceSession reached \(session.state) after stop()")
    }
    streamSession = nil
    deviceSession = nil

    // Reset published UI state so re-entering the view starts from a
    // clean slate instead of flashing the prior session's last frame.
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
    capturedPhoto = nil
    showPhotoPreview = false
    print("[Glasses] stopSession() end")
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

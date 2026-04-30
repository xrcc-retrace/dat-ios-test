import AVFoundation
import CoreMedia
import SwiftUI

@MainActor
class ExpertRecordingManager: ObservableObject {
  @Published var isRecording = false
  @Published var recordingDuration: TimeInterval = 0
  @Published var recordingURL: URL?
  /// True between the moment the user taps "Start recording" and the moment
  /// the writer is actually armed. Drives the button's disabled state so a
  /// second tap during the ~300 ms startup window can't land on the just-
  /// flipped "Stop recording" button and kill the session before any frames
  /// were captured.
  @Published var isStarting = false

  /// True while the glasses path is running its silent warmup cycle in
  /// `prepare()`. While this is set, `isHUDActive` returns false even
  /// when `isRecording` is true — so the recording HUD doesn't flash
  /// during the throwaway recording. iPhone never sets this flag.
  @Published var isWarmingUp: Bool = false

  /// HUD-visibility gate. Held until the audio engine is actually live so
  /// the heavy SwiftUI / Metal mount doesn't compete with the audio-session
  /// bring-up — main-thread contention during that ~250 ms window was
  /// triggering the `-10868` race on the input AU's first format
  /// validation. Trades a small post-tap lag for foolproof audio start.
  ///
  /// Suppressed during a glasses warmup cycle so the user never sees
  /// the throwaway recording's HUD pop on/off.
  var isHUDActive: Bool { isRecording && !isWarmingUp }

  private var assetWriter: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?

  /// Dims the most recently prepared writer was built for. Set by
  /// `prepareWriter(width:height:)`, cleared by `discardPreparedWriter()`
  /// and at the end of `stopRecording()`. The glasses VM uses this to
  /// detect mid-preview resolution changes and re-prepare the writer
  /// against the new dims, since `AVAssetWriter` rejects buffers whose
  /// dims don't match the writer's `AVVideoWidth/HeightKey`.
  private var preparedWriterDims: (width: Int, height: Int)?

  /// True when an `AVAssetWriter` has been pre-prepared and is waiting
  /// for samples (`startSession(atSourceTime:)` not yet called). Read
  /// by the glasses VM to gate `prepareWriter` debouncing.
  var isWriterPrepared: Bool { assetWriter != nil && !isRecording }

  /// Dims the prepared writer was built for, or nil if no writer is
  /// prepared. Read by the glasses VM to detect mid-preview resolution
  /// changes and re-prepare against the new dims.
  var preparedDims: (width: Int, height: Int)? { preparedWriterDims }

  private let audioSessionManager: AudioSessionManager

  private let recordingQueue = DispatchQueue(label: "com.retrace.recording")
  private var appendedFrameCount: Int64 = 0
  private var droppedFrameCount: Int64 = 0
  /// Shared flag flipped by whichever of {video, audio} arrives first —
  /// that sample's real PTS becomes the writer's session start, so both
  /// streams land on a single host-clock timeline.
  private var hasStartedSession = false
  private var durationTimer: Timer?
  private var statsTimer: Timer?
  /// Counted only on successful video appends. Read + reset from the stats
  /// timer every 5 s for the `[Recording] fps window` log.
  private var appendsInWindow: Int = 0

  /// One-shot diagnostic flag — flips true the first time a video
  /// `videoInput.append(...)` call returns false in this recording.
  /// Used to print `writer.error.code` exactly once (vs. spamming the
  /// console at 30 fps for the rest of the failed recording). Reset in
  /// `startRecording` so the next recording can log fresh.
  private var firstAppendFailureLogged: Bool = false

  // Video config matching DAT SDK StreamingResolution.high at 30fps.
  // Portrait is the historical default (glasses + iPhone expert portrait).
  // Landscape is used when the iPhone expert toggles "Landscape output"
  // — capture-output rotation is flipped in the same step (see
  // `IPhoneCameraCapture.setCaptureLandscapeOutput`) so frames arrive
  // already oriented landscape-right before they hit the writer.
  static let portraitSize: (width: Int, height: Int) = (720, 1280)
  static let landscapeSize: (width: Int, height: Int) = (1280, 720)

  init(audioSessionManager: AudioSessionManager) {
    self.audioSessionManager = audioSessionManager
  }

  // MARK: - Recording Control

  /// Errors from `startRecording`. Today only `audioStartFailed` is
  /// surfaced — any failure inside the AVAssetWriter setup still logs
  /// and returns false (writer-side failures aren't retryable here).
  enum StartRecordingError: LocalizedError {
    case audioStartFailed(Error)
    case writerSetupFailed

    var errorDescription: String? {
      switch self {
      case .audioStartFailed(let underlying):
        return "Audio failed to start. Tap Start again. (\(underlying.localizedDescription))"
      case .writerSetupFailed:
        return "Could not prepare the video writer. Tap Start again."
      }
    }
  }

  /// Build an `AVAssetWriter` + video/audio inputs off-main with the
  /// standard H.264 / AAC settings. Shared between `prepareWriter` and
  /// the legacy in-line creation path inside `startRecording`. Returns
  /// nil if any step fails — caller decides how to surface that.
  ///
  /// `outputURL` is generated here so callers don't have to manage temp
  /// filenames; it's returned alongside the writer.
  ///
  /// `videoSourceFormatHint`: optional `CMFormatDescription` describing
  /// the exact pixel format / dimensions / colorimetry the caller will
  /// feed into the video input. When provided, AVAssetWriter uses it
  /// to plan the encoder's input converter ahead of the first append,
  /// rather than auto-negotiating from the first sample buffer. Glasses
  /// path passes this in (the live `420v` `CMFormatDescription` from
  /// the DAT publisher); iPhone path passes nil and the writer auto-
  /// negotiates as before.
  private static func buildWriterOffMain(
    width: Int,
    height: Int,
    videoSourceFormatHint: CMFormatDescription? = nil
  ) async -> (writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput, url: URL)? {
    let fileName = "expert_\(Int(Date().timeIntervalSince1970)).mp4"
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    return await Task.detached(priority: .userInitiated) {
      try? FileManager.default.removeItem(at: outputURL)

      let writer: AVAssetWriter
      do {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
      } catch {
        print("[Recording] Failed to create AVAssetWriter: \(error)")
        return nil
      }

      let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
      ]
      let vInput = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: videoSettings,
        sourceFormatHint: videoSourceFormatHint
      )
      vInput.expectsMediaDataInRealTime = true
      if writer.canAdd(vInput) {
        writer.add(vInput)
      }

      // Audio sample rate — prefer the hardware rate, fall back to 16 kHz
      // if the session isn't ready yet. Reading this from a nonisolated
      // context is safe; `AVAudioSession.sharedInstance()` is thread-safe.
      let hwRate = AVAudioSession.sharedInstance().sampleRate
      let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: hwRate > 0 ? hwRate : 16000.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64000,
      ]
      let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      aInput.expectsMediaDataInRealTime = true
      if writer.canAdd(aInput) {
        writer.add(aInput)
      }

      guard writer.startWriting() else {
        print("[Recording] startWriting() returned false: \(writer.error?.localizedDescription ?? "unknown")")
        try? FileManager.default.removeItem(at: outputURL)
        return nil
      }
      // startSession is intentionally deferred until the first real sample
      // arrives (see appendVideoFrame / appendAudioBuffer).
      return (writer, vInput, aInput, outputURL)
    }.value
  }

  /// Pre-create the AVAssetWriter ahead of `startRecording()`. Glasses
  /// path calls this once first-frame dims are known, while the audio
  /// engine is still idle and BT/HFP isn't being grabbed. Avoids the
  /// rec-1 "Cannot Encode Media" failure where the writer is created
  /// concurrently with audio session activation, leaving the H.264
  /// hardware encoder in a state where every append fails.
  ///
  /// Idempotent: if a writer is already prepared with the same dims,
  /// no-op. If dims differ, the existing writer is discarded first.
  ///
  /// Returns true if a writer is ready (newly prepared or pre-existing).
  /// iPhone path never calls this — its `startRecording` continues to
  /// build the writer in-line.
  @discardableResult
  func prepareWriter(width: Int, height: Int) async -> Bool {
    // Don't disturb an in-flight recording.
    guard !isRecording, !isStarting else { return assetWriter != nil }

    // Already prepared with matching dims? No-op.
    if assetWriter != nil,
       let dims = preparedWriterDims,
       dims.width == width, dims.height == height {
      return true
    }

    // Different dims (or stale prepared writer): discard first.
    if assetWriter != nil {
      discardPreparedWriter()
    }

    guard let built = await Self.buildWriterOffMain(width: width, height: height) else {
      return false
    }

    assetWriter = built.writer
    videoInput = built.video
    audioInput = built.audio
    appendedFrameCount = 0
    droppedFrameCount = 0
    appendsInWindow = 0
    hasStartedSession = false
    recordingDuration = 0
    recordingURL = built.url
    preparedWriterDims = (width, height)

    print("[Recording] prepareWriter ✓ dims=\(width)x\(height) url=\(built.url.lastPathComponent)")
    return true
  }

  /// Cancel + discard a prepared (but not-yet-recording) writer. Removes
  /// the temp mp4. Safe no-op if no writer is prepared. Used on view
  /// teardown when the user exits without ever tapping Start, and after
  /// `stopRecording` to clean up before the glasses VM re-prepares for
  /// the next recording.
  ///
  /// Refuses to run mid-recording — `stopRecording` is the right path
  /// for an active session.
  func discardPreparedWriter() {
    guard !isRecording else {
      print("[Recording] discardPreparedWriter: ignored (recording active)")
      return
    }
    guard let writer = assetWriter else { return }

    videoInput?.markAsFinished()
    audioInput?.markAsFinished()
    writer.cancelWriting()
    if let url = recordingURL {
      try? FileManager.default.removeItem(at: url)
    }

    assetWriter = nil
    videoInput = nil
    audioInput = nil
    recordingURL = nil
    preparedWriterDims = nil
    hasStartedSession = false
    appendedFrameCount = 0
    droppedFrameCount = 0
    appendsInWindow = 0
    print("[Recording] discardPreparedWriter ✓")
  }

  /// Returns nil on success. Returns a `StartRecordingError` if the
  /// recording could not begin — the caller should surface that as an
  /// alert and not flip into a recording-active UI state.
  ///
  /// `postAudioSettleMs`: optional pause after `startCaptureAsync()`
  /// returns, before the writer is armed for the first sample. Glasses
  /// path passes a non-zero value (~100 ms) to let the HAL route-change
  /// cascade from `engine.start()` complete — the cascade can otherwise
  /// invalidate the AVAssetWriter's Video Toolbox session mid-first-batch
  /// (the "Cannot Encode Media" rec-1 failure). iPhone path passes 0
  /// (default) and is unaffected.
  @discardableResult
  func startRecording(
    width: Int = ExpertRecordingManager.portraitSize.width,
    height: Int = ExpertRecordingManager.portraitSize.height,
    postAudioSettleMs: UInt64 = 0
  ) async -> StartRecordingError? {
    guard !isRecording, !isStarting else { return nil }
    isStarting = true
    defer { isStarting = false }
    firstAppendFailureLogged = false

    // FAST PATH (glasses): a writer was pre-prepared via `prepareWriter`
    // before audio activation, so the H.264 encoder was initialized in
    // a calm BT-route state. Skip in-line writer creation and jump
    // straight to audio bring-up.
    //
    // SLOW PATH (iPhone, current behavior): no prepared writer; build
    // it in-line as before.
    let outputURL: URL
    if assetWriter != nil, let prepared = recordingURL {
      print("[Recording] startRecording reusing prepared writer (dims=\(preparedWriterDims?.width ?? -1)x\(preparedWriterDims?.height ?? -1))")
      outputURL = prepared
    } else {
      guard let built = await Self.buildWriterOffMain(width: width, height: height) else {
        return .writerSetupFailed
      }
      assetWriter = built.writer
      videoInput = built.video
      audioInput = built.audio
      outputURL = built.url
      recordingURL = built.url
    }

    // Reset stats regardless of which path we took (prepared writer
    // already has these zeroed, but resetting again is a cheap no-op
    // and keeps the failure-cleanup branches uniform).
    appendedFrameCount = 0
    droppedFrameCount = 0
    appendsInWindow = 0
    hasStartedSession = false
    recordingDuration = 0

    // Bring up audio capture off-main too (~200 ms on its own).
    // Throws on terminal failure (after one automatic retry) so we can
    // surface "audio failed" instead of silently producing a silent mp4.
    do {
      try await audioSessionManager.startCaptureAsync()
      // Optional post-audio settle window. Lets the HAL route-change
      // notifications (HFP finalization, categoryChange/
      // routeConfigurationChange) drain before the AVAssetWriter
      // accepts its first sample. Without this drain on the glasses
      // path, the route-change-driven XPC HAL reset that
      // `engine.start()` triggers can invalidate writer's Video
      // Toolbox session mid-first-batch (the rec-1 "Cannot Encode
      // Media" failure that produces appendedFrameCount=3 — exactly
      // the in-flight batch before the reset lands). iPhone passes
      // 0 (default) and skips this.
      if postAudioSettleMs > 0 {
        print("[Recording] settling \(postAudioSettleMs)ms post-audio-start before arming writer")
        try? await Task.sleep(nanoseconds: postAudioSettleMs * 1_000_000)
      }
    } catch {
      print("[Recording] Audio start failed: \(error.localizedDescription) — aborting")
      // Tear down the writer we just stood up (or were reusing from a
      // pre-prepared state) so the next Start tap re-creates a fresh
      // AVAssetWriter — writers can't be restarted once cancelled.
      videoInput?.markAsFinished()
      audioInput?.markAsFinished()
      assetWriter?.cancelWriting()
      try? FileManager.default.removeItem(at: outputURL)
      assetWriter = nil
      videoInput = nil
      audioInput = nil
      recordingURL = nil
      preparedWriterDims = nil
      return .audioStartFailed(error)
    }

    // Wire the audio buffer callback AFTER the engine is running — that
    // way we can't get a leftover buffer from a previous session racing
    // into the new writer.
    audioSessionManager.onAudioBuffer = { [weak self] buffer, time in
      self?.appendAudioBuffer(buffer, time: time)
    }

    isRecording = true

    durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.isRecording else { return }
        self.recordingDuration += 1
      }
    }

    statsTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
      guard let self else { return }
      let fps = self.appendsInWindow / 5
      self.appendsInWindow = 0
      print("[Recording] fps window: \(fps) fps")
    }

    print("[Recording] Started recording to \(outputURL.lastPathComponent)")
    return nil
  }

  func stopRecording() async -> URL? {
    guard isRecording, let writer = assetWriter else { return nil }

    isRecording = false
    durationTimer?.invalidate()
    durationTimer = nil
    statsTimer?.invalidate()
    statsTimer = nil

    // Stop audio capture
    audioSessionManager.onAudioBuffer = nil
    audioSessionManager.stopCapture()

    // Finalize writing
    videoInput?.markAsFinished()
    audioInput?.markAsFinished()

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      writer.finishWriting {
        continuation.resume()
      }
    }

    let url = recordingURL
    let status = writer.status
    let appended = appendedFrameCount
    let dropped = droppedFrameCount

    // Clean up writer refs before any return path. `preparedWriterDims`
    // also clears so the glasses VM's debounce in `prepareWriter` knows
    // it must build a fresh writer for the next recording.
    assetWriter = nil
    videoInput = nil
    audioInput = nil
    preparedWriterDims = nil

    // A recording is only usable if the writer finished cleanly AND at least one video frame landed.
    // If either is untrue the .mp4 will be missing its moov atom (or be empty) and fail upload.
    let ok = (status == .completed) && appended > 0
    if !ok {
      print("[Recording] Failed. status=\(status.rawValue) appendedFrames=\(appended) error=\(writer.error?.localizedDescription ?? "none")")
      if let url = url {
        try? FileManager.default.removeItem(at: url)
      }
      recordingURL = nil
      return nil
    }

    let fileSize: Int64 = {
      guard let url = url,
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? Int64
      else { return 0 }
      return size
    }()
    print("[Recording] Stopped. File: \(url?.lastPathComponent ?? "nil"), frames=\(appended), dropped=\(dropped), size=\(fileSize / 1024)KB")

    return url
  }

  // MARK: - Frame Appending

  /// Append a video frame straight from the DAT SDK.
  /// The `CMSampleBuffer` already carries decoded pixels and the real
  /// presentation timestamp — no image conversion, no pixel-buffer
  /// allocation, no CGContext redraw. The writer's first real sample PTS
  /// becomes the session start, so the file preserves true frame timing.
  func appendVideoFrame(_ sampleBuffer: CMSampleBuffer) {
    guard isRecording else { return }

    recordingQueue.async { [weak self] in
      guard let self,
            let writer = self.assetWriter,
            let videoInput = self.videoInput
      else { return }

      if !self.hasStartedSession {
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writer.startSession(atSourceTime: firstPTS)
        self.hasStartedSession = true
      }

      guard videoInput.isReadyForMoreMediaData else {
        self.droppedFrameCount += 1
        return
      }
      if videoInput.append(sampleBuffer) {
        self.appendedFrameCount += 1
        self.appendsInWindow += 1
      } else {
        self.droppedFrameCount += 1
        // One-shot diagnostic: print writer.error's NSError code +
        // domain on the FIRST failed append. Lets us tell apart:
        //   • -12780 kVTVideoEncoderMalfunctionErr → VT session
        //     invalidated by HAL reset (primary debugger hypothesis)
        //   • -12902 kVTVideoEncoderNotAvailableNowErr → VT session
        //     not in a usable state at append time
        //   • -12745 kAudioFormatUnsupportedDataFormatError → audio
        //     input sample-rate mismatch (secondary hypothesis)
        //   • anything else → a different cause we haven't named
        if !self.firstAppendFailureLogged {
          self.firstAppendFailureLogged = true
          let nsErr = writer.error as NSError?
          print("[Recording] first append failure: writer.status=\(writer.status.rawValue) error.code=\(nsErr?.code ?? 0) domain=\(nsErr?.domain ?? "?") desc=\(nsErr?.localizedDescription ?? "none") userInfo=\(nsErr?.userInfo ?? [:])")
        }
      }
    }
  }

  private func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
    recordingQueue.async { [weak self] in
      guard let self,
            let writer = self.assetWriter,
            let audioInput = self.audioInput
      else { return }

      guard let sampleBuffer = self.cmSampleBuffer(from: buffer, time: time) else { return }

      // If video hasn't started the session yet (audio arrived first),
      // use this audio sample's PTS to anchor. Host-clock-based for both.
      if !self.hasStartedSession {
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writer.startSession(atSourceTime: firstPTS)
        self.hasStartedSession = true
      }

      guard audioInput.isReadyForMoreMediaData else { return }
      audioInput.append(sampleBuffer)
    }
  }

  // MARK: - Audio Buffer Conversion

  private func cmSampleBuffer(from pcmBuffer: AVAudioPCMBuffer, time: AVAudioTime) -> CMSampleBuffer? {
    let format = pcmBuffer.format
    var asbd = format.streamDescription.pointee

    var formatDesc: CMAudioFormatDescription?
    let fmtStatus = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &asbd,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &formatDesc
    )
    guard fmtStatus == noErr, let desc = formatDesc else { return nil }

    // Use host-clock PTS directly — the writer's session start (set by the
    // first video or audio sample to arrive) is the single anchor, so both
    // streams land on one timeline without a per-stream rebase.
    let hostTime = time.hostTime
    let cmTime = CMClockMakeHostTimeFromSystemUnits(hostTime)

    let frameCount = pcmBuffer.frameLength
    var timing = CMSampleTimingInfo(
      duration: CMTimeMake(value: 1, timescale: Int32(asbd.mSampleRate)),
      presentationTimeStamp: cmTime,
      decodeTimeStamp: .invalid
    )

    var sampleBuffer: CMSampleBuffer?
    let sbStatus = CMSampleBufferCreate(
      allocator: kCFAllocatorDefault,
      dataBuffer: nil,
      dataReady: false,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: desc,
      sampleCount: CMItemCount(frameCount),
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sampleBuffer
    )

    guard sbStatus == noErr, let sb = sampleBuffer else { return nil }

    // Set the audio buffer data
    var abl = AudioBufferList()
    abl.mNumberBuffers = 1
    abl.mBuffers.mNumberChannels = asbd.mChannelsPerFrame
    abl.mBuffers.mDataByteSize = pcmBuffer.frameLength * UInt32(asbd.mBytesPerFrame)
    abl.mBuffers.mData = UnsafeMutableRawPointer(pcmBuffer.floatChannelData?[0])

    let setStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
      sb,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0,
      bufferList: &abl
    )

    guard setStatus == noErr else { return nil }
    return sb
  }
}

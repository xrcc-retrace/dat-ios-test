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

  private var assetWriter: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?

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

  func startRecording(
    width: Int = ExpertRecordingManager.portraitSize.width,
    height: Int = ExpertRecordingManager.portraitSize.height
  ) async {
    guard !isRecording, !isStarting else { return }
    isStarting = true
    defer { isStarting = false }

    let fileName = "expert_\(Int(Date().timeIntervalSince1970)).mp4"
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

    // Heavy, blocking setup off the main actor: file removal, AVAssetWriter
    // init, writer input creation, and startWriting(). These are all
    // documented thread-safe and collectively account for ~100 ms of the
    // old freeze.
    let writerVideoWidth = width
    let writerVideoHeight = height

    let built: (writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput)? =
      await Task.detached(priority: .userInitiated) {
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
          AVVideoWidthKey: writerVideoWidth,
          AVVideoHeightKey: writerVideoHeight,
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
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
        return (writer, vInput, aInput)
      }.value

    guard let built = built else { return }

    // Back on the main actor: publish the writer + clear stats.
    assetWriter = built.writer
    videoInput = built.video
    audioInput = built.audio
    appendedFrameCount = 0
    droppedFrameCount = 0
    appendsInWindow = 0
    hasStartedSession = false
    recordingDuration = 0
    recordingURL = outputURL

    // Bring up audio capture off-main too (~200 ms on its own).
    await audioSessionManager.startCaptureAsync()

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

    // Clean up writer refs before any return path
    assetWriter = nil
    videoInput = nil
    audioInput = nil

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

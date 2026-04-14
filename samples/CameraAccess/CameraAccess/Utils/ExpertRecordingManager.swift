import AVFoundation
import CoreMedia
import SwiftUI

@MainActor
class ExpertRecordingManager: ObservableObject {
  @Published var isRecording = false
  @Published var recordingDuration: TimeInterval = 0
  @Published var recordingURL: URL?

  private var assetWriter: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

  private let audioCaptureManager: AudioCaptureManager

  private let recordingQueue = DispatchQueue(label: "com.retrace.recording")
  private var frameCount: Int64 = 0
  private var audioStartTime: CMTime?
  private var hasStartedSession = false
  private var durationTimer: Timer?

  // Video config matching DAT SDK StreamingResolution.low at 24fps
  private let videoWidth = 640
  private let videoHeight = 480
  private let videoFPS: Int32 = 24

  init(audioCaptureManager: AudioCaptureManager) {
    self.audioCaptureManager = audioCaptureManager
  }

  // MARK: - Recording Control

  func startRecording() {
    guard !isRecording else { return }

    let fileName = "expert_\(Int(Date().timeIntervalSince1970)).mp4"
    let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

    // Clean up any existing file at this path
    try? FileManager.default.removeItem(at: outputURL)

    do {
      assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    } catch {
      print("[Recording] Failed to create AVAssetWriter: \(error)")
      return
    }

    guard let writer = assetWriter else { return }

    // Video input
    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: videoWidth,
      AVVideoHeightKey: videoHeight,
    ]
    let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    vInput.expectsMediaDataInRealTime = true
    videoInput = vInput

    pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: vInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: videoWidth,
        kCVPixelBufferHeightKey as String: videoHeight,
      ]
    )

    if writer.canAdd(vInput) {
      writer.add(vInput)
    }

    // Audio input — read actual hardware format after audio session is configured
    let sampleRate = audioCaptureManager.hardwareSampleRate
    let audioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate > 0 ? sampleRate : 16000.0,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64000,
    ]
    let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    aInput.expectsMediaDataInRealTime = true
    audioInput = aInput

    if writer.canAdd(aInput) {
      writer.add(aInput)
    }

    // Start writing
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    hasStartedSession = true

    // Reset state
    frameCount = 0
    audioStartTime = nil
    recordingDuration = 0
    recordingURL = outputURL

    // Wire up audio capture
    audioCaptureManager.onAudioBuffer = { [weak self] buffer, time in
      self?.appendAudioBuffer(buffer, time: time)
    }
    audioCaptureManager.startCapture()

    isRecording = true

    // Duration timer
    durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.isRecording else { return }
        self.recordingDuration += 1
      }
    }

    print("[Recording] Started recording to \(outputURL.lastPathComponent)")
  }

  func stopRecording() async -> URL? {
    guard isRecording, let writer = assetWriter else { return nil }

    isRecording = false
    durationTimer?.invalidate()
    durationTimer = nil

    // Stop audio capture
    audioCaptureManager.onAudioBuffer = nil
    audioCaptureManager.stopCapture()

    // Finalize writing
    videoInput?.markAsFinished()
    audioInput?.markAsFinished()

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      writer.finishWriting {
        continuation.resume()
      }
    }

    let url = recordingURL
    print("[Recording] Stopped. File: \(url?.lastPathComponent ?? "nil"), status: \(writer.status.rawValue)")

    if writer.status == .failed {
      print("[Recording] Writer error: \(writer.error?.localizedDescription ?? "unknown")")
      return nil
    }

    // Clean up
    assetWriter = nil
    videoInput = nil
    audioInput = nil
    pixelBufferAdaptor = nil

    return url
  }

  // MARK: - Frame Appending

  func appendVideoFrame(_ image: UIImage) {
    guard isRecording else { return }

    let currentFrame = frameCount
    frameCount += 1

    // Dispatch pixel buffer conversion + append to background queue
    recordingQueue.async { [weak self] in
      guard let self else { return }
      guard let videoInput = self.videoInput,
            let adaptor = self.pixelBufferAdaptor,
            videoInput.isReadyForMoreMediaData
      else { return }

      guard let pixelBuffer = self.pixelBuffer(from: image) else { return }

      let presentationTime = CMTimeMake(value: currentFrame, timescale: self.videoFPS)
      adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
    }
  }

  private func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
    recordingQueue.async { [weak self] in
      guard let self else { return }
      guard let audioInput = self.audioInput,
            audioInput.isReadyForMoreMediaData
      else { return }

      // Convert AVAudioPCMBuffer to CMSampleBuffer
      guard let sampleBuffer = self.cmSampleBuffer(from: buffer, time: time) else { return }
      audioInput.append(sampleBuffer)
    }
  }

  // MARK: - Pixel Buffer Conversion

  private func pixelBuffer(from image: UIImage) -> CVPixelBuffer? {
    guard let cgImage = image.cgImage else { return nil }

    var pixelBuffer: CVPixelBuffer?
    let attrs: [String: Any] = [
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]

    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      videoWidth,
      videoHeight,
      kCVPixelFormatType_32BGRA,
      attrs as CFDictionary,
      &pixelBuffer
    )

    guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard let context = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer),
      width: videoWidth,
      height: videoHeight,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: videoWidth, height: videoHeight))
    return buffer
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

    // Compute presentation time relative to first audio buffer
    let hostTime = time.hostTime
    let cmTime = CMClockMakeHostTimeFromSystemUnits(hostTime)

    if audioStartTime == nil {
      audioStartTime = cmTime
    }
    let relativeTime = CMTimeSubtract(cmTime, audioStartTime!)

    let frameCount = pcmBuffer.frameLength
    var timing = CMSampleTimingInfo(
      duration: CMTimeMake(value: 1, timescale: Int32(asbd.mSampleRate)),
      presentationTimeStamp: relativeTime,
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

import AVFoundation
import Foundation

@MainActor
class AudioSessionManager: ObservableObject {
  @Published var isCapturing = false
  @Published var isBluetoothConnected = false
  @Published var isAISpeaking = false

  private let engine = AVAudioEngine()
  private var inputNode: AVAudioInputNode { engine.inputNode }

  // MARK: - Playback

  private let playerNode = AVAudioPlayerNode()
  private let playbackFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 24_000,
    channels: 1,
    interleaved: true
  )!

  /// Tracks scheduled buffers so we know when AI stops speaking.
  private var scheduledBufferCount = 0

  // MARK: - Send format (mic → Gemini)

  private let sendFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16_000,
    channels: 1,
    interleaved: true
  )!
  private var audioConverter: AVAudioConverter?

  /// Called on the audio capture queue with each PCM buffer.
  var onAudioBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

  /// The actual hardware sample rate (read after configureAudioSession).
  var hardwareSampleRate: Double {
    AVAudioSession.sharedInstance().sampleRate
  }

  /// The hardware input format (read after configureAudioSession + engine prep).
  var inputFormat: AVAudioFormat {
    inputNode.inputFormat(forBus: 0)
  }

  init() {
    // Attach player node to engine before starting
    engine.attach(playerNode)
    engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleRouteChange),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Audio Session

  func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
      )
      try session.setActive(true)
      checkBluetoothRoute()
      logAudioRoute()
      print("[AudioSession] Audio session configured. Sample rate: \(session.sampleRate)")
    } catch {
      print("[AudioSession] Failed to configure audio session: \(error)")
    }
  }

  // MARK: - Permissions

  func requestMicrophonePermission() async -> Bool {
    return await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  // MARK: - Capture

  func startCapture() {
    guard !isCapturing else { return }

    configureAudioSession()

    // Use nil format to accept the hardware's native format
    // This avoids format mismatch errors with Bluetooth HFP devices
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
      self?.onAudioBuffer?(buffer, time)
    }

    do {
      try engine.start()
      playerNode.play()
      isCapturing = true

      // Lazily initialize audio converter now that we know the hardware format
      initializeConverterIfNeeded()

      logInputRoute()
      print("[AudioSession] Audio engine started with playback")
    } catch {
      print("[AudioSession] Audio engine start error: \(error)")
      inputNode.removeTap(onBus: 0)
    }
  }

  func stopCapture() {
    guard isCapturing else { return }
    inputNode.removeTap(onBus: 0)
    playerNode.stop()
    engine.stop()
    isCapturing = false
    isAISpeaking = false
    scheduledBufferCount = 0
    print("[AudioSession] Audio engine stopped")
  }

  // MARK: - Playback (PCM16LE 24kHz mono from Gemini)

  /// Play raw PCM16 Int16 audio data received from Gemini Live.
  /// Thread-safe — can be called from any thread.
  func playPcm16Audio(_ data: Data) {
    let bytesPerFrame = 2  // Int16
    let frameCount = AVAudioFrameCount(data.count / bytesPerFrame)
    guard frameCount > 0 else { return }

    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: playbackFormat,
      frameCapacity: frameCount
    ) else {
      print("[AudioSession] Failed to create playback buffer")
      return
    }

    buffer.frameLength = frameCount
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      memcpy(buffer.int16ChannelData![0], base, data.count)
    }

    scheduledBufferCount += 1
    Task { @MainActor in
      self.isAISpeaking = true
    }

    playerNode.scheduleBuffer(buffer) { [weak self] in
      guard let self = self else { return }
      Task { @MainActor in
        self.scheduledBufferCount -= 1
        if self.scheduledBufferCount <= 0 {
          self.scheduledBufferCount = 0
          self.isAISpeaking = false
        }
      }
    }
  }

  /// Flush all queued playback buffers and restart the player.
  func clearPlaybackBuffer() {
    playerNode.stop()
    scheduledBufferCount = 0
    Task { @MainActor in
      self.isAISpeaking = false
    }
    playerNode.play()
    print("[AudioSession] Playback buffer cleared")
  }

  // MARK: - Format Conversion (mic → PCM16 16kHz mono for Gemini)

  /// Convert a mic capture buffer to PCM16 16kHz mono Data for sending to Gemini.
  /// Returns nil if conversion fails.
  func convertBufferForSend(_ buffer: AVAudioPCMBuffer) -> Data? {
    guard let converter = audioConverter else {
      // Fallback: try to initialize now
      initializeConverterIfNeeded()
      guard let converter = audioConverter else { return nil }
      return convertWithConverter(converter, buffer: buffer)
    }
    return convertWithConverter(converter, buffer: buffer)
  }

  private func convertWithConverter(_ converter: AVAudioConverter, buffer: AVAudioPCMBuffer) -> Data? {
    let ratio = sendFormat.sampleRate / buffer.format.sampleRate
    let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
    guard outputFrameCount > 0 else { return nil }

    guard let outputBuffer = AVAudioPCMBuffer(
      pcmFormat: sendFormat,
      frameCapacity: outputFrameCount
    ) else { return nil }

    var error: NSError?
    var hasData = false

    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      if hasData {
        outStatus.pointee = .noDataNow
        return nil
      }
      hasData = true
      outStatus.pointee = .haveData
      return buffer
    }

    if let error = error {
      print("[AudioSession] Audio conversion error: \(error)")
      return nil
    }

    guard outputBuffer.frameLength > 0 else { return nil }

    // Extract raw Int16 bytes
    let byteCount = Int(outputBuffer.frameLength) * 2  // Int16 = 2 bytes
    guard let channelData = outputBuffer.int16ChannelData else { return nil }
    return Data(bytes: channelData[0], count: byteCount)
  }

  private func initializeConverterIfNeeded() {
    guard audioConverter == nil else { return }
    let hwFormat = inputNode.inputFormat(forBus: 0)
    guard hwFormat.sampleRate > 0 else {
      print("[AudioSession] Hardware format not ready, deferring converter init")
      return
    }
    audioConverter = AVAudioConverter(from: hwFormat, to: sendFormat)
    print("[AudioSession] Audio converter initialized: \(hwFormat.sampleRate)Hz → \(sendFormat.sampleRate)Hz")
  }

  // MARK: - Route Monitoring

  @objc private func handleRouteChange(notification: Notification) {
    guard let info = notification.userInfo,
          let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
    else { return }

    switch reason {
    case .oldDeviceUnavailable:
      print("[AudioSession] Audio device disconnected, reconfiguring...")
      configureAudioSession()
      Task { @MainActor in
        self.checkBluetoothRoute()
      }
    case .newDeviceAvailable:
      print("[AudioSession] New audio device available")
      Task { @MainActor in
        self.checkBluetoothRoute()
      }
    default:
      break
    }
  }

  private func checkBluetoothRoute() {
    let route = AVAudioSession.sharedInstance().currentRoute
    let hasBluetoothInput = route.inputs.contains { input in
      input.portType == .bluetoothHFP || input.portType == .bluetoothA2DP
    }
    let hasBluetoothOutput = route.outputs.contains { output in
      output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP
    }
    isBluetoothConnected = hasBluetoothInput || hasBluetoothOutput
  }

  private func logAudioRoute() {
    let route = AVAudioSession.sharedInstance().currentRoute
    for input in route.inputs {
      print("[AudioSession] Input: \(input.portName) (\(input.portType.rawValue))")
    }
    for output in route.outputs {
      print("[AudioSession] Output: \(output.portName) (\(output.portType.rawValue))")
    }
  }

  private func logInputRoute() {
    let route = AVAudioSession.sharedInstance().currentRoute
    for input in route.inputs {
      if input.portType == .bluetoothHFP {
        print("[AudioSession] ✓ Input: Bluetooth HFP (glasses mic)")
      } else if input.portType == .builtInMic {
        print("[AudioSession] ⚠ Input: Built-in phone mic")
      } else {
        print("[AudioSession] Input: \(input.portName) (\(input.portType.rawValue))")
      }
    }
    for output in route.outputs {
      if output.portType == .bluetoothHFP || output.portType == .bluetoothA2DP {
        print("[AudioSession] ✓ Output: Bluetooth (\(output.portName))")
      } else if output.portType == .builtInSpeaker {
        print("[AudioSession] Output: Built-in speaker (fallback)")
      } else {
        print("[AudioSession] Output: \(output.portName) (\(output.portType.rawValue))")
      }
    }
  }
}

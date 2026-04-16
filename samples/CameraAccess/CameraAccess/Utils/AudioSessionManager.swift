import AVFoundation
import Foundation

/// How the AudioSessionManager should configure its AVAudioSession.
/// `.coaching` is full-duplex with AEC and speaker fallback — needed for Gemini Live voice chat.
/// `.recording` is simplex capture — no playback, no AEC, no `.defaultToSpeaker` overrides.
/// The latter avoids the route-change thrash that detaches the mic tap during expert recording.
enum AudioSessionMode {
  case coaching
  case recording
}

@MainActor
class AudioSessionManager: ObservableObject {
  @Published var isCapturing = false
  @Published var isBluetoothConnected = false
  @Published var isAISpeaking = false

  let mode: AudioSessionMode

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

  // MARK: - Observability

  private var firstMicBufferLogged = false
  private var firstPlaybackLogged = false
  private var captureBuffersSinceLastFlush = 0
  private var captureFramesSinceLastFlush: AVAudioFrameCount = 0
  private var lastCaptureRate: Double = 0
  private var lastBufferReceivedAt: Date?
  private var silentMicWarned = false
  private var invalidFormatWarned = false
  private var playbackAllocFailures = 0
  private var statsTask: Task<Void, Never>?

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

  init(mode: AudioSessionMode = .coaching) {
    self.mode = mode

    // Attach player node only in coaching mode. Recording has no playback
    // and attaching the node forces `.playAndRecord`, which pulls in output-port
    // negotiation and triggers the route-change cascade we're trying to avoid.
    if mode == .coaching {
      engine.attach(playerNode)
      engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat)
    }

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
      switch mode {
      case .coaching:
        // Full-duplex with hardware AEC, speaker fallback when no HFP is paired.
        try session.setCategory(
          .playAndRecord,
          mode: .voiceChat,
          options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        )
      case .recording:
        // Simplex capture. No `.voiceChat` (no AEC processing), no `.defaultToSpeaker`
        // (nothing to play, and this option forces an override-to-speaker that
        // triggers the categoryChange cascade which detaches the mic tap).
        try session.setCategory(
          .record,
          mode: .default,
          options: [.allowBluetoothHFP, .allowBluetoothA2DP]
        )
      }
      try session.setActive(true)
      checkBluetoothRoute()
      logAudioRoute()
      let modeLabel = mode == .coaching
        ? "coaching (AEC, speaker fallback)"
        : "recording (simplex capture)"
      print(
        "[AudioSession] Configured for \(modeLabel): category=\(session.category.rawValue), "
        + "mode=\(session.mode.rawValue), sampleRate=\(session.sampleRate)Hz"
      )
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
    installMicTap()

    do {
      try engine.start()
      if mode == .coaching {
        playerNode.play()
      }
      isCapturing = true

      // Lazily initialize audio converter now that we know the hardware format
      initializeConverterIfNeeded()

      // Flag a silent-capture failure mode early.
      let inFmt = inputNode.inputFormat(forBus: 0)
      if inFmt.sampleRate == 0 || inFmt.channelCount == 0, !invalidFormatWarned {
        invalidFormatWarned = true
        print(
          "[AudioSession] ⚠ Invalid input format after engine start "
          + "(rate=\(inFmt.sampleRate), channels=\(inFmt.channelCount)) — "
          + "capture will be silent"
        )
      }

      startStatsTimer()
      logInputRoute()
      let suffix = mode == .coaching ? "with playback" : "(capture only)"
      print("[AudioSession] Audio engine started \(suffix)")
    } catch {
      print("[AudioSession] Audio engine start error: \(error)")
      inputNode.removeTap(onBus: 0)
    }
  }

  /// Install the mic tap at the current input-node format.
  /// Safe to call repeatedly — removes any existing tap first.
  /// Used both at `startCapture()` time and when a route change alters
  /// the input format, so the tap stays bound to the live bus.
  private func installMicTap() {
    inputNode.removeTap(onBus: 0)
    // Use nil format to accept the hardware's native format; avoids format mismatch on BT HFP.
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, time in
      guard let self = self else { return }
      self.recordCapturedBuffer(buffer)
      self.onAudioBuffer?(buffer, time)
    }
  }

  func stopCapture() {
    guard isCapturing else { return }
    inputNode.removeTap(onBus: 0)
    if mode == .coaching {
      playerNode.stop()
    }
    engine.stop()
    isCapturing = false
    isAISpeaking = false
    scheduledBufferCount = 0
    stopStatsTimer()
    print("[AudioSession] Audio engine stopped")

    // After recording the session is still in `.record` (input-only), which blocks
    // AVPlayer audio in the review sheet (both the recording preview and any step
    // clips). Flip to `.playback` here. A subsequent `startCapture()` resets the
    // category via `configureAudioSession()`, so the record ↔ review ↔ record
    // cycle stays intact.
    if mode == .recording {
      let session = AVAudioSession.sharedInstance()
      do {
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
        print("[AudioSession] Switched to .playback for review")
      } catch {
        print("[AudioSession] Failed to switch to .playback: \(error)")
      }
    }
  }

  // MARK: - Capture telemetry

  /// Called from the tap thread on every captured buffer.
  /// Extract primitives here so we don't capture the non-Sendable
  /// `AVAudioPCMBuffer` into the main-actor hop closure.
  nonisolated private func recordCapturedBuffer(_ buffer: AVAudioPCMBuffer) {
    let frames = buffer.frameLength
    let rate = buffer.format.sampleRate
    let channels = buffer.format.channelCount
    let commonFormat: String
    switch buffer.format.commonFormat {
    case .pcmFormatInt16: commonFormat = "Int16"
    case .pcmFormatFloat32: commonFormat = "Float32"
    case .pcmFormatInt32: commonFormat = "Int32"
    case .pcmFormatFloat64: commonFormat = "Float64"
    default: commonFormat = "other"
    }
    Task { @MainActor [weak self] in
      guard let self = self else { return }
      self.lastBufferReceivedAt = Date()
      self.captureBuffersSinceLastFlush += 1
      self.captureFramesSinceLastFlush += frames
      self.lastCaptureRate = rate
      self.silentMicWarned = false  // buffers are flowing; re-arm watchdog
      if !self.firstMicBufferLogged {
        self.firstMicBufferLogged = true
        print(
          "[AudioSession] First mic buffer: hwRate=\(rate)Hz, "
          + "frames=\(frames), format=\(commonFormat), channels=\(channels)"
        )
      }
    }
  }

  private func startStatsTimer() {
    guard statsTask == nil else { return }
    statsTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 s
        if Task.isCancelled { return }
        self?.flushCaptureStats()
        self?.checkSilentMicWatchdog()
      }
    }
  }

  private func stopStatsTimer() {
    statsTask?.cancel()
    statsTask = nil
    captureBuffersSinceLastFlush = 0
    captureFramesSinceLastFlush = 0
    firstMicBufferLogged = false
    firstPlaybackLogged = false
    silentMicWarned = false
    invalidFormatWarned = false
    lastBufferReceivedAt = nil
    playbackAllocFailures = 0
  }

  private func flushCaptureStats() {
    guard isCapturing else { return }
    if captureBuffersSinceLastFlush > 0 {
      print(
        "[AudioSession] Capture: \(captureBuffersSinceLastFlush) buffers, "
        + "\(captureFramesSinceLastFlush) frames, rate=\(lastCaptureRate)Hz "
        + "| Playback queue: \(scheduledBufferCount) chunks pending"
      )
    } else {
      print("[AudioSession] Capture: 0 buffers in last 5s "
        + "| Playback queue: \(scheduledBufferCount) chunks pending")
    }
    captureBuffersSinceLastFlush = 0
    captureFramesSinceLastFlush = 0
  }

  private func checkSilentMicWatchdog() {
    guard isCapturing, !silentMicWarned else { return }
    if let last = lastBufferReceivedAt,
       Date().timeIntervalSince(last) > 3.0 {
      silentMicWarned = true
      print(
        "[AudioSession] ⚠ No mic buffers for 3s — check BT HFP route or "
        + "glasses mic permission"
      )
    } else if lastBufferReceivedAt == nil,
              Date().timeIntervalSince(Date().addingTimeInterval(-3.0)) >= 0,
              captureBuffersSinceLastFlush == 0 {
      // Engine started but no first buffer ever arrived.
      silentMicWarned = true
      print(
        "[AudioSession] ⚠ No mic buffers since capture started — "
        + "check mic permission / hardware route"
      )
    }
  }

  // MARK: - Playback (PCM16LE 24kHz mono from Gemini)

  /// Play raw PCM16 Int16 audio data received from Gemini Live.
  /// Thread-safe — can be called from any thread. No-op in `.recording` mode.
  func playPcm16Audio(_ data: Data) {
    guard mode == .coaching else {
      print("[AudioSession] ⚠ playPcm16Audio called in .recording mode — ignoring")
      return
    }
    let bytesPerFrame = 2  // Int16
    let frameCount = AVAudioFrameCount(data.count / bytesPerFrame)
    guard frameCount > 0 else {
      Task { @MainActor [weak self] in
        guard let self = self else { return }
        self.playbackAllocFailures += 1
        if self.playbackAllocFailures == 1 {
          print("[AudioSession] ⚠ playPcm16Audio: zero-frame chunk (bytes=\(data.count))")
        }
      }
      return
    }

    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: playbackFormat,
      frameCapacity: frameCount
    ) else {
      Task { @MainActor [weak self] in
        guard let self = self else { return }
        self.playbackAllocFailures += 1
        print(
          "[AudioSession] ⚠ Failed to allocate playback buffer "
          + "(frames=\(frameCount), total failures=\(self.playbackAllocFailures))"
        )
      }
      return
    }

    buffer.frameLength = frameCount
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      memcpy(buffer.int16ChannelData![0], base, data.count)
    }

    scheduledBufferCount += 1
    Task { @MainActor [weak self] in
      guard let self = self else { return }
      self.isAISpeaking = true
      if !self.firstPlaybackLogged {
        self.firstPlaybackLogged = true
        print(
          "[AudioSession] First playback scheduled: \(data.count) bytes, "
          + "\(frameCount) frames @ 24kHz"
        )
      }
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
  /// Pass `reason` so logs make it clear WHY we dropped the queue
  /// (barge-in, tool-call handoff, or session teardown).
  func clearPlaybackBuffer(reason: String = "unspecified") {
    guard mode == .coaching else {
      print("[AudioSession] ⚠ clearPlaybackBuffer called in .recording mode — ignoring")
      return
    }
    let discarded = scheduledBufferCount
    playerNode.stop()
    scheduledBufferCount = 0
    Task { @MainActor in
      self.isAISpeaking = false
    }
    playerNode.play()
    print(
      "[AudioSession] Playback cleared (reason: \(reason)), "
      + "discarded \(discarded) queued chunks"
    )
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

    let reasonLabel = routeChangeReasonLabel(reason)
    print("[AudioSession] Route change: \(reasonLabel)")

    // NOTE: Do NOT call configureAudioSession() from inside a route-change handler.
    // Reconfiguring the session here triggers another categoryChange notification,
    // which cascades and can leave the mic tap orphaned from the live input format.
    // Let iOS own the routing; we just rebind the tap to the new input format.

    Task { @MainActor in
      self.checkBluetoothRoute()
      self.logAudioRoute()

      // Route changes that can alter the input format or invalidate the tap.
      // When capturing, drop the old tap, reinit the converter against the new
      // input format, and reinstall — so the tap stays bound to the live bus.
      switch reason {
      case .newDeviceAvailable,
           .oldDeviceUnavailable,
           .override,
           .categoryChange,
           .routeConfigurationChange:
        self.rebindMicTapIfCapturing(reason: reasonLabel)
      default:
        break
      }
    }
  }

  /// Re-bind the mic tap to the current input-node format after a route change.
  /// Safe no-op when we aren't capturing or the engine isn't running.
  private func rebindMicTapIfCapturing(reason: String) {
    guard isCapturing else { return }
    guard engine.isRunning else {
      print("[AudioSession] Route change (\(reason)) while engine is stopped — skipping tap rebind")
      return
    }

    let beforeFmt = inputNode.inputFormat(forBus: 0)

    // Install at the new format. `installMicTap()` removes any existing tap first.
    installMicTap()

    let afterFmt = inputNode.inputFormat(forBus: 0)

    // The hardware format may have changed (HFP ↔ built-in); rebuild the converter.
    audioConverter = nil
    initializeConverterIfNeeded()

    // Re-arm the silent-mic watchdog so it evaluates against the new route.
    silentMicWarned = false
    lastBufferReceivedAt = nil

    print(
      "[AudioSession] Tap re-installed after \(reason): "
      + "rate \(beforeFmt.sampleRate)Hz → \(afterFmt.sampleRate)Hz, "
      + "channels \(beforeFmt.channelCount) → \(afterFmt.channelCount)"
    )
  }

  private func routeChangeReasonLabel(_ reason: AVAudioSession.RouteChangeReason) -> String {
    switch reason {
    case .unknown: return "unknown"
    case .newDeviceAvailable: return "newDeviceAvailable"
    case .oldDeviceUnavailable: return "oldDeviceUnavailable"
    case .categoryChange: return "categoryChange"
    case .override: return "override"
    case .wakeFromSleep: return "wakeFromSleep"
    case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
    case .routeConfigurationChange: return "routeConfigurationChange"
    @unknown default: return "other(\(reason.rawValue))"
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
